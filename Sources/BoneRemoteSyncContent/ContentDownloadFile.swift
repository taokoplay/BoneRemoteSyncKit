import Foundation
import Darwin
import BoneRemoteSyncCore

/// Exclusive per-operation staging. Delegate owns writes until HTTP invalidation completes.
package final class ContentDownloadFile: @unchecked Sendable {
    private let destination: URL
    private let staging: URL
    package let lockKey: String
    private var handle: FileHandle?
    private var identity: (dev_t, ino_t)?
    private var installed = false

    package init(destination: URL) throws {
        guard destination.isFileURL, destination.host == nil || destination.host?.lowercased() == "localhost",
              destination.user == nil, destination.password == nil, destination.query == nil, destination.fragment == nil,
              !destination.hasDirectoryPath, !destination.path.isEmpty, destination.path != "/", !destination.path.contains("\0") else {
            throw RemoteSyncError.unsupported(operation: "Content download requires a local regular file")
        }
        self.destination = destination.standardizedFileURL
        guard !self.destination.hasDirectoryPath, self.destination.path != "/" else { throw ContentServerError.invalidReference }
        staging = self.destination.deletingLastPathComponent().appendingPathComponent(".bone-content-\(UUID()).tmp")
        var ancestor = self.destination.deletingLastPathComponent()
        var suffix = [self.destination.lastPathComponent]
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
        }
        lockKey = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
            .decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    deinit { cleanup() }

    package func validate(overwrite: Bool) throws {
        if let value = try Self.info(destination) {
            guard overwrite, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
                throw RemoteSyncError.conflict(path: destination.path)
            }
        }
    }
    func open() throws {
        guard handle == nil, identity == nil, !installed else { throw RemoteSyncError.conflict(path: destination.path) }
        do { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw RemoteSyncError.underlying("Content download directory creation failed") }
        let fd = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Self.posix(path: destination.path) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            Darwin.close(fd); throw RemoteSyncError.conflict(path: destination.path)
        }
        identity = (value.st_dev, value.st_ino)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func write(_ data: Data) throws {
        guard let handle else { throw ContentServerError.invalidResponse }
        var start = 0
        while start < data.count {
            let end = start + min(65536, data.count - start)
            do { try handle.write(contentsOf: data.subdata(in: start..<end)) }
            catch { throw RemoteSyncError.underlying("Content download write failed") }
            start = end
        }
    }
    func sync() throws {
        guard let handle else { throw ContentServerError.invalidResponse }
        guard fsync(handle.fileDescriptor) == 0 else { throw Self.posix(path: destination.path) }
    }
    /// Call synchronously after the provider's final generation/cancellation check.
    package func install(overwrite: Bool, bytes: Int64) throws {
        try validate(overwrite: overwrite)
        var opened = stat()
        guard bytes >= 0, let handle, let identity, fstat(handle.fileDescriptor, &opened) == 0,
              let current = try Self.info(staging), current.st_dev == identity.0, current.st_ino == identity.1,
              opened.st_dev == identity.0, opened.st_ino == identity.1,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1, opened.st_size == bytes,
              current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1 else { throw RemoteSyncError.conflict(path: destination.path) }
        guard !Task.isCancelled else { throw RemoteSyncError.cancelled }
        let result = overwrite ? rename(staging.path, destination.path) : renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.posix(path: destination.path) }
        installed = true
        try? handle.close(); self.handle = nil
    }
    package func cleanup() {
        try? handle?.close(); handle = nil
        guard !installed, let identity, let current = try? Self.info(staging),
              current.st_dev == identity.0, current.st_ino == identity.1 else { return }
        _ = unlink(staging.path)
    }
    private static func info(_ url: URL) throws -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw posix(path: url.path)
        }
        return value
    }
    private static func posix(path: String) -> RemoteSyncError {
        switch errno {
        case EACCES, EPERM, EROFS: return .permissionDenied(path: path)
        case EEXIST, ELOOP, EISDIR, ENOTDIR, ENOTEMPTY: return .conflict(path: path)
        case ENOENT: return .notFound(path: path)
        default: return .underlying("Content local file operation failed (\(errno))")
        }
    }
}

struct ContentDownloadSink: Sendable {
    let file: ContentDownloadFile
    let expectedSize: Int64?
    let options: RemoteDownloadOptions
}
