import Foundation
import BoneRemoteSyncCore

extension BaiduDriveSource {
    /// 前台完整下载。Range、checkpoint与强条件版本读取尚未声明支持。
    @discardableResult
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        let ctx = try context()
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "百度网盘首期不支持恢复或强条件下载")
        }
        guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载目录") }
        _ = try BDLocation.fsid(entry.id, binding: ctx.binding)
        let file = try BDDownloadFile(destination: destination)
        guard destinations.insert(file.lockKey).inserted else { throw RemoteSyncError.conflict(path: destination.path) }
        defer { file.cleanup(); destinations.remove(file.lockKey) }
        try file.validate(overwrite: options.overwrite)
        let before = try await item(id: entry.id, dlink: true, context: ctx)
        guard !before.entry.isDirectory, let size = before.entry.size, let raw = before.dlink,
              entry.size == nil || entry.size == size,
              entry.modifiedAt == nil || entry.modifiedAt == before.entry.modifiedAt else { throw RemoteSyncError.conflict(path: "Baidu resource") }
        let access = try await downloadToken(context: ctx)
        try check(ctx)
        let url = try BDLocation.download(raw, token: access, endpoints: endpoints)
        let result = try await ctx.client.send(URLRequest(url: url), sink: .init(file: file, expectedSize: size, options: options))
        try check(ctx)
        let after = try await item(id: entry.id, context: ctx)
        guard after.entry.id == before.entry.id, after.entry.size == size, !after.entry.isDirectory,
              after.entry.modifiedAt == before.entry.modifiedAt, after.cloudHash == before.cloudHash else {
            throw RemoteSyncError.conflict(path: "Baidu resource")
        }
        // This is observed change detection, not an atomic remote version lock or content hash proof.
        try check(ctx)
        try file.install(overwrite: options.overwrite, bytes: result.transferredBytes)
        return before.entry
    }
}
