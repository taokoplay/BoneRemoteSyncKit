import Foundation
import BoneRemoteSyncCore

extension OPDSSource {
    /// 前台整文件下载；仅接受当前会话签发且未被修改的文件描述。
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        let current = try connected()
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "OPDS 首期不支持恢复或条件下载")
        }
        guard let path = entry.path, let resource = resources[path], resource.entry == entry else { throw OPDSError.invalidReference }
        let file = try OPDSDownloadFile(destination: destination)
        guard destinations.insert(file.lockKey).inserted else { throw RemoteSyncError.conflict(path: destination.path) }
        defer { file.cleanup(); destinations.remove(file.lockKey) }
        try file.validate(overwrite: options.overwrite)
        let result = try await current.client.send(resource.url, catalog: false,
            sink: .init(file: file, mediaType: resource.mediaType, options: options))
        try check(current)
        // No suspension between the lifecycle gate and the atomic commit.
        try file.install(overwrite: options.overwrite, bytes: result.transferredBytes)
        return entry
    }
}
