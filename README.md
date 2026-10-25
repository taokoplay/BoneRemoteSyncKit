# BoneRemoteSyncKit

面向多来源远程文件访问与同步的 Swift SDK。通过统一契约提供本地目录读写、WebDAV 文件读写，以及 OneDrive Personal 主盘读写（上传、建目录、改名、删除）；SMB、其他网盘、iCloud Drive 适配器及同步引擎仍在规划中。

截至 2026-10-20：本地来源支持浏览、传输和文件管理；新增 `BoneRemoteSyncWebDAV`，支持匿名/Basic 连接、PROPFIND 目录与文件信息、流式 GET 和有条件的断点续传。WebDAV 已通过自建 HTTP 集成测试与一台真实飞牛服务的只读功能验收（当前账号可见非隐藏树、3个小样本下载与条件续传），不代表其他厂商、大文件或移动端运行兼容。第一阶段性能优化已加入块式接收、日期解析复用与有界并发遍历；可恢复传输 v1 新增显式启用的有限重试，以及 checkpoint / 跨进程下载恢复，已通过 localhost 故障注入与独立 PID / SIGKILL 验收。本次恢复能力没有连接真实飞牛，不代表真实 NAS 断网或其他厂商兼容验收；仍没有自动同步引擎。

截至 2026-10-25，WebDAV 新增完整文件 PUT 上传、递归 MKCOL、DELETE、MOVE 与 COPY，接入 `RemoteCopyingSource`。写能力通过 localhost 合成服务验证，**尚未在真实 NAS 上进行写入验收**；不是 WebDAV 全部扩展协议实现，未提供 LOCK/UNLOCK、PROPPATCH、ACL 或通用断点上传。

新增 `BoneRemoteSyncOneDrive` v1：原生 public-client OAuth + PKCE 辅助、令牌兑换/刷新、主盘连接、分页浏览、stat、安全完整下载，以及上传、递归建目录、改名与删除。当前只通过本地合成 fixture 验证，**未用真实 Microsoft 应用或账号完成兼容性验收**。

## 命名

`BoneRemoteSyncKit` 作为包名与仓库名，模块名统一用 `BoneRemoteSync` + 来源后缀，与包名保持一致：

| 名称 | 结论 |
| --- | --- |
| **BoneRemoteSyncKit** | ✅ 采用。`Bone` 为品牌前缀，`RemoteSync` 描述能力域，`Kit` 符合 Swift 生态惯例 |
| AnyDrive | 备选。更强调"多来源统一"，但弱化了同步语义 |
| MountKit / MountPoint | ❌ 暗示挂载，而本 SDK 是浏览 + 同步，不提供 POSIX 挂载点 |
| SourceKit | ❌ 与 Apple 的 Swift 工具链框架重名 |
| CloudKit | ❌ 与 Apple 的 CloudKit 重名 |
| FileProviderKit | ❌ 与 Apple 的 FileProvider 框架易混；将来做 File Provider 扩展时无法区分 |

## 分层

```text
调用方 (App)
    ↓
BoneRemoteSyncEngine   快照 / diff / 计划 / 执行 / 冲突     ← 未实现
    ↓
RemoteSource 契约  （BoneRemoteSyncCore）
    ↓
各来源适配器        （BoneRemoteSyncWebDAV / BoneRemoteSyncSMB / BoneRemoteSyncCloudAPI …）
    ↓
传输层             URLSession / libsmb2 / ssh / 系统挂载
```

同步引擎与适配器分离：只做"浏览 + 下载"的调用方不必引入同步逻辑。

## 模块

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| `BoneRemoteSyncCore` | `RemoteSource` 契约、`RemoteEntry`、`RemoteCapabilities`、`RemoteSyncError`、`RemotePath`、凭据与传输选项 | ✅ |
| `BoneRemoteSyncLocal` | 本地目录读写、文件传输及管理；为后续适配器提供真实文件系统测试基础 | ✅ |
| `BoneRemoteSyncWebDAV` | WebDAV 读写：PROPFIND / GET / PUT / MKCOL / DELETE / MOVE / COPY，下载 Range、有限重试与 checkpoint 恢复 | ✅ 本地写入 fixture 验证；真实 NAS 写入待验收 |
| `BoneRemoteSyncOneDrive` | Personal 主盘读写：PKCE/OAuth、分页浏览、安全完整下载、上传、递归建目录、改名、删除 | ✅ 本地 fixture 验证；真实账号待验收 |
| `BoneRemoteSyncSMB` | SMB2/3，需要 libsmb2 二进制依赖 | 待实现 |
| 其他厂商网盘适配器 | 分厂商独立模块，不共享一套不真实的 API | 待实现 |
| `BoneRemoteSyncICloud` | iCloud Drive 本地协调器 + 未下载文件触发 | 待实现 |
| `BoneRemoteSyncEngine` | 双向同步、冲突策略、状态库 | 待实现 |

## 设计约定

