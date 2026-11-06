import Foundation
import BoneRemoteSyncCore

struct BDHTTPResponse: Sendable {
    let response: HTTPURLResponse
    let data: Data
    let transferredBytes: Int64
}

/// Each request has an isolated session; a redirect is considered only after
/// that session has invalidated and can no longer access the download sink.
final class BDHTTPClient: @unchecked Sendable {
    private let configuration: BaiduDriveConfiguration
    private let endpoints: BDEndpoints
    private let lock = NSLock()
    private var closed = false
    private var active: [UUID: BDHTTPState] = [:]

    init(configuration: BaiduDriveConfiguration, endpoints: BDEndpoints) {
        self.configuration = configuration
        self.endpoints = endpoints
    }

    deinit { cancel() }

    func send(_ request: URLRequest, body: Data? = nil, sink: BDDownloadSink? = nil) async throws -> BDHTTPResponse {
        do {
            try Task.checkCancellation()
            guard configuration.timeout.isFinite, configuration.timeout > 0,
                  configuration.maxConcurrentTransfers > 0 else { throw BaiduDriveError.invalidConfiguration }
            guard let url = request.url, request.httpBodyStream == nil else { throw BaiduDriveError.invalidReference }
            let method = (request.httpMethod ?? "GET").uppercased()
            let payload = body ?? request.httpBody
            if let sink {
                guard method == "GET", payload == nil else { throw BaiduDriveError.invalidReference }
                guard sink.expectedSize >= 0 else { throw BaiduDriveError.invalidResponse }
                guard sink.options.resumeFrom == nil else {
                    throw RemoteSyncError.unsupported(operation: "Baidu download resume")
                }
                guard sink.options.expectedETag == nil else {
                    throw RemoteSyncError.unsupported(operation: "Baidu conditional download")
                }
            }
            var current = try BDLocation.serviceURL(url, endpoints: endpoints)
            var redirects = 0
            while true {
                try Task.checkCancellation()
                let outgoing = try Self.preparedRequest(request, url: current, method: method,
                                                        body: payload, timeout: configuration.timeout,
                                                        download: sink != nil)
                let result = try await perform(outgoing, sink: sink)
                try Task.checkCancellation()
                guard lock.withLock({ !closed }) else { throw RemoteSyncError.cancelled }
                guard (300...399).contains(result.response.statusCode) else { return result }
                // Metadata APIs and multipart POSTs must never replay on a redirect.
                guard sink != nil, method == "GET", redirects < 5,
                      Self.isRedirect(result.response.statusCode) else { throw BaiduDriveError.invalidResponse }
                current = try Self.redirectURL(result.response, from: current, endpoints: endpoints)
                redirects += 1
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Rebuild from an allowlist so no caller or redirected request can forward
    /// Authorization, Cookie, Referer, Host, or HTTP framing headers.
    static func preparedRequest(_ original: URLRequest, url: URL, method: String, body: Data?,
                                timeout: TimeInterval, download: Bool) throws -> URLRequest {
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw BaiduDriveError.invalidReference
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        if !download {
            for name in ["Accept", "Content-Type"] {
                if let value = original.value(forHTTPHeaderField: name) {
                    guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        throw BaiduDriveError.invalidReference
                    }
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(download ? "*/*" : "application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func redirectURL(_ response: HTTPURLResponse, from current: URL, endpoints: BDEndpoints) throws -> URL {
        guard let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty,
              !location.contains("\\"),
              !location.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }),
              let resolved = URL(string: location, relativeTo: current)?.absoluteURL else {
            throw BaiduDriveError.invalidResponse
        }
        let next = try BDLocation.serviceURL(resolved, endpoints: endpoints)
        guard !(current.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https") else {
            throw BaiduDriveError.invalidReference
        }
        // The server owns its signed query. Never add the original access_token.
        return next
    }

    private func perform(_ request: URLRequest, sink: BDDownloadSink?) async throws -> BDHTTPResponse {
        let id = UUID()
        let state = BDHTTPState(sink: sink)
        try lock.withLock {
            guard !closed else { throw RemoteSyncError.cancelled }
            guard active.count < configuration.maxConcurrentTransfers else { throw RemoteSyncError.rateLimited(retryAfter: nil) }
            active[id] = state
            state.start(request, timeout: configuration.timeout)
        }
        defer { _ = lock.withLock { active.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await state.result()
        } onCancel: {
            state.cancel()
        }
    }

    func cancel() {
        let states = lock.withLock {
            closed = true
            return Array(active.values)
        }
        states.forEach { $0.cancel() }
    }

    static func isRedirect(_ status: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(status)
    }

    static func validateStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200: return
        case 202: throw BaiduDriveError.asynchronousResult
        case 206: throw RemoteSyncError.integrityMismatch(path: "Baidu resource")
        case 401: throw RemoteSyncError.authenticationFailed(reason: "Baidu authentication failed")
        case 403: throw RemoteSyncError.permissionDenied(path: "Baidu resource")
        case 404, 410: throw RemoteSyncError.notFound(path: "Baidu resource")
        case 409, 412: throw RemoteSyncError.conflict(path: "Baidu resource")
        case 429: throw RemoteSyncError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599: throw RemoteSyncError.network("Baidu HTTP \(response.statusCode)")
        default: throw BaiduDriveError.invalidResponse
        }
    }

    static func mapped(_ error: any Error) -> any Error {
        if let error = error as? BaiduDriveError { return error }
        if let error = error as? RemoteSyncError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return RemoteSyncError.cancelled }
        if let error = error as? URLError { return RemoteSyncError.network("Baidu transport failed (\(error.errorCode))") }
        return RemoteSyncError.underlying("Baidu operation failed")
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = Double(value), seconds <= 31_536_000 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = max(0, date.timeIntervalSinceNow)
        return seconds.isFinite && seconds <= 31_536_000 ? seconds : nil
    }
}
