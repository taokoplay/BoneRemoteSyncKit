# 通用 API 与生命周期

[返回项目首页](../README.md) · [本地目录](Local.md) · [iCloud Drive](ICloudDrive.md) · [WebDAV](WebDAV.md) · [OneDrive](OneDrive.md) · [Catalog](Catalog.md) · [错误日志](Logging.md)

> 本页按 `v0.3.0` API 描述。iCloud Drive、通用稳定 ID 读取、条件上传、内容校验值、Catalog、必填列表 coverage、阶段进度和 `connectedDriveID()` 自此版本发布，不在 `v0.2.0` 中。

## 统一入口与模块

推荐只依赖 `BoneRemoteSyncKit` 产品，并使用 `import BoneRemoteSyncKit`。统一入口重新导出现有模块，不包装或复制原类型，不在导入时建立连接。

| 产品／模块 | 职责 |
| --- | --- |
| `BoneRemoteSyncKit` | 对外统一入口 |
| `BoneRemoteSyncCore` | 来源协议、条目、能力、错误、路径、凭据与传输选项 |
| `BoneRemoteSyncLocal` | 本地目录来源 |
| `BoneRemoteSyncICloud` | iCloud Drive 文件协调、占位下载及状态快照 |
| `BoneRemoteSyncWebDAV` | WebDAV 文件读写与下载恢复 |
| `BoneRemoteSyncOneDrive` | OneDrive Personal 主盘与 OAuth/PKCE 辅助 |
| `BoneRemoteSyncCatalog` | 可选配置、凭据桥接与离线目录索引（见 [Catalog](Catalog.md)） |

分模块产品供按需依赖使用，不是旧版兼容层。接入以当前版本的 API 和数据格式为准，不承诺保留旧接口或跨版本数据迁移；宿主应同步更新调用代码。统一导出目前使用 Swift 编译器的 `@_exported import` 下划线属性，并通过独立消费端验证；它不是应当在业务代码中复制的接入方式。

```text
App：import BoneRemoteSyncKit
    ↓
RemoteSource / RemoteWritableSource / RemoteCopyingSource
    ↓
LocalFileSource / ICloudDriveSource / WebDAVSource / OneDriveSource
    ↓
本地文件系统 / iCloud 容器与 NSFileCoordinator / URLSession
```

当前没有 `BoneRemoteSyncEngine` 或 SMB 产品。iCloud Drive 为独立来源，详见 [iCloud 指南](ICloudDrive.md)；Catalog 默认工厂暂不集成它。枚举中其他预留来源类型不代表适配器已实现。

## 协议与能力

| 协议 | 主要接口 | 当前实现 |
| --- | --- | --- |
| `RemoteSource` | `connect`、`disconnect`、`list`、`stat`、`download` | 全部来源 |
| `RemoteWritableSource` | `upload`、`makeDirectory`、`remove`、`move` | 全部来源 |
| `RemoteCopyingSource` | `copy` | 本地、WebDAV、iCloud（仅文件） |

`walk` 和按路径下载是 `RemoteSource` 的扩展方法。`RemoteCapabilities` 用于界面与任务规划，但不能代替服务端权限验证；即使能力为 true，操作仍可能被拒绝。`maxConcurrentTransfers` 只是建议值，不是全局调度器。

## 连接、取消与清理

1. 创建来源实例并调用 `connect(_:)`。
2. 在该会话内执行一个或多个操作。
3. 在成功、失败或退出账号时等待 `disconnect()`。