1. **能力先声明后使用。** UI 和同步引擎依据 `RemoteCapabilities` 决定展示与规划，不靠 try-catch 兜底。
2. **读写与复制在协议层分开。** 只读来源遵循 `RemoteSource`，可写来源遵循 `RemoteWritableSource`，支持来源内复制的再遵循 `RemoteCopyingSource`。能力位必须与可调用接口一致。
3. **路径统一归一化。** 对外一律 POSIX 风格、以 `/` 开头；SMB 的反斜杠、WebDAV 的编码、云盘的 fileId 全部收敛在适配器内部。
4. **错误统一归类。** 底层错误翻译为 `RemoteSyncError`；凭据问题归为 `.authenticationFailed`，路径使用来源规范化路径（本地传输文件错误保留实际文件路径字符串）；自动重试使用 WebDAV 适配器内部的精确白名单，不把公共 `isRetryable` 视为自动重试授权。
5. **下载原子落盘。** 普通下载先写 `<目标>.part`，校验长度后原子替换；失败保留 `.part` 供手动续传，按适配器规则校验版本。WebDAV 手动续传要求调用方保存与 part 对应的强 ETag；显式 managed 恢复另使用 `<目标>.part.checkpoint.json` 保存已提交前缀。
   OneDrive v1 例外：不支持续传，使用同目录随机 staging，失败清理本次 staging，不触碰既有 `.part` 或 WebDAV checkpoint。
6. **凭据不落日志。** 适配器只接收 `RemoteCredential`，持久化由调用方走 Keychain。

## 当前本地来源能力

| 操作 | 语义与限制 |
| --- | --- |
| 列目录、stat、walk | 目录优先排序，可包含隐藏文件；原 stream 式 walk 是顺序遍历，新 visitor 式 walk 可配置有界并发；本地 list 一次返回全部，不实现分页，但仍校验 `limit` 为正数并拒绝非空 `cursor` |
| 下载 | `.part` 写入、字节数校验、续传、可选 etag 复验、进度与取消 |
| 上传 | 仅普通文件，支持空文件；自动创建父目录；默认覆盖普通文件；不覆盖目录或 symlink；同目录随机 staging，完成后原子安装 |
| 上传取消/失败 | 清理本次 staging，保留原目标；已自动创建的空父目录可能保留；**不支持上传续传** |
| 新建目录 | 递归且幂等，文件同名时报冲突 |
| 删除 | 文件或非空目录，目录递归删除；禁止删除来源根及指向根的 symlink 别名 |
| 移动、复制 | 文件和目录均支持；不覆盖已有目标；目标父目录必须已存在；拒绝目录移入/复制到自身子目录 |
| 变更流、内容哈希、调度 | 未实现；size+mtime 仅是元数据指纹，不是内容校验哈希；并发数是建议值，不代表已有调度器 |

移动/复制在开始前检查取消，不承诺在 Foundation 的整目录操作中途抢占或回滚。复制目录保留其中的符号链接本身，不读取链接的外部目标；通过来源 API 直接访问外跳链接仍会被拒绝。

### 路径与权限边界

- 写操作检查规范路径、根目录保护与父目录符号链接，包括目标文件尚不存在的情况；悬空/循环链接及含 NUL 的非法路径保守拒绝。
- 这是应用层路径边界检查，**不是安全 sandbox**，不保证抵抗其他进程在检查与执行之间恶意替换目录（TOCTOU）。调用方应使用自己控制的根目录。
- iOS/macOS sandbox、security-scoped URL 的授权生命周期由调用方管理；目前不封装 bookmark、Keychain 或 iCloud 文件协调。
- 所有测试仅使用各自创建的临时目录，不会删除或改写用户真实文件。

## 使用

```swift
import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

let source = LocalFileSource(root: URL(fileURLWithPath: "/path/to/dir"))
try await source.connect(.anonymous)

let page = try await source.list(path: "/")
for entry in page.entries {
    print(entry.name, entry.size ?? 0)
}

// 递归遍历
for try await entry in source.walk(path: "/") where !entry.isDirectory {
    print(entry.path ?? entry.id)
}

// 下载（支持断点续传）
let entry = try await source.stat(path: "/a.txt")
try await source.download(
    entry,
    to: URL(fileURLWithPath: "/tmp/a.txt"),
    options: RemoteDownloadOptions(expectedETag: entry.etag)
)

// 上传一个本地普通文件。overwrite=false 可以避免覆盖同名文件。
let uploaded = try await source.upload(
    from: URL(fileURLWithPath: "/tmp/input.txt"),
    to: "/documents/input.txt",
    options: RemoteUploadOptions(overwrite: false)
)

try await source.makeDirectory(path: "/archive")
try await source.copy(from: uploaded.path ?? "/" + uploaded.id, to: "/archive/copy.txt")
try await source.move(from: "/archive/copy.txt", to: "/archive/renamed.txt")
// remove(path:) 可递归删除目录；应在用户确认后由 App 调用。
await source.disconnect()
```

进度回调为同步 `@Sendable` 回调，不保证运行在主线程；UI 更新应切换到 `MainActor`。`RemoteUploadOptions.contentType` 在本地来源不写入文件 MIME 元数据，返回的 contentType 根据扩展名推导。

## WebDAV 使用

