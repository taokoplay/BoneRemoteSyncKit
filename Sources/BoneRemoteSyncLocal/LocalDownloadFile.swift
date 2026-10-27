import Foundation
import Darwin
import BoneRemoteSyncCore

/// Pins the input and part identities before any truncation. This is not a sandbox against
/// malicious parent-directory replacement; the host must exclusively own its output paths.
final class LocalDownloadFile {
    let source: URL
    let destination: URL
    let part: URL
    let input: FileHandle
    let original: stat

    init(source: URL, destination: URL) throws {
        guard destination.isFileURL, destination.host == nil || destination.host == "localhost",
              !destination.path.isEmpty, destination.path != "/", !destination.hasDirectoryPath,
              !destination.path.utf8.contains(0) else {
            throw RemoteSyncError.unsupported(operation: "本地下载目标不是普通文件路径")
        }
        self.source = source
        self.destination = destination.standardizedFileURL
        part = self.destination.appendingPathExtension("part")
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posix(source.path) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw RemoteSyncError.unsupported(operation: "本地下载源不是普通文件")
        }
        input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        original = info
    }

    deinit { try? input.close() }

    private func validate(overwrite: Bool, offset: Int64) throws {
        if let target = try Self.info(destination) {
            guard overwrite, target.st_mode & S_IFMT == S_IFREG, target.st_nlink == 1,
                  !Self.sameIdentity(target, original) else {
                throw RemoteSyncError.conflict(path: destination.path)
            }
        }
        if let partial = try Self.info(part) {
            guard partial.st_mode & S_IFMT == S_IFREG, partial.st_nlink == 1,
                  !Self.sameIdentity(partial, original), offset == 0 || partial.st_size == offset else {
                throw RemoteSyncError.conflict(path: part.path)
            }
        } else if offset > 0 { throw RemoteSyncError.conflict(path: part.path) }
    }

    func transfer(options: RemoteDownloadOptions) throws {
        let offset = options.resumeFrom ?? 0
        guard offset >= 0, offset <= original.st_size else {
            throw RemoteSyncError.unsupported(operation: "本地下载续传偏移无效")
        }
        try Task.checkCancellation()
        try validate(overwrite: options.overwrite, offset: offset)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Do not unlink or O_TRUNC an existing path: verify the opened inode first.
        let flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (offset == 0 ? O_CREAT : 0)
        let fd = Darwin.open(part.path, flags, mode_t(0o600))
        guard fd >= 0 else { throw Self.posix(part.path) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              !Self.sameIdentity(opened, original), offset == 0 || opened.st_size == offset else {
            throw RemoteSyncError.conflict(path: part.path)
        }
        try validate(overwrite: options.overwrite, offset: offset)
        guard let currentPart = try Self.info(part), Self.sameIdentity(currentPart, opened) else {
            throw RemoteSyncError.conflict(path: part.path)
        }
        try Task.checkCancellation()
        if offset == 0 { try output.truncate(atOffset: 0) }
        try input.seek(toOffset: UInt64(offset))
        try output.seek(toOffset: UInt64(offset))
        var written = offset
        options.reportTransferred(written, total: original.st_size)
        while true {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: 1 << 20) ?? Data()
            if bytes.isEmpty { break }
            guard Int64(bytes.count) <= original.st_size - written else {
                throw RemoteSyncError.integrityMismatch(path: destination.path)
            }
            try output.write(contentsOf: bytes)
            written += Int64(bytes.count)
            options.reportTransferred(written, total: original.st_size)
        }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(input.fileDescriptor, &after) == 0,
              let sourceNow = try Self.info(source), Self.sameVersion(after, original),
              Self.sameVersion(sourceNow, original) else { throw RemoteSyncError.conflict(path: source.path) }
        if options.verifySize, written != original.st_size {
            throw RemoteSyncError.integrityMismatch(path: destination.path)
        }
        try output.synchronize()
        try validate(overwrite: options.overwrite, offset: 0)
        var final = stat()
        guard fstat(fd, &final) == 0, let current = try Self.info(part),
              Self.sameIdentity(final, opened), Self.sameIdentity(current, opened),
              final.st_nlink == 1, current.st_nlink == 1, final.st_size == written else {
            throw RemoteSyncError.conflict(path: part.path)
        }
        // Preserve ordinary permissions of an existing destination, but never copy setuid,
        // setgid or sticky bits onto downloaded content. New files retain private part mode.
        let targetMode = options.overwrite ? try Self.info(destination)?.st_mode : nil
        guard fchmod(fd, (targetMode ?? final.st_mode) & 0o777) == 0 else { throw Self.posix(part.path) }
        try output.synchronize()
        try Task.checkCancellation()
        let result = options.overwrite
            ? rename(part.path, destination.path)
            : renamex_np(part.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.posix(destination.path) }
        // rename is the commit point. A subsequent close failure cannot undo installation.
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func info(_ url: URL) throws -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw posix(url.path)
        }
        return value
    }

    private static func posix(_ path: String) -> RemoteSyncError {
        switch errno {
        case ENOENT: return .notFound(path: path)
        case EACCES, EPERM, EROFS: return .permissionDenied(path: path)
        case EEXIST, ELOOP, EISDIR, ENOTDIR, ENOTEMPTY: return .conflict(path: path)
        default: return .underlying("本地下载文件错误（\(errno)）")
        }
    }
}
