import Foundation

/// The permission saved with a Catalog source profile.
/// 保存于来源配置中的文件访问权限。
public enum RemoteAccessPermission: String, Sendable, Codable, Equatable, CaseIterable {
    case readOnly
    case editor

    var allowsMutation: Bool { self == .editor }
}

/// A source wrapper that enforces the permission selected for a persisted source profile.
/// Read operations are delegated unchanged; every mutation is checked before reaching the adapter.
public final class RemoteAccessControlledSource: RemoteCopyingSource, @unchecked Sendable {
    public let source: any RemoteSource
    public let permission: RemoteAccessPermission

    public init(source: any RemoteSource, permission: RemoteAccessPermission) {
        self.source = source
        self.permission = permission
    }

    public var kind: RemoteSourceKind { source.kind }

    public var capabilities: RemoteCapabilities {
        guard permission.allowsMutation else {
            var value = source.capabilities
            value.upload = false
            value.resumableUpload = false
            value.makeDirectory = false
            value.remove = false
            value.move = false
            value.conditionalUpload = false
            value.copy = false
            return value
        }
        return source.capabilities
    }

    public func connect(_ credential: RemoteCredential) async throws { try await source.connect(credential) }
    public func disconnect() async { await source.disconnect() }
    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        try await source.list(path: path, request: request)
    }
    public func stat(path: String) async throws -> RemoteEntry { try await source.stat(path: path) }
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        try await source.download(entry, to: destination, options: options)
    }

    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions) async throws -> RemoteEntry {
        try checkMutation("上传文件", path: path)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "上传文件")
        }
        return try await writable.upload(from: localURL, to: path, options: options)
    }

    public func makeDirectory(path: String) async throws {
        try checkMutation("创建目录", path: path)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "创建目录")
        }
        try await writable.makeDirectory(path: path)
    }

    public func remove(path: String) async throws {
        try checkMutation("删除", path: path)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "删除")
        }
        try await writable.remove(path: path)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try checkMutation("移动", path: sourcePath)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "移动")
        }
        try await writable.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try checkMutation("复制", path: sourcePath)
        guard let copying = source as? any RemoteCopyingSource else {
            throw RemoteSyncError.unsupported(operation: "复制")
        }
        try await copying.copy(from: sourcePath, to: destinationPath)
    }

    private func checkMutation(_ operation: String, path: String) throws {
        guard permission.allowsMutation else {
            throw RemoteSyncError.permissionDenied(path: path)
        }
    }
}