```swift
import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

// 必须是最终 collection URL；根路径会限制为此 URL 下的内容。
let dav = try WebDAVSource(
    baseURL: URL(string: "https://nas.example.com/dav/documents/")!
)
try await dav.connect(.basic(username: "alice", password: "从 Keychain 获取"))
// 无认证服务可使用 .anonymous；不支持 Digest、NTLM 或 OAuth。
let page = try await dav.list(path: "/")
let entry = try await dav.stat(path: "/资料/report.pdf")
let destination = FileManager.default.temporaryDirectory.appendingPathComponent("report.pdf")
let downloaded = try await dav.download(
    entry, to: destination,
    options: .init(progress: { written in print("已写入字节：", written) })
)
print(page.entries.count, downloaded.size ?? 0)
await dav.disconnect()
```

### WebDAV 能力与安全前提

- **读写与复制。** 遵循 `RemoteCopyingSource`（包含 `RemoteWritableSource` / `RemoteSource`），上传、建目录、删除、移动、复制能力为 true；上传续传、变更流、内容哈希仍为 false。能力位表示适配器实现，并非服务端支持或账号写权限探测；权限不足/方法不支持时仍会报错。旧 `walk(path:includeHidden:)` 是顺序目录遍历；新 visitor 式 `walk` 支持有界并发。两者都不是媒体播放或文件内容流 API。
- **连接验证。** `connect` 使用根目录 Depth:0 PROPFIND 验证 collection；每次连接独立 ephemeral URLSession 池，活动响应独占串行 delegate 队列，最多保留4个空闲会话以复用连接；断开/重连取消旧请求，旧下载不能安装本地文件；旧写流程不能借用新连接继续发送，已发出的远端写入仍可能完成。连接失败保持未连接。
- **路径。** 来源内 `/` 对应 `baseURL`；逐段编码中文、空格、`#`、`?`、`%`。只接受同源、根内的安全 href，拒绝编码斜杠/点段、NUL、反斜杠、query、fragment。不会拿服务端 href 直接发请求。
- **认证与网络。** 默认系统 TLS 校验，不放行自签名，不自动读取系统凭据或保存密码；禁止自动跟随全部 3xx，请提供最终 URL。支持 HTTP 以适配本地网络，但 **HTTP Basic 只是 Base64，不能保护密码，请优先 HTTPS**。App 的 ATS、网络/局域网权限和证书配置由调用方管理，SDK 不修改系统安全设置。
- **目录。** Depth:1 排除自身、非直接子项和失败属性，默认过滤点开头隐藏项，目录优先排序。没有通用分页：`limit` 允许为 nil 或正数但只作为统一请求提示、不会截断结果；非法 `limit` 与非 nil `cursor` 均明确拒绝，`nextCursor=nil`。对文件调用 list 抛 `.unsupported(operation: "列出非目录条目")`。XML 限 16MiB、32 层和最多 100,000 条响应；仅支持 UTF-8 DAV XML，拒绝 DTD/实体声明。按 Data 块接收，在来源 actor 外聚合/解析；一次 XML 解析独占并复用一组日期解析器，无全局共享可变 formatter。超限需拆分目录，不会伪造下一页。
- **下载。** URLSession delegate 按 Data 块接收，来源 actor 外按 64KiB 写入 `<目标>.part`，完成后同步并原子安装；不主动把整文件放入内存。应用层接收队列最多256KiB，按64KiB交付，慢消费者对独占回调队列施加背压并暂停任务；URLSession/系统内部缓存、在途回调 Data 及写入缓冲不计入该队列上限，因此它不是进程总内存上限。断开会唤醒阻塞的回调。空文件、进度、取消和非覆盖安装均有测试。状态/ETag/Range 头验证失败不会改写原 part；传输中失败或取消保留已写 part，旧目标不变。失败前自动创建的父目录可能保留。
- **校验。** 默认校验响应及条目大小；HTTP Content-Length/Range 的传输完整性始终校验。ETag 是不透明版本标识，不保证是内容哈希。没有大小/哈希的服务无法证明文件内容完整，可信 TLS 与服务端语义仍是前提。
- **本地目的路径。** 目标及 part 必须是普通文件；拒绝最终 symlink、目录，以及多硬链接 part，避免清空其他文件。父目录可以是调用方授权的链接。单个 `WebDAVSource` 同时预留目标、`.part` 与 `.part.checkpoint.json`，拒绝三者重叠的并发下载目标，并保守折叠 Unicode/大小写/字符宽度等价路径；这可能在大小写敏感卷误拒绝部分并发。**调用方必须跨来源实例与进程协调目标、part 及 checkpoint 的独占使用**，不得让外部进程同时改写。不是系统级 sandbox，不抵抗恶意父目录替换 TOCTOU。
- **限流。** 429 映射为 `.rateLimited`；`Retry-After` 仅接受非负整数秒或 HTTP 日期，超过一年/非法输入视为无可用间隔，不会因非有限值导致显示崩溃。
- **非后台传输。** `timeout` 是请求超时（默认 60 秒），资源总超时至少 24 小时；显式 retry policy 可另外设置总 deadline，默认 `.none` 不增加总 deadline 或重试。没有后台 session、限速或全局并发调度器。`maxConcurrentTransfers` 只是建议值，实际并行度由调用方控制。

### WebDAV 写操作

