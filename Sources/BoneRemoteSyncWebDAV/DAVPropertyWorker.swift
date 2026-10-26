import Foundation
import BoneRemoteSyncCore

/// Collect bounded Data chunks and parse off the source actor, so unrelated requests can progress.
enum DAVPropertyWorker {
    static func fetch(session: DAVHTTPSession, request: URLRequest, path: String, location: WebDAVLocation,
                      retryPolicy: WebDAVRetryPolicy = .none, scope suppliedScope: DAVOperationScope? = nil) async throws -> [DAVResponse] {
        let scope = suppliedScope ?? DAVOperationScope(pool: session, policy: retryPolicy)
        let work: @Sendable () async throws -> [DAVResponse] = {
            try await DAVRetryExecutor.run(policy: retryPolicy, scope: scope, runtime: scope.runtime) { _ in
                let responses = try await fetchOnce(session: session, request: request, path: path, runtime: scope.runtime)
                _ = try resource(in: responses, path: path, location: location, requestURL: request.url!)
                return responses
            }
        }
        if suppliedScope != nil { return try await work() }
        return try await scope.run(work)
    }

    /// Select the requested resource before filtering failed child entries. Absence, permission
    /// failure and missing properties are distinct outcomes in a successful HTTP 207 response.
    static func resource(in responses: [DAVResponse], path: String, location: WebDAVLocation,
                         requestURL: URL) throws -> DAVResponse {
        guard let item = responses.first(where: { location.path(for: $0.href, relativeTo: requestURL) == path }) else {
            throw RemoteSyncError.notFound(path: path)
        }
        if let status = item.status, !(200..<300).contains(status) {
            throw DAVRequestFailure.http(status: status, retryAfter: nil, path: path)
        }
        guard item.hasProperties else { throw RemoteSyncError.underlying("WebDAV 目标资源缺少属性") }
        return item
    }

    private static func fetchOnce(session: DAVHTTPSession, request: URLRequest, path: String, runtime: DAVRetryRuntime) async throws -> [DAVResponse] {
        var stream = try await DAVHTTP.stream(session: session, request: request)
        defer { stream.cancel() }
        // URLSession still refuses all redirects. Only a PROPFIND canonicalization that adds
        // exactly one slash is reconstructed locally, once per attempt, under the same scope.
        if let canonical = collectionRequest(request, response: stream.response) {
            stream.cancel()
            try Task.checkCancellation()
            stream = try await DAVHTTP.stream(session: session, request: canonical)
        }
        let response = stream.response
        try DAVHTTP.validateForRetry(response, path: path, allowed: [207], now: runtime.wallNow())
        let limit = 16 * 1024 * 1024
        guard response.expectedContentLength <= limit else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 目录响应超过 16MiB")
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        while let chunk = try await stream.next() {
            try Task.checkCancellation()
            guard chunk.count <= limit - data.count else {
                throw RemoteSyncError.unsupported(operation: "WebDAV 目录响应超过 16MiB")
            }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return try DAVMultiStatusParser.parse(data)
    }

    private static func collectionRequest(_ request: URLRequest, response: HTTPURLResponse) -> URLRequest? {
        guard request.httpMethod == "PROPFIND", [301, 308].contains(response.statusCode),
              let original = request.url,
              let base = URLComponents(url: original, resolvingAgainstBaseURL: false),
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !base.percentEncodedPath.hasSuffix("/"),
              let raw = response.value(forHTTPHeaderField: "Location"), !raw.isEmpty,
              !raw.contains("\\"), !raw.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let resolved = URL(string: raw, relativeTo: original)?.absoluteURL,
              let target = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil,
              target.scheme?.lowercased() == base.scheme?.lowercased(),
              target.host?.lowercased() == base.host?.lowercased(),
              (target.port ?? (target.scheme == "https" ? 443 : 80)) == (base.port ?? (base.scheme == "https" ? 443 : 80)),
              target.percentEncodedPath == base.percentEncodedPath + "/" else { return nil }
        // Never send a server-provided URL: construct the already-authorized path locally.
        var canonical = base
        canonical.percentEncodedPath += "/"
        guard let url = canonical.url else { return nil }
        var result = request
        result.url = url
        return result
    }
}
