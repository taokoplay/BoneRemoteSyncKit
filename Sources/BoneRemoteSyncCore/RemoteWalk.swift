/// visitor 式目录遍历的资源与安全上限。
///
/// 初始化不抛错；`walk(path:options:visit:)` 在发出任何请求前验证取值。
public struct RemoteWalkOptions: Sendable {
    /// 同时执行的 `list` 请求数，合法范围为 1...16。
    public var maxConcurrentRequests: Int
    /// 可以读取的最深目录层级；起始目录为 0。0 允许读取起始目录中的文件，
    /// 但遇到需要继续读取的子目录时会抛错，而不是静默跳过。
    public var maxDepth: Int
    /// 整次遍历最多发现的条目数，必须大于 0。包含目录条目，不含起始目录本身。
    /// 已完成但尚未交给 visitor 的页面也占用此预算。
    public var maxEntries: Int
    /// 原样传递给每次 `list` 请求，由来源实现隐藏条目过滤。
    public var includeHidden: Bool

    public init(
        maxConcurrentRequests: Int = 4,
        maxDepth: Int = 64,
        maxEntries: Int = 100_000,
        includeHidden: Bool = false
    ) {
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
        self.includeHidden = includeHidden
    }
}

/// 仅在整次遍历成功后返回的统计。
public struct RemoteWalkSummary: Sendable {
    /// 成功交给 visitor 的条目数，含目录条目，不含起始目录本身。
    public let entryCount: Int
    /// 实际读取的不同目录数，包含起始目录；同目录的多页只计一次。
    public let directoryCount: Int

    public init(entryCount: Int, directoryCount: Int) {
        self.entryCount = entryCount
        self.directoryCount = directoryCount
    }
}

