import Foundation
import BoneRemoteSyncCore

/// WebDAV 文件读写来源。支持匿名与 Basic，使用系统 TLS 验证，不自动跟随重定向。
/// 能力表示已实现的方法，不保证当前服务或账号有权限；写操作失败可能已产生远端副作用。
/// 标准 WebDAV 没有统一游标分页；每次 list 返回完整 Depth:1 结果。
public actor WebDAVSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .webdav
    public nonisolated let capabilities = RemoteCapabilities(
        rangedDownload: true, upload: true, makeDirectory: true, remove: true, move: true, copy: true
    )

    let location: WebDAVLocation
    private let timeout: TimeInterval
    let retryPolicy: WebDAVRetryPolicy
    private var session: DAVHTTPSession?
    private var authorization: String?
    private var connected = false
    var generation: UInt64 = 0
    var activeDestinations: Set<String> = []

    public init(baseURL: URL, timeout: TimeInterval = 60, retryPolicy: WebDAVRetryPolicy = .none) throws {
        guard timeout.isFinite, timeout > 0 else { throw RemoteSyncError.unsupported(operation: "WebDAV 超时时间") }
        try retryPolicy.validate()
        location = try WebDAVLocation(baseURL: baseURL)
        self.timeout = timeout
        self.retryPolicy = retryPolicy
    }

    deinit { session?.invalidateAndCancel() }

    public func connect(_ credential: RemoteCredential) async throws {
        disconnectSession()
        switch credential {
        case .anonymous: authorization = nil
        case .basic(let username, let password):
            guard !username.contains(":"), !username.contains("\r"), !username.contains("\n"),
                  !password.contains("\r"), !password.contains("\n") else {
                throw RemoteSyncError.authenticationFailed(reason: "WebDAV Basic 凭据格式无效")
            }
            authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        default: throw RemoteSyncError.authenticationFailed(reason: "WebDAV 凭据类型不受支持")
        }
        session = DAVHTTP.session(timeout: timeout)
        let version = generation
        do {
            let entries = try await propfind(path: "/", depth: 0)
            try checkGeneration(version)
            let entry = try selfEntry(in: entries, path: "/")
            guard entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "WebDAV 根不是目录") }
            connected = true
        } catch {
            if generation == version { disconnectSession() }
            throw DAVHTTP.mapped(error)
        }
    }

    public func disconnect() async { disconnectSession() }

    private func disconnectSession() {
        generation &+= 1
        connected = false
        authorization = nil
        session?.invalidateAndCancel()
        session = nil
        // 正在退出的传输仍拥有自己的目的路径锁，直到 defer 释放。
    }

    func context() throws -> (DAVHTTPSession, UInt64) {
        guard connected, let session else { throw RemoteSyncError.notConnected }
        return (session, generation)
    }

    func checkGeneration(_ version: UInt64) throws {
        try Task.checkCancellation()
        guard version == generation else { throw RemoteSyncError.cancelled }
    }

    func request(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try location.url(for: path))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        _ = try context()
        try request.validate()
        guard request.cursor == nil else { throw RemoteSyncError.unsupported(operation: "WebDAV 游标分页") }
        let path = RemotePath.normalize(path)
        do {
            let entries = try await propfind(path: path, depth: 1)
            let root = try selfEntry(in: entries, path: path)
            guard root.isDirectory else { throw RemoteSyncError.unsupported(operation: "列出非目录条目") }
            var seen: Set<String> = []
            var children = entries.filter { entry in
                guard let child = entry.path, child != path, RemotePath.parent(of: child) == path,
                      request.includeHidden || !entry.name.hasPrefix("."), seen.insert(child).inserted else { return false }
                return true
            }
            children.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return RemoteListPage(entries: children)
        } catch { throw DAVHTTP.mapped(error) }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        _ = try context()
        let path = RemotePath.normalize(path)
        do { return try selfEntry(in: await propfind(path: path, depth: 0), path: path) }
        catch { throw DAVHTTP.mapped(error) }
    }

    private func selfEntry(in entries: [RemoteEntry], path: String) throws -> RemoteEntry {
        guard let entry = entries.first(where: { $0.path == path }) else { throw RemoteSyncError.notFound(path: path) }
        return entry
    }

    private func propfind(path: String, depth: Int) async throws -> [RemoteEntry] {
        guard let session else { throw RemoteSyncError.notConnected }
        let version = generation
        var request = try request(path: path, method: "PROPFIND")
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let responses = try await DAVPropertyWorker.fetch(session: session, request: request, path: path, location: location, retryPolicy: retryPolicy)
        try checkGeneration(version)
        _ = try DAVPropertyWorker.resource(in: responses, path: path, location: location, requestURL: request.url!)
        return responses.compactMap { item in
            guard item.hasProperties, item.status.map({ (200..<300).contains($0) }) ?? true,
                  let itemPath = location.path(for: item.href, relativeTo: request.url!) else { return nil }
            return RemoteEntry(id: RemotePath.relative(itemPath), path: itemPath,
                name: itemPath == "/" ? location.baseURL.lastPathComponent : RemotePath.name(of: itemPath),
                type: item.isDirectory ? .directory : .file, size: item.isDirectory ? nil : item.size,
                modifiedAt: item.modifiedAt, etag: item.etag, contentType: item.contentType, createdAt: item.createdAt)
        }
    }

    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/><d:getetag/><d:getcontenttype/></d:prop></d:propfind>
    """
}