```swift
// 先显式建父目录；上传、移动和复制不会自动补建父目录。
try await dav.makeDirectory(path: "/归档/2026")
let uploaded = try await dav.upload(
    from: localFileURL,
    to: "/归档/2026/report.txt",
    options: .init(overwrite: false, contentType: "text/plain", progress: { sent in
        print("已发送字节：", sent)
    })
)
try await dav.copy(from: uploaded.path!, to: "/归档/2026/copy.txt")
try await dav.move(from: "/归档/2026/copy.txt", to: "/归档/2026/final.txt")
// 仅在调用方确认要删除此资源后调用；目录会递归删除。
try await dav.remove(path: "/归档/2026/final.txt")
```

`localFileURL` 由宿主提供；以上片段在已连接的 `dav` 上执行。成功和失败路径均应 `await disconnect()`，可编译完整生命周期示例见 [Examples/WebDAVReadWrite](Examples/WebDAVReadWrite/README.md)。

| 操作 | 行为与限制 |
| --- | --- |
| 上传 | 完整 PUT，支持空文件、中文/特殊字符路径与 MIME 类型；只接受本地普通文件，拒绝目录、最终 symlink、FIFO 与非法头字段。父目录须已存在。无 SDK 固定大小上限，但受本地空间、服务端限制与超时约束；无上传续传。 |
| 上传源 | 以 64KiB 块复制到私有 0700 临时目录中的 0600 快照，再通过文件式 URLSession upload task 发送；内存不随整个文件大小增长，但需约一个源文件大小的临时磁盘空间。正常退出清理快照，进程被杀可能留下系统临时文件；不提供自动垃圾回收。源在快照期间不可被外部修改，身份/大小/mtime/ctime 复验不是恶意 TOCTOU sandbox。 |
| 非覆盖 | `overwrite=false` 使用服务端 `If-None-Match: *`，同名资源或并发创建返回冲突；不依赖客户端先查后写。 |
| 覆盖 | `overwrite=true` 预检目标类型。已存在普通文件必须提供强 ETag，PUT 发送 `If-Match`；若目标不存在则发送 `If-None-Match: *`。目录不可被文件覆盖。弱/缺失 ETag 的已有文件返回 `.unsupported`，不会降级为不安全覆盖。并发版本变化返回冲突。 |
| 上传结果与进度 | 返回 PUT 确认的路径、快照大小及响应 ETag/Last-Modified（可能为 nil），不再补一次可能失败或读到他人版本的 stat。不是下载回读/内容哈希验证。progress 从 0 开始，后续来自 URLSession 发送进度，不表示持久化完成；同步、非主线程回调，不可长期阻塞。 |
| 建目录 | 逐级 MKCOL，已有目录成功、同名文件冲突；根目录为空操作。中途失败已建父目录保留。 |
| 删除 | DELETE 文件或整棵非空目录，根目录受保护，不存在返回 notFound；不做客户端逐项删后重试。 |
| 移动/重命名、复制 | MOVE / COPY 同来源文件或目录，`Destination` 仅由受约束根 URL 与编码路径生成，`Overwrite: F` 禁止覆盖，COPY 使用 `Depth: infinity`。父目录须已存在，拒绝根、自身及子路径目标。 |
| 错误 | 401/407 认证、403 权限、409/412/423 冲突、429 限流；写请求 405/501 为不支持。207 不当成功，返回说明可能部分完成的错误；不自动跟随重定向或发送锁 token。 |

**远端写入不是事务。** 服务器开始接收 PUT 后原文件可能已改变；取消、超时、断开、丢失响应、207 或响应读取失败都不证明写入未发生，库不回滚、不补偿删除，也不承诺“失败保留旧远端目标”。请重新查询远端状态后决定下一步，不要仅凭 `RemoteSyncError.isRetryable` 重放写操作。`retryPolicy.totalTimeout` 覆盖单次写调用的快照、预检及请求；重试次数只用于其中的只读预检。多个实例/进程间的写入协调、服务器路径别名与权限配置由调用方管理。

不实现通用 WebDAV 上传续传、锁管理（LOCK/UNLOCK）、自定义属性写入（PROPPATCH）、ACL、版本管理或同步引擎。受锁保护的资源返回冲突；这里的“完整文件管理”指现有 Core 协议的全部读写/复制操作，而不是所有 WebDAV 扩展标准。

### 有界并发目录遍历

旧 `walk(path:includeHidden:)` 保持兼容。需要并发与消费背压时使用新的 async visitor API：

```swift
let summary = try await dav.walk(
    path: "/",
    options: RemoteWalkOptions(
        maxConcurrentRequests: 4, maxDepth: 64,
        maxEntries: 100_000, includeHidden: false
    )
) { entry in
    // 这里可 await 数据库存储或 UI 更新。visitor 不会并发执行。
    print(entry.path ?? entry.id)
}
print(summary.entryCount, summary.directoryCount)
```

