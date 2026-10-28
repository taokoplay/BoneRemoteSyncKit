import Foundation

/// Public identity for one prepared resumable upload.
///
/// The handle is deliberately opaque: it contains no session URL, bearer token,
/// cookie, file descriptor, or other provider credential. A provider may persist
/// the secret session record privately and use this value to retrieve it.
public struct RemoteUploadHandle: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let source: RemoteSourceBinding
    public let target: RemoteFileReference
    public let sourceSize: Int64
    /// Provider-local immutable snapshot fingerprint, not a remote ETag.
    public let sourceFingerprint: String

    public init(
        id: UUID = UUID(),
        source: RemoteSourceBinding,
        target: RemoteFileReference,
        sourceSize: Int64,
        sourceFingerprint: String
    ) throws {
        guard sourceSize >= 0,
              target.source == source,
              !sourceFingerprint.isEmpty,
              sourceFingerprint.utf8.count <= 256,
              !sourceFingerprint.contains(where: { $0.isWhitespace }) else {
            throw RemoteSyncError.unsupported(operation: "可恢复上传句柄")
        }
        self.id = id
        self.source = source
        self.target = target
        self.sourceSize = sourceSize
        self.sourceFingerprint = sourceFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, target, sourceSize, sourceFingerprint
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            source: values.decode(RemoteSourceBinding.self, forKey: .source),
            target: values.decode(RemoteFileReference.self, forKey: .target),
            sourceSize: values.decode(Int64.self, forKey: .sourceSize),
            sourceFingerprint: values.decode(String.self, forKey: .sourceFingerprint)
        )
    }
}

/// Provider-confirmed upload state. Byte progress is never derived from a
/// local upload callback; it is updated only after a server response or status
/// query identifies the accepted range.
public enum RemoteUploadPhase: String, Sendable, Hashable, Codable {
    case preparing
    case creationUnknown
    case abortUnknown
    case uploading
    case reconciling
    case conflict
    case needsAuthorization
    case sessionExpired
    case sourceSnapshotMissing
    case committed
    case committedCleanupPending
    case aborted
    case unknown
}

public struct RemoteUploadCheckpoint: Sendable, Hashable, Codable {
    public let handle: RemoteUploadHandle
    public let confirmedBytes: Int64
    public let totalBytes: Int64
    public let phase: RemoteUploadPhase
    public let expiresAt: Date?

    public init(
        handle: RemoteUploadHandle,
        confirmedBytes: Int64,
        totalBytes: Int64,
        phase: RemoteUploadPhase,
        expiresAt: Date? = nil
    ) throws {
        guard totalBytes == handle.sourceSize, totalBytes >= 0, confirmedBytes >= 0, confirmedBytes <= totalBytes else {
            throw RemoteSyncError.conflict(path: "upload-checkpoint")
        }
        self.handle = handle
        self.confirmedBytes = confirmedBytes
        self.totalBytes = totalBytes
        self.phase = phase
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case handle, confirmedBytes, totalBytes, phase, expiresAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(handle: c.decode(RemoteUploadHandle.self, forKey: .handle),
                      confirmedBytes: c.decode(Int64.self, forKey: .confirmedBytes),
                      totalBytes: c.decode(Int64.self, forKey: .totalBytes),
                      phase: c.decode(RemoteUploadPhase.self, forKey: .phase),
                      expiresAt: c.decodeIfPresent(Date.self, forKey: .expiresAt))
    }
}

public enum RemoteUploadCommitState: String, Sendable, Hashable, Codable {
    case committed
    case committedCleanupPending
    case needsReconciliation
}

public struct RemoteResumableUploadResult: Sendable {
    public let entry: RemoteEntry?
    public let handle: RemoteUploadHandle
    public let state: RemoteUploadCommitState
    public let confirmedBytes: Int64
    public let totalBytes: Int64

    public init(
        entry: RemoteEntry?,
        handle: RemoteUploadHandle,
        state: RemoteUploadCommitState,
        confirmedBytes: Int64,
        totalBytes: Int64
    ) throws {
        guard totalBytes == handle.sourceSize, totalBytes >= 0, confirmedBytes >= 0, confirmedBytes <= totalBytes else {
            throw RemoteSyncError.conflict(path: "upload-result")
        }
        guard state == .needsReconciliation || (entry != nil && confirmedBytes == totalBytes) else {
            throw RemoteSyncError.conflict(path: "upload-result")
        }
        self.entry = entry
        self.handle = handle
        self.state = state
        self.confirmedBytes = confirmedBytes
        self.totalBytes = totalBytes
    }
}

/// Provider-owned resumable upload contract. The provider controls its secret
/// session record and decides how a local immutable snapshot is retained.
public struct RemoteResumableUploadOptions: Sendable {
    public var overwrite: Bool
    public var expectedETag: String?
    public var contentType: String?
    /// Stable private local directory controlled by the host. The provider stores
    /// an immutable snapshot here. The host must keep this directory outside sync roots.
    public var snapshotDirectory: URL
    /// Must be a positive multiple of 320 KiB and less than 60 MiB.
    public var chunkSize: Int64
    /// Reports the contiguous prefix confirmed by the provider, not bytes sent.
    public var progress: (@Sendable (Int64) -> Void)?

    public init(
        overwrite: Bool = false,
        expectedETag: String? = nil,
        contentType: String? = nil,
        snapshotDirectory: URL,
        chunkSize: Int64 = 5 * 1024 * 1024,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.overwrite = overwrite
        self.expectedETag = expectedETag
        self.contentType = contentType
        self.snapshotDirectory = snapshotDirectory
        self.chunkSize = chunkSize
        self.progress = progress
    }
}

/// Source-specific upload session support. The target reference carries the
/// host-provided binding so a handle cannot silently move to another account.
public protocol RemoteResumableUploadSource: RemoteSource {
    /// Local preparation only. Persist the returned handle before calling uploadResuming.
    func prepareResumableUpload(
        from localURL: URL,
        to target: RemoteFileReference,
        options: RemoteResumableUploadOptions
    ) async throws -> RemoteUploadHandle

    func uploadResuming(
        _ handle: RemoteUploadHandle,
        options: RemoteResumableUploadOptions? ,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> RemoteResumableUploadResult

    func uploadCheckpoint(
        _ handle: RemoteUploadHandle
    ) async throws -> RemoteUploadCheckpoint?

    /// Abort is explicit and best-effort. A returned unknown/reconciliation
    /// error never claims that already committed remote bytes were rolled back.
    func abortResumableUpload(
        _ handle: RemoteUploadHandle
    ) async throws
}
