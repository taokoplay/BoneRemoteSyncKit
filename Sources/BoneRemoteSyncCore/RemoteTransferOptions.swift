import Foundation

/// 下载选项。
///
/// SDK 负责落盘细节：先写 `<目标>.part`，完成后原子替换，失败保留 `.part` 供续传。
/// 调用方只需要给出目标 URL 和一个可选的进度回调。
public struct RemoteDownloadOptions: Sendable {
    /// 从 `.part` 的哪个偏移继续。nil 表示从头开始。
    public var resumeFrom: Int64?
    /// 续传前的校验值。与远端当前值不一致时抛 `.conflict`，不允许接着写。
    public var expectedETag: String?
    /// 目标已存在时是否覆盖。false 抛 `.conflict`。
    public var overwrite: Bool
    /// 写完后校验字节数。默认开启。
    public var verifySize: Bool
    /// 已写入字节数（含续传偏移）。调用方自行做节流。
    public var progress: (@Sendable (Int64) -> Void)?

    public init(
        resumeFrom: Int64? = nil,
        expectedETag: String? = nil,
        overwrite: Bool = true,
        verifySize: Bool = true,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.resumeFrom = resumeFrom
        self.expectedETag = expectedETag
        self.overwrite = overwrite
        self.verifySize = verifySize
        self.progress = progress
    }
}

/// 上传选项，供 RemoteWritableSource 使用。
public struct RemoteUploadOptions: Sendable {
    public var overwrite: Bool
    public var contentType: String?
    public var progress: (@Sendable (Int64) -> Void)?

    public init(
        overwrite: Bool = true,
        contentType: String? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.overwrite = overwrite
        self.contentType = contentType
        self.progress = progress
    }
}