- 并发合法范围1...16，默认4；并发3/4是建议起点，不保证适合每个服务。仅此遍历入口实际限制 list 并发，不是全局传输调度器。
- 起始目录深度0；目录计数包含起始目录。visitor 顺序 await，消费一页期间不补充请求，已有至多N个请求仍可完成；跨目录结果顺序不保证。
- 页面进入结果缓冲前共享预留整页发现预算，重复路径、非直接孩子、自身、缺失路径、cursor循环和上限均抛错，不静默返回截断成功。来源错误/visitor错误会取消并等待请求收敛。
- 默认深度64、条目100000；条目限制不是字节上限，不能阻止适配器预先物化超大单页。持续不同 cursor 的空页仍可继续，调用方应提供deadline/取消；WebDAV 本身不分页。
- visitor可能在最终失败前已产生部分副作用，本调用不是事务；list/visitor必须协作响应取消。只有ObjectID但没有路径的来源不适用此入口。

### 第一阶段性能测量

使用独立 Release runner 和仅监听 localhost 的合成服务，比较优化前快照与当前代码；每场景至少3次取中位数，下载额外 warmup 不计入。校验32MiB payload的SHA-256、2000项元数据及30目录/30文件的路径和请求数。原始数据、命令、源码SHA与墙钟/CPU/进程累计peakRSS保存在会话工作台的 `verification/webdav-performance`；可复跑脚本位于 `benchmarks/webdav-performance/run.py`。

这些测量不是飞牛公网链路吞吐承诺。原顺序walk仍受网络往返主导；只有切换新visitor入口才启用并发。该性能阶段没有改变原始强 ETag / part 配对要求。后续可恢复传输 v1 增加了下文的重试与 checkpoint；目录缓存、多连接分片下载仍未实现。

### 手动 WebDAV 续传（保持兼容）

此入口必须由调用方把 **该 part 对应的强 ETag** 与任务状态一起保存，再传入 `resumeFrom` 和 `expectedETag`。普通 `download` 不创建续传 sidecar，也不检验 part 已有内容的哈希；不能将其他文件的 part 或 ETag 配对使用。需要 SDK 管理 checkpoint、验证前缀及自动恢复体传输失败时，使用下文的 `downloadResumable`，不要让两种入口交替接管同一个 part。

```swift
// 假设这是上次失败下载保存的任务状态，而不是重新 stat 后随意换的新 ETag。
let savedETag = "\"server-version-123\""
let part = destination.appendingPathExtension("part")
let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
let offset = (attributes[.size] as! NSNumber).int64Value
try await dav.connect(.basic(username: "alice", password: "从 Keychain 获取"))
let currentEntry = try await dav.stat(path: "/资料/report.pdf")
_ = try await dav.download(
    currentEntry, to: destination,
    options: .init(resumeFrom: offset, expectedETag: savedETag)
)
await dav.disconnect()
```

只有 `offset > 0` 才发送 `Range: bytes=<offset>-`，part 的长度必须精确相等；同时发送 `If-Match`。弱 ETag（`W/`）或无强 ETag 不允许续传，也不能用作 `expectedETag`。服务端必须返回相同强 ETag、206 和正确的 `Content-Range`/长度；忽略 Range 返回 200、版本变化、416 等均失败，不会静默从头覆盖或追加。未提供强 ETag 的服务仍可从头下载，不承诺续传。`rangedDownload=true` 表示适配器实现了条件 Range 路径，不代表所有服务器都接受 Range。

### 显式启用有限重试

```swift
let dav = try WebDAVSource(
    baseURL: URL(string: "https://nas.example.com/dav/documents/")!,
    timeout: 60,
    retryPolicy: .standard
)
```

- 默认 `.none`：只尝试一次，不添加总 deadline。`.standard`：总尝试最多 3 次、初始退避 0.5 秒、退避上限 8 秒、总 deadline 120 秒；退避带 0.5...1 倍 jitter。`maxAttempts` 包含首次，不是额外次数。
- 仅重试只读 PROPFIND / GET（含写流程的只读预检），从不自动重试 PUT / MKCOL / DELETE / MOVE / COPY：HTTP **408、429、500、502、503、504**，以及原始 `URLError` 的 `timedOut`、`networkConnectionLost`、`notConnectedToInternet`、`cannotConnectToHost`、`dnsLookupFailed`。取消、认证/权限、TLS/证书、重定向、XML、ETag/Range/完整性及本地文件错误不重试；不依赖公共 `isRetryable` 提示或错误字符串。
- 有效 `Retry-After` 是等待下限，不压缩到 `maxDelay`；超过剩余 deadline 时停止并返回最后错误。单个恢复调用先进行最多 N 次 stat 预检，再进行最多 N 次 GET / Range，共用一个 deadline，最多 2N 个请求，不含之前单独调用的 `connect`。同一恢复调用内 GET 重试不会再次 stat 或换用新版本。
- 普通 `download` 仅重试**尚未开始打开/截断 part** 的失败。体传输或磁盘修改开始后仍保留原有手动恢复语义，不自动重启。自动恢复体传输失败只在 managed 入口执行。
- `maxAttempts` 必须为 1...8；延时有限且 `0 <= initialDelay <= maxDelay <= 300` 秒；`totalTimeout` 若非 nil 必须在 `(0, 86400]` 秒，多次尝试要求提供总 deadline。非法策略在 source 初始化时拒绝。
- deadline 使用单调时钟；取消和 session 关闭会唤醒网络及退避等待，并收敛操作子任务。同步磁盘 IO、XML 解析和用户阻塞回调无法被强制抢占，返回后仍复查 deadline；这不是硬实时超时。最终安装前重新检查 generation、取消、deadline 和文件身份。

