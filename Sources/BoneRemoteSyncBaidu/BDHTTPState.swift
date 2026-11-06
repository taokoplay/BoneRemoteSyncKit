import Foundation
import BoneRemoteSyncCore

/// Response bytes and staging writes are confined to one serial delegate queue.
/// Cancellation returns to the caller only after URLSession invalidation, so
/// caller-owned cleanup cannot race a late write or progress callback.
final class BDHTTPState: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let metadataLimit = 8 * 1024 * 1024
    static let envelopeLimit = 64 * 1024

    private let lock = NSLock()
    private let sink: BDDownloadSink?
    // Protected by lock; shared with cancellation and the awaiting task.
    private var session: URLSession?
    private var cancelled = false
    private var terminal: Result<BDHTTPResponse, any Error>?
    private var waiter: CheckedContinuation<BDHTTPResponse, any Error>?
    // Confined to the delegate queue.
    private var response: HTTPURLResponse?
    private var data = Data()
    private var prefix = Data()
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: (any Error)?
    private var responseOnly = false
    private var completed: Result<BDHTTPResponse, any Error>?

    init(sink: BDDownloadSink?) {
        self.sink = sink
    }

    func start(_ request: URLRequest, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.withLock { self.session = session }
        session.dataTask(with: request).resume()
    }

    func result() async throws -> BDHTTPResponse {
        // A cancellation check here could return while the delegate owns the file.
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let terminal { continuation.resume(with: terminal) }
                else { waiter = continuation }
            }
        }
    }

    func cancel() {
        let session = lock.withLock {
            cancelled = true
            return self.session
        }
        session?.invalidateAndCancel()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never accept Foundation's proposed request, including its headers.
        self.response = response
        responseOnly = true
        completionHandler(nil)
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
            failure = failure ?? RemoteSyncError.authenticationFailed(reason: "Baidu authentication failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            failure = BaiduDriveError.invalidResponse
            completionHandler(.cancel)
            return
        }
        self.response = response
        if (300...399).contains(response.statusCode) {
            responseOnly = true
            completionHandler(.cancel)
            return
        }
        do {
            expected = try Self.validateResponse(response, expectedSize: sink?.expectedSize)
            if let sink {
                try sink.file.validate(overwrite: sink.options.overwrite)
                try sink.file.open()
                sink.options.reportTransferred(0, total: sink.expectedSize)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard !isCancelled, failure == nil, !responseOnly else { return }
        do {
            let count = Int64(bytes.count)
            guard count <= Int64.max - received,
                  expected.map({ count <= $0 - received }) ?? true else { throw Self.integrityError }
            if let sink {
                // Metadata size is part of the reference, even when verifySize is disabled.
                guard count <= sink.expectedSize - received else { throw Self.integrityError }
                if sink.expectedSize <= Int64(Self.envelopeLimit) {
                    prefix.append(bytes)
                }
                try sink.file.write(bytes)
                received += count
                sink.options.reportTransferred(received, total: sink.expectedSize)
            } else {
                guard bytes.count <= Self.metadataLimit - data.count else { throw BaiduDriveError.responseTooLarge }
                data.append(bytes)
                received += count
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do {
            guard !isCancelled else { throw RemoteSyncError.cancelled }
            if let failure { throw failure }
            guard let response else {
                throw error.map(BDHTTPClient.mapped) ?? BaiduDriveError.invalidResponse
            }
            if responseOnly {
                completed = .success(BDHTTPResponse(response: response, data: Data(), transferredBytes: 0))
            } else {
                // HTTP framing and reference size are both mandatory, independent
                // of RemoteDownloadOptions.verifySize.
                if let expected, expected != received { throw Self.integrityError }
                if let sink, sink.expectedSize != received { throw Self.integrityError }
                if let error { throw BDHTTPClient.mapped(error) }
                if let sink {
                    if sink.expectedSize <= Int64(Self.envelopeLimit) {
                        try Self.validateDownloadEnvelope(prefix)
                    }
                    try sink.file.sync()
                }
                completed = .success(BDHTTPResponse(response: response, data: data, transferredBytes: sink == nil ? 0 : received))
            }
        } catch {
            completed = .failure(BDHTTPClient.mapped(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let result: Result<BDHTTPResponse, any Error>
        if isCancelled { result = .failure(RemoteSyncError.cancelled) }
        else if let completed { result = completed }
        else { result = .failure(error.map(BDHTTPClient.mapped) ?? BaiduDriveError.invalidResponse) }
        let continuation = lock.withLock {
            terminal = result
            self.session = nil
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private static var integrityError: RemoteSyncError { .integrityMismatch(path: "Baidu resource") }

    static func validateResponse(_ response: HTTPURLResponse, expectedSize: Int64?) throws -> Int64? {
        try BDHTTPClient.validateStatus(response)
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard encoding == nil || encoding == "identity",
              response.value(forHTTPHeaderField: "Content-Range") == nil else { throw integrityError }
        let length = try contentLength(response)
        if let expectedSize {
            guard expectedSize >= 0, length.map({ $0 == expectedSize }) ?? true else { throw integrityError }
        } else {
            guard length.map({ $0 <= Int64(metadataLimit) }) ?? true else { throw BaiduDriveError.responseTooLarge }
        }
        return length
    }

    private static func contentLength(_ response: HTTPURLResponse) throws -> Int64? {
        if let header = response.value(forHTTPHeaderField: "Content-Length") {
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(value),
                  response.expectedContentLength < 0 || response.expectedContentLength == length,
                  response.value(forHTTPHeaderField: "Transfer-Encoding") == nil else { throw integrityError }
            return length
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    /// HTML and JSON are valid user files. Only a complete JSON object no larger
    /// than 64 KiB with a nonzero Baidu error code AND request_id is classified as
    /// an API failure. A user document with this exact envelope is indistinguishable.
    static func validateDownloadEnvelope(_ bytes: Data) throws {
        guard bytes.count <= envelopeLimit,
              let envelope = try? JSONDecoder().decode(DownloadEnvelope.self, from: bytes),
              envelope.hasRequestID else { return }
        if let code = envelope.errno, code != 0 { throw BaiduDriveError.api(code: code) }
        if let code = envelope.errorCode, code != 0 { throw BaiduDriveError.api(code: code) }
    }

    private struct DownloadEnvelope: Decodable {
        let errno: Int?
        let errorCode: Int?
        let hasRequestID: Bool

        private enum CodingKeys: String, CodingKey {
            case errno, errorCode = "error_code", requestID = "request_id"
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            errno = (try? values.decode(Int.self, forKey: .errno))
                ?? (try? values.decode(String.self, forKey: .errno)).flatMap(Int.init)
            errorCode = (try? values.decode(Int.self, forKey: .errorCode))
                ?? (try? values.decode(String.self, forKey: .errorCode)).flatMap(Int.init)
            if let id = try? values.decode(String.self, forKey: .requestID) {
                hasRequestID = !id.isEmpty
            } else {
                hasRequestID = (try? values.decode(UInt64.self, forKey: .requestID)) != nil
                    || (try? values.decode(Int64.self, forKey: .requestID)) != nil
            }
        }
    }
}
