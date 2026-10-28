import Foundation
import Darwin
import CryptoKit
import BoneRemoteSyncCore

private struct FileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    func sameObject(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino }
}

private func metadata(_ url: URL) -> stat? {
    var value = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else { return nil }
    return value
}

/// This is an exclusive, private cache, not a defense against an attacker who can
/// rename its parent directories. Ancestors must remain caller-owned and stable.
struct ManagedMaterializedFile: Sendable {
    let url: URL
    fileprivate let directory: URL
    fileprivate let root: URL
    fileprivate let rootIdentity: FileIdentity
    fileprivate let directoryIdentity: FileIdentity
    fileprivate let identity: FileIdentity

    fileprivate var ownsDirectory: Bool {
        guard let r = metadata(root), let d = metadata(directory) else { return false }
        return r.st_mode & S_IFMT == S_IFDIR && d.st_mode & S_IFMT == S_IFDIR
            && rootIdentity.sameObject(r) && directoryIdentity.sameObject(d)
    }
    var isUnchanged: Bool {
        guard ownsDirectory, let file = metadata(url), file.st_mode & S_IFMT == S_IFREG,
              file.st_nlink == 1 else { return false }
        return FileIdentity(file) == identity
    }
    @discardableResult func remove() -> Bool {
        guard ownsDirectory else { return false }
        do { try FileManager.default.removeItem(at: directory); return true }
        catch { return false }
    }
}

final class MaterializationTransaction {
    let staging: URL
    private let root: URL
    private let directory: URL
    private let final: URL
    private let rootIdentity: FileIdentity
    private let directoryIdentity: FileIdentity
    private var verified: FileIdentity?
    private var committed = false

    init(cacheDirectory: URL) throws {
        guard cacheDirectory.isFileURL, cacheDirectory.host == nil || cacheDirectory.host == "localhost" else {
            throw RemoteSyncError.unsupported(operation: "缓存必须为本地文件目录")
        }
        root = cacheDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let r = metadata(root), r.st_mode & S_IFMT == S_IFDIR else {
            throw RemoteSyncError.permissionDenied(path: "materialization-cache")
        }
        rootIdentity = FileIdentity(r)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        guard let d = metadata(directory), d.st_mode & S_IFMT == S_IFDIR else {
            throw RemoteSyncError.permissionDenied(path: "materialization-staging")
        }
        directoryIdentity = FileIdentity(d)
        staging = directory.appendingPathComponent("content.staging")
        final = directory.appendingPathComponent("content")
    }

    private func validateDirectories() throws {
        guard let r = metadata(root), rootIdentity.sameObject(r), r.st_mode & S_IFMT == S_IFDIR,
              let d = metadata(directory), directoryIdentity.sameObject(d), d.st_mode & S_IFMT == S_IFDIR else {
            throw RemoteSyncError.conflict(path: "materialization-directory")
        }
    }

    func verify(expectedSize: Int64?, checksum: RemoteContentChecksum? = nil) throws {
        try validateDirectories()
        let descriptor = staging.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw RemoteSyncError.integrityMismatch(path: "materialization-staging") }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              expectedSize == nil || value.st_size == expectedSize else {
            throw RemoteSyncError.integrityMismatch(path: "materialization-staging")
        }
        let before = FileIdentity(value)
        if let checksum {
            guard checksum.algorithm == .sha256 else {
                throw RemoteSyncError.unsupported(operation: "物化校验目前仅支持 SHA-256")
            }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RemoteSyncError.integrityMismatch(path: "materialization-checksum")
                }
                hasher.update(data: Data(buffer.prefix(count)))
            }
            guard Data(hasher.finalize()) == checksum.digest else {
                throw RemoteSyncError.integrityMismatch(path: "materialization-checksum")
            }
        }
        guard fstat(descriptor, &value) == 0, FileIdentity(value) == before else {
            throw RemoteSyncError.conflict(path: "materialization-staging")
        }
        verified = before
    }

    func commit() throws -> ManagedMaterializedFile {
        try validateDirectories()
        guard let verified, let value = metadata(staging), value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, FileIdentity(value) == verified else {
            throw RemoteSyncError.conflict(path: "materialization-staging")
        }
        let descriptor = directory.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw RemoteSyncError.permissionDenied(path: "materialization-directory") }
        defer { close(descriptor) }
        var d = stat()
        guard fstat(descriptor, &d) == 0, directoryIdentity.sameObject(d) else {
            throw RemoteSyncError.conflict(path: "materialization-directory")
        }
        // Same directory/device; no copy fallback and no overwrite of another file.
        guard renameatx_np(descriptor, "content.staging", descriptor, "content", UInt32(RENAME_EXCL)) == 0 else {
            throw RemoteSyncError.underlying("文件物化原子安装失败")
        }
        guard let installed = metadata(final), verified.sameObject(installed), installed.st_nlink == 1 else {
            throw RemoteSyncError.integrityMismatch(path: "materialization-content")
        }
        committed = true
        return ManagedMaterializedFile(url: final, directory: directory, root: root,
                                       rootIdentity: rootIdentity, directoryIdentity: directoryIdentity,
                                       identity: FileIdentity(installed))
    }

    func cleanupUncommitted() {
        guard !committed, (try? validateDirectories()) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
