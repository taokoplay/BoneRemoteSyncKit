import Foundation
import Darwin
import BoneRemoteSyncCore

/// One operation exclusively owns this store. No cross-process lock or hostile-directory sandbox.
final class DAVCheckpointStore: @unchecked Sendable {
    let target: WebDAVDownloadTarget
    let binding: DAVCheckpointBinding
    var url: URL { target.part.appendingPathExtension("checkpoint.json") }
    private let lock = NSLock()
    private var observed = false
    private var identity: Identity?
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let seconds: Int64
        let nanos: Int64
        init(_ info: stat) {
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
            seconds = Int64(info.st_mtimespec.tv_sec); nanos = Int64(info.st_mtimespec.tv_nsec)
        }
    }
    init(target: WebDAVDownloadTarget, binding: DAVCheckpointBinding) { self.target = target; self.binding = binding }

    func load() throws -> DAVCheckpointRecord? { try lock.withLock { try readLocked() } }

    private func readLocked() throws -> DAVCheckpointRecord? {
        guard let info = try information() else {
            if observed, identity != nil { throw conflict() }
            observed = true; identity = nil
            return nil
        }
        let current = Identity(info)
        if observed, identity != current { throw conflict() }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw conflict() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, Identity(opened) == current,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw conflict() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024 + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 64 * 1024 else { throw conflict() }
        }
        let record: DAVCheckpointRecord
        do { record = try JSONDecoder().decode(DAVCheckpointRecord.self, from: data) }
        catch { throw conflict() }
        try record.validate()
        guard record.binding == binding else { throw conflict() }
        observed = true; identity = current
        return record
    }

    func save(_ record: DAVCheckpointRecord, hooks: DAVRecoveryTestHooks = .none) throws {
        try lock.withLock {
            try record.validate()
            guard record.binding == binding else { throw conflict() }
            _ = try readLocked()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= 64 * 1024 else { throw conflict() }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID()).tmp")
            let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw RemoteSyncError.permissionDenied(path: url.path) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); _ = unlink(temporary.path) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try hooks.call(.beforeCheckpointRename)
            let current = try information().map(Identity.init)
            guard current == identity else { throw conflict() }
            guard rename(temporary.path, url.path) == 0 else { throw RemoteSyncError.permissionDenied(path: url.path) }
            identity = try information().map(Identity.init)
            observed = true
        }
    }

    func removeIfMatching(_ record: DAVCheckpointRecord) throws {
        try lock.withLock {
            guard let saved = try readLocked() else { return }
            guard saved == record, try information().map(Identity.init) == identity else { throw conflict() }
            guard unlink(url.path) == 0 else { throw RemoteSyncError.permissionDenied(path: url.path) }
            observed = true; identity = nil
        }
    }

    private func information() throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw conflict()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 64 * 1024 else { throw conflict() }
        return info
    }
    private func conflict() -> RemoteSyncError { .conflict(path: url.path) }
}
