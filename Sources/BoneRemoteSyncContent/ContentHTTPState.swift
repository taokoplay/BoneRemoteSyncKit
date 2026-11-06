import Foundation
import BoneRemoteSyncCore

/// Response buffers and file writes are confined to one serial delegate queue.
final class ContentHTTPState: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let kind: ContentResponseKind
    private let sink: ContentDownloadSink?
    private let lock = NSLock()
    private var session: URLSession?
    private var cancelled = false
    private var terminal: Result<ContentHTTPResponse, any Error>?
    private var waiter: CheckedContinuation<ContentHTTPResponse, any Error>?
    // Delegate-queue state.
    private var response: HTTPURLResponse?
    private var data = Data()
    private var prefix = Data()
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: (any Error)?
    private var completed: Result<ContentHTTPResponse, any Error>?
    private var invalidJSONType = false

    init(limit: Int, kind: ContentResponseKind, sink: ContentDownloadSink?) {
        self.limit = limit; self.kind = kind; self.sink = sink
    }
    func start(_ request: URLRequest, timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let mayStart = lock.withLock { self.session = session; return !cancelled }
        if mayStart { session.dataTask(with: request).resume() }
        else { session.invalidateAndCancel() }
    }
    func result() async throws -> ContentHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let terminal { continuation.resume(with: terminal) }
                else { waiter = continuation }
            }
        }
    }
    func cancel() {
        let session = lock.withLock { cancelled = true; return self.session }
        session?.invalidateAndCancel()
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        self.response = response; failure = ContentServerError.redirectRejected
        completionHandler(nil); task.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            failure = failure ?? RemoteSyncError.authenticationFailed(reason: "Content service authentication failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else { completionHandler(.cancel); return }
        do {
            guard let response = response as? HTTPURLResponse else { throw ContentServerError.invalidResponse }
            self.response = response
            try ContentHTTPClient.validateStatus(response, download: sink != nil)
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity", response.value(forHTTPHeaderField: "Content-Range") == nil else { throw integrityError }
            expected = try contentLength(response)
            let mime = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let json = mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json")
            switch kind {
            case .json: invalidJSONType = !json
            case .image: guard mime.hasPrefix("image/") else { throw ContentServerError.invalidResponse }
            case .binary:
                guard !json, mime != "text/html", mime != "application/xhtml+xml",
                      mime != "application/xml", mime != "text/xml", !mime.hasSuffix("+xml") else { throw ContentServerError.invalidResponse }
            }
            if let sink {
                if let size = sink.expectedSize {
                    guard size >= 0, expected.map({ $0 == size }) ?? true else { throw integrityError }
                }
                try sink.file.validate(overwrite: sink.options.overwrite)
                try sink.file.open()
                sink.options.reportTransferred(0, total: expected ?? sink.expectedSize)
            } else {
                guard expected.map({ $0 <= Int64(limit) }) ?? true else { throw ContentServerError.resourceLimit }
            }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard !isCancelled, failure == nil else { return }
        do {
            let count = Int64(bytes.count)
            guard count <= Int64.max - received, expected.map({ count <= $0 - received }) ?? true else { throw integrityError }
            if let sink {
                guard sink.expectedSize.map({ count <= $0 - received }) ?? true else { throw integrityError }
                if prefix.count < 4096 {
                    prefix.append(contentsOf: bytes.prefix(4096 - prefix.count))
                    let start = String(decoding: prefix, as: UTF8.self).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") || start.hasPrefix("<?xml") {
                        throw ContentServerError.invalidResponse
                    }
                }
                try sink.file.write(bytes); received += count
                sink.options.reportTransferred(received, total: expected ?? sink.expectedSize)
            } else {
                guard bytes.count <= limit - data.count else { throw ContentServerError.resourceLimit }
                data.append(bytes); received += count
            }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do {
            guard !isCancelled else { throw RemoteSyncError.cancelled }
            if let failure { throw failure }
            guard let response else { throw error.map(ContentHTTPClient.mapped) ?? ContentServerError.invalidResponse }
            if let expected, expected != received { throw integrityError }
            if let size = sink?.expectedSize, size != received { throw integrityError }
            if let error { throw ContentHTTPClient.mapped(error) }
            guard !invalidJSONType || data.isEmpty else { throw ContentServerError.invalidResponse }
            try sink?.file.sync()
            completed = .success(.init(response: response, data: data, transferredBytes: sink == nil ? 0 : received))
        } catch { completed = .failure(ContentHTTPClient.mapped(error)) }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let result: Result<ContentHTTPResponse, any Error>
        if isCancelled { result = .failure(RemoteSyncError.cancelled) }
        else if let completed { result = completed }
        else { result = .failure(error.map(ContentHTTPClient.mapped) ?? ContentServerError.invalidResponse) }
        let continuation = lock.withLock {
            terminal = result; self.session = nil
            let continuation = waiter; waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
    private var integrityError: RemoteSyncError { .integrityMismatch(path: "Content resource") }
    private func contentLength(_ response: HTTPURLResponse) throws -> Int64? {
        if let header = response.value(forHTTPHeaderField: "Content-Length") {
            let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int64(text),
                  response.expectedContentLength < 0 || response.expectedContentLength == size,
                  response.value(forHTTPHeaderField: "Transfer-Encoding") == nil else { throw integrityError }
            return size
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }
}
