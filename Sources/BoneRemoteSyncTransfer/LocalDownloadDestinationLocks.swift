import Foundation
import CryptoKit
import Darwin
import BoneRemoteSyncCore

/// Nonblocking advisory locks on a stable private LOCAL directory. All processes
/// must use this same directory and protocol. Not a network/distributed lock.
/// Lock files are retained (never unlink a live lock inode); crash closes fds.
/// The host must keep ancestors stable and prevent foreign mutation of this root.
public struct LocalDownloadDestinationLocks: RemoteDownloadDestinationLocking {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func acquire(destination: URL) async throws -> RemoteDownloadDestinationLease {
        try Task.checkCancellation()
        try Self.validateURL(directory, file: false)
        try Self.validateURL(destination, file: true)
        let keys = Self.reservedKeys(destination)
        let lockPath = Self.canonicalPath(directory.resolvingSymlinksInPath().path)
        guard keys.allSatisfy({ $0 != lockPath && !$0.hasPrefix(lockPath + "/") }) else {
            throw RemoteSyncError.conflict(path: "download-lock-directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard root >= 0 else { throw RemoteSyncError.conflict(path: "download-lock-directory") }
        defer { Darwin.close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw RemoteSyncError.conflict(path: "download-lock-directory")
        }
        var descriptors: [Int32] = []
        do {
            for key in keys.sorted() {
                try Task.checkCancellation()
                let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
                let fd = openat(root, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
                guard fd >= 0 else { throw RemoteSyncError.conflict(path: "download-destination-lock") }
                descriptors.append(fd)
                var opened = stat(); var current = stat()
                guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      opened.st_nlink == 1, opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
                      flock(fd, LOCK_EX | LOCK_NB) == 0,
                      fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                    throw RemoteSyncError.conflict(path: "download-destination-lock")
                }
            }
            let held = DownloadLockDescriptors(descriptors)
            return RemoteDownloadDestinationLease { held.close() }
        } catch {
            for fd in descriptors { Darwin.close(fd) }
            throw error
        }
    }

    private static func validateURL(_ url: URL, file: Bool) throws {
        guard url.isFileURL, url.host == nil || url.host == "localhost",
              !url.path.isEmpty, !url.path.utf8.contains(0),
              !file || (url.path != "/" && !url.hasDirectoryPath) else {
            throw RemoteSyncError.unsupported(operation: "恢复下载需要本地目录和普通文件目标")
        }
    }

    private static func reservedKeys(_ destination: URL) -> Set<String> {
        // Resolve existing ancestors, not the final component (which may be an
        // invalid symlink and must be rejected by the provider's target checks).
        let normalized = destination.standardizedFileURL
        let parent = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = canonicalPath(parent.appendingPathComponent(normalized.lastPathComponent).path)
        return [path, path + ".part", path + ".part.checkpoint.json"]
    }

    private static func canonicalPath(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private final class DownloadLockDescriptors: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]
    init(_ descriptors: [Int32]) { self.descriptors = descriptors }
    func close() { lock.withLock { for fd in descriptors { Darwin.close(fd) }; descriptors.removeAll() } }
    deinit { close() }
}
