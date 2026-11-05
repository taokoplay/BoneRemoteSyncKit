import Foundation
import BoneRemoteSyncCore

struct OPDSHTTPResponse: Sendable {
    let response: HTTPURLResponse
    let data: Data
    let transferredBytes: Int64
}

/// Independent, isolated OPDS transport. Redirects are followed only after the
/// preceding session has drained, with a freshly constructed request each time.
final class OPDSHTTPClient: @unchecked Sendable {
    private let configuration: OPDSConfiguration
    private let authorization: String?
    private let lock = NSLock()
    private var closed = false
    private var active: [UUID: OPDSHTTPState] = [:]

    init(configuration: OPDSConfiguration, credential: RemoteCredential) throws {
        self.configuration = configuration
        switch credential {
        case .anonymous:
            authorization = nil
        case .basic(let username, let password):
            guard !username.contains(":"),
                  !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RemoteSyncError.authenticationFailed(reason: "Invalid OPDS Basic credential")
            }
            authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        default:
            throw RemoteSyncError.unsupported(operation: "OPDS credential type")
        }
    }

    deinit { cancel() }

    func send(_ url: URL, catalog: Bool = true, sink: OPDSDownloadSink? = nil) async throws -> OPDSHTTPResponse {
        do {
            try Task.checkCancellation()
            if let sink {
                guard sink.options.resumeFrom == nil else { throw RemoteSyncError.unsupported(operation: "OPDS download resume") }
                guard sink.options.expectedETag == nil else { throw RemoteSyncError.unsupported(operation: "OPDS conditional download") }
            }
            var current = try OPDSLocation.validate(url, configuration: configuration, catalog: catalog)
            var mayAuthorize = OPDSLocation.sameOrigin(current, configuration.rootURL)
            var redirects = 0
            while true {
                try Task.checkCancellation()
                var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue(sink == nil ? "application/atom+xml, application/opensearchdescription+xml, application/xml, text/xml" : "*/*", forHTTPHeaderField: "Accept")
                if mayAuthorize { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
                let result = try await perform(request, sink: sink)
                try Task.checkCancellation()
                guard lock.withLock({ !closed }) else { throw RemoteSyncError.cancelled }
                guard Self.isRedirect(result.response.statusCode) else { return result }
                guard redirects < 5 else { throw OPDSError.redirectLimit }
                guard let location = result.response.value(forHTTPHeaderField: "Location"),
                      let resolved = OPDSLocation.resolve(location, relativeTo: current) else { throw OPDSError.invalidURL }
                let next = try OPDSLocation.validate(resolved, configuration: configuration, catalog: catalog)
                guard !(current.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http") else {
                    throw OPDSError.disallowedOrigin
                }
                // Once a chain leaves the credential origin, even a return hop stays anonymous.
                mayAuthorize = mayAuthorize && OPDSLocation.sameOrigin(current, next)
                    && OPDSLocation.sameOrigin(next, configuration.rootURL)
                current = next
                redirects += 1
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private func perform(_ request: URLRequest, sink: OPDSDownloadSink?) async throws -> OPDSHTTPResponse {
        let id = UUID()
        let state = OPDSHTTPState(configuration: configuration, sink: sink)
        try lock.withLock {
            guard !closed else { throw RemoteSyncError.cancelled }
            guard active.count < configuration.maxConcurrentTransfers else { throw OPDSError.resourceLimit }
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
        case 401: throw RemoteSyncError.authenticationFailed(reason: "OPDS authentication failed")
        case 403: throw RemoteSyncError.permissionDenied(path: "OPDS resource")
        case 404, 410: throw RemoteSyncError.notFound(path: "OPDS resource")
        case 409, 412: throw RemoteSyncError.conflict(path: "OPDS resource")
        case 206: throw RemoteSyncError.integrityMismatch(path: "OPDS resource")
        case 429: throw RemoteSyncError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599: throw RemoteSyncError.network("OPDS HTTP \(response.statusCode)")
        default: throw RemoteSyncError.unsupported(operation: "OPDS HTTP \(response.statusCode)")
        }
    }

    static func mapped(_ error: Error) -> Error {
        if let error = error as? OPDSError { return error }
        if let error = error as? RemoteSyncError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return RemoteSyncError.cancelled }
        if let error = error as? URLError { return RemoteSyncError.network("OPDS transport failed (\(error.errorCode))") }
        return RemoteSyncError.underlying("OPDS operation failed")
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
