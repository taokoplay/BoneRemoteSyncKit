import Foundation
import Darwin
import BoneRemoteSyncCore

extension WebDAVDownloadTarget {
    var reservedPaths: Set<String> { [lockKey, lockKey + ".part", lockKey + ".part.checkpoint.json"] }

    /// New managed parts must never truncate a file whose ownership is unknown.
    func createManagedPart() throws -> FileHandle {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(part.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.posix(path: part.path) }
        return try checkedHandle(descriptor, path: part)
    }

    func openManagedPart(installed: Bool = false) throws -> FileHandle {
        let path = installed ? destination : part
        guard let info = try Self.information(path), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw RemoteSyncError.conflict(path: path.path)
        }
        let descriptor = Darwin.open(path.path, (installed ? O_RDONLY : O_RDWR) | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.posix(path: path.path) }
        return try checkedHandle(descriptor, path: path)
    }

    private func checkedHandle(_ descriptor: Int32, path: URL) throws -> FileHandle {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              let current = try Self.information(path), opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
            Darwin.close(descriptor)
            throw RemoteSyncError.conflict(path: path.path)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func verifyManagedIdentity(handle: FileHandle, record: DAVCheckpointRecord, installed: Bool = false) throws {
        var opened = stat()
        let url = installed ? destination : part
        guard fstat(handle.fileDescriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              UInt64(opened.st_dev) == record.partDevice, UInt64(opened.st_ino) == record.partInode,
              opened.st_size >= record.committedBytes,
              let current = try Self.information(url), current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            throw RemoteSyncError.conflict(path: url.path)
        }
        if record.phase == .readyToInstall, opened.st_size != record.expectedSize { throw RemoteSyncError.conflict(path: url.path) }
    }
}