### Managed checkpoint 与进程重启恢复

```swift
// accountID 由 App 为逻辑账号持久保存，例如账号记录中的 UUID；不要每次下载重新生成。
let accountID = "account-uuid-stored-by-app"
try await dav.connect(.basic(username: "alice", password: "从 Keychain 获取"))
let downloaded = try await dav.downloadResumable(
    path: "/资料/report.pdf",
    to: destination,
    options: .init(
        sourceNamespace: accountID,
        checkpointIntervalBytes: 8 * 1024 * 1024,
        overwrite: true,
        progress: { written in print("当前已写入：", written) }
    )
)
await dav.disconnect()
// App / 进程重启后：用同一来源根、账号 namespace、远端路径和目标路径再次调用即可。
// .none 也能在下一次显式调用中恢复，只是不在本次调用内自动重试网络失败。
```

- 只适用于**强 ETag + 已知非负总大小**的普通文件，恢复模式始终验证大小；每个 GET 都以原强 ETag 发送 `If-Match`，offset > 0 时另加 Range。版本变化、忽略 Range、错误范围、416、压缩传输或不完整 EOF 都不当作完成；不会把两个版本拼起来。
- `sourceNamespace` 为调用方分配、跨进程稳定的不透明账号 ID，1...256 UTF-8 字节、不得有 NUL；不同账号必须使用不同 ID，不放入密码、token 或 Authorization。它防止意外跨账号复用，不认证账号身份。根 URL、远端路径和目标路径也参与绑定，位置变化不会自动迁移 checkpoint。
- 文件命名为 `<目标>.part` 和 `<目标>.part.checkpoint.json`。新 part、checkpoint 临时文件使用 `0600`；checkpoint 最多 64KiB，保存绑定 SHA256、强 ETag、预期总大小、已提交偏移、前缀 SHA256、part dev/inode 和有限 metadata，不保存密码或原 URL。**摘要不是加密或 HMAC；ETag、大小、metadata 仍可能敏感。** 调用方必须控制其目录权限。
- 每次提交先同步 part，再同步并原子替换 sidecar；恢复在同一文件描述符上以 64KiB 分块验证已提交前缀，再回滚未提交尾部。间隔默认 8MiB，合法范围 64KiB...256MiB；间隔越小，重传损失通常越小，但同步和 checkpoint 写入越频繁。已有前缀需要重算 SHA256，可能读取两次；恢复模式增加 hash、文件同步和 stat 成本，不保证比普通下载更快。
- progress 表示当前**写入**字节，不是已提交字节；取消、崩溃或自动重试后可退回最近检查点，不承诺跨重试单调。进度回调同步执行且不保证主线程，阻塞回调会延迟取消/超时返回。
- 未知旧 part、缺一配对、schema/摘要/身份/账号/路径/版本错配、符号链接、目录、FIFO 或多硬链接会保守拒绝，不自动 adopt、覆盖或删除。首次 part 创建至初始 checkpoint 的极小窗口终止也可能留下 orphan。发生 conflict 时，由调用方确认归属后显式管理/清理；SDK 不提供自动垃圾回收、配额或跨进程锁。
- `readyToInstall` 记录支持安装前恢复；rename 已完成但清理 sidecar 失败时，以目标 dev/inode/大小/hash 与远端版本确认上次安装并幂等返回。rename 成功即逻辑成功，不因后续清理失败返回假失败。完整长度但没有 ready / 已确认 EOF 的 part 不直接安装，而是条件 GET 从零重下。
- 普通下载仍可使用原手动 part；**不得混用普通与 managed 入口接管同一组持久化文件**。单 source 三路径锁只解决活动调用间冲突，不能代替跨实例/跨进程独占。TOCTOU、恶意同时改写、硬件断电或目录 rename 的断电持久性不在保证内。

恢复验收只使用 `127.0.0.1` 合成服务：故障矩阵、取消/关闭/deadline、摘要与安全 IO、独立 PID 的取消后重启与 SIGKILL，以及 ready / rename 窗口。复跑工具和原始证据位于会话工作台 `diagnostics/recovery-check` 与 `verification/webdav-recovery`。没有真实 NAS 断网、大文件公网性能、移动设备运行或断电验收；没有后台传输、自动同步、缓存或多连接分片。新增写操作的验收与恢复下载验收分别记录，不能将只读 NAS 验收扩展为写入验收。

## 实现顺序

1. ✅ 契约 + 本地读写来源（列目录、下载续传、上传、目录管理与取消）
2. ✅ WebDAV 文件读写适配器（浏览、下载及条件续传、上传、建目录、删除、移动、复制；真实 NAS 写入待验收）
3. SMB 适配器 + mDNS 发现（覆盖局域网 NAS 与飞牛）
4. 同步引擎：快照、diff、单向下载、断点与重试
5. 双向同步 + 冲突策略 + 状态库
6. 🔶 厂商网盘 OpenAPI：OneDrive/Graph 主盘读写 v1 已落地（真实账号验收待完成）；其余厂商待实现
7. iCloud Drive、DLNA 媒体源（独立类型，不混入文件系统模型）

## 构建与测试

