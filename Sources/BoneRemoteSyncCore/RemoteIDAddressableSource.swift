import Foundation

/// 可选的稳定 ID 读取合同。ID 由同一来源/账号返回，不是路径、下载 URL 或分页链接。
/// 不承诺跨账号、跨盘或跨来源有效，也不为路径型来源赋予重命名后稳定的身份。
public protocol RemoteIDAddressableSource: RemoteSource {
    /// 按来源返回的 ID 重新查询元数据；无法可靠还原当前路径时返回 path=nil。
    func stat(id: String) async throws -> RemoteEntry
    /// 按父目录 ID 列出一层；游标须绑定 ID 寻址模式、父 ID、选项及当前会话。
    func list(parentID: String, request: RemoteListRequest) async throws -> RemoteListPage
}

public extension RemoteIDAddressableSource {
    func list(parentID: String) async throws -> RemoteListPage {
        try await list(parentID: parentID, request: .all)
    }

    @discardableResult
    func download(id: String, to destination: URL, options: RemoteDownloadOptions = .init()) async throws -> RemoteEntry {
        let entry = try await stat(id: id)
        guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载目录") }
        return try await download(entry, to: destination, options: options)
    }
}
