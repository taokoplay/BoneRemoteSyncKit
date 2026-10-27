import Foundation
import BoneRemoteSyncCore

extension OneDriveSource {
    /// Complete foreground download. Unlike WebDAV, failures clean up this call's random staging;
    /// resumeFrom and cross-process checkpoints are intentionally unsupported.
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        do {
            let ctx = try context()
            guard options.resumeFrom == nil else { throw RemoteSyncError.unsupported(operation: "OneDrive v1 断点续传") }
            guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载目录") }
            let target = try ODDownloadTarget(destination: destination)
            guard destinations.insert(target.lockKey).inserted else { throw RemoteSyncError.conflict(path: destination.path) }
            defer { target.cleanup(); destinations.remove(target.lockKey) }
            try target.validate(overwrite: options.overwrite)
            for attempt in 0...1 {
                let value = try await item(id: entry.id, path: entry.path, context: ctx)
                guard value.file != nil, let size = value.size, let raw = value.downloadURL else { throw RemoteSyncError.unsupported(operation: "OneDrive 条目不可下载") }
                for expected in [entry.etag, options.expectedETag].compactMap({ $0 }) {
                    guard value.eTag == expected else { throw RemoteSyncError.conflict(path: entry.path ?? "/") }
                }
                let url = try ODLocation.download(raw, endpoints: endpoints)
                try check(ctx.generation)
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                // No Graph token, If-Match or ambient credentials are forwarded to the pre-authorized CDN.
                let result = try await ctx.client.send(request, sink: ODDownloadSink(target: target, expected: size,
                    verifySize: options.verifySize, progress: { options.reportTransferred($0, total: size) }))
                try check(ctx.generation)
                if attempt == 0, [401, 403].contains(result.response.statusCode) { continue }
                try ODHTTPClient.validate(result.response, path: entry.path ?? "/")
                guard let bytes = result.transferredBytes else { throw RemoteSyncError.integrityMismatch(path: entry.path ?? "/") }
                // A pre-authorized URL has its own HTTP semantics; Graph eTag is not a CDN
                // validator. Bracket the transfer with Graph metadata checks instead of
                // forwarding Graph If-Match. This detects observed version changes, not a
                // transactionally pinned Graph/CDN snapshot or a cryptographic content hash.
                let after = try await item(id: entry.id, path: entry.path, context: ctx)
                guard after.eTag == value.eTag, after.size == value.size, after.file != nil else {
                    throw RemoteSyncError.conflict(path: entry.path ?? "/")
                }
                // No await across final lifecycle gate and rename: disconnect cannot interleave installation.
                try check(ctx.generation)
                try target.install(overwrite: options.overwrite, bytes: bytes)
                return value.entry(drive: ctx.drive, path: entry.path)
            }
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 下载链接已失效")
        } catch { throw ODHTTPClient.mapped(error) }
    }
}
