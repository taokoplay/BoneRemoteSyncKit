import Foundation

/// A source wrapper that enforces the permissions selected for a persisted source profile.
/// Every file operation is checked before reaching the adapter.
public final class RemoteAccessControlledSource: RemoteCopyingSource, Sendable {
    public let source: any RemoteSource
    public let permission: RemoteAccessPermission

    /// 默认只读；即使传入空集合或仅写权限，也会补齐必选的读取权限。
    public init(source: any RemoteSource, permission: RemoteAccessPermission = .readOnly) {
        self.source = source
        self.permission = permission.union(.readOnly)
    }

    public var kind: RemoteSourceKind { source.kind }

    public var capabilities: RemoteCapabilities {
        var value = source.capabilities
        let canRead = permission.contains(.readOnly)
        let canUpload = !permission.intersection([.edit, .create]).isEmpty
        value.list = value.list && canRead
        value.stat = value.stat && canRead
        value.download = value.download && canRead
        value.rangedDownload = value.rangedDownload && canRead
        value.idAddressing = value.idAddressing && canRead
        value.changeFeed = value.changeFeed && canRead
        value.contentHash = value.contentHash && canRead
        value.upload = value.upload && canUpload
        value.resumableUpload = value.resumableUpload && canUpload
        value.conditionalUpload = value.conditionalUpload && permission.contains(.edit)
        value.makeDirectory = value.makeDirectory && permission.contains(.create)
        value.remove = value.remove && permission.contains(.delete)
        value.move = value.move && permission.contains(.edit)
        value.copy = value.copy && permission.contains([.readOnly, .create])
        return value
    }

    public func connect(_ credential: RemoteCredential) async throws { try await source.connect(credential) }
    public func disconnect() async { await source.disconnect() }
    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        try check(.readOnly, path: path)
        return try await source.list(path: path, request: request)
    }
    public func stat(path: String) async throws -> RemoteEntry {
        try check(.readOnly, path: path)
        return try await source.stat(path: path)
    }
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        try check(.readOnly, path: entry.path ?? entry.id)
        return try await source.download(entry, to: destination, options: options)
    }

    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions) async throws -> RemoteEntry {
        guard !permission.intersection([.edit, .create]).isEmpty else {
            throw RemoteSyncError.permissionDenied(path: path)
        }
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "上传文件")
        }
        let checkedOptions = try await uploadOptions(options, path: path)
        return try await writable.upload(from: localURL, to: path, options: checkedOptions)
    }

    public func makeDirectory(path: String) async throws {
        try check(.create, path: path)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "创建目录")
        }
        try await writable.makeDirectory(path: path)
    }

    public func remove(path: String) async throws {
        try check(.delete, path: path)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "删除")
        }
        try await writable.remove(path: path)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try check(.edit, path: sourcePath)
        guard let writable = source as? any RemoteWritableSource else {
            throw RemoteSyncError.unsupported(operation: "移动")
        }
        try await writable.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try check(.readOnly, path: sourcePath)
        try check(.create, path: destinationPath)
        guard let copying = source as? any RemoteCopyingSource else {
            throw RemoteSyncError.unsupported(operation: "复制")
        }
        try await copying.copy(from: sourcePath, to: destinationPath)
    }

    private func check(_ required: RemoteAccessPermission, path: String) throws {
        guard permission.contains(required) else {
            throw RemoteSyncError.permissionDenied(path: path)
        }
    }

    private func uploadOptions(_ options: RemoteUploadOptions, path: String) async throws -> RemoteUploadOptions {
        if options.expectedETag != nil {
            // A conditional upload can only update an existing version, never create a file.
            try check(.edit, path: path)
            return options
        }
        if !options.overwrite {
            try check(.create, path: path)
            return options
        }
        if permission.contains([.edit, .create]) { return options }

        // Inspect the target to distinguish creation from editing an existing file.
        let existing: RemoteEntry?
        do { existing = try await source.stat(path: path) }
        catch RemoteSyncError.notFound { existing = nil }
        var checked = options
        if let existing {
            try check(.edit, path: path)
            // Preserve the observed version where the adapter supports conditional writes.
            // Other adapters retain their existing cross-process coordination requirements.
            if source.capabilities.conditionalUpload, let etag = existing.etag {
                checked.expectedETag = etag
            }
        } else {
            try check(.create, path: path)
            // A concurrent creator must never turn create-only access into an overwrite.
            checked.overwrite = false
        }
        return checked
    }
}
