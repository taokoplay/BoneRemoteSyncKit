import Foundation

/// 宿主负责恢复本地目录 bookmark 或 security-scoped 授权，并在会话结束时释放 lease。
public protocol RemoteLocalAccessResolver: Sendable {
    /// 根据持久化引用恢复本地目录访问权限。
    func resolve(reference: String) async throws -> RemoteLocalAccessLease
}
/// 覆盖一个 Catalog 会话生命周期的本地目录访问租约。
public final class RemoteLocalAccessLease: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?
    /// 创建本地目录访问租约；rootURL 必须是有效的本地文件 URL。
    public init(rootURL: URL, release: @escaping @Sendable () -> Void) throws {
        guard rootURL.isFileURL, !rootURL.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
        self.rootURL = rootURL; releaseAction = release
    }
    /// 释放宿主持有的目录访问权限；重复调用安全。
    public func release() {
        let action = lock.withLock { let value = releaseAction; releaseAction = nil; return value }
        action?()
    }
    deinit { release() }
}