```bash
swift build
swift test
```

平台要求：iOS 15+ / macOS 12+ / tvOS 15+ / visionOS 1+，Swift 6 语言模式。仅支持已声明的 Apple 平台；文件安全实现使用 Darwin API，不提供 Linux 支持。无第三方运行依赖；包提供 Core、Local、WebDAV、OneDrive 四个 library product，没有同名总入口模块。

WebDAV 与 OneDrive HTTP 集成测试仅在 macOS 运行，需要 `/usr/bin/python3`（Python 3.8+，标准库，无额外安装包）。fixture 仅监听 `127.0.0.1` 的动态端口，仅读取内置测试数据、记录虚构测试凭据和使用自建临时目录；生产模块不依赖 Python。

历史只读/恢复验证使用 Swift 6.2 / Xcode 26.0。2026-10-25 写能力验证使用 Swift 6.4 / Xcode 27.1、Swift 6 语言模式：全包 222 项测试通过（34 XCTest + 188 Swift Testing），Release 构建及读写示例类型检查通过；Core/WebDAV 按 macOS 12、iOS 15、tvOS 15、visionOS 1 下限完成 arm64 模块编译，其中后三者使用 Simulator SDK。新增 15 项 WebDAV 写测试包含参数化故障场景。编译不等于模拟器/真机或旧系统运行验证，也未用 Swift 6.0 编译器重测。

## OneDrive Personal 主盘 v1（读 + 写）

SwiftPM 依赖添加 `.product(name: "BoneRemoteSyncOneDrive", package: "BoneRemoteSyncKit")`，然后 `import BoneRemoteSyncOneDrive`。

```swift
let config = try OneDriveConfiguration(
    clientID: "<你的公开 Application client ID>",
    redirectURI: URL(string: "your-app://oauth/onedrive")!
)
let oauth = OneDriveOAuth(configuration: config)
let transaction = try oauth.authorize()
// 宿主用系统授权 UI 打开 transaction.url；不得打印这个 URL。
// 收到回调后先在宿主内消费 transaction，保证同一事务只处理一次：
let code = try oauth.authorizationCode(from: callbackURL, transaction: transaction)
let token = try await oauth.exchange(code: code, transaction: transaction)
// 先将 token 安全保存到当前账号 Keychain，再连接。
let source = OneDriveSource(configuration: config, onTokenRefresh: { updated in
    try accountKeychain.save(updated) // 宿主同步、线程安全且账号隔离的实现
})
try await source.connect(token.credential)
let first = try await source.list(path: "/", request: .init(limit: 100))
if let cursor = first.nextCursor {
    let second = try await source.list(path: "/", request: .init(cursor: cursor, limit: 100))
    // 处理 second.entries，继续直到 nextCursor == nil。
}
if let file = first.entries.first(where: { !$0.isDirectory }) {
    _ = try await source.download(file, to: destinationURL, options: .init(overwrite: false))
}
await source.disconnect()
```

上例中的 `callbackURL`、`accountKeychain` 和 `destinationURL` 由宿主提供；不是库内全局对象。完整可编译接入片段及账号验收清单见 [Examples/OneDriveReadOnly](Examples/OneDriveReadOnly/README.md)。

### 范围和生命周期

- **只支持 Personal 主盘**，不包含组织/SharePoint、共享 `remoteItem`、package、已删除条目；遇到不支持的 facet 明确报错，不静默漏掉。
- SDK 提供授权 URL、严格 state/redirect/重复参数校验、PKCE S256、code 兑换和刷新；不包含授权 UI、Keychain、账号选择、回调注册、device code flow 或 app secret。
- 使用 `Files.ReadWrite offline_access`，`consumers` authority。写入能力（`upload`/`makeDirectory`/`remove`/`move`）要求写权限，`Files.Read` 会在真实账号上以 403 拒绝写操作；库固定申请写权限，只读宿主也会被要求同意“完全访问文件”。helper 无状态，宿主应一次性消费授权事务；原生 public client 不嵌入 secret。
- `onTokenRefresh` 是同步 throwing `@Sendable` 提交回调，必须原子保存到所属账号，不能回调 source 或长期阻塞。回调成功才发布新凭据；失败关闭连接且错误不包含宿主异常细节。省略时只更新内存，**不会持久化轮换 token**。
- 并发请求共享一个刷新。单个等待者取消时会等待该刷新收敛、提交当前账号已轮换的新凭据后才抛取消，可能等待至该HTTP请求timeout；disconnect会取消共享请求。一个请求取消不丢弃已轮换的新凭据；disconnect/reconnect 的 generation 隔离防止旧会话回写。刷新网络或认证失败均关闭该连接，避免重复使用可能已轮换的旧 refresh token。宿主决定重新授权/重连。
- API HTTP 401 最多刷新并重放一次；CDN 401/403 只在尚未打开 staging 时重新获取一次链接。不做429/5xx自动重试；429映射 `.rateLimited(retryAfter:)`，支持整数或HTTP-date。调用方不能因为 `isRetryable` 就盲目重试令牌兑换。
- `timeout` 为 URLSession 每次 HTTP 请求的时间预算，不是整个分页/授权/多阶段下载的共享绝对deadline。同步宿主回调/本地I/O不可强制抢占。

