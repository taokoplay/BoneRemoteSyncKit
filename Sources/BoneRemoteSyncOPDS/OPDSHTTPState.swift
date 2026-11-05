import Foundation
import BoneRemoteSyncCore

/// All response bytes and file operations stay on one serial delegate queue.
/// Cancellation only requests invalidation; result() waits for the final delegate
/// invalidation callback, so the caller can safely clean up the file on return.
final class OPDSHTTPState: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let sink: OPDSDownloadSink?
    private let configuration: OPDSConfiguration
    // Protected by lock; accessed by cancellation and the awaiting task.
    private var session: URLSession?
    private var cancelled = false
    private var terminal: Result<OPDSHTTPResponse, Error>?
    private var waiter: CheckedContinuation<OPDSHTTPResponse, Error>?
    // Confined to the serial delegate queue.
    private var response: HTTPURLResponse?
    private var data = Data()
    private var prefix = Data()
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?
    private var responseOnly = false
    private var completed: Result<OPDSHTTPResponse, Error>?
    private var needsCatalogValidation = false

    init(configuration: OPDSConfiguration, sink: OPDSDownloadSink?) {
        self.configuration = configuration
        self.limit = configuration.maxResponseBytes
        self.sink = sink
    }

    func start(_ request: URLRequest, timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        lock.withLock { self.session = session }
        session.dataTask(with: request).resume()
    }

    func result() async throws -> OPDSHTTPResponse {
        // Do not check task cancellation here: a live delegate may still own the file.
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
        // Save the response here too: a redirect must never open the sink or buffer its body.
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
            // Basic is sent preemptively only to the approved origin. Never retry
            // a challenge using ambient credentials or return an opaque -999 error.
            failure = failure ?? RemoteSyncError.authenticationFailed(reason: "OPDS authentication failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            failure = RemoteSyncError.network("OPDS response is not HTTP")
            completionHandler(.cancel)
            return
        }
        self.response = response
        if OPDSHTTPClient.isRedirect(response.statusCode) {
            responseOnly = true
            completionHandler(.cancel)
            return
        }
        do {
            try OPDSHTTPClient.validateStatus(response)
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity",
                  response.value(forHTTPHeaderField: "Content-Range") == nil else { throw integrityError }
            expected = try Self.contentLength(response)
            let mediaType = Self.mediaType(response.value(forHTTPHeaderField: "Content-Type"))
            if let sink {
                try Self.validateDownloadType(mediaType, expected: Self.mediaType(sink.mediaType) ?? "")
                try sink.file.validate(overwrite: sink.options.overwrite)
                try sink.file.open()
                sink.options.reportTransferred(0, total: expected)
            } else {
                let recognized = ["application/atom+xml", "application/opensearchdescription+xml", "application/xml", "text/xml"]
                if !recognized.contains(mediaType ?? "") {
                    guard configuration.compatibility == .compatible,
                          ["", "text/html", "application/xhtml+xml", "text/plain", "application/octet-stream"].contains(mediaType ?? "") else {
                        throw OPDSError.unexpectedContentType
                    }
                    needsCatalogValidation = true
                }
                guard expected.map({ $0 <= Int64(limit) }) ?? true else { throw OPDSError.resourceLimit }
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
                  expected.map({ count <= $0 - received }) ?? true else { throw integrityError }
            if let sink {
                if prefix.count < 4096 {
                    prefix.append(contentsOf: bytes.prefix(4096 - prefix.count))
                    try Self.validatePrefix(prefix, expected: Self.mediaType(sink.mediaType) ?? "")
                }
                try sink.file.write(bytes)
                received += count
                sink.options.reportTransferred(received, total: expected)
            } else {
                guard bytes.count <= limit - data.count else { throw OPDSError.resourceLimit }
                data.append(bytes)
                received += count
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            guard !isCancelled else { throw RemoteSyncError.cancelled }
            if let failure { throw failure }
            guard let response else {
                throw error.map(OPDSHTTPClient.mapped) ?? RemoteSyncError.network("OPDS HTTP response is missing")
            }
            if responseOnly {
                completed = .success(OPDSHTTPResponse(response: response, data: Data(), transferredBytes: 0))
            } else {
                // HTTP framing is always verified, independently of metadata verifySize.
                if let expected, expected != received { throw integrityError }
                if let error { throw OPDSHTTPClient.mapped(error) }
                if needsCatalogValidation {
                    guard let url = response.url else { throw OPDSError.invalidURL }
                    let root = try OPDSXMLTree(configuration: configuration, base: url).parse(data)
                    guard (root.namespace == OPDSFeedParser.atom && ["feed", "entry"].contains(root.name))
                        || (root.namespace == OPDSSearch.namespace && root.name == "OpenSearchDescription") else {
                        throw OPDSError.unexpectedContentType
                    }
                }
                if let sink { try sink.file.sync() }
                completed = .success(OPDSHTTPResponse(response: response, data: data, transferredBytes: sink == nil ? 0 : received))
            }
        } catch {
            completed = .failure(OPDSHTTPClient.mapped(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let result: Result<OPDSHTTPResponse, Error>
        if isCancelled { result = .failure(RemoteSyncError.cancelled) }
        else if let completed { result = completed }
        else { result = .failure(error.map(OPDSHTTPClient.mapped) ?? RemoteSyncError.network("OPDS session ended without a result")) }
        let continuation = lock.withLock {
            terminal = result
            self.session = nil
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private var integrityError: RemoteSyncError { .integrityMismatch(path: "OPDS resource") }

    private static func contentLength(_ response: HTTPURLResponse) throws -> Int64? {
        if let header = response.value(forHTTPHeaderField: "Content-Length") {
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(value),
                  response.expectedContentLength < 0 || response.expectedContentLength == length,
                  response.value(forHTTPHeaderField: "Transfer-Encoding") == nil else {
                throw RemoteSyncError.integrityMismatch(path: "OPDS resource")
            }
            return length
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private static func mediaType(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isXML(_ type: String) -> Bool {
        type == "application/xml" || type == "text/xml" || type.hasSuffix("+xml")
    }

    private static func validateDownloadType(_ actual: String?, expected: String) throws {
        guard !expected.isEmpty else { throw OPDSError.unexpectedContentType }
        guard let actual else { return }
        guard actual != "text/html", actual != "application/xhtml+xml",
              actual != "application/json", actual != "text/json", !actual.hasSuffix("+json"),
              !isXML(actual) || isXML(expected) else { throw OPDSError.unexpectedContentType }
        if actual == "application/octet-stream" { return }
        if expected == "application/octet-stream", OPDSAcquisition.directTypes.contains(canonicalType(actual)) { return }
        if canonicalType(actual) == canonicalType(expected) { return }
        if (actual == "application/xml" || actual == "text/xml"), isXML(expected) { return }
        throw OPDSError.unexpectedContentType
    }

    private static func canonicalType(_ type: String) -> String {
        switch type {
        case "application/x-pdf": return "application/pdf"
        case "application/x-cbz": return "application/vnd.comicbook+zip"
        case "application/x-cbr": return "application/vnd.comicbook-rar"
        default: return type
        }
    }

    private static func validatePrefix(_ data: Data, expected: String) throws {
        let text: String
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            let littleEndian = data.first == 0xff
            let bytes = Array(data.dropFirst(2))
            let units: [UInt16] = stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map { index in
                let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
                return littleEndian ? first | (second << 8) : (first << 8) | second
            }
            text = String(decoding: units, as: UTF16.self)
        } else { text = String(decoding: data, as: UTF8.self) }
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        var start = text.lowercased().trimmingCharacters(in: whitespace)
        if start.hasPrefix("<?xml") {
            guard isXML(expected) else { throw OPDSError.unexpectedContentType }
            if let end = start.range(of: "?>") { start = String(start[end.upperBound...]).trimmingCharacters(in: whitespace) }
        }
        while start.hasPrefix("<!--"), let end = start.range(of: "-->") {
            start = String(start[end.upperBound...]).trimmingCharacters(in: whitespace)
        }
        let html = ["<html", "<head", "<body", "<!doctype html"].contains { marker in
            guard start.hasPrefix(marker) else { return false }
            let remainder = start.dropFirst(marker.count)
            return remainder.first.map({ $0.isWhitespace || $0 == ">" || $0 == "/" }) == true
        }
        if html { throw OPDSError.unexpectedContentType }
    }
}
