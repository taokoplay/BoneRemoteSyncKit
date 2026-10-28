import Foundation
import BoneRemoteSyncCore

/// Per-file scheduling settings. Values are validated before source I/O.
public struct RemoteSegmentedDownloadOptions: Sendable, Hashable {
    public var segmentSize: Int64
    public var maxConcurrentSegments: Int
    /// Small files use ordinary downloading in ifSupported mode. Required mode
    /// ignores this threshold, but still requires a nonempty, sized file.
    public var minimumFileSize: Int64

    public init(segmentSize: Int64 = 4 * 1024 * 1024,
                maxConcurrentSegments: Int = 3,
                minimumFileSize: Int64 = 8 * 1024 * 1024) {
        self.segmentSize = segmentSize
        self.maxConcurrentSegments = maxConcurrentSegments
        self.minimumFileSize = minimumFileSize
    }

    func validate() throws {
        guard segmentSize > 0, segmentSize <= RemoteByteRange.maximumLength,
              (1...16).contains(maxConcurrentSegments), minimumFileSize >= 0 else {
            throw RemoteSyncError.unsupported(operation: "无效的分片下载配置")
        }
    }
}

public enum RemoteDownloadStrategy: Sendable, Hashable {
    case sequential
    /// Fall back only for ineligible entries or an unavailable first range.
    case segmentedIfSupported(RemoteSegmentedDownloadOptions = .init())
    /// Fail rather than perform an ordinary download, including for empty files.
    case segmentedRequired(RemoteSegmentedDownloadOptions = .init())

    var configuration: RemoteSegmentedDownloadOptions? {
        switch self {
        case .sequential: nil
        case .segmentedIfSupported(let config), .segmentedRequired(let config): config
        }
    }
    var isRequired: Bool {
        if case .segmentedRequired = self { return true }
        return false
    }
}