public extension RemoteSource {
    /// 使用有界并发读取子树，并逐条等待消费端完成。
    ///
    /// - 请求与背压：最多同时执行 `maxConcurrentRequests` 个 `list`。每个子任务
    ///   只读取一页，不自行循环预取；本次页面的 visitor 全部返回前，不补充任何请求。
    ///   visitor 从不并发执行。已有的其他请求可以完成，因此最多保留 N 个页面
    ///   （含当前正在消费的页面），不存在无界 `AsyncStream` 或后台生产者。
    /// - 预算：页面返回后、进入 task group 的结果缓冲前，先原子预留整页条目预算；
    ///   不仅限制已消费数量，也限制已发现条目和待遍历目录。来源的 `list` 已经物化
    ///   页面，所以无法限制适配器在返回前分配的页面大小；此方法不是字节内存上限。
    /// - 分页与顺序：同一目录的 cursor 严格顺序请求，检测重复 cursor。
    ///   保留每页内部顺序，不保证不同目录的全局顺序。cursor 历史仅在该目录分页
    ///   期间保留；空页面仍会继续翻页，其页数不受条目预算限制。
    /// - 路径安全：所有条目必须具有路径，归一化后必须是当前目录的直接孩子。
    ///   使用 `RemotePath.normalize` 检测重复路径；自身、祖先、跨目录条目和重复路径
    ///   均抛错，不静默过滤。此 API 不适用于只有 ObjectID、没有路径的来源。
    ///   验证只使用归一化路径；visitor 收到来源原始条目，`id` 和元数据不被改写。
    /// - 错误：非法选项、深度/条目上限、cursor 循环和无效路径抛
    ///   `RemoteSyncError.unsupported`；来源和 visitor 的错误原样传递。
    ///   超限不会返回截断的成功结果。错误发生前可能已有 visitor 调用，
    ///   调用方需要自行处理部分副作用，不能将一次调用视为事务。
    /// - 取消与会话：使用结构化 task group；检测到错误后取消并等待所有请求收敛，
    ///   不留下后台 task。不连接、断开、重试或缓存来源，复用调用方现有会话。
    ///   取消是协作式的：来源的 `list` 与 visitor 必须响应取消；若它们忽略取消，
    ///   此方法仍会等待其结束，而不是让请求逃离生命周期。
    func walk(
        path: String,
        options: RemoteWalkOptions,
        visit: @escaping @Sendable (RemoteEntry) async throws -> Void
    ) async throws -> RemoteWalkSummary {
        guard (1...16).contains(options.maxConcurrentRequests),
              options.maxDepth >= 0, options.maxEntries > 0 else {
            throw RemoteSyncError.unsupported(operation: "遍历参数超出合法范围")
        }
        try Task.checkCancellation()
        let root = RemotePath.normalize(path)
        let budget = RemoteWalkBudget(limit: options.maxEntries)

        return try await withThrowingTaskGroup(of: RemoteWalkPage.self) { group in
            // A separate pagination slot prevents the root's continuation from adding an
            // extra directory to the maxEntries-bounded pending directory stack.
            var pagination: RemoteWalkRequest? = .init(path: root, depth: 0)
            var pendingDirectories: [RemoteWalkRequest] = []
            var inFlight = 0
            var entryCount = 0
            var directoryCount = 0
            var seenPaths: Set<String> = [root]

            do {
                while pagination != nil || !pendingDirectories.isEmpty || inFlight > 0 {
                    try Task.checkCancellation()
                    while inFlight < options.maxConcurrentRequests {
                        let work: RemoteWalkRequest
                        if let nextPage = pagination {
                            work = nextPage
                            pagination = nil
                        } else if let directory = pendingDirectories.popLast() {
                            work = directory
                        } else {
                            break
                        }
                        if work.cursor == nil {
                            guard directoryCount < Int.max else {
                                throw RemoteSyncError.unsupported(operation: "遍历目录数量超出可表示范围")
                            }
                            directoryCount += 1
                        }
                        inFlight += 1
                        group.addTask {
                            try Task.checkCancellation()
                            let page = try await self.list(
                                path: work.path,
                                request: RemoteListRequest(
                                    cursor: work.cursor,
                                    limit: options.maxEntries,
                                    includeHidden: options.includeHidden
                                )
                            )
                            try Task.checkCancellation()
                            try await budget.reserve(page.entries.count)
                            return RemoteWalkPage(request: work, page: page)
                        }
                    }

                    guard let result = try await group.next() else { break }
                    inFlight -= 1
                    try Task.checkCancellation()
                    var work = result.request
                    let page = result.page
                    guard page.coverage == .complete else {
                        throw RemoteSyncError.unsupported(operation: "遍历目录列表不完整")
                    }
                    var children: [RemoteWalkRequest] = []

                    // Validate a complete page before invoking its visitor or adding children.
                    // The budget has already been reserved by the fetch task, including for
                    // completed sibling pages awaiting consumption in the task group.
                    for entry in page.entries {
                        try Task.checkCancellation()
                        guard let rawPath = entry.path else {
                            throw RemoteSyncError.unsupported(operation: "遍历条目缺少路径")
                        }
                        let childPath = RemotePath.normalize(rawPath)
                        guard RemotePath.parent(of: childPath) == work.path else {
                            throw RemoteSyncError.unsupported(operation: "遍历条目不是当前目录的直接子项")
                        }
                        guard seenPaths.insert(childPath).inserted else {
                            throw RemoteSyncError.unsupported(operation: "遍历遇到重复路径或目录循环")
                        }
                        if entry.isDirectory {
                            guard work.depth < options.maxDepth else {
                                throw RemoteSyncError.unsupported(operation: "遍历超过最大目录深度")
                            }
                            children.append(.init(path: childPath, depth: work.depth + 1))
                        }
                    }
                    if let cursor = page.nextCursor {
                        guard work.seenCursors.insert(cursor).inserted else {
                            throw RemoteSyncError.unsupported(operation: "遍历遇到重复分页游标")
                        }
                        work.cursor = cursor
                    }

                    for entry in page.entries {
                        try Task.checkCancellation()
                        try await visit(entry)
                        try Task.checkCancellation()
                        entryCount += 1
                    }
                    pendingDirectories.append(contentsOf: children.reversed())
                    if page.nextCursor != nil { pagination = work }
                }
                try Task.checkCancellation()
                return RemoteWalkSummary(entryCount: entryCount, directoryCount: directoryCount)
            } catch {
                group.cancelAll()
                // Exiting the structured scope joins every child, preserving this error.
                throw error
            }
        }
    }
}

private struct RemoteWalkRequest: Sendable {
    let path: String
    let depth: Int
    var cursor: String?
    var seenCursors: Set<String> = []
}

private struct RemoteWalkPage: Sendable {
    let request: RemoteWalkRequest
    let page: RemoteListPage
}

/// Only returned pages reserve budget; all fetch tasks share one atomic discovery limit.
private actor RemoteWalkBudget {
    private var remaining: Int

    init(limit: Int) { remaining = limit }

    func reserve(_ count: Int) throws {
        try Task.checkCancellation()
        guard count <= remaining else {
            throw RemoteSyncError.unsupported(operation: "遍历超过最大条目数")
        }
        remaining -= count
    }
}
