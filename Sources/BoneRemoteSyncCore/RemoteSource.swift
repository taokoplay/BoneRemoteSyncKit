import Foundation

/// 来源类型。用于 UI 分组、能力预设和诊断，不参与业务分支判断。
public enum RemoteSourceKind: String, Sendable, Codable, CaseIterable {
    case local
    case smb
    case webdav
    case ftp
    case sftp
    case nfs
    /// 厂商 OpenAPI（百度网盘、阿里云盘、OneDrive、Google Drive…）。
    case cloudAPI
    /// iCloud Drive：本质是本地文件 + 协调器，不是网络协议。
    case iCloud
    /// 只读媒体源，不具备文件系统语义。
    case dlna

    /// DLNA 这类"媒体源"要走不同的 UI 路径，不能混进文件浏览器。
    public var isFileSystemLike: Bool { self != .dlna }
}

/// 统一来源契约。
///
/// 只有"读"的必备能力放在这里；写操作放在 `RemoteWritableSource`，
/// 这样只读来源（DLNA、只读网盘、iCloud 只读挂载）不会被迫实现空方法。
///
/// 实现建议用 `actor`，`kind` 与 `capabilities` 声明为 `nonisolated let`。
public protocol RemoteSource: Sendable {
    var kind: RemoteSourceKind { get }
    var capabilities: RemoteCapabilities { get }

    /// 建立会话。凭据错误使用 `RemoteSyncError.authenticationFailed`。
    /// 来源可另行公开结构化诊断错误；具体错误类型与恢复策略以来源合同为准。
    func connect(_ credential: RemoteCredential) async throws

    /// 释放连接与临时资源。重复调用必须安全。
    func disconnect() async

    /// 列出一层目录。路径不存在抛 `.notFound`。
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage

    func stat(path: String) async throws -> RemoteEntry

    /// 下载到本地文件。最终目标只安装完整内容；失败可保留来源约定的 staging/part。
    /// 取消或错误不能撤回已完成的原子安装。
    func download(
        _ entry: RemoteEntry,
        to destination: URL,
        options: RemoteDownloadOptions
    ) async throws -> RemoteEntry
}

public extension RemoteSource {
    func list(path: String) async throws -> RemoteListPage {
        try await list(path: path, request: .all)
    }

    /// 先 stat 再下载，顺带拿到真实大小与 etag 用于续传校验。
    @discardableResult
    func download(
        path: String,
        to destination: URL,
        options: RemoteDownloadOptions = RemoteDownloadOptions()
    ) async throws -> RemoteEntry {
        let entry = try await stat(path: path)
        guard !entry.isDirectory else {
            throw RemoteSyncError.unsupported(operation: "下载目录")
        }
        return try await download(entry, to: destination, options: options)
    }

    /// 顺序浏览子树，可产出来源返回的部分列表，不证明完整性。
    /// 需要完整扫描时使用带 `RemoteWalkOptions` 的 visitor 重载；不要据此流删除缺失条目。
    func walk(
        path: String,
        includeHidden: Bool = false
    ) -> AsyncThrowingStream<RemoteEntry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var stack: [String] = [RemotePath.normalize(path)]
                    while let current = stack.popLast() {
                        var cursor: String?
                        repeat {
                            let page = try await list(
                                path: current,
                                request: RemoteListRequest(cursor: cursor, includeHidden: includeHidden)
                            )
                            for entry in page.entries {
                                continuation.yield(entry)
                                if entry.isDirectory, let childPath = entry.path {
                                    stack.append(childPath)
                                }
                            }
                            cursor = page.nextCursor
                        } while cursor != nil
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 可写来源。UI 依据 `capabilities` 决定展示哪些操作，实现方按需遵循本协议。
public protocol RemoteWritableSource: RemoteSource {
    func upload(
        from localURL: URL,
        to path: String,
        options: RemoteUploadOptions
    ) async throws -> RemoteEntry

    /// 递归创建目录；已经存在的目录视为成功。
    func makeDirectory(path: String) async throws

    /// 删除文件或递归删除目录。实现方必须拒绝删除来源根目录。
    func remove(path: String) async throws

    /// 移动文件或目录，不覆盖已存在目标；调用方需先创建目标父目录。
    func move(from sourcePath: String, to destinationPath: String) async throws
}

/// 可选的来源内复制能力。未提供复制接口的来源不能将 capabilities.copy 声明为 true。
/// 不要求所有可写来源实现复制，以兼容没有服务端复制 API 的网盘。
public protocol RemoteCopyingSource: RemoteWritableSource {
    /// 复制文件或目录，不覆盖已存在目标；调用方需先创建目标父目录。
    func copy(from sourcePath: String, to destinationPath: String) async throws
}
