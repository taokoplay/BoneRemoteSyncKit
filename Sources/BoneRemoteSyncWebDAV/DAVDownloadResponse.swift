import Foundation
import BoneRemoteSyncCore

/// Shared validation before either ordinary or managed downloads may touch the part file.
struct DAVDownloadResponse {
    let expectedSize: Int64?
    let rangeLength: Int64?
    let etag: String?

    init(response: HTTPURLResponse, entry: RemoteEntry, options: RemoteDownloadOptions,
         offset: Int64, path: String, now: Date = Date()) throws {
        try DAVHTTP.validateForRetry(response, path: path, allowed: offset > 0 ? [206] : [200], now: now)
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { throw RemoteSyncError.unsupported(operation: "WebDAV 压缩传输编码") }
        etag = response.value(forHTTPHeaderField: "ETag")
        if let expected = options.expectedETag {
            guard etag == expected else { throw RemoteSyncError.conflict(path: path) }
        }
        if offset > 0 {
            guard let rawRange = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseRange(rawRange), range.start == offset,
                  range.end == range.total - 1, entry.size == nil || entry.size == range.total else {
                throw RemoteSyncError.conflict(path: path)
            }
            expectedSize = range.total
            rangeLength = range.end - range.start + 1
            if response.expectedContentLength >= 0, response.expectedContentLength != rangeLength {
                throw RemoteSyncError.integrityMismatch(path: path)
            }
        } else {
            guard response.value(forHTTPHeaderField: "Content-Range") == nil else { throw RemoteSyncError.conflict(path: path) }
            let length = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            if options.verifySize, let size = entry.size, let length, size != length {
                throw RemoteSyncError.integrityMismatch(path: path)
            }
            expectedSize = length ?? entry.size
            rangeLength = length
        }
    }

    private static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let halves = value.split(separator: " ", omittingEmptySubsequences: false)
        guard halves.count == 2, halves[0].lowercased() == "bytes" else { return nil }
        let totalParts = halves[1].split(separator: "/", omittingEmptySubsequences: false)
        guard totalParts.count == 2, let total = Int64(totalParts[1]), total > 0 else { return nil }
        let bounds = totalParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
}
