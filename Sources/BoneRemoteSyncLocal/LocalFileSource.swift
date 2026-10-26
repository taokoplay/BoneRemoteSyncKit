import Foundation
import UniformTypeIdentifiers
import BoneRemoteSyncCore

/// 本地目录来源。
///
/// 两个用途：
/// 1. 测试桩 —— 不依赖任何服务器就能验证契约、下载与续传；
/// 2. iCloud 的基础 —— iCloud Drive 在 iOS/macOS 上就是"某个特殊目录里的文件"，
///    后续只需在这层之上补 `NSFileCoordinator` 与未下载占位文件的触发逻辑。
public actor LocalFileSource: RemoteCopyingSource {
    public nonisolated let kind: RemoteSourceKind = .local
    public nonisolated let capabilities = RemoteCapabilities(
        list: true,
        stat: true,
        download: true,
        rangedDownload: true,
        upload: true,
        resumableUpload: false,
        makeDirectory: true,
        remove: true,
        move: true,
        copy: true,
        changeFeed: false,
        contentHash: false,
        maxConcurrentTransfers: 4
    )

    let root: URL
    let fileManager = FileManager.default
    private var isConnected = false

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - RemoteSource

    public func connect(_ credential: RemoteCredential) async throws {
        guard case .anonymous = credential else {
            throw RemoteSyncError.authenticationFailed(reason: "本地目录不接受凭据")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RemoteSyncError.notFound(path: root.path)
        }
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        try requireConnected()
        try request.validate()
        let normalized = RemotePath.normalize(path)
        guard request.cursor == nil else {
            throw RemoteSyncError.unsupported(operation: "本地来源不支持游标分页")
        }
        let directory = try resolve(normalized)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw RemoteSyncError.notFound(path: normalized)
        }
        guard isDirectory.boolValue else {
            throw RemoteSyncError.unsupported(operation: "列出非目录条目")
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey,
        ]
        let parentPath = normalized
        var entries = try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            .compactMap { url -> RemoteEntry? in
                guard request.includeHidden || !url.lastPathComponent.hasPrefix(".") else { return nil }
                return try? makeEntry(for: url, at: RemotePath.join(parentPath, url.lastPathComponent))
            }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // 本地来源一次性返回全部；仍保留游标字段以兼容契约。
        return RemoteListPage(entries: entries, nextCursor: nil)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        try requireConnected()
        let url = try resolve(path)
        let normalized = RemotePath.normalize(path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RemoteSyncError.notFound(path: normalized)
        }
        return try makeEntry(for: url, at: normalized)
    }

    public func download(
        _ entry: RemoteEntry,
        to destination: URL,
        options: RemoteDownloadOptions
    ) async throws -> RemoteEntry {
        try requireConnected()
        guard !entry.isDirectory else {
            throw RemoteSyncError.unsupported(operation: "下载目录")
        }

        let remotePath = RemotePath.normalize(entry.path ?? "/" + entry.id)
        let sourceURL = try resolve(remotePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RemoteSyncError.notFound(path: remotePath)
        }

        let current = try makeEntry(for: sourceURL, at: remotePath)
        if let expected = options.expectedETag, let actual = current.etag, expected != actual {
            throw RemoteSyncError.conflict(path: remotePath)
        }
        try withFileErrors(path: destination.path) {
            // Resolve only the source alias already validated to be inside the configured root.
            let pinnedSource = try canonicalURL(sourceURL, path: remotePath)
            let transfer = try LocalDownloadFile(source: pinnedSource, destination: destination)
            try transfer.transfer(options: options)
        }

        return current
    }

    // MARK: - 内部

    func requireConnected() throws {
        guard isConnected else { throw RemoteSyncError.notConnected }
    }

    /// 解析到根目录下的真实 URL，并阻断越界（含符号链接出逃）。
    func resolve(_ path: String) throws -> URL {
        // Foundation 的 file URL 可能截断包含 NUL 的路径，不能让它变成另一个有效目标。
        let normalized = RemotePath.normalize(path)
        guard !path.utf8.contains(0) else { throw RemoteSyncError.permissionDenied(path: normalized) }
        let relative = RemotePath.relative(normalized)
        let url = relative.isEmpty
            ? root
            : root.appendingPathComponent(relative, isDirectory: false)
        let resolvedRoot = try canonicalURL(root, path: normalized).path
        let resolvedURL = try canonicalURL(url, path: normalized).path
        let rootPrefix = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        guard resolvedURL == resolvedRoot || resolvedURL.hasPrefix(rootPrefix) else {
            throw RemoteSyncError.permissionDenied(path: normalized)
        }
        return url
    }

    /// `path` 必须由调用方按来源内路径显式给出。
    /// 不能用 `url.path` 与 `root.path` 做前缀比较来反推相对路径：
    /// FileManager 返回的 URL 可能已被解析成 /private/var/...，与 /var/... 的根不一致，
    /// 前缀失配会算出空路径，进而在递归遍历里导致自我循环。
    func makeEntry(for url: URL, at path: String) throws -> RemoteEntry {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey,
        ])
        let isDirectory = values.isDirectory ?? false
        let normalized = RemotePath.normalize(path)
        let relative = RemotePath.relative(normalized)
        let size = isDirectory ? nil : Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate
        return RemoteEntry(
            id: relative,
            path: normalized,
            name: url.lastPathComponent,
            type: isDirectory ? .directory : .file,
            size: size,
            modifiedAt: modified,
            etag: Self.fingerprint(size: size, modifiedAt: modified),
            contentType: values.contentType?.preferredMIMEType,
            createdAt: values.creationDate
        )
    }

    /// 本地来源的 etag：size + 毫秒级 mtime。精度足够，且不需要读文件内容。
    private static func fingerprint(size: Int64?, modifiedAt: Date?) -> String? {
        guard let size else { return nil }
        let millis = Int64((modifiedAt ?? .distantPast).timeIntervalSince1970 * 1000)
        return "\(size)-\(millis)"
    }

}
