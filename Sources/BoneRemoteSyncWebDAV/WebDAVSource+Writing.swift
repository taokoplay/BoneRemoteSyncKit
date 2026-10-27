import Foundation
import BoneRemoteSyncCore

extension WebDAVSource: RemoteCopyingSource {
    /// Full PUT upload. The parent must exist. No upload resumption or remote rollback is promised.
    /// A private disk snapshot requires free space approximately equal to the input file size.
    @discardableResult
    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions = .init()) async throws -> RemoteEntry {
        do {
            let (ctx, version) = try writeContext()
            let path = RemotePath.normalize(path)
            guard path != "/" else { throw RemoteSyncError.unsupported(operation: "WebDAV 不能用文件覆盖根目录") }
            _ = try location.url(for: path)
            if let expected = options.expectedETag {
                guard options.overwrite, expected.utf8.count <= 4096, Self.isStrongETag(expected) else {
                    throw RemoteSyncError.unsupported(operation: "WebDAV 条件上传需要 overwrite=true 和强 ETag")
                }
            }
            if let type = options.contentType,
               type.isEmpty || type.utf8.count > 1024 || type.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                throw RemoteSyncError.unsupported(operation: "WebDAV Content-Type 无效")
            }
            let entry = try await ctx.scope.run {
                let snapshot = try await DAVUploadSnapshot.create(from: localURL, scope: ctx.scope)
                try await ctx.requireDirectory(RemotePath.parent(of: path)!)
                var request = try ctx.request(path, method: "PUT")
                request.setValue(options.contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(String(snapshot.size), forHTTPHeaderField: "Content-Length")
                if let expected = options.expectedETag {
                    guard let existing = try await ctx.optionalStat(path), !existing.isDirectory, existing.etag == expected else {
                        throw RemoteSyncError.conflict(path: path)
                    }
                    // Never replace the caller's version with the later preflight version.
                    // The server must still enforce it if the resource changes after preflight.
                    request.setValue(expected, forHTTPHeaderField: "If-Match")
                } else if !options.overwrite {
                    request.setValue("*", forHTTPHeaderField: "If-None-Match")
                } else if let existing = try await ctx.optionalStat(path) {
                    guard !existing.isDirectory else { throw RemoteSyncError.conflict(path: path) }
                    // Preserve the preflight type/version check at the server. Without a strong
                    // validator there is no safe conditional replacement of an existing resource.
                    guard let etag = existing.etag, Self.isStrongETag(etag) else {
                        throw RemoteSyncError.unsupported(operation: "WebDAV 覆盖已有文件需要强 ETag")
                    }
                    request.setValue(etag, forHTTPHeaderField: "If-Match")
                } else {
                    request.setValue("*", forHTTPHeaderField: "If-None-Match")
                }
                options.progress?(0)
                try ctx.scope.check()
                let response = try await ctx.send(request, path: path, allowed: [200, 201, 204], uploadFile: snapshot.url,
                                                  progress: options.progress)
                // Return metadata from the successful PUT; a second PROPFIND must not turn an
                // acknowledged upload into failure or return another client's later version.
                return RemoteEntry(id: RemotePath.relative(path), path: path, name: RemotePath.name(of: path),
                                   type: .file, size: snapshot.size,
                                   modifiedAt: response.value(forHTTPHeaderField: "Last-Modified").flatMap(DAVHTTPDate.parse),
                                   etag: response.value(forHTTPHeaderField: "ETag"), contentType: options.contentType ?? "application/octet-stream")
            }
            try checkGeneration(version)
            return entry
        } catch { throw DAVHTTP.mapped(error, localPath: localURL.path) }
    }

    /// Recursively creates collections; existing collections succeed, existing files conflict.
    public func makeDirectory(path: String) async throws {
        do {
            let (ctx, version) = try writeContext()
            let path = RemotePath.normalize(path)
            _ = try location.url(for: path)
            try await ctx.scope.run { try await ctx.makeDirectory(path) }
            try checkGeneration(version)
        } catch { throw DAVHTTP.mapped(error) }
    }

    /// DELETE includes the entire collection subtree. Never deletes the configured source root.
    public func remove(path: String) async throws {
        do {
            let (ctx, version) = try writeContext()
            let path = RemotePath.normalize(path)
            guard path != "/" else { throw RemoteSyncError.unsupported(operation: "WebDAV 不能删除根目录") }
            try await ctx.scope.run {
                let item = try await ctx.stat(path)
                let request = try ctx.request(path, method: "DELETE", collection: item.isDirectory)
                _ = try await ctx.send(request, path: path, allowed: [200, 204])
            }
            try checkGeneration(version)
        } catch { throw DAVHTTP.mapped(error) }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await relocate(from: sourcePath, to: destinationPath, method: "MOVE")
    }

    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try await relocate(from: sourcePath, to: destinationPath, method: "COPY")
    }

    private func relocate(from sourcePath: String, to destinationPath: String, method: String) async throws {
        do {
            let (ctx, version) = try writeContext()
            let source = RemotePath.normalize(sourcePath), destination = RemotePath.normalize(destinationPath)
            guard source != "/", destination != "/" else {
                throw RemoteSyncError.unsupported(operation: method == "MOVE" ? "WebDAV 不能移动根目录或覆盖根目录" : "WebDAV 不能复制根目录或覆盖根目录")
            }
            let destinationURL = try location.url(for: destination)
            guard source != destination, !destination.hasPrefix(source + "/") else {
                throw RemoteSyncError.conflict(path: destination)
            }
            try await ctx.scope.run {
                let item = try await ctx.stat(source)
                try await ctx.requireDirectory(RemotePath.parent(of: destination)!)
                var request = try ctx.request(source, method: method, collection: item.isDirectory)
                let target = item.isDirectory ? destinationURL.appendingPathComponent("") : destinationURL
                request.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
                request.setValue("F", forHTTPHeaderField: "Overwrite")
                if method == "COPY" { request.setValue("infinity", forHTTPHeaderField: "Depth") }
                do { _ = try await ctx.send(request, path: source, allowed: [201]) }
                catch let error as DAVRequestFailure {
                    if case .http(let status, _, _) = error, status == 412 || status == 409 {
                        throw RemoteSyncError.conflict(path: destination)
                    }
                    throw error
                }
            }
            try checkGeneration(version)
        } catch { throw DAVHTTP.mapped(error) }
    }

    private func writeContext() throws -> (DAVWriteContext, UInt64) {
        let (session, version) = try context()
        try checkGeneration(version)
        return (DAVWriteContext(session: session, location: location, template: try request(path: "/", method: "GET"),
                                retryPolicy: retryPolicy, scope: DAVOperationScope(pool: session, policy: retryPolicy)), version)
    }
}
