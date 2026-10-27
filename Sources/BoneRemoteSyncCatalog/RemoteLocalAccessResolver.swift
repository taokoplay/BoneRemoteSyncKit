import Foundation

/// Host-owned bookmark/security-scope resolution. The lease must cover the complete connected session.
public protocol RemoteLocalAccessResolver: Sendable {
    func resolve(reference: String) async throws -> RemoteLocalAccessLease
}

public final class RemoteLocalAccessLease: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?
    public init(rootURL: URL, release: @escaping @Sendable () -> Void) throws {
        guard rootURL.isFileURL, !rootURL.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
        self.rootURL = rootURL; releaseAction = release
    }
    public func release() {
        let action = lock.withLock { let value = releaseAction; releaseAction = nil; return value }
        action?()
    }
    deinit { release() }
}
