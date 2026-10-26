import Foundation
import BoneRemoteSyncCore

/// An immutable connection snapshot. All steps use the same pool and Authorization, including
/// after actor reentrancy. Closing the pool prevents an old operation from using a new account.
struct DAVWriteContext: Sendable {
    let session: DAVHTTPSession
    let location: WebDAVLocation
    let template: URLRequest
    let retryPolicy: WebDAVRetryPolicy
    let scope: DAVOperationScope

    func request(_ path: String, method: String, collection: Bool = false) throws -> URLRequest {
        try scope.check()
        var result = template
        let url = try location.url(for: path)
        result.url = collection && !url.absoluteString.hasSuffix("/") ? url.appendingPathComponent("") : url
        result.httpMethod = method
        return result
    }

    func stat(_ path: String) async throws -> RemoteEntry {
        var request = try request(path, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(WebDAVSource.propfindBody.utf8)
        let responses = try await DAVPropertyWorker.fetch(session: session, request: request, path: path, location: location,
                                                         retryPolicy: retryPolicy, scope: scope)
        try scope.check()
        let item = try DAVPropertyWorker.resource(in: responses, path: path, location: location, requestURL: request.url!)
        return RemoteEntry(id: RemotePath.relative(path), path: path, name: RemotePath.name(of: path),
                           type: item.isDirectory ? .directory : .file, size: item.size,
                           modifiedAt: item.modifiedAt, etag: item.etag, contentType: item.contentType, createdAt: item.createdAt)
    }

    func optionalStat(_ path: String) async throws -> RemoteEntry? {
        do { return try await stat(path) }
        catch {
            if case .notFound = DAVHTTP.mapped(error) { return nil }
            throw error
        }
    }

    func requireDirectory(_ path: String) async throws {
        guard try await stat(path).isDirectory else { throw RemoteSyncError.conflict(path: path) }
    }

    /// No mutation retries, even when a read retry policy is enabled. A lost reply may mean that
    /// the server has already committed. 207 is never treated as a blanket success.
    func send(_ request: URLRequest, path: String, allowed: Set<Int>, uploadFile: URL? = nil,
              progress: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPURLResponse {
        try scope.check()
        let stream = try await DAVHTTP.stream(session: session, request: request, uploadFile: uploadFile, progress: progress)
        defer { stream.cancel() }
        let response = stream.response
        if response.statusCode == 405 || response.statusCode == 501 {
            throw RemoteSyncError.unsupported(operation: "WebDAV \(request.httpMethod ?? "写操作")")
        }
        if response.statusCode == 207 {
            throw RemoteSyncError.underlying("WebDAV \(request.httpMethod ?? "写操作") 返回 207，可能部分完成；请重新查询远端状态")
        }
        try DAVHTTP.validateForRetry(response, path: path, allowed: allowed)
        // Drain bounded success bodies to observe transport completion, without retaining them.
        let limit = 1024 * 1024
        guard response.expectedContentLength <= limit else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 写响应超过 1MiB；远端可能已完成")
        }
        var count = 0
        while let chunk = try await stream.next() {
            try scope.check()
            guard chunk.count <= limit - count else {
                throw RemoteSyncError.unsupported(operation: "WebDAV 写响应超过 1MiB；远端可能已完成")
            }
            count += chunk.count
        }
        try scope.check()
        return response
    }

    func makeDirectory(_ path: String) async throws {
        try scope.check()
        guard path != "/" else { return }
        var current = ""
        for component in path.dropFirst().split(separator: "/") {
            current += "/" + component
            if let item = try await optionalStat(current) {
                guard item.isDirectory else { throw RemoteSyncError.conflict(path: current) }
                continue
            }
            let request = try request(current, method: "MKCOL", collection: true)
            do { _ = try await send(request, path: current, allowed: [201]) }
            catch {
                // MKCOL 405 means an existing resource, or an unsupported method. A concurrent
                // creator is benign only after a fresh successful collection lookup.
                let isExistingRace: Bool
                if case .unsupported(let operation) = error as? RemoteSyncError {
                    isExistingRace = operation == "WebDAV MKCOL"
                } else if case .http(let status, _, _) = error as? DAVRequestFailure {
                    isExistingRace = status == 409 || status == 412
                } else { isExistingRace = false }
                if isExistingRace, let item = try await optionalStat(current) {
                    guard item.isDirectory else { throw RemoteSyncError.conflict(path: current) }
                    continue
                }
                throw error
            }
        }
    }
}
