import Foundation

/// 来源能力声明。
///
/// 存在的意义是让 UI 和同步引擎"先问再做"：勾选了什么才显示什么、
/// 才规划什么动作，而不是靠 try-catch 在运行时兜底。
public struct RemoteCapabilities: Sendable, Hashable {
    /// 是否支持列目录。理论上所有来源都应为 true，保留字段用于尚未实现的适配器。
    public var list: Bool
    public var stat: Bool
    /// 是否实现 RemoteIDAddressableSource。只涉及稳定 ID 读取，不表示支持按 ID 写入或遍历。
    public var idAddressing: Bool
    public var download: Bool
    /// 是否支持按字节区间读取，决定能否断点续传。
    public var rangedDownload: Bool
    public var upload: Bool
    /// 上传时能可靠执行调用方 expectedETag；false 时不得静默忽略该条件。
    public var conditionalUpload: Bool
    public var resumableUpload: Bool
    public var makeDirectory: Bool
    public var remove: Bool
    public var move: Bool
    public var copy: Bool
    /// 是否提供远端变更流。false 意味着同步只能靠定期全量扫描。
    public var changeFeed: Bool
    /// 是否由来源提供稳定内容校验值；false 不代表 ETag 是哈希。
    public var contentHash: Bool
    /// 建议并发传输数。云端通常 3~4，局域网 SMB 可以更高。
    public var maxConcurrentTransfers: Int

    public init(
        list: Bool = true,
        stat: Bool = true,
        idAddressing: Bool = false,
        download: Bool = true,
        rangedDownload: Bool = false,
        upload: Bool = false,
        conditionalUpload: Bool = false,
        resumableUpload: Bool = false,
        makeDirectory: Bool = false,
        remove: Bool = false,
        move: Bool = false,
        copy: Bool = false,
        changeFeed: Bool = false,
        contentHash: Bool = false,
        maxConcurrentTransfers: Int = 3
    ) {
        self.list = list
        self.stat = stat
        self.idAddressing = idAddressing
        self.download = download
        self.rangedDownload = rangedDownload
        self.upload = upload
        self.conditionalUpload = conditionalUpload
        self.resumableUpload = resumableUpload
        self.makeDirectory = makeDirectory
        self.remove = remove
        self.move = move
        self.copy = copy
        self.changeFeed = changeFeed
        self.contentHash = contentHash
        self.maxConcurrentTransfers = maxConcurrentTransfers
    }
}

extension RemoteCapabilities {
    /// 只读浏览：目录 + 下载 + 续传。
    public static let readOnly = RemoteCapabilities(
        list: true,
        stat: true,
        download: true,
        rangedDownload: true
    )

    /// 局域网 NAS 的典型能力（SMB 实现参考值，实际以适配器探测结果为准）。
    public static let networkAttachedStorage = RemoteCapabilities(
        list: true,
        stat: true,
        download: true,
        rangedDownload: true,
        upload: true,
        resumableUpload: false,
        makeDirectory: true,
        remove: true,
        move: true,
        copy: true,
        changeFeed: false,
        contentHash: false,
        maxConcurrentTransfers: 4
    )
}
