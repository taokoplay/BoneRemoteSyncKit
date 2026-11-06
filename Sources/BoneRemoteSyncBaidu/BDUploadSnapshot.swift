import Foundation
import CryptoKit
import Darwin
import BoneRemoteSyncCore

/// One upload owns this immutable snapshot. Reads use pread, so no shared file offset changes.
/// MD5 is required by Baidu's block protocol; it is not a trusted remote content checksum.
final class BDUploadSnapshot: @unchecked Sendable {
    static let blockSize = 4 * 1024 * 1024
    let size: Int64
    let blockMD5s: [String]
    private let file: FileHandle
    private let directory: FileHandle
    private let directoryURL: URL
    private let identity: stat

    /// Nonisolated async work leaves the source actor free for browsing and downloads.
    static func create(from source: URL, maximumBytes: Int64) async throws -> BDUploadSnapshot {
        try BDUploadSnapshot(source: source, maximumBytes: maximumBytes)
    }

    init(source: URL, maximumBytes: Int64) throws {
        try Self.checkCancellation()
        guard source.isFileURL, source.host == nil || source.host?.lowercased() == "localhost",
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil,
              !source.hasDirectoryPath, !source.path.isEmpty, !source.path.contains("\0") else {
            throw RemoteSyncError.unsupported(operation: "Baidu upload requires a local regular file")
        }
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { throw Self.localError() }
        defer { Darwin.close(sourceFD) }
        var before = stat()
        var named = stat()
        guard fstat(sourceFD, &before) == 0, lstat(source.path, &named) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              Self.unchanged(before, named) else { throw RemoteSyncError.sourceSnapshotMissing }
        guard before.st_size > 0 else {
            throw RemoteSyncError.unsupported(operation: "Baidu empty-file upload is not supported")
        }
        guard maximumBytes > 0, before.st_size <= maximumBytes else {
            throw RemoteSyncError.unsupported(operation: "Baidu upload exceeds the configured size limit")
        }

        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("bone-baidu-upload-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw Self.localError() }
        let temporary = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        let directoryFD = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            _ = rmdir(temporary.path)
            throw Self.localError()
        }
        let directoryHandle = FileHandle(fileDescriptor: directoryFD, closeOnDealloc: true)
        var fileIdentity: stat?
        var retained = false
        defer {
            if !retained {
                Self.removeOwned(directory: temporary, descriptor: directoryFD, file: fileIdentity)
                try? directoryHandle.close()
            }
        }
        let writeFD = openat(directoryFD, "snapshot", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard writeFD >= 0 else { throw Self.localError() }
        defer { Darwin.close(writeFD) }
        var created = stat()
        guard fstat(writeFD, &created) == 0, created.st_mode & S_IFMT == S_IFREG, created.st_nlink == 1 else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
        fileIdentity = created

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copied: Int64 = 0
        var blockBytes = 0
        var digest = Insecure.MD5()
        var hashes: [String] = []
        while copied < before.st_size {
            try Self.checkCancellation()
            let wanted = min(buffer.count, Int(before.st_size - copied), Self.blockSize - blockBytes)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteSyncError.sourceSnapshotMissing }
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < count {
                    try Self.checkCancellation()
                    let n = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: written), count - written)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw Self.localError() }
                    written += n
                }
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            }
            copied += Int64(count)
            blockBytes += count
            if blockBytes == Self.blockSize || copied == before.st_size {
                hashes.append(digest.finalize().map { String(format: "%02x", $0) }.joined())
                digest = Insecure.MD5()
                blockBytes = 0
            }
        }
        try Self.checkCancellation()
        var after = stat()
        guard fstat(sourceFD, &after) == 0, lstat(source.path, &named) == 0,
              Self.unchanged(before, after), Self.unchanged(before, named) else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
        guard fsync(writeFD) == 0, fchmod(writeFD, mode_t(0o400)) == 0 else { throw Self.localError() }
        var final = stat()
        guard fstat(writeFD, &final) == 0, final.st_size == copied, final.st_nlink == 1 else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
        let readFD = openat(directoryFD, "snapshot", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard readFD >= 0 else { throw Self.localError() }
        let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        var readable = stat()
        guard fstat(readFD, &readable) == 0, Self.unchanged(final, readable) else {
            try? readHandle.close()
            throw RemoteSyncError.sourceSnapshotMissing
        }
        size = copied
        blockMD5s = hashes
        file = readHandle
        directory = directoryHandle
        directoryURL = temporary
        identity = final
        retained = true
    }

    deinit {
        Self.removeOwned(directory: directoryURL, descriptor: directory.fileDescriptor, file: identity)
        try? file.close()
        try? directory.close()
    }

    /// At most one 4 MiB block is materialized, regardless of the whole file's size.
    func chunk(part: Int) throws -> Data {
        try Self.checkCancellation()
        guard blockMD5s.indices.contains(part) else { throw BaiduDriveError.invalidResponse }
        try validate()
        let offset = Int64(part) * Int64(Self.blockSize)
        let count = Int(min(Int64(Self.blockSize), size - offset))
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var copied = 0
            while copied < count {
                try Self.checkCancellation()
                let n = pread(file.fileDescriptor, bytes.baseAddress!.advanced(by: copied),
                              min(64 * 1024, count - copied), off_t(offset + Int64(copied)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw RemoteSyncError.sourceSnapshotMissing }
                copied += n
            }
        }
        try validate()
        guard Insecure.MD5.hash(data: result).map({ String(format: "%02x", $0) }).joined() == blockMD5s[part] else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
        return result
    }

    private func validate() throws {
        var current = stat()
        var named = stat()
        guard fstat(file.fileDescriptor, &current) == 0,
              fstatat(directory.fileDescriptor, "snapshot", &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.unchanged(identity, current), Self.unchanged(identity, named) else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    /// Never recursively remove a directory or unlink an object whose identity we do not own.
    private static func removeOwned(directory: URL, descriptor: Int32, file: stat?) {
        if let file {
            var current = stat()
            if fstatat(descriptor, "snapshot", &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == file.st_dev, current.st_ino == file.st_ino {
                _ = unlinkat(descriptor, "snapshot", 0)
            }
        }
        var opened = stat()
        var named = stat()
        if fstat(descriptor, &opened) == 0, lstat(directory.path, &named) == 0,
           opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
           named.st_mode & S_IFMT == S_IFDIR {
            _ = rmdir(directory.path)
        }
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw RemoteSyncError.cancelled }
    }

    private static func localError() -> RemoteSyncError {
        switch errno {
        case EACCES, EPERM: .permissionDenied(path: "Baidu upload source")
        case ENOENT: .notFound(path: "Baidu upload source")
        case ELOOP, EISDIR, ENOTDIR: .sourceSnapshotMissing
        default: .underlying("Baidu upload snapshot filesystem operation failed")
        }
    }
}
