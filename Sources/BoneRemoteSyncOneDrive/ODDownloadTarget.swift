import Foundation
import Darwin
import BoneRemoteSyncCore

/// One-operation staging file. Never adopts or removes a pre-existing .part/checkpoint.
final class ODDownloadTarget: @unchecked Sendable {
    let destination: URL
    let staging: URL
    let lockKey: String
    private var handle: FileHandle?
    private var identity: (dev_t, ino_t)?
    private var installed = false
    init(destination: URL) throws {
        guard destination.isFileURL, destination.host == nil || destination.host == "localhost",
              !destination.hasDirectoryPath, !destination.path.isEmpty, destination.path != "/", !destination.path.contains("\0") else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 下载目标不是本地普通文件路径")
        }
        self.destination = destination.standardizedFileURL
        staging = self.destination.deletingLastPathComponent().appendingPathComponent(".bone-onedrive-\(UUID()).tmp")
        var ancestor = self.destination.deletingLastPathComponent()
        var suffix = [self.destination.lastPathComponent]
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
        }
        lockKey = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
            .decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    deinit { cleanup() }
    func validate(overwrite: Bool) throws {
        if let value = try Self.info(destination) {
            guard overwrite, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw RemoteSyncError.conflict(path: destination.path) }
        }
    }
    func open() throws {
        guard handle == nil else { throw RemoteSyncError.conflict(path: destination.path) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Self.posix(path: destination.path) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            Darwin.close(fd); throw RemoteSyncError.conflict(path: destination.path)
        }
        identity = (value.st_dev, value.st_ino); handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func write(_ data: Data) throws {
        guard let handle else { throw RemoteSyncError.underlying("OneDrive staging 未打开") }
        // Bound application write sizes. URLSession supplies serial chunks; no unbounded user-space queue.
        var start = 0
        while start < data.count {
            let end = min(start + 65536, data.count)
            do { try handle.write(contentsOf: data.subdata(in: start..<end)) }
            catch { throw RemoteSyncError.underlying("OneDrive 本地写入失败") }
            start = end
        }
    }
    func sync() throws {
        guard let handle, fsync(handle.fileDescriptor) == 0 else { throw Self.posix(path: destination.path) }
    }
    /// Called by the source actor after its final generation/cancellation gate, with no await.
    func install(overwrite: Bool, bytes: Int64) throws {
        try validate(overwrite: overwrite)
        var opened = stat()
        guard let handle, let identity, fstat(handle.fileDescriptor, &opened) == 0,
              let current = try Self.info(staging), current.st_dev == identity.0, current.st_ino == identity.1,
              opened.st_dev == identity.0, opened.st_ino == identity.1,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1, opened.st_size == bytes,
              current.st_nlink == 1 else { throw RemoteSyncError.conflict(path: destination.path) }
        try Task.checkCancellation()
        let status = overwrite ? rename(staging.path, destination.path) : renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL))
        guard status == 0 else { throw Self.posix(path: destination.path) }
        installed = true // rename is the commit point. A later close failure cannot undo it.
        try? handle.close(); self.handle = nil
    }
    func cleanup() {
        try? handle?.close(); handle = nil
        guard !installed, let identity, let current = try? Self.info(staging), current.st_dev == identity.0, current.st_ino == identity.1 else { return }
        _ = unlink(staging.path)
    }
    private static func info(_ url: URL) throws -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { if errno == ENOENT { return nil }; throw posix(path: url.path) }
        return value
    }
    private static func posix(path: String) -> RemoteSyncError {
        switch errno {
        case EACCES, EPERM, EROFS: return .permissionDenied(path: path)
        case EEXIST, ELOOP, EISDIR, ENOTDIR, ENOTEMPTY: return .conflict(path: path)
        case ENOENT: return .notFound(path: path)
        default: return .underlying("OneDrive 本地文件错误（\(errno)）")
        }
    }
}

struct ODDownloadSink: Sendable {
    let target: ODDownloadTarget
    let expected: Int64
    let verifySize: Bool
    let progress: (@Sendable (Int64) -> Void)?
}
