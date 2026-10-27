import Foundation
import Security
import BoneRemoteSyncCore

/// Generic-password records, device-only, non-synchronizing, without an implicit access group.
/// The host chooses an app-specific service. Construction performs no Keychain access.
public final class KeychainRemoteCredentialStore: RemoteCredentialStore, @unchecked Sendable {
    public let coordinationID: String
    private let service: String
    private let backend: any CatalogSecurityBackend
    public convenience init(service: String) throws { try self.init(service: service, backend: SystemCatalogSecurityBackend()) }
    init(service: String, backend: any CatalogSecurityBackend) throws {
        guard CatalogValidation.text(service, max: 1024) else { throw RemoteCatalogError.invalidConfiguration }
        self.service = service; self.backend = backend
        coordinationID = "KeychainRemoteCredentialStore:" + service
    }
    private func query(_ reference: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: reference.uuidString, kSecAttrSynchronizable as String: false]
    }
    private func encoded(_ credential: RemoteCredential) throws -> Data {
        do { return try JSONEncoder().encode(StoredCredential(credential)) }
        catch { throw RemoteCredentialStoreError.invalidRecord }
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw RemoteCredentialStoreError.missing
        case errSecDuplicateItem: throw RemoteCredentialStoreError.alreadyExists
        default: throw RemoteCredentialStoreError.unavailable(status)
        }
    }
    public func read(reference: UUID) throws -> RemoteCredential? {
        var query = query(reference)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copy(query)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data, data.count <= 1024 * 1024,
              let value = try? JSONDecoder().decode(StoredCredential.self, from: data) else { throw RemoteCredentialStoreError.invalidRecord }
        return value.credential
    }
    public func insert(_ credential: RemoteCredential, reference: UUID) throws {
        var query = query(reference)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = try encoded(credential)
        try check(backend.add(query))
    }
    public func replace(_ credential: RemoteCredential, reference: UUID) throws {
        try check(backend.update(query(reference), attributes: [kSecValueData as String: try encoded(credential)]))
    }
    public func remove(reference: UUID) throws {
        let status = backend.delete(query(reference))
        if status != errSecItemNotFound { try check(status) }
    }
}

protocol CatalogSecurityBackend: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
struct SystemCatalogSecurityBackend: CatalogSecurityBackend {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
