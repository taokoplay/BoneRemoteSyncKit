import Foundation
import Darwin
import BoneRemoteSyncCore

/// A private, bounded-memory snapshot keeps URLSession from reopening a caller-controlled path.
/// The caller must not modify the original during snapshotting; metadata checks detect ordinary
/// replacement/size/mtime changes, but are not an adversarial filesystem sandbox.
final class DAVUploadSnapshot: Sendable {
    let url: URL
    let size: Int64
    private let directory: URL
    private init(url: URL, size: Int64, directory: URL) {
        self.url = url; self.size = size; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func create(from localURL: URL, scope: DAVOperationScope) async throws -> DAVUploadSnapshot {
        try scope.check()
        guard localURL.isFileURL, !localURL.path.utf8.contains(0) else {
            throw RemoteSyncError.unsupported(operation: "上传非本地文件")
        }
        guard let before = try WebDAVDownloadTarget.information(localURL) else {
            throw RemoteSyncError.notFound(path: localURL.path)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw RemoteSyncError.unsupported(operation: "上传非普通文件")
        }
        let fd = Darwin.open(localURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WebDAVDownloadTarget.posix(path: localURL.path) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var opened = Darwin.stat()
        guard fstat(fd, &opened) == 0, same(before, opened), opened.st_mode & S_IFMT == S_IFREG, opened.st_size >= 0 else {
            throw RemoteSyncError.conflict(path: localURL.path)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneDAVUpload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent("body")
        let outFD = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard outFD >= 0 else { throw WebDAVDownloadTarget.posix(path: localURL.path) }
        let output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        defer { try? output.close() }
        var count: Int64 = 0
        while true {
            try scope.check()
            let data = try input.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            guard Int64(data.count) <= opened.st_size - count else { throw RemoteSyncError.conflict(path: localURL.path) }
            try output.write(contentsOf: data)
            count += Int64(data.count)
        }
        var after = Darwin.stat()
        guard fstat(fd, &after) == 0, same(opened, after), count == opened.st_size,
              let current = try WebDAVDownloadTarget.information(localURL), same(opened, current) else {
            throw RemoteSyncError.conflict(path: localURL.path)
        }
        try output.close()
        try scope.check()
        handedOff = true
        return DAVUploadSnapshot(url: url, size: count, directory: directory)
    }

    private static func same(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
        && lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
