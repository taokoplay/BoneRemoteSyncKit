import Foundation
import BoneRemoteSyncCore

package enum ContentAuthorization: Sendable {
    case none, basic(username: String, password: String), bearer(String), apiKey(String)
}
package enum ContentResponseKind: Sendable { case json, image, binary }
package struct ContentHTTPResponse: Sendable {
    package let response: HTTPURLResponse
    package let data: Data
    package let transferredBytes: Int64
}

/// Per-call conservative delivery observation. False proves no URLSession request was started;
/// true does not prove the server received or committed the request. Read only after send drains.
package final class ContentRequestAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    package init() {}
    package var mayHaveBeenSent: Bool { lock.withLock { started } }
    fileprivate func markSubmitted() { lock.withLock { started = true } }
}

private actor ContentRequestGate {
    private var lastAdmission: TimeInterval?
    func wait(interval: TimeInterval) async throws {
        while true {
            try Task.checkCancellation()
            guard interval > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let lastAdmission {
                let remaining = interval - (now - lastAdmission)
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded(.up)))
                    continue
                }
            }
            lastAdmission = now
            return
        }
    }
}

/// One connection owns its authentication, rate gate and bounded request tasks.
package final class ContentHTTPClient: @unchecked Sendable {
    private let configuration: ContentServerConfiguration
    private let authorizationHeaders: [String: String]
    private let gate = ContentRequestGate()
    private let lock = NSLock()
    private var closed = false
    private var active: [UUID: Task<ContentHTTPResponse, any Error>] = [:]

    package init(configuration: ContentServerConfiguration, authorization: ContentAuthorization = .none) throws {
        self.configuration = configuration
        switch authorization {
        case .none: authorizationHeaders = [:]
        case .basic(let username, let password):
            guard !username.isEmpty, !username.contains(":"), username.utf8.count <= 4096, password.utf8.count <= 32768,
                  !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RemoteSyncError.authenticationFailed(reason: "Invalid content service credential")
            }
            authorizationHeaders = ["Authorization": "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()]
        case .bearer(let token): authorizationHeaders = ["Authorization": "Bearer " + (try ContentValidation.token(token))]
        case .apiKey(let token): authorizationHeaders = ["X-API-Key": try ContentValidation.token(token)]
        }
    }
    deinit { cancel() }

    package func url(path: [String], query: [URLQueryItem] = []) throws -> URL {
        try ContentLocation.url(configuration: configuration, path: path, query: query)
    }
    package func serviceURL(_ value: String) throws -> URL { try ContentLocation.serviceURL(value, configuration: configuration) }
    package func streamRequest(path: [String], query: [URLQueryItem] = []) throws -> ContentStreamRequest {
        try streamRequest(url: url(path: path, query: query))
    }
    package func streamRequest(url: URL) throws -> ContentStreamRequest {
        try checkOpen()
        return .init(url: try ContentLocation.validate(url, configuration: configuration), headers: authorizationHeaders)
    }
    package func send(path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                      headers: [String: String] = [:], kind: ContentResponseKind = .json,
                      attempt: ContentRequestAttempt? = nil) async throws -> ContentHTTPResponse {
        try await send(url: url(path: path, query: query), method: method, body: body, headers: headers, kind: kind, attempt: attempt)
    }
    package func send(url: URL, method: String = "GET", body: Data? = nil,
                      headers: [String: String] = [:], kind: ContentResponseKind = .json,
                      attempt: ContentRequestAttempt? = nil) async throws -> ContentHTTPResponse {
        let request = try preparedRequest(url: url, method: method, body: body, headers: headers, kind: kind)
        return try await execute(request, kind: kind, sink: nil, attempt: attempt)
    }
    package func download(_ resource: ContentResource, file: ContentDownloadFile, options: RemoteDownloadOptions) async throws -> Int64 {
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "Content download resume/conditional request")
        }
        try file.validate(overwrite: options.overwrite)
        let request = try preparedRequest(url: resource.url, method: "GET", body: nil, headers: [:], kind: .binary)
        return try await execute(request, kind: .binary,
                                 sink: .init(file: file, expectedSize: options.verifySize ? resource.entry.size : nil, options: options)).transferredBytes
    }

    private func preparedRequest(url: URL, method: String, body: Data?, headers: [String: String], kind: ContentResponseKind) throws -> URLRequest {
        try checkOpen()
        guard ["GET", "POST", "PATCH", "PUT", "DELETE"].contains(method),
              body.map({ $0.count <= configuration.maxResponseBytes }) ?? true,
              method != "GET" || body == nil else { throw ContentServerError.invalidReference }
        var request = URLRequest(url: try ContentLocation.validate(url, configuration: configuration),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        switch kind {
        case .json: request.setValue("application/json", forHTTPHeaderField: "Accept")
        case .image: request.setValue("image/*", forHTTPHeaderField: "Accept")
        case .binary: request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var seen = Set<String>()
        for (key, value) in headers {
            let name = key.lowercased()
            guard ["x-return-tokens", "content-type", "accept"].contains(name), seen.insert(name).inserted,
                  value.utf8.count <= 4096,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ContentServerError.invalidReference
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in authorizationHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func execute(_ request: URLRequest, kind: ContentResponseKind, sink: ContentDownloadSink?,
                         attempt: ContentRequestAttempt? = nil) async throws -> ContentHTTPResponse {
        do {
            try Task.checkCancellation()
            let id = UUID(), configuration = self.configuration, gate = self.gate
            let task: Task<ContentHTTPResponse, any Error> = try lock.withLock {
                guard !closed else { throw RemoteSyncError.cancelled }
                guard active.count < configuration.maxConcurrentRequests else { throw RemoteSyncError.rateLimited(retryAfter: nil) }
                let task = Task {
                    try await withThrowingTaskGroup(of: ContentHTTPResponse.self) { group in
                        group.addTask {
                            try await gate.wait(interval: configuration.requestInterval)
                            try Task.checkCancellation()
                            let state = ContentHTTPState(limit: configuration.maxResponseBytes, kind: kind, sink: sink)
                            return try await withTaskCancellationHandler {
                                try Task.checkCancellation()
                                attempt?.markSubmitted()
                                state.start(request, timeout: configuration.timeout)
                                return try await state.result()
                            } onCancel: { state.cancel() }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64((configuration.timeout * 1_000_000_000).rounded(.up)))
                            throw URLError(.timedOut)
                        }
                        defer { group.cancelAll() }
                        guard let result = try await group.next() else { throw RemoteSyncError.cancelled }
                        return result
                    }
                }
                active[id] = task
                return task
            }
            defer { _ = lock.withLock { active.removeValue(forKey: id) } }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try checkOpen()
            return result
        } catch { throw Self.mapped(error) }
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard lock.withLock({ !closed }) else { throw RemoteSyncError.cancelled }
    }
    package func cancel() {
        let tasks = lock.withLock { closed = true; return Array(active.values) }
        tasks.forEach { $0.cancel() }
    }

    static func validateStatus(_ response: HTTPURLResponse, download: Bool) throws {
        if [200, 201, 204, 205].contains(response.statusCode), !download || response.statusCode == 200 { return }
        switch response.statusCode {
        case 300...399: throw ContentServerError.redirectRejected
        case 401: throw RemoteSyncError.authenticationFailed(reason: "Content service authentication failed")
        case 403: throw RemoteSyncError.permissionDenied(path: "Content resource")
        case 404, 410: throw RemoteSyncError.notFound(path: "Content resource")
        case 409, 412: throw RemoteSyncError.conflict(path: "Content resource")
        case 206: throw RemoteSyncError.integrityMismatch(path: "Content resource")
        case 429: throw RemoteSyncError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599: throw RemoteSyncError.network("Content service HTTP \(response.statusCode)")
        default: throw ContentServerError.invalidResponse
        }
    }
    static func mapped(_ error: any Error) -> any Error {
        if error is ContentServerError || error is RemoteSyncError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return RemoteSyncError.cancelled }
        if let error = error as? URLError { return RemoteSyncError.network("Content transport failed (\(error.errorCode))") }
        return ContentServerError.invalidResponse
    }
    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(text), seconds <= 31_536_000 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        let seconds = max(0, date.timeIntervalSinceNow)
        return seconds <= 31_536_000 ? seconds : nil
    }
}
