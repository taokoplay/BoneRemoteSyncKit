import Foundation
import BoneRemoteSyncCore

extension LocalFileSource {
    /// 将一个普通本地文件写入来源。失败和取消清理本次 staging，不留半成品在目标位置。
    /// 本实现尚不支持上传续传；contentType 由文件扩展名推导，不写入 MIME 元数据。
    @discardableResult
    public func upload(
        from localURL: URL,
        to path: String,
        options: RemoteUploadOptions = .init()
    ) async throws -> RemoteEntry {
        try requireConnected()
        guard options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "本地来源不支持条件上传")
        }
        let normalized = RemotePath.normalize(path)
        guard localURL.isFileURL else { throw RemoteSyncError.unsupported(operation: "上传非本地文件") }
        return try withFileErrors(path: normalized) {
            try Task.checkCancellation()
            guard itemExists(at: localURL) else { throw RemoteSyncError.notFound(path: localURL.path) }
            let before = try fileManager.attributesOfItem(atPath: localURL.path)
            guard before[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteSyncError.unsupported(operation: "上传非普通文件")
            }

            let destination = try mutationURL(normalized)
            if itemExists(at: destination) {
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                guard options.overwrite, attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw RemoteSyncError.conflict(path: normalized)
                }
            }
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            // 父目录创建后再次核对边界。
            _ = try mutationURL(normalized)
            let (staging, output) = try createUploadStaging(in: parent)
            defer {
                try? output.close()
                try? fileManager.removeItem(at: staging)
            }
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            var written: Int64 = 0
            options.progress?(0)
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
                options.progress?(written)
            }
            try Task.checkCancellation()
            // URLResourceValues 会缓存同一个 URL 的元数据，不能用于传输后的复验。
            let after = try fileManager.attributesOfItem(atPath: localURL.path)
            guard before[.size] as? NSNumber == after[.size] as? NSNumber,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
                throw RemoteSyncError.conflict(path: localURL.path)
            }
            guard written == (before[.size] as? NSNumber)?.int64Value else {
                throw RemoteSyncError.integrityMismatch(path: normalized)
            }
            try output.synchronize()
            try output.close()
            try installUploadStaging(staging, at: destination, path: normalized, overwrite: options.overwrite)
            return try makeEntry(for: destination, at: normalized)
        }
    }
}
