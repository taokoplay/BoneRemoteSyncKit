import Foundation
import BoneRemoteSyncCore

final class ODHTTPState: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let sink: ODDownloadSink?
    private let uploadProgress: (@Sendable (Int64) -> Void)?
    private var written: Int64 = 0
    private var data = Data()
    private var response: HTTPURLResponse?
    private var terminal: Result<ODHTTPResponse, Error>?
    private var waiter: CheckedContinuation<ODHTTPResponse, Error>?
    private var session: URLSession?
    init(limit: Int, sink: ODDownloadSink?, uploadProgress: (@Sendable (Int64) -> Void)? = nil) {
        self.limit = limit; self.sink = sink; self.uploadProgress = uploadProgress
    }
    func start(_ request: URLRequest, timeout: TimeInterval, body: ODUploadBody? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        lock.withLock { self.session = session }
        let task: URLSessionTask
        switch body {
        case .none: task = session.dataTask(with: request)
        case .data(let payload)?: task = session.uploadTask(with: request, from: payload)
        case .file(let url)?: task = session.uploadTask(with: request, fromFile: url)
        }
        task.resume()
    }
    func result() async throws -> ODHTTPResponse {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { if let terminal { continuation.resume(with: terminal) } else { waiter = continuation } }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<ODHTTPResponse, Error>) {
        let session: URLSession? = lock.withLock {
            guard terminal == nil else { return nil }
            terminal = result; waiter?.resume(with: result); waiter = nil
            let session = self.session; self.session = nil; return session
        }
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        uploadProgress?(totalBytesSent)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); cancel(); return }
        let accepted = lock.withLock { () -> Bool in
            guard terminal == nil else { return false }
            self.response = response; return true
        }
        guard accepted else { completionHandler(.cancel); return }
        if let sink {
            // Reject failed/redirect responses before creating staging or reading arbitrary error bodies.
            guard response.statusCode == 200 else { finish(.success(ODHTTPResponse(response: response, data: Data()))); completionHandler(.cancel); return }
            do {
                let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                guard encoding == nil || encoding == "identity", response.value(forHTTPHeaderField: "Content-Range") == nil,
                      response.expectedContentLength <= sink.expected,
                      !sink.verifySize || response.expectedContentLength < 0 || response.expectedContentLength == sink.expected else {
                    throw RemoteSyncError.integrityMismatch(path: sink.target.destination.path)
                }
                let opened = try lock.withLock {
                    guard terminal == nil else { return false }
                    try sink.target.open()
                    return true
                }
                guard opened else { completionHandler(.cancel); return }
                // Report the phase even for an empty response, outside the state lock.
                sink.progress?(0)
                completionHandler(.allow)
            } catch { finish(.failure(error)); completionHandler(.cancel) }
        } else if response.expectedContentLength > Int64(limit) {
            finish(.failure(RemoteSyncError.unsupported(operation: "OneDrive 响应超过大小限制"))); completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            let progress: (Int64, (@Sendable (Int64) -> Void)?)? = try lock.withLock {
                guard terminal == nil else { return nil }
                if let sink {
                    guard Int64(data.count) <= sink.expected - written else { throw RemoteSyncError.integrityMismatch(path: sink.target.destination.path) }
                    try sink.target.write(data); written += Int64(data.count)
                    return (written, sink.progress)
                }
                guard data.count <= limit - self.data.count else { throw RemoteSyncError.unsupported(operation: "OneDrive 响应超过大小限制") }
                self.data.append(data); return nil
            }
            if let (count, callback) = progress { callback?(count) }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let result: Result<ODHTTPResponse, Error> = lock.withLock {
            if terminal != nil { return .failure(CancellationError()) }
            if let sink {
                do {
                    if sink.verifySize, written != sink.expected { throw RemoteSyncError.integrityMismatch(path: sink.target.destination.path) }
                    if let response, response.expectedContentLength >= 0, written != response.expectedContentLength {
                        throw RemoteSyncError.integrityMismatch(path: sink.target.destination.path)
                    }
                    try sink.target.sync()
                } catch { return .failure(error) }
            }
            guard let response else { return .failure(RemoteSyncError.network("OneDrive 缺少 HTTP 响应")) }
            return .success(ODHTTPResponse(response: response, data: data, transferredBytes: sink == nil ? nil : written))
        }
        finish(result)
    }
}
