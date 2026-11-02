import Foundation
import BoneRemoteSyncCore

/// Explicit provider-owned upload recovery. Separate from the download queue:
/// no automatic scheduling, connection changes, retries or hidden session creation.
/// Persist prepare's handle before resume. The provider owns snapshots, secret
/// session persistence and cooperative transaction exclusion.
/// 显式可恢复上传服务；不自动调度、重连、重试或隐式创建远端会话。
public struct RemoteUploadRecovery: Sendable {
    public let binding: RemoteSourceBinding
    private let source: any RemoteSource

    /// 创建固定来源绑定的恢复上传服务。
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

    /// 准备本地不可变快照并保存可恢复上传句柄。
    public func prepare(from localURL: URL, to target: RemoteFileReference,
                        options: RemoteResumableUploadOptions) async throws -> RemoteUploadHandle {
        try await provider(target).prepareResumableUpload(from: localURL, to: target, options: options)
    }

    /// 使用已保存句柄继续上传，并返回服务端确认的最终状态。
    public func resume(_ handle: RemoteUploadHandle,
                       progress: (@Sendable (Int64) -> Void)? = nil) async throws -> RemoteResumableUploadResult {
        // Do not check cancellation after returning an authoritative commit receipt.
        try await provider(handle.target).uploadResuming(handle, options: nil, progress: progress)
    }

    /// 读取来源确认的上传检查点。
    public func checkpoint(_ handle: RemoteUploadHandle) async throws -> RemoteUploadCheckpoint? {
        try await provider(handle.target).uploadCheckpoint(handle)
    }

    /// 显式终止远端上传会话并清理来源管理的快照。
    public func abort(_ handle: RemoteUploadHandle) async throws {
        try await provider(handle.target).abortResumableUpload(handle)
    }
}