[首页快速上手](../README.md#快速上手)提供完整的 `do/catch` 清理方式。不要用 `defer { Task { ... } }` 声称已经等待断开：新建任务可能在宿主流程返回后才运行。

来源以 actor 管理状态；`await` 期间仍可能发生重入，不能把一次调用视为跨所有步骤的锁或事务。网络来源断开／重连会取消旧请求并隔离旧会话结果，但无法撤回已到达远端的写入。取消是协作式的，同步磁盘 I/O、用户回调或服务端工作无法被强制即时终止。

## 路径与条目

- 路径使用来源内 POSIX 风格，`/` 对应配置的本地目录、WebDAV collection、iCloud 容器的配置子目录或 OneDrive 主盘根。
- `RemotePath.normalize` 负责格式归一化；不要先对路径执行 URL 编码，WebDAV 会逐段处理中文、空格和特殊字符。
- `RemoteEntry.id` 与 `path` 不可互换。OneDrive 的 `RemoteIDAddressableSource` 支持按不透明 ID 读取条目、列出父目录和下载；重命名后按 ID 查询可能返回 `path=nil`，不能回退到旧路径。稳定 ID 只在同一来源/账号/主盘会话内有效，不能持久化为跨账号凭据或拼接为 URL。其他来源尚未声明该能力，调用方应检查 `capabilities.idAddressing`，不要把相对路径伪装成稳定 ID。
- `etag` 是版本元数据，不保证是内容哈希。`RemoteUploadOptions.expectedETag` 只有在 `conditionalUpload` 为 true 时才可用；WebDAV 将调用方的强 ETag 原样放入 `If-Match`，其他当前来源明确拒绝。缺少可信版本信息时，`size` 与 `modifiedAt` 只能用于启发式比较。
- `RemoteContentChecksum` 另行表达整文件摘要，包含算法和原始摘要字节；不同算法不能直接比较，且 SDK 不因来源报告摘要就声称已验证下载。`hasReliableFingerprint` 只表示具备 ETag 或修改时间，不证明内容一致，也不能单独支撑自动删除或双向冲突决策。

## 文件时间与类型分类

`RemoteEntry` 同时用于 list、stat 和下载返回值。除名称、路径、文件/目录、大小、修改时间、ETag 与 MIME 外，现在还包含可选 `createdAt: Date?`，以及无 I/O 的计算属性 `fileCategory: RemoteFileCategory`。

| 来源 | `createdAt` 的含义 |
| --- | --- |
| Local / iCloud | 本机文件系统 `creationDate` |
| WebDAV | 成功 DAV 属性中的 `creationdate`（ISO 8601，支持小数秒和时区偏移） |
| OneDrive | Graph `driveItem.createdDateTime`，不是 `fileSystemInfo.createdDateTime` |

网络创建时间接受带时区的 `YYYY-MM-DDTHH:mm:ss[.小数秒]Z` 或 `±HH:mm` 形式，严格检查日期与完整输入；年份为 0001–9999 的延伸公历，时区偏移小时小于 24、分钟小于 60，不接受闰秒、24:00、无时区或尾随垃圾。

缺失或无法解析时返回 nil，不以修改时间或当前时间填充。这些来源的创建时间不一定有完全相同的语义，也不代表 EXIF 拍摄时间、音频录制时间或首次内容生成时间。移动、复制、上传可能改变创建时间。下载返回的是**来源条目元数据**，不承诺把该时间设置到本地目标文件。

分类规则依次为：

1. 目录固定为 `.directory`。
2. MIME 忽略大小写、两端空格和 `;` 后的参数：`image/*`、`audio/*`、`video/*` 分别归入图片、音频、视频；`text/*` 及已识别 PDF、Office、JSON、XML、EPUB 等归入文档；ZIP、gzip、tar、7z、RAR 等归入归档。这里的 `*` 表示合法的具体子类型，不是接受通配符 MIME。
3. 仅当 MIME 缺失、格式无效，或为 `application/octet-stream`、`binary/octet-stream`、`application/binary` 时，按不区分大小写的常见扩展名回退。
4. 未识别的具体 MIME、未知扩展名、无扩展名或单独的 `.jpg` 等点文件返回 `.unknown`。如 `application/ogg` 可能承载音频或视频，不武断归类；仅有 `.mp4` 时则作为视频提示。

可用类别为 `.directory`、`.image`、`.audio`、`.video`、`.document`、`.archive`、`.unknown`。例如 `audio/flac` 配合文件名 `photo.jpg` 返回 `.audio`；未知的具体 `application/x-custom` 配合该文件名仍返回 `.unknown`。常见扩展名映射是有限清单，不是完整格式注册表。

```swift
import Foundation
import BoneRemoteSyncKit

func describeFile(_ entry: RemoteEntry) -> String {
    let created = entry.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "未知"
    return "\(entry.name) · \(entry.fileCategory.rawValue) · 创建时间：\(created)"
}
```

分类不打开文件、不读取文件头、不下载远端内容，也不验证 MIME 或扩展名是否真实；不能用它做安全校验或判断文件一定可解码。当前没有图片尺寸、EXIF、音视频时长、封面、缩略图、播放或转码 API。普通 list 不会隐式提取这些信息。

当前数据语义：`createdAt` 是默认 nil 的可选参数；Swift 合成的 Codable 将缺失字段解码为 nil，与来源可能不提供创建时间的语义一致。这不是跨版本格式兼容承诺。分类是计算属性，不重复写入 Codable 数据。`createdAt` 参与合成的相等性/哈希，完整条目相等不等于内容相同；`hasReliableFingerprint` 仍只依据 ETag 或修改时间，不因为有创建时间就变成 true。

## 稳定 ID 读取

部分云盘可通过可选的 `RemoteIDAddressableSource` 按稳定条目标识读取，而不是依赖可变路径。当前只有 OneDrive Personal 实现 `stat(id:)`、`list(parentID:request:)` 与 `download(id:to:options:)`；按 ID 返回的条目可以没有路径。调用前检查 `capabilities.idAddressing`，不要把路径、分页游标或下载 URL 当稳定 ID。

## 分页

`RemoteListRequest.limit` 是正数页大小提示，不是跨来源统一截断条数：

| 来源 | `limit` | `cursor` |
| --- | --- | --- |
| 本地 / iCloud | nil 或正数合法，仍返回完整单层结果 | 拒绝任何非 nil 值，包括 `""` |
| WebDAV | nil 或正数合法，仍返回完整 Depth:1 结果 | 拒绝任何非 nil 值，包括 `""` |
| OneDrive | 向 Graph 发送 `min(limit, 200)`，实际条数由服务端决定 | 使用来源返回的游标，并保持目录与选项一致 |

`RemoteListRequest.all` **不代表自动消费所有 OneDrive 页面**。四个来源的 list 均先检查连接上下文，再在操作中校验请求参数，因此未连接时不保证优先返回参数错误。

`RemoteListPage(coverage:entries:nextCursor:)` 必须显式传入 `.complete/.partial/.unknown`，没有默认 complete。`isLastPage` 只表示 cursor 为 nil；所有页 complete 且全部分页完成才有目录发布资格，仍不证明瞬时快照。

以下函数在已连接的来源上逐页读取，不把整个目录累积到数组。visitor 可能在后续分页失败前已经产生副作用。

```swift
import BoneRemoteSyncKit

func visitDirectory(
    source: any RemoteSource,
    path: String,
    visit: @Sendable (RemoteEntry) async throws -> Void
) async throws {
    var request = RemoteListRequest(limit: 100)
    while true {
        let page = try await source.list(path: path, request: request)
        guard page.coverage == .complete else {
            throw RemoteSyncError.unsupported(operation: "目录列表不完整")
        }
        for entry in page.entries {
            try await visit(entry)
        }
        guard let cursor = page.nextCursor else { break }
        request = request.nextPage(cursor: cursor)
    }
}
```

OneDrive 游标绑定当前连接、路径与选项，成功推进后旧游标失效；不要持久化或跨账号复用。分页失败或遍历未完成时，不应把缺少的条目直接推导为远端删除。

## 目录遍历

`walk(path:includeHidden:)` 提供顺序 `AsyncThrowingStream`。需要有界并发、条目预算和消费背压时，使用 async visitor 版本：

```swift
import BoneRemoteSyncKit

func inspectTree(source: any RemoteSource) async throws -> RemoteWalkSummary {
    try await source.walk(
        path: "/",
        options: RemoteWalkOptions(
            maxConcurrentRequests: 4,
            maxDepth: 64,
            maxEntries: 100_000,
            includeHidden: false
        )
    ) { entry in
        // 可 await 数据库存储或 UI 更新；visitor 不会并发执行。
        print(entry.path ?? entry.id)
    }
}
```

- 同时执行的 `list` 请求数为 1…16，默认 4；只限制本次遍历，不限制其他下载或上传。
- 起始目录深度为 0，目录计数包含起始目录；默认最大深度 64、最大条目数 100,000。
- visitor 顺序等待；消费一页时不补充请求，已有的至多 N 个请求仍可完成。不同目录之间的返回顺序不保证。
- 页面进入结果缓冲前会预留发现预算；重复路径、非直接子项、自身、缺失路径、游标循环及预算超限都会报错，不返回静默截断的成功结果。
- 条目限制不是字节内存上限，无法阻止适配器先物化超大单页。持续不同游标的空页不消耗条目预算，调用方仍需管理截止时间或取消。
- 来源或 visitor 出错时会取消并等待请求收敛；双方都须协作响应取消。visitor 已产生的副作用不会回滚。
- 该遍历入口要求条目具有路径，不适用于只有 ObjectID 的媒体来源。

## 写入与失败语义

下表为原三个来源；iCloud 的协调、本地提交与云端异步传播、仅文件 copy 和冲突拒绝策略见 [iCloud 写入语义](ICloudDrive.md#当前能力与协调语义)。

统一协议统一的是调用方式，不是远端事务保证。

| 行为 | 本地 | WebDAV | OneDrive |
| --- | --- | --- | --- |
| 上传父目录 | 可自动创建 | 必须已存在 | 必须已存在 |
| `overwrite=false` | 非覆盖安装 | `If-None-Match: *` | Graph `conflictBehavior=fail` |
| `overwrite=true` | 原子替换普通文件 | 已有文件要求强 ETag / `If-Match` | Graph `conflictBehavior=replace` |
| `expectedETag` | 不支持，调用前拒绝 | 强 ETag 预检并原样发送 `If-Match` | 不支持，调用前拒绝 |
| 上传临时存储 | 同目录 staging | 私有磁盘快照，约源文件大小 | 文件式上传；不要假定具备 WebDAV 快照保证 |
| MOVE / COPY | 不覆盖；父目录须存在 | `Overwrite: F`；父目录须存在 | MOVE 先查目标再 PATCH；无 COPY |
| 写入失败 | 按操作保留或清理局部状态 | 远端可能已改变，无回滚 | 远端可能已改变，无回滚 |

`RemoteUploadOptions.overwrite` 和 `RemoteDownloadOptions.overwrite` 默认均为 true；需要保留已有文件时应显式设为 false。递归建目录中途失败可留下已创建父目录；删除目录会递归删除内容。

**OneDrive MOVE 的并发限制：** 当前实现先拒绝已存在目标，再发送 PATCH，没有显式的原子非覆盖请求条件。不能把该预检当成与 WebDAV `Overwrite: F` 相同的竞争保护；真实服务行为尚待验收。

**远端写入不是事务：** 网络错误、超时、取消、断开或 207 等响应不能证明操作未发生。先重新核对远端状态，再决定是否重试；不要盲目重放、回滚或补偿删除。

## 错误与重试

`RemoteSyncError` 提供未连接、认证失败、不存在、权限不足、不支持、限流、网络错误、冲突、完整性不匹配、取消和底层错误等分类。iCloud 特有账号/容器/目录/超时/版本冲突保留 `ICloudDriveError`，其 `remoteSyncError` 仅是宿主可选的共享投影（见 [错误映射](ICloudDrive.md#宿主错误映射与迁移)）。其他错误由适配器尽量归一化，但宿主仍应保留普通 `Error` 的兜底处理，不假定所有本地系统异常都已映射。

- `isRetryable` 只是分类提示，不包含操作幂等性判断。
- WebDAV 默认不重试；显式策略只重试白名单内的 PROPFIND / GET，写流程的只读预检可使用同一策略，写请求本身不重试。
- OneDrive 的令牌刷新与一次认证重放是专用生命周期逻辑，不是通用 429 / 5xx 重试器。
- `.conflict` 不只表示版本变化，也可能表示目标已存在、资源锁定或文件类型冲突。
- 错误中的路径可能是来源路径或真实本地文件路径；诊断时应区分，不要一律当作远端路径。

## 进度与线程

进度回调为同步 `@Sendable` 闭包，不保证在主线程。回调应线程安全且快速返回；UI 更新由宿主切换到 `MainActor`。

`RemoteDownloadOptions.progress` 报告已写 staging/part 字节（含续传偏移）。新增 `phaseProgress` 报告 `RemoteDownloadProgress`：iCloud preparing 状态变化与各来源普通 download 的 transferring 字节，比例 0...1；未知总量或空文件比例 nil。两阶段比例独立，重试可回退，达到 1 不等于最终安装成功。iCloud 不伪造系统网络百分比，详见[下载阶段状态机](ICloudDrive.md#下载阶段状态机)。上传回调报告发送进度。它们不等于远端持久化确认；WebDAV managed 恢复回调也不等于 checkpoint 已提交偏移，重试后可能回退。长时间阻塞回调会延迟取消与截止时间处理。网络来源已在途的回调可能晚于取消返回；宿主应以任务标识过滤过期事件，不把 async 终态当作回调排空屏障。

## 宿主职责

- 登录 UI、账号选择与授权策略。直接使用来源模块时负责安全存储和 token 原子持久化；使用 Catalog 时可选内置 Keychain 桥接，仍须管理 service、账号退出和授权 UI。
- 系统 sandbox、security-scoped URL／bookmark、ATS 和局域网权限。
- 多来源实例、多个进程之间的目标文件、part、checkpoint 独占协调。
- 上传来源在读取期间保持稳定；下载目标位于应用有权且可独占控制的目录。
- 后台任务、带宽限制、全局并发、应用级重试和同步冲突策略。

应用层路径验证不构成抵抗恶意父目录替换的 sandbox。SDK 不提供跨进程锁、自动垃圾回收或硬件断电持久性保证。

## 列表完整性与缓存消费者

无 options 的 stream `walk` 保留即时部分浏览语义，不能据其缺项清理缓存。带 `RemoteWalkOptions` 的 visitor 遍历遇到 partial/unknown 页会失败，在访问该页条目前拒绝；之前完整页的 visitor 副作用不会回滚。需要跨启动保存列表、失败保留旧版本与目录级发布时使用 [Catalog](Catalog.md)，不要把 visitor 逐条回调直接当作完整目录事务。

## 错误诊断日志

Core 提供 `RemoteLogger` 与白名单结构化事件，默认关闭输出；Catalog 可通过 `SQLiteRemoteCatalogStore(databaseURL:logger:)` 注入并继承使用。原始错误描述可能含路径或底层消息，不应直接写普通日志。级别、固定错误码、自动覆盖位置与 OSLog 接入见[错误日志规范](Logging.md)。
