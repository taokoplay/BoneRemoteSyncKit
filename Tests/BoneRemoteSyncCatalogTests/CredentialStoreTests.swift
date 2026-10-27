import Foundation
import Security
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

final class MemorySecurityBackend: CatalogSecurityBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    var failure: OSStatus? { get { lock.withLock { failureValue } } set { lock.withLock { failureValue = newValue } } }
    private var failureValue: OSStatus?
    private(set) var sawDeviceOnly = false
    private func key(_ query: [String: Any]) -> String {
        (query[kSecAttrService as String] as? String ?? "") + ":" + (query[kSecAttrAccount as String] as? String ?? "")
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock { if let failureValue { return (failureValue, nil) }; let value = data[key(query)]; return (value == nil ? errSecItemNotFound : errSecSuccess, value) }
    }
    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if let failureValue { return failureValue }
            guard data[key(query)] == nil else { return errSecDuplicateItem }
            sawDeviceOnly = query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                && query[kSecAttrSynchronizable as String] as? Bool == false
                && query[kSecAttrAccessGroup as String] == nil
            data[key(query)] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if let failureValue { return failureValue }
            guard data[key(query)] != nil else { return errSecItemNotFound }
            data[key(query)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if let failureValue { return failureValue }
            return data.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

@Suite struct CredentialStoreTests {
    @Test func completeRecordRotatesAndServicesAndAccountsAreIsolated() throws {
        let backend = MemorySecurityBackend()
        let a = try KeychainRemoteCredentialStore(service: "test.A", backend: backend)
        let b = try KeychainRemoteCredentialStore(service: "test.B", backend: backend)
        let ref = UUID(); let other = UUID()
        let original = RemoteCredential.oauth(accessToken: "ACCESS-secret", refreshToken: "REFRESH-secret", expiresAt: Date(timeIntervalSince1970: 12345))
        let rotated = RemoteCredential.oauth(accessToken: "ROTATED-secret", refreshToken: "NEW-refresh", expiresAt: Date(timeIntervalSince1970: 99999))
        #expect(try a.read(reference: ref) == nil)
        try a.insert(original, reference: ref)
        #expect(try a.read(reference: ref) == original)
        #expect(try b.read(reference: ref) == nil && a.read(reference: other) == nil)
        #expect(backend.sawDeviceOnly)
        #expect(throws: RemoteCredentialStoreError.alreadyExists) { try a.insert(rotated, reference: ref) }
        try a.replace(rotated, reference: ref)
        #expect(try a.read(reference: ref) == rotated)
        try a.remove(reference: ref)
        #expect(throws: RemoteCredentialStoreError.missing) { try a.replace(rotated, reference: ref) }
        #expect(try a.read(reference: ref) == nil)
    }
    @Test func inaccessibleStoreDoesNotLookLikeAnonymousOrMissing() throws {
        let backend = MemorySecurityBackend(); let store = try KeychainRemoteCredentialStore(service: "test", backend: backend)
        backend.failure = errSecInteractionNotAllowed
        #expect(throws: RemoteCredentialStoreError.unavailable(errSecInteractionNotAllowed)) { try store.read(reference: UUID()) }
        #expect(throws: RemoteCredentialStoreError.unavailable(errSecInteractionNotAllowed)) { try store.insert(.apiToken("SECRET"), reference: UUID()) }
    }
    @Test func revokedHandleCannotRecreateOrOverwriteCredentials() throws {
        let backend = MemorySecurityBackend(); let store = try KeychainRemoteCredentialStore(service: "test", backend: backend)
        let reference = UUID(); try store.insert(.apiToken("original"), reference: reference)
        let handle = CatalogCredentialHandle(reference: reference, store: store)
        try handle.replace(.apiToken("rotated"))
        #expect(try store.read(reference: reference) == .apiToken("rotated"))
        handle.revoke(); try store.remove(reference: reference)
        #expect(throws: RemoteCredentialStoreError.revoked) { try handle.replace(.apiToken("late")) }
        #expect(try store.read(reference: reference) == nil)
    }
}
