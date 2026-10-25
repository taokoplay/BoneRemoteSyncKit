import Foundation
import BoneRemoteSyncCore

extension WebDAVSource {
    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        let (session, version) = try context()
        guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载目录") }
        let path = RemotePath.normalize(entry.path ?? "/" + entry.id)
        let offset = options.resumeFrom ?? 0
        guard offset >= 0 else { throw RemoteSyncError.conflict(path: path) }
        if offset > 0 {
            guard let etag = options.expectedETag, Self.isStrongETag(etag) else {
                throw RemoteSyncError.unsupported(operation: "WebDAV 续传需要强 ETag")
            }
        }
        if let etag = options.expectedETag, !Self.isStrongETag(etag) {
            throw RemoteSyncError.unsupported(operation: "WebDAV If-Match 需要强 ETag")
        }
        let target = try WebDAVDownloadTarget(destination: destination)
        // Also reserve the managed sidecar, so another download cannot treat it as its target.
        let lockedPaths = target.reservedPaths
        guard activeDestinations.isDisjoint(with: lockedPaths) else { throw RemoteSyncError.conflict(path: destination.path) }
        activeDestinations.formUnion(lockedPaths)
        defer { activeDestinations.subtract(lockedPaths) }
        let scope = DAVOperationScope(pool: session, policy: retryPolicy)
        do {
            try checkGeneration(version)
            try target.validate(overwrite: options.overwrite, offset: offset)
            var request = try request(path: path, method: "GET")
            request.setValue(options.expectedETag, forHTTPHeaderField: "If-Match")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let prepared = try await DAVDownloadWorker.run(session: session, request: request, entry: entry,
                                                           target: target, options: options, offset: offset, path: path,
                                                           retryPolicy: retryPolicy, scope: scope)
            // No await between generation check and rename: disconnect cannot interleave installation.
            try checkGeneration(version)
            try scope.check()
            try target.install(handle: prepared.handle, overwrite: options.overwrite)
            return prepared.entry
        } catch { throw DAVHTTP.mapped(error, localPath: destination.path) }
    }

    static func isStrongETag(_ value: String) -> Bool {
        guard value.utf8.count >= 2, value.first == "\"", value.last == "\"" else { return false }
        return value.dropFirst().dropLast().utf8.allSatisfy { $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80 }
    }

}
