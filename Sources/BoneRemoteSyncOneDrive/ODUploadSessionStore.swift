import Foundation
import Security
import BoneRemoteSyncCore

/// Private provider record. `uploadURL` is a pre-authenticated operation secret
/// and must never appear in a public model, log, checkpoint or Catalog row.
struct ODUploadSessionRecord: Codable, Sendable {
    let handle: RemoteUploadHandle
    var uploadURL: URL?
    var expirationDate: Date?
    let snapshotURL: URL
    let snapshotDevice: Int64
    let snapshotInode: UInt64
    let contentType: String
    let overwrite: Bool
    let expectedETag: String?
    let chunkSize: Int64
    let binding: RemoteSourceBinding
    let driveID: String
    var parentID: String?
    /// SHA-256 for each 320 KiB block, packed as 32-byte digests. Private only.
    let blockDigests: Data
    var phase: RemoteUploadPhase
    var confirmedBytes: Int64
    var committedEntry: RemoteEntry?

    init(handle: RemoteUploadHandle, uploadURL: URL? = nil, expirationDate: Date? = nil, snapshotURL: URL, snapshotDevice: Int64, snapshotInode: UInt64,
         contentType: String, overwrite: Bool, expectedETag: String?, chunkSize: Int64,
         binding: RemoteSourceBinding, driveID: String, parentID: String? = nil, blockDigests: Data,
         phase: RemoteUploadPhase = .preparing, confirmedBytes: Int64 = 0, committedEntry: RemoteEntry? = nil) {
        self.handle = handle; self.uploadURL = uploadURL; self.expirationDate = expirationDate
        self.snapshotDevice = snapshotDevice; self.snapshotInode = snapshotInode
        self.snapshotURL = snapshotURL; self.contentType = contentType; self.overwrite = overwrite
        self.expectedETag = expectedETag; self.chunkSize = chunkSize; self.binding = binding
        self.driveID = driveID; self.parentID = parentID; self.blockDigests = blockDigests
        self.phase = phase; self.confirmedBytes = confirmedBytes; self.committedEntry = committedEntry
    }
}

protocol ODUploadSessionStore: Sendable {
    func read(_ id: UUID) throws -> ODUploadSessionRecord?
    func insert(_ record: ODUploadSessionRecord) throws
    func replace(_ record: ODUploadSessionRecord) throws
    func remove(_ id: UUID) throws
}

/// Device-only, non-synchronizing Keychain store. The service is deliberately
/// supplied by the host and is not shared with CatalogRemoteCredentialStore.
final class OneDriveUploadSessionStore: ODUploadSessionStore, @unchecked Sendable {
    private let service: String
    private let backend: any ODUploadSecurityBackend

    init(service: String, backend: any ODUploadSecurityBackend = SystemODUploadSecurityBackend()) throws {
        guard !service.isEmpty, service.utf8.count <= 1024,
              !service.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 上传会话安全服务")
        }
        self.service = service
        self.backend = backend
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    private func encode(_ record: ODUploadSessionRecord) throws -> Data {
        guard (record.uploadURL?.absoluteString.utf8.count ?? 0) <= 32768,
              record.snapshotURL.isFileURL else {
            throw RemoteSyncError.secureStorageUnavailable
        }
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 1024 * 1024 else { throw RemoteSyncError.secureStorageUnavailable }
            return data
        }
        catch { throw RemoteSyncError.secureStorageUnavailable }
    }

    private func check(_ status: OSStatus, missingIsNil: Bool = false) throws -> Bool {
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound:
            if missingIsNil { return false }
            throw RemoteSyncError.secureStorageUnavailable
        case errSecDuplicateItem: throw RemoteSyncError.conflict(path: "upload-session")
        default: throw RemoteSyncError.secureStorageUnavailable
        }
    }

    func read(_ id: UUID) throws -> ODUploadSessionRecord? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copy(request)
        guard try check(status, missingIsNil: true), let data, data.count <= 1024 * 1024,
              let record = try? JSONDecoder().decode(ODUploadSessionRecord.self, from: data) else {
            if status == errSecItemNotFound { return nil }
            throw RemoteSyncError.secureStorageUnavailable
        }
        return record
    }

    func insert(_ record: ODUploadSessionRecord) throws {
        var request = query(record.handle.id)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecValueData as String] = try encode(record)
        _ = try check(backend.add(request))
    }

    func replace(_ record: ODUploadSessionRecord) throws {
        _ = try check(backend.update(query(record.handle.id), attributes: [kSecValueData as String: try encode(record)]))
    }

    func remove(_ id: UUID) throws {
        let status = backend.delete(query(id))
        if status != errSecSuccess && status != errSecItemNotFound { _ = try check(status) }
    }
}

protocol ODUploadSecurityBackend: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemODUploadSecurityBackend: ODUploadSecurityBackend {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
