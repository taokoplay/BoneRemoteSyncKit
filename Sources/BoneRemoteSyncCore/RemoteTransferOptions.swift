import Foundation

/// 来源准备下载内容时的通用状态。
public enum RemoteDownloadPreparationState: String, Sendable, Codable, Equatable {
    case notStarted
    case inProgress
    case ready
    case unknown
}

/// 下载所处阶段。
public enum RemoteDownloadPhase: String, Sendable, Codable, Equatable {
    /// 来源正在准备本地可读内容，例如 iCloud Drive 正在下载占位文件。
    case preparing
    /// SDK 正在把来源内容写入本地 staging/part，成功后再安装到最终目标。
    case transferring
}

/// 下载阶段的可选进度快照。
///
/// `fractionCompleted` 使用 0...1。来源无法提供可靠比例时为 nil；
/// 准备阶段无可靠字节数时 `completedBytes == 0`、`totalBytes == nil`，不能据此推断未发生网络流量。
/// 传输阶段表示已写入 staging/part 的字节数（含续传偏移），不是最终目标已安装。
public struct RemoteDownloadProgress: Sendable, Equatable {
    public let phase: RemoteDownloadPhase
    /// 仅准备阶段有值；传输阶段用 `completedBytes` 表示实际写入量。
    public let preparationState: RemoteDownloadPreparationState?
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let fractionCompleted: Double?

    public init(
        phase: RemoteDownloadPhase,
        preparationState: RemoteDownloadPreparationState? = nil,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        fractionCompleted: Double? = nil
    ) {
        self.phase = phase
        self.preparationState = phase == .preparing ? preparationState : nil
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.map { max(0, $0) }
        if let fractionCompleted, fractionCompleted.isFinite {
            self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        } else {
            self.fractionCompleted = nil
        }
    }

    /// An attempt-local byte snapshot; reaching 1 does not certify final installation.
    package static func transferring(completedBytes: Int64, totalBytes: Int64?) -> Self {
        let fraction: Double? = if let totalBytes, totalBytes > 0 {
            Double(completedBytes) / Double(totalBytes)
        } else { nil }
        return Self(phase: .transferring, completedBytes: completedBytes,
                    totalBytes: totalBytes, fractionCompleted: fraction)
    }
}

/// 下载选项。
///
/// SDK 负责 staging/part 与最终安装；是否支持续传、失败保留或清理临时内容以来源合同为准。
/// `progress` 保持简单的已写字节回调；需要区分云端准备阶段时使用 `phaseProgress`。
public struct RemoteDownloadOptions: Sendable {
    /// 从 `.part` 的哪个偏移继续。nil 表示从头开始。
    public var resumeFrom: Int64?
    /// 续传前的校验值。与远端当前值不一致时抛 `.conflict`，不允许接着写。
    public var expectedETag: String?
    /// 目标已存在时是否覆盖。false 抛 `.conflict`。
    public var overwrite: Bool
    /// 写完后校验字节数。默认开启。
    public var verifySize: Bool
    /// 已写入 staging/part 的字节数（含续传偏移）。每次传输尝试内不递减；重试可回退。
    /// 不包含来源准备内容的网络下载量，不代表原子安装或远端同步完成。调用方自行做节流。
    public var progress: (@Sendable (Int64) -> Void)?
    /// 阶段和可选比例回调。内置来源在开始写入时及每批字节写入后报告 transferring；
    /// iCloud 另报告 preparing 状态变化（相同快照去重，按 pollInterval 采样，可能跳过短暂状态）。
    /// 两阶段的比例独立，未知/空文件比例为 nil；达到 1 也不代表最终安装成功。
    /// 无固定频率，重试可从较小偏移重报。同步 @Sendable 回调须快速且线程安全，UI 由宿主切换执行器。
    /// 网络来源已在途的回调可能晚于取消返回；宿主应以任务标识过滤过期事件。
    public var phaseProgress: (@Sendable (RemoteDownloadProgress) -> Void)?

    package func reportTransferred(_ bytes: Int64, total: Int64?) {
        progress?(bytes)
        phaseProgress?(.transferring(completedBytes: bytes, totalBytes: total))
    }

    public init(
        resumeFrom: Int64? = nil,
        expectedETag: String? = nil,
        overwrite: Bool = true,
        verifySize: Bool = true,
        progress: (@Sendable (Int64) -> Void)? = nil,
        phaseProgress: (@Sendable (RemoteDownloadProgress) -> Void)? = nil
    ) {
        self.resumeFrom = resumeFrom
        self.expectedETag = expectedETag
        self.overwrite = overwrite
        self.verifySize = verifySize
        self.progress = progress
        self.phaseProgress = phaseProgress
    }
}

/// 上传选项，供 RemoteWritableSource 使用。
public struct RemoteUploadOptions: Sendable {
    public var overwrite: Bool
    /// 仅在远端仍匹配调用方读取的版本时更新。需要来源支持可靠条件上传；不支持时必须拒绝，不能静默忽略。
    /// 与 overwrite=false 不能同时使用。ETag 是来源内不透明版本，不是内容摘要。
    public var expectedETag: String?
    public var contentType: String?
    public var progress: (@Sendable (Int64) -> Void)?

    public init(
        overwrite: Bool = true,
        expectedETag: String? = nil,
        contentType: String? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.overwrite = overwrite
        self.expectedETag = expectedETag
        self.contentType = contentType
        self.progress = progress
    }
}
