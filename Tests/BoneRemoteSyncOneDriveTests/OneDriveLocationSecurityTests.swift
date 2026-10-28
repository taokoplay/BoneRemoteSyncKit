#if os(macOS)
import Foundation
import Security
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

private final class RecordingUploadSecurityBackend: ODUploadSecurityBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var lastQuery: [String: Any] = [:]
    var failUpdate = false

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            lastQuery = query
            let key = query[kSecAttrAccount as String] as? String ?? ""
            guard let value = values[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, value)
        }
    }
    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            lastQuery = query
            let key = query[kSecAttrAccount as String] as? String ?? ""
            guard values[key] == nil else { return errSecDuplicateItem }
            values[key] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            lastQuery = query
            if failUpdate { return errSecAuthFailed }
            let key = query[kSecAttrAccount as String] as? String ?? ""
            guard values[key] != nil else { return errSecItemNotFound }
            values[key] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            lastQuery = query
            let key = query[kSecAttrAccount as String] as? String ?? ""
            values.removeValue(forKey: key)
            return errSecSuccess
        }
    }
}

@Suite struct OneDriveLocationSecurityTests {
    private let fixture = ODEndpoints(
        graph: URL(string: "http://127.0.0.1:8765/v1.0/")!,
        authority: URL(string: "http://127.0.0.1:8765/oauth/")!,
        allowsLoopback: true
    )
    private let production = ODEndpoints.production

    @Test func keychainStoreUsesDeviceOnlyNonSynchronizingPrivateService() throws {
        let backend = RecordingUploadSecurityBackend()
        let service = try OneDriveUploadSessionStore(service: "fixture-session", backend: backend)
        let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "onedrive:D")
        let target = RemoteFileReference(source: binding, path: "/file.bin")
        let handle = try RemoteUploadHandle(source: binding, target: target, sourceSize: 3, sourceFingerprint: "abc")
        let id = handle.id
        let record = ODUploadSessionRecord(handle: handle,
                                           uploadURL: URL(string: "https://uploads.example.com/session?token=secret")!,
                                           expirationDate: nil,
                                           snapshotURL: URL(fileURLWithPath: "/private/snapshot"), snapshotDevice: 0, snapshotInode: 0,
                                           contentType: "application/octet-stream",
                                           overwrite: true,
                                           expectedETag: nil,
                                           chunkSize: 320 * 1024,
                                           binding: binding,
                                           driveID: "D", blockDigests: Data(repeating: 0, count: 32))
        try service.insert(record)
        let query = backend.lastQuery
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(query[kSecAttrService as String] as? String == "fixture-session")
        do {
            let loaded = try service.read(id)
            #expect(loaded?.handle == handle)
        } catch {
            Issue.record("读取会话记录失败：\(error)")
        }
        try service.replace(record)
        backend.failUpdate = true
        #expect(throws: RemoteSyncError.secureStorageUnavailable) { try service.replace(record) }
        try service.remove(id)
    }

    @Test func acceptsOnlyExplicitFixtureLoopbackHTTP() throws {
        #expect(throws: Never.self) {
            try ODLocation.validateUploadSessionURL(
                URL(string: "http://127.0.0.1:8765/upload-session/abc")!, endpoints: fixture
            )
        }
        #expect(throws: RemoteSyncError.self) {
            try ODLocation.validateUploadSessionURL(
                URL(string: "http://127.0.0.1:8765/upload-session/abc")!, endpoints: production
            )
        }
        #expect(throws: RemoteSyncError.self) {
            try ODLocation.validateUploadSessionURL(
                URL(string: "http://127.0.0.1:8766/upload-session/abc")!, endpoints: fixture
            )
        }
    }

    @Test func acceptsPreauthorizedQueryButRejectsCredentialsFragmentPrivateAndAmbiguousHosts() throws {
        #expect(throws: Never.self) {
            try ODLocation.validateUploadSessionURL(
                URL(string: "https://uploads.example.com/session?tempauth=secret")!, endpoints: production
            )
        }
        let urls = [
            "https://uploads.example.com/session#fragment",
            "https://user:password@uploads.example.com/session",
            "https://uploads.example.com./session",
            "https://uploads.example.com.local/session",
            "https://uploads.example.com:8443/session",
            "https://127.0.0.1/session",
            "https://10.0.0.1/session",
            "https://2130706433/session"
        ]
        for raw in urls {
            #expect(throws: RemoteSyncError.self) {
                try ODLocation.validateUploadSessionURL(URL(string: raw)!, endpoints: production)
            }
        }
    }

    @Test func acceptsConstrainedProductionHTTPSHost() throws {
        #expect(throws: Never.self) {
            try ODLocation.validateUploadSessionURL(
                URL(string: "https://sn3302.up.1drv.com/upload-session/abc")!, endpoints: production
            )
        }
    }
}
#endif
