import Foundation

/// 归一化错误。
///
/// 适配器必须把所有底层差异（ECONNREFUSED、STATUS_LOGON_FAILURE、HTTP 401/423、
/// 网盘 rate_limited）翻译成这里的枚举，上层才能写一份重试与提示逻辑。
public enum RemoteSyncError: Error, Sendable, Equatable {
    case notConnected
    case authenticationFailed(reason: String?)
    case notFound(path: String)
    case permissionDenied(path: String)
    /// 该来源不支持这个操作。正常情况下 UI 应已按 capabilities 隐藏入口，走到这里说明能力声明不准。
    case unsupported(operation: String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    /// 远端内容在两次操作之间被替换（etag 变化），续传必须作废。
    case conflict(path: String)
    /// 传输完成但长度或校验值不符。
    case integrityMismatch(path: String)
    /// A provider-owned upload session no longer exists or has expired.
    case uploadSessionExpired
    /// The immutable local upload snapshot is unavailable or changed.
    case sourceSnapshotMissing
    /// A final remote write may have committed, but this client cannot prove its outcome.
    case uploadCommitUnknown
    /// The configured protected session store could not read or atomically update a record.
    case secureStorageUnavailable
    case cancelled
    /// 未能归类的底层错误，保留原始描述便于排查。
    case underlying(String)
}

extension RemoteSyncError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected:
            return "来源尚未连接"
        case .authenticationFailed(let reason):
            return "认证失败" + (reason.map { "：\($0)" } ?? "")
        case .notFound(let path):
            return "路径不存在：\(path)"
        case .permissionDenied(let path):
            return "无权访问：\(path)"
        case .unsupported(let operation):
            return "当前来源不支持该操作：\(operation)"
        case .rateLimited(let retryAfter):
            // 公开枚举可能由任意适配器构造；格式化不得因 NaN/无穷或整数越界崩溃。
            if let retryAfter, retryAfter.isFinite, retryAfter >= 0,
               let seconds = Int(exactly: retryAfter.rounded(.towardZero)) {
                return "触发限流，\(seconds) 秒后重试"
            }
            return "触发限流"
        case .network(let detail):
            return "网络错误：\(detail)"
        case .conflict(let path):
            return "远端内容已变化：\(path)"
        case .integrityMismatch(let path):
            return "文件校验不一致：\(path)"
        case .uploadSessionExpired:
            return "远端上传会话已过期"
        case .sourceSnapshotMissing:
            return "上传源快照不可用或已变化"
        case .uploadCommitUnknown:
            return "远端上传结果需要核对"
        case .secureStorageUnavailable:
            return "上传会话安全存储不可用"
        case .cancelled:
            return "任务已取消"
        case .underlying(let detail):
            return detail
        }
    }

    /// 是否值得自动重试。认证、不支持、冲突重试也没用。
    public var isRetryable: Bool {
        switch self {
        case .network, .rateLimited:
            return true
        case .authenticationFailed, .notFound, .permissionDenied, .unsupported,
             .conflict, .integrityMismatch, .uploadSessionExpired, .sourceSnapshotMissing,
             .uploadCommitUnknown, .secureStorageUnavailable, .cancelled, .notConnected, .underlying:
            return false
        }
    }
}
