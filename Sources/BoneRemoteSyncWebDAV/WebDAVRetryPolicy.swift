import Foundation
import BoneRemoteSyncCore

/// Explicit opt-in policy for idempotent WebDAV reads. maxAttempts includes the first request.
/// WebDAV 幂等读取请求的显式重试策略；写请求不会因此自动重试。
public struct WebDAVRetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let totalTimeout: TimeInterval?

    /// 创建重试策略；maxAttempts 包含第一次请求。
    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 8, totalTimeout: TimeInterval? = 120) {
        self.maxAttempts = maxAttempts; self.initialDelay = initialDelay
        self.maxDelay = maxDelay; self.totalTimeout = totalTimeout
    }
    public static let none = WebDAVRetryPolicy(maxAttempts: 1, totalTimeout: nil)
    public static let standard = WebDAVRetryPolicy()

    /// 校验重试次数、退避时长和总时限。
    func validate() throws {
        guard (1...8).contains(maxAttempts), initialDelay.isFinite, maxDelay.isFinite,
              initialDelay >= 0, maxDelay >= initialDelay, maxDelay <= 300,
              maxAttempts == 1 || totalTimeout != nil else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 重试策略")
        }
        if let totalTimeout, !totalTimeout.isFinite || totalTimeout <= 0 || totalTimeout > 86_400 {
            throw RemoteSyncError.unsupported(operation: "WebDAV 操作总时限")
        }
    }
}
