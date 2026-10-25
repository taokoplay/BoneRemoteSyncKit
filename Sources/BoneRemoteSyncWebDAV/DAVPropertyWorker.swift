import Foundation
import BoneRemoteSyncCore

/// Collect bounded Data chunks and parse off the source actor, so unrelated requests can progress.
enum DAVPropertyWorker {
    static func fetch(session: DAVHTTPSession, request: URLRequest, path: String,
                      retryPolicy: WebDAVRetryPolicy = .none, scope suppliedScope: DAVOperationScope? = nil) async throws -> [DAVResponse] {
        let scope = suppliedScope ?? DAVOperationScope(pool: session, policy: retryPolicy)
        let work: @Sendable () async throws -> [DAVResponse] = {
            try await DAVRetryExecutor.run(policy: retryPolicy, scope: scope, runtime: scope.runtime) { _ in
                try await fetchOnce(session: session, request: request, path: path, runtime: scope.runtime)
            }
        }
        if suppliedScope != nil { return try await work() }
        return try await scope.run(work)
    }

    private static func fetchOnce(session: DAVHTTPSession, request: URLRequest, path: String, runtime: DAVRetryRuntime) async throws -> [DAVResponse] {
        let stream = try await DAVHTTP.stream(session: session, request: request)
        defer { stream.cancel() }
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
}
