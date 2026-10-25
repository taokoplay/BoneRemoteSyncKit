import Foundation
import Darwin
import BoneRemoteSyncCore

extension LocalFileSource {
    /// fileExists 不会识别悬空符号链接，而写操作不能把它当成空槽覆盖。
    func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// Foundation 在路径末端尚不存在时可能不解析父目录 symlink。
    /// 先找到最近的已存在祖先并 realpath，再拼接缺失部分，才能正确判断边界。
    func canonicalURL(_ url: URL, path: String) throws -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !itemExists(at: ancestor), ancestor.path != "/" {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                throw RemoteSyncError.permissionDenied(path: path)
            }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        guard let resolved = realpath(ancestor.path, nil) else {
            let code = errno
            if code == ENOENT || code == ELOOP {
                // 悬空/循环 symlink 不被视为可以安全新建的路径。
                throw RemoteSyncError.permissionDenied(path: path)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { free(resolved) }
        var canonical = URL(fileURLWithPath: String(cString: resolved))
        for component in suffix { canonical.appendPathComponent(component) }
        return canonical
    }

    func mutationURL(_ normalizedPath: String) throws -> URL {
        let url = try resolve(normalizedPath)
        let resolvedRoot = try canonicalURL(root, path: normalizedPath).path
        guard normalizedPath != "/", try canonicalURL(url, path: normalizedPath).path != resolvedRoot else {
            throw RemoteSyncError.permissionDenied(path: normalizedPath)
        }
        return url
    }

    /// move/copy 共同的非覆盖策略，以及目录不能移入自身子目录的校验。
    func relocationURLs(from source: String, to destination: String) throws -> (URL, URL) {
        let sourceURL = try mutationURL(source)
        guard itemExists(at: sourceURL) else { throw RemoteSyncError.notFound(path: source) }
        let destinationURL = try mutationURL(destination)
        guard !itemExists(at: destinationURL) else { throw RemoteSyncError.conflict(path: destination) }
        let entry = try makeEntry(for: sourceURL, at: source)
        if entry.isDirectory {
            let sourceResolved = try canonicalURL(sourceURL, path: source).path
            let destinationResolved = try canonicalURL(destinationURL, path: destination).path
            guard !destinationResolved.hasPrefix(sourceResolved + "/") else {
                throw RemoteSyncError.conflict(path: destination)
            }
        }
        return (sourceURL, destinationURL)
    }

    func withFileErrors<T>(path: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as RemoteSyncError { throw error }
        catch is CancellationError { throw RemoteSyncError.cancelled }
        catch {
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain {
                switch Int32(error.code) {
                case ENOENT: throw RemoteSyncError.notFound(path: path)
                case EACCES, EPERM, EROFS: throw RemoteSyncError.permissionDenied(path: path)
                case EEXIST, ENOTEMPTY, EISDIR, ENOTDIR: throw RemoteSyncError.conflict(path: path)
                default: break
                }
            }
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    throw RemoteSyncError.notFound(path: path)
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                    throw RemoteSyncError.permissionDenied(path: path)
                case NSFileWriteFileExistsError:
                    throw RemoteSyncError.conflict(path: path)
                default: break
                }
            }
            throw RemoteSyncError.underlying(error.localizedDescription)
        }
    }

    /// 随机、排他创建临时文件，拒绝跟随最终符号链接，避免破坏用户已有文件。
    func createUploadStaging(in parent: URL) throws -> (URL, FileHandle) {
        let url = parent.appendingPathComponent(".bone-upload-\(UUID().uuidString).part")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// 相同目录下 rename 原子替换；非覆盖模式用 RENAME_EXCL，防止检查后目标又被创建。
    func installUploadStaging(_ staging: URL, at destination: URL, path: String, overwrite: Bool) throws {
        let verifiedDestination = try mutationURL(path)
        guard verifiedDestination.standardizedFileURL == destination.standardizedFileURL else {
            throw RemoteSyncError.conflict(path: path)
        }
        if itemExists(at: destination) {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard overwrite, attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteSyncError.conflict(path: path)
            }
        }
        try Task.checkCancellation()
        let result = overwrite
            ? rename(staging.path, destination.path)
            : renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
