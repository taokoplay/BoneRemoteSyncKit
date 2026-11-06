# 通用 API 与生命周期

[返回项目首页](../README.md) · [业务场景与选型](UseCases.md) · [本地目录](Local.md) · [iCloud Drive](ICloudDrive.md) · [WebDAV](WebDAV.md) · [OneDrive](OneDrive.md) · [百度](BaiduDrive.md) · [Catalog](Catalog.md) · [错误日志](Logging.md)

> 本页描述已发布 `v0.8.2` API 与当前工作区未发布的百度、Komga、Kavita、Audiobookshelf 扩展；新模块需使用包含本次实现的源码，不代表远端 `main` 已可安装。OPDS 只读书库自 `v0.8.0`、可组合网盘权限自 `v0.7.0`、Catalog 统计/缓存失效/iCloud 配置自 `v0.6.0` 提供。图标资源、来源显示名称和网盘类型列表自 `v0.5.0` 提供；R3 批量状态、Transfer、公共区间/恢复协议与 OneDrive Upload Session 自 `v0.4.0` 提供。

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
| `BoneRemoteSyncBaidu` | **未发布**：百度官方开放 API 的应用目录来源与 OAuth URL/回调辅助，仅依赖 Core 与系统框架，由 Kit 重导出 |
| `BoneRemoteSyncTransfer` | **自 v0.4.0 提供**：通用文件物化、lease、前台下载调度、可插拔单文件分片下载、显式 WebDAV 恢复下载与 OneDrive 恢复上传入口（见 [Transfer](Transfer.md)） |
| `BoneRemoteSyncCatalog` | 可选配置、凭据桥接与离线目录索引（见 [Catalog](Catalog.md)） |
| `BoneRemoteSyncOPDS` | **自 v0.8.0**：OPDS 1.2 专用书目浏览/搜索/详情与只读下载，仅依赖 Core；不集成 Catalog |
| `BoneRemoteSyncContent` | **未发布**：内容服务共享配置、分页、认证播放请求及受限 HTTP/下载设施，仅依赖 Core |
| `BoneRemoteSyncKomga` | **未发布**：Komga 原生书库、下载与阅读进度，依赖 Content/Core |
| `BoneRemoteSyncKavita` | **未发布**：Kavita 原生系列/卷章、下载与阅读进度，依赖 Content/Core |
| `BoneRemoteSyncAudiobookshelf` | **未发布**：有声书/播客、文件下载、收听进度与直放会话，依赖 Content/Core |
| `BoneRemoteSyncBrowser` | **未发布**：文件与四种书库的统一浏览/分页/搜索/详情/封面/下载选择、Codable 展示快照及错误分类；保留原生引用，见 [Browser](Browser.md) |

分模块产品供按需依赖使用，不是旧版兼容层。接入以当前版本的 API 和数据格式为准，不承诺保留旧接口或跨版本数据迁移；宿主应同步更新调用代码。统一导出目前使用 Swift 编译器的 `@_exported import` 下划线属性，它不是应当在业务代码中复制的接入方式；本轮消费端验证结果以[验证记录](Validation.md)为准。

## 图标与来源类型 API

统一入口 `BoneRemoteSyncKit` 提供以下公开类型：

| API | 参数 | 返回值 / 行为 |
| --- | --- | --- |
| `BoneRemoteSyncIcons.sourceTypes()` | 无 | 返回全部 `RemoteSourceKind` 对应的 `[BoneRemoteSyncSourceType]` |
| `BoneRemoteSyncIcons.driveTypes()` | 无 | 返回 6 个网盘图标目录项的 `[BoneRemoteSyncDriveType]` |
| `BoneRemoteSyncIcons.icon(for:)` | `kind: RemoteSourceKind` | 返回对应的 `BoneRemoteSyncIcon?`；没有内置图标时为 `nil` |
| `BoneRemoteSyncIcons.iconURL(for:)` | `kind: RemoteSourceKind` | 返回 bundle 内 PNG 的 `URL?` |
| `BoneRemoteSyncIcons.iconData(for:)` | `kind: RemoteSourceKind` | 返回 PNG `Data`；资源不存在时抛出 `BoneRemoteSyncIconError.missingResource` |
| `BoneRemoteSyncIcon.url` | 无 | 当前图标资源的 PNG URL |
| `BoneRemoteSyncIcon.data()` | 无 | 当前图标的 PNG 数据 |

