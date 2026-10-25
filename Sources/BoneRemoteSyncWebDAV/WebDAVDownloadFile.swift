import Foundation
import Darwin
import BoneRemoteSyncCore

/// 下载的本地文件事务。响应通过验证后才打开 part；失败保留 part，成功 rename 安装。
/// 不提供对恶意外部目录替换的系统级 sandbox。
struct WebDAVDownloadTarget {
    let destination: URL
    let part: URL
    let lockKey: String

    init(destination: URL) throws {
        guard destination.isFileURL, !destination.path.isEmpty, destination.path != "/",
              !destination.path.utf8.contains(0), !destination.hasDirectoryPath else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 下载目标不是普通文件路径")
        }
        self.destination = destination.standardizedFileURL
        part = self.destination.appendingPathExtension("part")
        var ancestor = self.destination.deletingLastPathComponent()
        var suffix: [String] = [self.destination.lastPathComponent]
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw RemoteSyncError.permissionDenied(path: destination.path) }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        // 保守统一 Unicode 与大小写等价，避免默认 APFS 上大小写别名共享同一 part。
        // 在大小写敏感卷也使用该规则：可误拒绝并发，不允许互相改写已返回的目标。
        lockKey = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
            .decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func validate(overwrite: Bool, offset: Int64) throws {
        if let info = try Self.information(destination) {
            guard info.st_mode & S_IFMT == S_IFREG, overwrite else { throw RemoteSyncError.conflict(path: destination.path) }
        }
        if let info = try Self.information(part) {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw RemoteSyncError.conflict(path: part.path) }
            if offset > 0, info.st_size != offset { throw RemoteSyncError.conflict(path: part.path) }
        } else if offset > 0 { throw RemoteSyncError.conflict(path: part.path) }
    }

    func open(offset: Int64) throws -> FileHandle {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 不使用 O_TRUNC：先验证打开的描述符类型/链接数，再决定是否清空。
        let flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | (offset > 0 ? 0 : O_CREAT)
        let descriptor = Darwin.open(part.path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.posix(path: part.path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, offset == 0 || info.st_size == offset else {
            Darwin.close(descriptor)
            throw RemoteSyncError.conflict(path: part.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            if offset == 0 { try handle.truncate(atOffset: 0) }
            try handle.seek(toOffset: UInt64(offset))
            return handle
        } catch { try? handle.close(); throw error }
    }

    func install(handle: FileHandle, overwrite: Bool) throws {
        try validate(overwrite: overwrite, offset: 0)
        var opened = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0,
              let current = try Self.information(part),
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            throw RemoteSyncError.conflict(path: part.path)
        }
        try Task.checkCancellation()
        let result = overwrite ? rename(part.path, destination.path) : renamex_np(part.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.posix(path: destination.path) }
    }

    static func information(_ url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posix(path: url.path)
        }
        return info
    }

    static func posix(path: String) -> RemoteSyncError {
        switch errno {
        case ENOENT: return .notFound(path: path)
        case EACCES, EPERM, EROFS: return .permissionDenied(path: path)
        case EEXIST, ELOOP, EISDIR, ENOTDIR, ENOTEMPTY: return .conflict(path: path)
        default: return .underlying("WebDAV 本地文件错误（\(errno)）")
        }
    }
}