### 条目、分页与下载安全

- `RemoteEntry.id` 是 `driveID + itemID` 的不透明编码，`path` 只用于展示/路径定位，下载始终重新按 ID 查元数据。Graph eTag 仅用于元数据变化检查，不作为 CDN HTTP validator。
- list保留服务端顺序；默认不显示点号隐藏名称；`limit`必须为正数，发往Graph的页大小为`min(limit, 200)`，不保证每页恰好返回该数量；所有来源在发请求前拒绝非法 `limit`，不支持分页的来源拒绝非空 `cursor`。Core visitor walk的整次条目预算仍由Core独立检查。`RemoteListRequest.all` 不会自动读完所有Graph页面，调用方必须跟随 `nextCursor`。游标绑定当前连接、路径及选项，成功推进消费旧游标；最多256个待推进游标，满时淘汰最早的未推进游标，连接清空；被淘汰/已消费的游标明确报错，不影响新列表或保留游标继续推进。循环历史只保留URL的SHA256，单目录最多10000页；这不是整个App的内存硬上限。nextLink必须同源/同API版本/同一目录children资源，循环会报错。
- Graph固定 `https://graph.microsoft.com/v1.0/`，token端点固定微软consumers；JSON响应最多8MiB、token最多1MiB。默认系统TLS校验；不带系统Cookie或环境认证；不跟随自动重定向。
- 预授权downloadUrl只来自受认证Graph响应，不作为条目字段、稳定ID、游标或日志输出；CDN请求不带Graph bearer或Graph If-Match。仅允许HTTPS并拒绝userinfo、fragment及明显本地/私网literal地址；不限定微软CDN域名后缀。此检查不是完整SSRF/DNS rebinding防护，使用者仍须信任微软Graph及自身网络环境。
- **完整下载，无Range/续传**：`capabilities.rangedDownload == false`，任何非nil `resumeFrom`（包括0）都报不支持。拒绝206、非identity编码、Content-Range及长度异常；默认校验Graph大小，关闭verifySize也不允许超出Graph大小，并始终检查已声明HTTP长度。
- 下载前后查Graph元数据，发现eTag/大小变化不安装；这不是跨Graph/CDN的事务快照或内容哈希验证，`contentHash == false`，不存在可靠eTag时不能宣称版本强校验。
- 同目录随机0600 staging，独占创建、NOFOLLOW、分块写、fsync、身份及硬链接验证，最后原子rename；失败只清理本次staging，旧目标、旧`.part`及checkpoint不变。拒绝目标symlink、目录和多硬链接。父目录可能自动创建并在失败后保留。progress在串行HTTP delegate队列调用，必须线程安全且不长期阻塞；取消时一个已进入的progress回调可能仍在返回中，不是硬实时抢占。
- 同source内保守折叠大小写/宽度/Unicode目标别名并互斥；跨source/进程协调、恶意父目录TOCTOU、系统sandbox、后台传输、断电持久性、security-scoped bookmark均不在保证范围内。

### 写入能力与限制

`OneDriveSource` 同时遵循 `RemoteWritableSource`，能力位 `upload`/`makeDirectory`/`remove`/`move` 为 true，`resumableUpload`/`rangedDownload`/`copy` 为 false。

```swift
let staging = URL(fileURLWithPath: "/tmp/report.txt")
try await source.makeDirectory(path: "/归档/2026")
let uploaded = try await source.upload(
    from: staging,
    to: "/归档/2026/report.txt",
    options: .init(overwrite: false, contentType: "text/plain")
)
try await source.move(from: "/归档/2026/report.txt", to: "/归档/2026/final.txt")
try await source.remove(path: "/归档/2026/final.txt")
```

| 操作 | 语义与限制 |
| --- | --- |
| `upload` | Graph simple upload 单次 PUT，**上限 250MiB**，超出抛 `.unsupported`，不降级到 upload session。只接受普通文件，不能用文件覆盖根目录。 |
| 覆盖行为 | `RemoteUploadOptions.overwrite == true` 时发 `@microsoft.graph.conflictBehavior=replace`，否则发 `fail`；不在本地抢先判断，冲突由服务端结果决定。 |
| `makeDirectory` | 逐级递归创建，已存在目录视为成功，同名文件抛 `.conflict`；目标为根目录时直接返回。 |
| `remove` | 删除文件或整棵目录；拒绝删除根目录；不存在时按 Graph 结果映射错误。 |
| `move` | Graph PATCH 改名或移动，不覆盖已存在目标（服务端 `fail`），不实现服务端复制。 |
| 进度与取消 | `upload` 的 `progress` 来自 URLSession delegate 串行队列，必须线程安全且不长期阻塞；取消后已发出的请求可能仍到达服务端，库不做补偿删除。 |

写操作同样在返回前做 generation 检查，连接断开或重连后的旧会话结果不会回写；但不提供跨进程锁、事务语义或写入后自动校验（上传结果只校验 Graph 返回的 size/name/drive/path）。

### 官方接口依据

- [原生授权码与PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [注册应用](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
- [列出子项与分页](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0)
- [driveItem及预授权下载URL](https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0)
- [文件下载、短期URL与Range语义](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0)
