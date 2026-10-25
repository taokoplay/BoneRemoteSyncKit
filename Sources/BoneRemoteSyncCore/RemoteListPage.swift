import Foundation

/// 来源分页请求。
///
/// `limit` 为调用方的正数页大小提示；适配器可以将其限制在服务端上限内，
/// 但不能静默忽略非法值。`cursor` 由来源生成，只能传回同一来源、同一目录与
/// 同一组分页选项；不支持游标的来源必须对非空 cursor 抛 `.unsupported`，不能
/// 静默返回第一页。标准 WebDAV 没有通用分页协议，因此只接受空 cursor，并一次
/// 返回完整 Depth:1 结果。
public struct RemoteListRequest: Sendable, Equatable {
    public var cursor: String?
    public var limit: Int?
    public var includeHidden: Bool

    public init(cursor: String? = nil, limit: Int? = nil, includeHidden: Bool = false) {
        self.cursor = cursor
        self.limit = limit
        self.includeHidden = includeHidden
    }

    /// 一次取完（来源不支持分页时等价于 limit = nil）。
    public static let all = RemoteListRequest()

    public func nextPage(cursor: String) -> RemoteListRequest {
        var copy = self
        copy.cursor = cursor
        return copy
    }

    /// 验证跨来源都适用的请求部分。来源专属的 cursor 归属校验仍由适配器完成。
    ///
    /// 采用延迟抛错而不是让初始化器变成 throwing，以保持 `RemoteListRequest` 的
    /// 轻量值类型和现有调用方式；所有 `RemoteSource.list` 实现都必须在发请求前调用。
    public func validate() throws {
        guard limit.map({ $0 > 0 }) ?? true else {
            throw RemoteSyncError.unsupported(operation: "分页大小必须大于0")
        }
    }
}

/// 一页结果。`nextCursor` 为 nil 表示目录已读完。
public struct RemoteListPage: Sendable, Equatable {
    public let entries: [RemoteEntry]
    public let nextCursor: String?

    public init(entries: [RemoteEntry], nextCursor: String? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
    }

    public var isLastPage: Bool { nextCursor == nil }
}
