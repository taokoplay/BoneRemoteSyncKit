import Foundation
import BoneRemoteSyncCore

extension LocalFileSource {
    /// 递归创建目录，已经存在的目录视为成功；不会把文件替换成目录。
    public func makeDirectory(path: String) async throws {
        try requireConnected()
        let normalized = RemotePath.normalize(path)
        try withFileErrors(path: normalized) {
            try Task.checkCancellation()
            let url = try resolve(normalized)
            if itemExists(at: url) {
                let entry = try makeEntry(for: url, at: normalized)
                guard entry.isDirectory else { throw RemoteSyncError.conflict(path: normalized) }
                return
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 删除文件或递归删除目录。来源根及解析后指向根的别名不可删除。
    public func remove(path: String) async throws {
        try requireConnected()
        let normalized = RemotePath.normalize(path)
        try withFileErrors(path: normalized) {
            try Task.checkCancellation()
            let url = try mutationURL(normalized)
            guard itemExists(at: url) else { throw RemoteSyncError.notFound(path: normalized) }
            try fileManager.removeItem(at: url)
        }
    }

    /// 来源内复制文件或目录。Foundation 保留 symlink 本身，不遍历其外部目标。
    /// 不覆盖目标，也不自动创建目标父目录。
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try requireConnected()
        let source = RemotePath.normalize(sourcePath)
        let destination = RemotePath.normalize(destinationPath)
        try withFileErrors(path: destination) {
            try Task.checkCancellation()
            let (sourceURL, destinationURL) = try relocationURLs(from: source, to: destination)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    /// 移动文件或目录。不覆盖目标，也不自动创建目标父目录。
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try requireConnected()
        let source = RemotePath.normalize(sourcePath)
        let destination = RemotePath.normalize(destinationPath)
        try withFileErrors(path: destination) {
            try Task.checkCancellation()
            let (sourceURL, destinationURL) = try relocationURLs(from: source, to: destination)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}
