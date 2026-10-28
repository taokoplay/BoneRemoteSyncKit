import Foundation
import BoneRemoteSyncCore

extension WebDAVSource: RemoteConditionalDownloadSource {
    public nonisolated func conditionalDownloadVersion(for entry: RemoteEntry) -> String? {
        guard let etag = entry.etag, Self.isStrongETag(etag) else { return nil }
        return etag
    }

    public func download(_ entry: RemoteEntry, to destination: URL, requiringVersion: String,
                         options: RemoteDownloadOptions) async throws -> RemoteEntry {
        guard Self.isStrongETag(requiringVersion) else {
            throw RemoteSyncError.unsupported(operation: "WebDAV If-Match 需要强 ETag")
        }
        var options = options
        options.expectedETag = requiringVersion
        return try await download(entry, to: destination, options: options)
    }
}