`BoneRemoteSyncDriveType` 的字段为：`id: String`、`displayName: String`、`icon: BoneRemoteSyncIcon` 和 `kind: RemoteSourceKind`。`BoneRemoteSyncSourceType` 的字段为：`kind`、`displayName` 和可选 `icon`。当前工作区新增 `.baidu`，`driveTypes()` 的百度项对应此类型及 `BaiduDriveSource`；Google Drive、阿里云盘仍只有图标目录项。图标存在不等于来源已实现，实际来源能力仍需检查 `RemoteSource.capabilities`。

## Catalog 路径与统计

`BoneRemoteSyncIcons.driveTypes()` 只返回静态展示字段，不包含账号路径或容量。具体来源的选定路径和扫描统计由 Catalog 返回：

```swift
let root = try await catalog.store.root(id: rootID)
let summary = try await catalog.storageSummary(rootID: rootID)
print(root.path, summary?.recursiveFileCount as Any, summary?.totalBytes as Any)
```

`RemoteCatalogStorageSummary` 字段：

| 字段 | 含义 |
| --- | --- |
| `rootID` / `path` | 统计绑定的 Catalog root 和当前选定路径 |
| `recursiveFileCount` | 最近一次完整 subtree 扫描的递归文件数 |
| `recursiveDirectoryCount` | 最近一次完整 subtree 扫描发现的子目录数，不含 root 自身 |
| `totalBytes` | 文件大小全部已知时的递归总字节数；存在未知大小时为 `nil` |
| `capacityBytes` / `usedBytes` | 来源提供 quota 能力时的服务端容量/已用空间，否则为 `nil` |
| `isComplete` / `isStale` | 是否完成完整扫描、统计是否已被远端 mutation 或失败刷新标旧 |
| `measuredAt` / `quotaMeasuredAt` | 扫描统计和 quota 的测量时间 |

只有保存 root 的完整 `subtree` 刷新成功后才生成或替换递归统计；`children` 刷新不改递归统计。宿主通过来源的上传、删除或移动接口改变远端内容后，应调用 `catalog.invalidateCache(rootID:directory:)` 或执行刷新。`clearIndex`、root 替换、binding 重绑和 profile 删除会清除对应 summary；路径失效自动回退到 `/` 时旧路径统计也不会沿用。

