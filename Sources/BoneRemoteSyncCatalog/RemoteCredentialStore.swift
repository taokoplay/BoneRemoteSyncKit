import Foundation
import BoneRemoteSyncCore

/// 凭据安全存储协议。实现必须线程安全，并以原子方式保存完整凭据。
/// 凭据不得写入 Catalog SQLite、日志或普通配置文件。
public protocol RemoteCredentialStore: Sendable {
    var coordinationID: String { get }
    /// 按引用读取凭据；引用不存在时返回 `nil`。
    func read(reference: UUID) throws -> RemoteCredential?
    /// Must fail if the reference already exists; never overwrite a previous binding during creation.
    /// 插入新凭据；引用已存在时必须失败，不能覆盖旧绑定。
    func insert(_ credential: RemoteCredential, reference: UUID) throws
    /// Must fail when the record is absent; rotation must never recreate a logged-out credential.
    /// 替换已有凭据；记录不存在时必须失败，避免重新创建已注销的凭据。
    func replace(_ credential: RemoteCredential, reference: UUID) throws
    /// 删除指定凭据引用。
    func remove(reference: UUID) throws
}

/// 凭据安全存储操作失败原因。
public enum RemoteCredentialStoreError: Error, Sendable, Equatable {
    case unavailable(Int32)
    case missing
    case alreadyExists
    case invalidRecord
    case revoked
}

/// A fixed immutable binding, with synchronous revocation serialized against token writes.
final class CatalogCredentialHandle: @unchecked Sendable {
    let reference: UUID
    let store: any RemoteCredentialStore
    private let lock = NSLock()
    private var revoked = false
    init(reference: UUID, store: any RemoteCredentialStore) { self.reference = reference; self.store = store }
    func replace(_ credential: RemoteCredential) throws {
        try lock.withLock {
            guard !revoked else { throw RemoteCredentialStoreError.revoked }
            try store.replace(credential, reference: reference)
        }
    }
    func revoke() { lock.withLock { revoked = true } }
}

// Private wire representation: it is used ONLY inside the secure credential store, never in SQLite.
enum StoredCredential: Codable {
    case anonymous
    case basic(username: String, password: String)
    case smb(username: String, password: String, domain: String?)
    case apiToken(String)
    case oauth(accessToken: String, refreshToken: String?, expiresAt: Date?)

    init(_ value: RemoteCredential) {
        switch value {
        case .anonymous: self = .anonymous
        case .basic(let user, let password): self = .basic(username: user, password: password)
        case .smb(let user, let password, let domain): self = .smb(username: user, password: password, domain: domain)
        case .apiToken(let token): self = .apiToken(token)
        case .oauth(let access, let refresh, let expires): self = .oauth(accessToken: access, refreshToken: refresh, expiresAt: expires)
        }
    }
    var credential: RemoteCredential {
        switch self {
        case .anonymous: .anonymous
        case .basic(let user, let password): .basic(username: user, password: password)
        case .smb(let user, let password, let domain): .smb(username: user, password: password, domain: domain)
        case .apiToken(let token): .apiToken(token)
        case .oauth(let access, let refresh, let expires): .oauth(accessToken: access, refreshToken: refresh, expiresAt: expires)
        }
    }
}
