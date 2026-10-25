import Foundation
import BoneRemoteSyncCore

/// Opt-in managed checkpoint download. Namespace must be a stable opaque ID unique to the logical account.
public struct WebDAVResumableDownloadOptions: Sendable {
    public let sourceNamespace: String
    public let checkpointIntervalBytes: Int64
    public let overwrite: Bool
    public let progress: (@Sendable (Int64) -> Void)?

    public init(sourceNamespace: String, checkpointIntervalBytes: Int64 = 8 * 1024 * 1024,
                overwrite: Bool = true, progress: (@Sendable (Int64) -> Void)? = nil) {
        self.sourceNamespace = sourceNamespace; self.checkpointIntervalBytes = checkpointIntervalBytes
        self.overwrite = overwrite; self.progress = progress
    }
    func validate() throws {
        guard (1...256).contains(sourceNamespace.utf8.count), !sourceNamespace.utf8.contains(0),
              (64 * 1024...256 * 1024 * 1024).contains(checkpointIntervalBytes) else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 检查点选项")
        }
    }
}