**扫描节流（未发布）：** `RemoteCatalogRefreshOptions.requestInterval: TimeInterval` 表示同一次扫描的 `list/stat` 最小放行间隔，单位秒，默认 `0`，范围 `0...86400`；所有并发目录和分页共享。可用 `.init(scope: .subtree, concurrency: 1, requestInterval: 0.5)` 串行扫描并间隔 500 ms。等待计入 timeout，可被取消；连接/认证、选根预检、适配器内部重试和其他任务不在此限制内，不是全局 HTTP 限流。详细语义见 [Catalog 刷新](Catalog.md#选择目录刷新与离线查询)。



```text
App：import BoneRemoteSyncKit
    ↓
RemoteSource / RemoteWritableSource / RemoteCopyingSource
    ↓
LocalFileSource / ICloudDriveSource / WebDAVSource / OneDriveSource / BaiduDriveSource（未发布）
    ↓
本地文件系统 / iCloud 容器与 NSFileCoordinator / URLSession
```

当前没有 `BoneRemoteSyncEngine` 或 SMB 产品。iCloud Drive 为独立来源，Catalog 已支持保存 iCloud 配置、打开固定会话并索引选定目录；宿主仍需提供正确 entitlement 和容器，详见 [iCloud 指南](ICloudDrive.md)。枚举中其他预留来源类型不代表适配器已实现。

## 协议与能力

| 协议 | 主要接口 | 当前实现 |
| --- | --- | --- |
| `RemoteSource` | `connect`、`disconnect`、`list`、`stat`、`download` | 文件来源；OPDS 仅提供登记描述 stat/下载，list 明确不支持 |
| `RemoteWritableSource` | `upload`、`makeDirectory`、`remove`、`move` | 五类文件来源（含未发布百度）；OPDS 不遵循 |
| `RemoteCopyingSource` | `copy` | 本地、WebDAV、iCloud（仅文件）、百度（未发布） |
| `RemoteIDAddressableSource` | `stat(id:)`、`list(parentID:request:)`、`download(id:to:options:)` | OneDrive Personal、百度（未发布）；仅在各自绑定范围内读取 |
| `RemoteByteRangeSource` | **自 v0.4.0 提供**：强版本与有界区间 `readBytes` | WebDAV；Transfer 复用调度/合并，其他来源可实现协议接入，见 [分片下载](Transfer.md#可插拔的单文件并行分片下载) |
| `RemoteResumableDownloadSource` | **自 v0.4.0 提供**：checkpoint 观察、受管理恢复下载 | WebDAV；需明确目标互斥，见 [Transfer](Transfer.md) |
| `RemoteResumableUploadSource` | **自 v0.4.0 提供**：本地准备、继续上传、checkpoint、显式终止 | OneDrive Personal 专用构造器 opt-in；与下载队列分离，见 [OneDrive](OneDrive.md#upload-session-可恢复上传显式-opt-in) |

自 `v0.8.0` 提供的 `OPDSSource` 使用 `browse`、`nextPage`、`publication`、`search` 处理书库链接，通过 `prepareDownload` 签发会话内合成路径，交给 Transfer。`sourceBinding()` 每次连接变化；stat 不做远端 HEAD，文件版本及大小保持未知，不支持强版本缓存、递归目录或 Catalog。不要把书目 Atom ID、Feed ETag 或 updated 当作文件版本。详见 [OPDS API](OPDS.md)。

未发布 `BaiduDriveSource` 使用已存在且获授权的 `/apps/{app}` 或子目录作为 `rootPath`，不提供全盘浏览。`BaiduDriveOAuth` 生成简化/授权码模式 URL 并校验回调；code 交换和令牌刷新交给宿主后端保护 SecretKey，无 PKCE 承诺。`BaiduDriveTokenRefresher` 由宿主调用后端并安全持久化新令牌，单实例合并刷新、核对账号，失败使会话失效；Catalog 的固定引用回调另见 [Catalog](Catalog.md)。尚无真实百度应用或 token，接入合同见 [百度指南](BaiduDrive.md)。

未发布原生 `KomgaSource`、`KavitaSource`、`AudiobookshelfSource` 均遵循 `RemoteSource`，但仅声明会话登记描述的 `stat` 与完整 `download`；通过各自的原生 API 浏览和搜索，不支持 `list/walk` 或 Catalog。`prepareDownload` 返回会话内不透明引用，与同一连接的 `sourceBinding()` 一起接入 Transfer。阅读/收听进度是独立显式写操作，不表示实现文件上传/删除。`RemoteSourceKind` 新增 `.komga`、`.kavita`、`.audiobookshelf`，宿主穷举 switch 需覆盖；图标仍为 nil。详见 [内容服务合同](ContentServices.md)。

## 网盘访问权限

Catalog 保存的 `RemoteSourceProfile.permission` 使用 `RemoteAccessPermission: OptionSet`：默认只读且读取必选，编辑、新增、删除可多选：

| 权限 | 允许操作 |
| --- | --- |
| `.readOnly`（必选） | 浏览、stat、下载、遍历 |
| `.edit` | 覆盖已有文件、移动、重命名 |
| `.create` | 上传新文件、建目录、复制（会话自动包含读取权限） |
| `.delete` | 删除文件或目录 |

例如 `permission: [.readOnly, .edit, .create]` 允许读取、编辑和新增，拒绝删除。`allCases` 枚举四个选项，宿主界面应将只读固定勾选并禁用取消，其余三项使用 `contains`、`insert`、`remove` 管理。配置与受控会话自动补齐读取权限：`[]` 等价于只读，`.create` 等价于 `[.readOnly, .create]`，`.all` 授予全部权限。`OptionSet` 本身保留标准集合运算语义。

使用 `RemoteCatalog.saveSource(..., permission:)` 保存，默认值为 `.readOnly`，`RemoteSourceProfile` 和 `RemoteAccessControlledSource` 同样默认只读。`catalog.store.profiles()` 和 `catalog.store.profile(id:)` 返回包含读取权限的组合。持久化的 `permission` 必须是权限名称数组（只读为 `["readOnly"]`），不接受角色字符串、缺失字段、null 或未知名称。旧角色 API 和兼容解码已移除；直接解码不合法配置抛出 `DecodingError`，数据库读取返回 `RemoteCatalogError.invalidConfiguration`。旧格式配置需按新模型重新配置。

Catalog 会话的 `RemoteAccessControlledSource` 按操作检查权限；`capabilities` 同步裁剪但不会增加来源本身没有的能力。普通上传区分目标是否存在，非覆盖上传要求新增权限，条件上传要求编辑权限。仅新增时禁止覆盖；仅编辑时优先固定来源支持的 ETag，否则存在性预检仍需宿主协调外部并发删除。完整语义见 [Catalog](Catalog.md)。此配置只约束受控会话，不修改远端账号授权；直接使用原始适配器不受它约束。

`RemoteCapabilities` 反映受控来源可展示的操作入口，但调用方仍须处理服务端权限、冲突、条件版本和来源错误。
`walk` 和按路径下载是 `RemoteSource` 的扩展方法。`RemoteCapabilities` 用于界面与任务规划，但不能代替服务端权限验证；即使能力为 true，操作仍可能被拒绝。低层 `maxConcurrentTransfers` 只是建议值；`RemoteTransferCoordinator` 将它作为各 binding 的调度上限输入，同时实施自身全局限制，不能限制绕过该 coordinator 的调用。

## 连接、取消与清理

1. 创建来源实例并调用 `connect(_:)`。
2. 在该会话内执行一个或多个操作。
3. 在成功、失败或退出账号时等待 `disconnect()`。

[首页快速上手](../README.md#快速上手)提供完整的 `do/catch` 清理方式。不要用 `defer { Task { ... } }` 声称已经等待断开：新建任务可能在宿主流程返回后才运行。

来源以 actor 管理状态；`await` 期间仍可能发生重入，不能把一次调用视为跨所有步骤的锁或事务。网络来源断开／重连会取消旧请求并隔离旧会话结果，但无法撤回已到达远端的写入。取消是协作式的，同步磁盘 I/O、用户回调或服务端工作无法被强制即时终止。

## 路径与条目

- 路径使用来源内 POSIX 风格，`/` 对应配置的本地目录、WebDAV collection、iCloud 容器的配置子目录、OneDrive 主盘根或百度授权应用目录的 `rootPath`。
- `RemotePath.normalize` 负责格式归一化；不要先对路径执行 URL 编码，WebDAV 与百度会处理请求编码。
- `RemoteEntry.id` 与 `path` 不可互换。OneDrive 和百度通过 `RemoteIDAddressableSource` 支持按不透明 ID 读取、列目录和下载；OneDrive 重命名后按 ID 查询可能返回 `path=nil`，不能回退到旧路径。百度 ID 包含应用/用户/根作用域和精确 uint64 `fs_id`，`uk` 同样精确读取；返回路径必须仍在配置根内。ID 不是授权凭据，不能跨账号复用、手工拼装或拼接为 URL；调用前检查 `capabilities.idAddressing`。
- `etag` 是版本元数据，不保证是内容哈希。`RemoteUploadOptions.expectedETag` 只有在 `conditionalUpload` 为 true 时才可用；WebDAV 将调用方的强 ETag 原样放入 `If-Match`，其他当前来源明确拒绝。缺少可信版本信息时，`size` 与 `modifiedAt` 只能用于启发式比较。
- `RemoteContentChecksum` 另行表达整文件摘要，包含算法和原始摘要字节；不同算法不能直接比较，且 SDK 不因来源报告摘要就声称已验证下载。`hasReliableFingerprint` 只表示具备 ETag 或修改时间，不证明内容一致，也不能单独支撑自动删除或双向冲突决策。
- 百度不将服务端 MD5 作为 `contentChecksums`、ETag 或强版本；仅在单次下载前后内部观察。Transfer 的 size+mtime 是启发式缓存，不能发现所有同大小同时间的内容替换。

## 文件时间与类型分类

`RemoteEntry` 同时用于 list、stat 和下载返回值。除名称、路径、文件/目录、大小、修改时间、ETag 与 MIME 外，现在还包含可选 `createdAt: Date?`，以及无 I/O 的计算属性 `fileCategory: RemoteFileCategory`。

| 来源 | `createdAt` 的含义 |
| --- | --- |
| Local / iCloud | 本机文件系统 `creationDate` |
| WebDAV | 成功 DAV 属性中的 `creationdate`（ISO 8601，支持小数秒和时区偏移） |
| OneDrive | Graph `driveItem.createdDateTime`，不是 `fileSystemInfo.createdDateTime` |
| 百度（未发布） | `server_ctime`，服务端 Unix 时间；`server_mtime` 对应修改时间 |

WebDAV / OneDrive 的网络创建时间接受带时区的 `YYYY-MM-DDTHH:mm:ss[.小数秒]Z` 或 `±HH:mm` 形式，严格检查日期与完整输入；年份为 0001–9999 的延伸公历，时区偏移小时小于 24、分钟小于 60，不接受闰秒、24:00、无时区或尾随垃圾。百度使用服务端 Unix 时间。

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

分类不打开文件、不读取文件头、不下载远端内容，也不验证 MIME 或扩展名是否真实；不能用它做安全校验或判断文件一定可解码。普通文件 `list` 不提取图片尺寸、EXIF、时长或封面。未发布原生内容服务可获取服务端已有的媒体元数据、封面和页面；Audiobookshelf 可创建直放会话，但 SDK 不提供媒体解析器、播放器或转码器，见 [内容服务](ContentServices.md)。

当前数据语义：`createdAt` 是默认 nil 的可选参数；Swift 合成的 Codable 将缺失字段解码为 nil，与来源可能不提供创建时间的语义一致。这不是跨版本格式兼容承诺。分类是计算属性，不重复写入 Codable 数据。`createdAt` 参与合成的相等性/哈希，完整条目相等不等于内容相同；`hasReliableFingerprint` 仍只依据 ETag 或修改时间，不因为有创建时间就变成 true。

## 稳定 ID 读取

部分云盘可通过可选的 `RemoteIDAddressableSource` 按稳定条目标识读取，而不是依赖可变路径。当前 OneDrive Personal 和未发布百度实现 `stat(id:)`、`list(parentID:request:)` 与 `download(id:to:options:)`；OneDrive 按 ID 返回的条目可以没有路径。百度必须使用来源签发的完整 ID，可跟随同一根内的重命名，跨应用/账号/根或条目移出根时拒绝。调用前检查 `capabilities.idAddressing`，不要把原始 `fs_id`、路径、分页游标或下载 URL 当稳定 ID。

## 分页

`RemoteListRequest.limit` 是正数页大小提示，不是跨来源统一截断条数：

| 来源 | `limit` | `cursor` |
| --- | --- | --- |
| 本地 / iCloud | nil 或正数合法，仍返回完整单层结果 | 拒绝任何非 nil 值，包括 `""` |
| WebDAV | nil 或正数合法，仍返回完整 Depth:1 结果 | 拒绝任何非 nil 值，包括 `""` |
| OneDrive | 向 Graph 发送 `min(limit, 200)`，实际条数由服务端决定 | 使用来源返回的游标，并保持目录与选项一致 |
| 百度（未发布） | list 的 start/limit 分页，单页最多 1000 | 绑定连接、路径/父 ID、原始 limit 和 includeHidden；成功推进后旧游标失效 |

`RemoteListRequest.all` **不代表自动消费所有 OneDrive 或百度页面**。来源会在操作中校验连接与请求参数，未连接时不保证优先返回参数错误。

`RemoteListPage(coverage:entries:nextCursor:)` 必须显式传入 `.complete/.partial/.unknown`，没有默认 complete。`isLastPage` 只表示 cursor 为 nil；所有页 complete 且全部分页完成才有目录发布资格，仍不证明瞬时快照。

iCloud 另提供 `ICloudDriveSource.statuses(paths:)` 批量读取本机条目状态。该 iCloud 专用 API 返回有序的 `ICloudDriveStatusResult`，每项包含归一化路径与 `Result<ICloudDriveStatus, any Error>`；它不扩展 Core、无需连接、不 hydration、不建目录，也不保证原子快照。

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

OneDrive 与百度游标绑定当前连接、路径与选项，成功推进后旧游标失效；不要持久化或跨账号复用。百度分页失败后从第一页重试，满页可产生最终返回空页的下一游标；offset 分页即使每页 complete 也不是瞬时快照。分页失败或遍历未完成时，不应把缺少的条目直接推导为远端删除。

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

下表列出本地、WebDAV、OneDrive 和当前工作区未发布百度；iCloud 的协调、本地提交与云端异步传播、仅文件 copy 和冲突拒绝策略见 [iCloud 写入语义](ICloudDrive.md#当前能力与协调语义)。

统一协议统一的是调用方式，不是远端事务保证。

| 行为 | 本地 | WebDAV | OneDrive | 百度（未发布） |
| --- | --- | --- | --- | --- |
| 上传父目录 | 可自动创建 | 必须已存在 | 必须已存在 | 必须已存在，可显式递归 mkdir；配置根须预先存在 |
| `overwrite=false` | 非覆盖安装 | `If-None-Match: *` | Graph `conflictBehavior=fail` | `rtype=0`，冲突失败，不改名 |
| `overwrite=true` | 原子替换普通文件 | 已有文件要求强 ETag / `If-Match` | Graph `conflictBehavior=replace` | 整文件替换，无强条件 |
| `expectedETag` | 不支持，调用前拒绝 | 强 ETag 预检并原样发送 `If-Match` | 不支持，调用前拒绝 | 不支持，副作用前拒绝 |
| 上传临时存储 | 同目录 staging | 私有磁盘快照，约源文件大小 | 文件式上传；不要假定具备 WebDAV 快照保证 | 私有磁盘快照，约源文件大小；非空 ≤4 GiB，4 MiB 顺序分片，无持久续传 |
| MOVE / COPY | 不覆盖；父目录须存在 | `Overwrite: F`；父目录须存在 | MOVE 先查目标再 PATCH；无 COPY | 同步 `async=0` / `ondup=fail`；父目录须存在 |
| 写入失败 | 按操作保留或清理局部状态 | 远端可能已改变，无回滚 | 远端可能已改变，无回滚 | 远端可能已改变，无回滚或自动重放 |

普通 `RemoteUploadOptions.overwrite` 和 `RemoteDownloadOptions.overwrite` 默认均为 true；需要保留已有文件时应显式设为 false。递归建目录中途失败可留下已创建父目录；删除目录会递归删除内容。

**OneDrive MOVE 的并发限制：** 当前实现先拒绝已存在目标，再发送 PATCH，没有显式的原子非覆盖请求条件。不能把该预检当成与 WebDAV `Overwrite: F` 相同的竞争保护；真实服务行为尚待验收。

**百度写入边界：** 同一来源实例串行写入，并发写返回冲突，不构成跨实例事务。move/copy/delete 检查顶层及逐项结果；服务端返回非零 `taskid` 时以 `asynchronousResult` 拒绝当作已完成。上传仅支持非空普通文件，precreate 非 1 的内部完成状态也明确不支持；未知结果需核对远端。禁止对配置根本身执行写入/删除/移动/复制，不支持 `expectedETag`、Range、下载 `resumeFrom`、持久续传、后台传输、变更流或强条件读取。

**远端写入不是事务：** 网络错误、超时、取消、断开或 207 等响应不能证明操作未发生。先重新核对远端状态，再决定是否重试；不要盲目重放、回滚或补偿删除。

## 错误与重试

`RemoteSyncError` 提供未连接、认证失败、不存在、权限不足、不支持、限流、网络错误、冲突、完整性不匹配、取消和底层错误等分类。iCloud 特有账号/容器/目录/超时/版本冲突保留 `ICloudDriveError`，其 `remoteSyncError` 仅是宿主可选的共享投影（见 [错误映射](ICloudDrive.md#宿主错误映射与迁移)）。其他错误由适配器尽量归一化，但宿主仍应保留普通 `Error` 的兜底处理，不假定所有本地系统异常都已映射。

- `isRetryable` 只是分类提示，不包含操作幂等性判断。
- WebDAV 默认不重试；显式策略只重试白名单内的 PROPFIND / GET，写流程的只读预检可使用同一策略，写请求本身不重试。
- OneDrive 的令牌刷新与一次认证重放是专用生命周期逻辑，不是通用 429 / 5xx 重试器。
- 百度按到期时间合并单实例刷新并核对账号；认证错误不自动重放写请求，无隐藏网络重试。`.apiToken` 或无 expiry 的 OAuth 不自动到期刷新，宿主负责重新授权。
- `.conflict` 不只表示版本变化，也可能表示目标已存在、资源锁定或文件类型冲突。
- 错误中的路径可能是来源路径或真实本地文件路径；诊断时应区分，不要一律当作远端路径。

## 进度与线程

进度回调为同步 `@Sendable` 闭包，不保证在主线程。回调应线程安全且快速返回；UI 更新由宿主切换到 `MainActor`。

`RemoteDownloadOptions.progress` 报告已写 staging/part 字节（含续传偏移）。新增 `phaseProgress` 报告 `RemoteDownloadProgress`：iCloud preparing 状态变化与各来源普通 download 的 transferring 字节，比例 0...1；未知总量或空文件比例 nil。两阶段比例独立，重试可回退，达到 1 不等于最终安装成功。iCloud 不伪造系统网络百分比，详见[下载阶段状态机](ICloudDrive.md#下载阶段状态机)。上传进度按来源合同报告：百度报告本次服务端确认的分片字节，最终大小仅在 create 成功后报告，服务端跳过重复分片时可跳跃，不表示瞬时发送速率；其他来源按各自发送进度合同处理。进度不构成通用远端持久化证明；WebDAV managed 恢复回调也不等于 checkpoint 已提交偏移，重试后可能回退。长时间阻塞回调会延迟取消与截止时间处理。网络来源已在途的回调可能晚于取消返回；宿主应以任务标识过滤过期事件，不把 async 终态当作回调排空屏障。

## 宿主职责

- 登录 UI、账号选择与授权策略。直接使用来源模块时负责安全存储和 token 原子持久化；使用 Catalog 时可选内置 Keychain 桥接，仍须管理 service、账号退出和授权 UI。
- 系统 sandbox、security-scoped URL／bookmark、ATS 和局域网权限。
- 多来源实例、多个进程之间的目标文件、part、checkpoint 独占协调。
- 上传来源在读取期间保持稳定；下载目标位于应用有权且可独占控制的目录。
- 后台任务、带宽限制、全局并发、应用级重试和同步冲突策略。

应用层路径验证不构成抵抗恶意父目录替换的 sandbox。普通来源操作不提供通用跨进程锁；显式恢复下载和 OneDrive Upload Session 分别提供要求所有参与者遵循同一协议的本地合作锁，详见 [Transfer](Transfer.md)。SDK 不提供自动垃圾回收或硬件断电持久性保证。

## 列表完整性与缓存消费者

无 options 的 stream `walk` 保留即时部分浏览语义，不能据其缺项清理缓存。带 `RemoteWalkOptions` 的 visitor 遍历遇到 partial/unknown 页会失败，在访问该页条目前拒绝；之前完整页的 visitor 副作用不会回滚。需要跨启动保存列表、失败保留旧版本与目录级发布时使用 [Catalog](Catalog.md)，不要把 visitor 逐条回调直接当作完整目录事务。

## 错误诊断日志

Core 提供 `RemoteLogger` 与白名单结构化事件，默认关闭输出；Catalog 可通过 `SQLiteRemoteCatalogStore(databaseURL:logger:)` 注入并继承使用。原始错误描述可能含路径或底层消息，不应直接写普通日志。级别、固定错误码、自动覆盖位置与 OSLog 接入见[错误日志规范](Logging.md)。

## 显式可恢复上传

> 本节 API 自 `v0.4.0` 提供，不包含在 `v0.3.0` 标签中。

`RemoteResumableUploadSource` 定义本地prepare、resume、checkpoint和abort；`RemoteUploadRecovery`是仅依赖Core的显式通用适配，不自动加入下载coordinator。`RemoteResumableUploadOptions.overwrite`默认**false**，与普通上传不同。宿主先保存prepare返回的非秘密handle，再启动resume；结果区分committed与committedCleanupPending，后者不等于未提交。OneDrive仅在专用构造器启用，条件ETag替换仍unsupported。详见[Transfer恢复上传](Transfer.md#显式恢复上传onedrive)及[OneDrive合同](OneDrive.md#upload-session-可恢复上传显式-opt-in)。
