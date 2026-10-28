import Foundation
import BoneRemoteSyncCore

/// Explicit provider-owned upload recovery. Separate from the download queue:
/// no automatic scheduling, connection changes, retries or hidden session creation.
/// Persist prepare's handle before resume. The provider owns snapshots, secret
/// session persistence and cooperative transaction exclusion.
public struct RemoteUploadRecovery: Sendable {
    public let binding: RemoteSourceBinding
    private let source: any RemoteSource

    public init(source: any RemoteSource, binding: RemoteSourceBinding) {
        self.source = source
        self.binding = binding
    }

    private func provider(_ reference: RemoteFileReference) throws -> any RemoteResumableUploadSource {
        guard reference.source == binding, source.kind == binding.kind else {
            throw RemoteSyncError.conflict(path: "upload-binding")
        }
        guard source.capabilities.resumableUpload,
              let provider = source as? any RemoteResumableUploadSource else {
            throw RemoteSyncError.unsupported(operation: "来源未启用受管理恢复上传")
        }
        return provider
    }

    public func prepare(from localURL: URL, to target: RemoteFileReference,
                        options: RemoteResumableUploadOptions) async throws -> RemoteUploadHandle {
        try await provider(target).prepareResumableUpload(from: localURL, to: target, options: options)
    }

    public func resume(_ handle: RemoteUploadHandle,
                       progress: (@Sendable (Int64) -> Void)? = nil) async throws -> RemoteResumableUploadResult {
        // Do not check cancellation after returning an authoritative commit receipt.
        try await provider(handle.target).uploadResuming(handle, options: nil, progress: progress)
    }

    public func checkpoint(_ handle: RemoteUploadHandle) async throws -> RemoteUploadCheckpoint? {
        try await provider(handle.target).uploadCheckpoint(handle)
    }

    public func abort(_ handle: RemoteUploadHandle) async throws {
        try await provider(handle.target).abortResumableUpload(handle)
    }
}
