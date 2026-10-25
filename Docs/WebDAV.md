# WebDAV 接入与传输语义

[返回项目首页](../README.md) · [通用 API](API.md) · [读写示例](../Examples/WebDAVReadWrite/README.md)

`WebDAVSource` 支持 PROPFIND、GET、PUT、MKCOL、DELETE、MOVE、COPY，通过 `import BoneRemoteSyncKit` 使用。支持匿名和 Basic 认证；它是文件管理适配器，不是全部 WebDAV 扩展标准的实现。

## 连接与生命周期

将最终 collection URL 作为来源根。以下函数的凭据由宿主从安全存储取得，成功和失败都会等待断开：

```swift
import Foundation
import BoneRemoteSyncKit

func listWebDAVRoot(baseURL: URL, credential: RemoteCredential) async throws -> [RemoteEntry] {
    let dav = try WebDAVSource(baseURL: baseURL)
    do {
        try await dav.connect(credential)
        let page = try await dav.list(path: "/")
        await dav.disconnect()
        return page.entries
    } catch {
        await dav.disconnect()
        throw error
    }
}
```

下面的写入和恢复片段均在已连接的 `dav` 上执行。`localFileURL`、`destination` 由宿主提供；调用方在成功与异常路径统一断开，不要让独立 `Task` 代替等待清理。

## 能力与安全前提

### 能力、连接与认证

- **读写与复制。** 遵循 `RemoteCopyingSource`（包含 `RemoteWritableSource` / `RemoteSource`），上传、建目录、删除、移动、复制能力为 true；上传续传、变更流、内容哈希仍为 false。能力位表示适配器实现，并非服务端支持或账号写权限探测；权限不足/方法不支持时仍会报错。旧 `walk(path:includeHidden:)` 是顺序目录遍历；新 visitor 式 `walk` 支持有界并发。两者都不是媒体播放或文件内容流 API。
- **连接验证。** `connect` 使用根目录 Depth:0 PROPFIND 验证 collection；每次连接独立 ephemeral URLSession 池，活动响应独占串行 delegate 队列，最多保留4个空闲会话以复用连接；断开/重连取消旧请求，旧下载不能安装本地文件；旧写流程不能借用新连接继续发送，已发出的远端写入仍可能完成。连接失败保持未连接。
- **路径。** 来源内 `/` 对应 `baseURL`；逐段编码中文、空格、`#`、`?`、`%`。只接受同源、根内的安全 href，拒绝编码斜杠/点段、NUL、反斜杠、query、fragment。不会拿服务端 href 直接发请求。
- **认证与网络。** 默认系统 TLS 校验，不放行自签名，不自动读取系统凭据或保存密码；禁止自动跟随全部 3xx，请提供最终 URL。支持 HTTP 以适配本地网络，但 **HTTP Basic 只是 Base64，不能保护密码，请优先 HTTPS**。App 的 ATS、网络/局域网权限和证书配置由调用方管理，SDK 不修改系统安全设置。
### 浏览与下载

- **目录。** Depth:1 排除自身、非直接子项和失败属性，默认过滤点开头隐藏项，目录优先排序。没有通用分页：`limit` 允许为 nil 或正数但只作为统一请求提示、不会截断结果；非法 `limit` 与非 nil `cursor` 均明确拒绝，`nextCursor=nil`。对文件调用 list 抛 `.unsupported(operation: "列出非目录条目")`。XML 限 16 MiB、32 层和最多 100,000 条响应；仅支持 UTF-8 DAV XML，拒绝 DTD/实体声明。按 Data 块接收，在来源 actor 外聚合/解析；一次 XML 解析独占并复用一组日期解析器，无全局共享可变 formatter。超限需拆分目录，不会伪造下一页。
- **下载。** URLSession delegate 按 Data 块接收，来源 actor 外按 64 KiB 写入 `<目标>.part`，完成后同步并原子安装；不主动把整文件放入内存。应用层接收队列最多 256 KiB，按 64 KiB交付，慢消费者对独占回调队列施加背压并暂停任务；URLSession/系统内部缓存、在途回调 Data 及写入缓冲不计入该队列上限，因此它不是进程总内存上限。断开会唤醒阻塞的回调。空文件、进度、取消和非覆盖安装均有测试。状态/ETag/Range 头验证失败不会改写原 part；传输中失败或取消保留已写 part，旧目标不变。失败前自动创建的父目录可能保留。
- **校验。** 默认校验响应及条目大小；HTTP Content-Length/Range 的传输完整性始终校验。ETag 是不透明版本标识，不保证是内容哈希。没有大小/哈希的服务无法证明文件内容完整，可信 TLS 与服务端语义仍是前提。
### 本地目标与请求预算

- **本地目的路径。** 目标及 part 必须是普通文件；拒绝最终 symlink、目录，以及多硬链接 part，避免清空其他文件。父目录可以是调用方授权的链接。单个 `WebDAVSource` 同时预留目标、`.part` 与 `.part.checkpoint.json`，拒绝三者重叠的并发下载目标，并保守折叠 Unicode/大小写/字符宽度等价路径；这可能在大小写敏感卷误拒绝部分并发。**调用方必须跨来源实例与进程协调目标、part 及 checkpoint 的独占使用**，不得让外部进程同时改写。不是系统级 sandbox，不抵抗恶意父目录替换 TOCTOU。
- **限流。** 429 映射为 `.rateLimited`；`Retry-After` 仅接受非负整数秒或 HTTP 日期，超过一年/非法输入视为无可用间隔，不会因非有限值导致显示崩溃。
- **非后台传输。** `timeout` 是请求超时（默认 60 秒），资源总超时至少 24 小时；显式 retry policy 可另外设置总 deadline，默认 `.none` 不增加总 deadline 或重试。没有后台 session、限速或全局并发调度器。`maxConcurrentTransfers` 只是建议值，实际并行度由调用方控制。

## 写入与文件管理

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
try await dav.copy(from: "/归档/2026/report.txt", to: "/归档/2026/copy.txt")
try await dav.move(from: "/归档/2026/copy.txt", to: "/归档/2026/final.txt")
// 仅在调用方确认要删除此资源后调用；目录会递归删除。
try await dav.remove(path: "/归档/2026/final.txt")
print(uploaded.path ?? uploaded.id)
```

`localFileURL` 由宿主提供；以上片段在已连接的 `dav` 上执行。成功和失败路径均应 `await disconnect()`，可编译完整生命周期示例见 [Examples/WebDAVReadWrite](../Examples/WebDAVReadWrite/README.md)。

| 操作 | 行为与限制 |
| --- | --- |
| 上传 | 完整 PUT，支持空文件、中文/特殊字符路径与 MIME 类型；只接受本地普通文件，拒绝目录、最终 symlink、FIFO 与非法头字段。父目录须已存在。无 SDK 固定大小上限，但受本地空间、服务端限制与超时约束；无上传续传。 |
| 上传源 | 以 64 KiB 块复制到私有 0700 临时目录中的 0600 快照，再通过文件式 URLSession upload task 发送；内存不随整个文件大小增长，但需约一个源文件大小的临时磁盘空间。正常退出清理快照，进程被杀可能留下系统临时文件；不提供自动垃圾回收。源在快照期间不可被外部修改，身份/大小/mtime/ctime 复验不是恶意 TOCTOU sandbox。 |
| 非覆盖 | `overwrite=false` 使用服务端 `If-None-Match: *`，同名资源或并发创建返回冲突；不依赖客户端先查后写。 |
| 覆盖 | `overwrite=true` 预检目标类型。已存在普通文件必须提供强 ETag，PUT 发送 `If-Match`；若目标不存在则发送 `If-None-Match: *`。目录不可被文件覆盖。弱/缺失 ETag 的已有文件返回 `.unsupported`，不会降级为不安全覆盖。并发版本变化返回冲突。 |
| 上传结果与进度 | 返回 PUT 确认的路径、快照大小及响应 ETag/Last-Modified（可能为 nil），不再补一次可能失败或读到他人版本的 stat。不是下载回读/内容哈希验证。progress 从 0 开始，后续来自 URLSession 发送进度，不表示持久化完成；同步、非主线程回调，不可长期阻塞。 |
| 建目录 | 逐级 MKCOL，已有目录成功、同名文件冲突；根目录为空操作。中途失败已建父目录保留。 |
| 删除 | DELETE 文件或整棵非空目录，根目录受保护，不存在返回 notFound；不做客户端逐项删后重试。 |
| 移动/重命名、复制 | MOVE / COPY 同来源文件或目录，`Destination` 仅由受约束根 URL 与编码路径生成，`Overwrite: F` 禁止覆盖，COPY 使用 `Depth: infinity`。父目录须已存在，拒绝根、自身及子路径目标。 |
| 错误 | 401/407 认证、403 权限、409/412/423 冲突、429 限流；写请求 405/501 为不支持。207 不当成功，返回说明可能部分完成的错误；不自动跟随重定向或发送锁 token。 |

**远端写入不是事务。** 服务器开始接收 PUT 后原文件可能已改变；取消、超时、断开、丢失响应、207 或响应读取失败都不证明写入未发生，库不回滚、不补偿删除，也不承诺“失败保留旧远端目标”。请重新查询远端状态后决定下一步，不要仅凭 `RemoteSyncError.isRetryable` 重放写操作。`retryPolicy.totalTimeout` 覆盖单次写调用的快照、预检及请求；重试次数只用于其中的只读预检。多个实例/进程间的写入协调、服务器路径别名与权限配置由调用方管理。

不实现通用 WebDAV 上传续传、锁管理（LOCK/UNLOCK）、自定义属性写入（PROPPATCH）、ACL、版本管理或同步引擎。受锁保护的资源返回冲突；这里的“完整文件管理”指现有 Core 协议的全部读写/复制操作，而不是所有 WebDAV 扩展标准。

## 手动下载续传

此入口必须由调用方把 **该 part 对应的强 ETag** 与任务状态一起保存，再传入 `resumeFrom` 和 `expectedETag`。普通 `download` 不创建续传 sidecar，也不检验 part 已有内容的哈希；不能将其他文件的 part 或 ETag 配对使用。需要 SDK 管理 checkpoint、验证前缀及自动恢复体传输失败时，使用下文的 `downloadResumable`，不要让两种入口交替接管同一个 part。

```swift
// 假设这是上次失败下载保存的任务状态，而不是重新 stat 后随意换的新 ETag。
let savedETag = "\"server-version-123\""
let part = destination.appendingPathExtension("part")
let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
guard let fileSize = attributes[.size] as? NSNumber else {
    throw RemoteSyncError.unsupported(operation: "无法读取 part 文件大小")
}
let offset = fileSize.int64Value
let currentEntry = try await dav.stat(path: "/资料/report.pdf")
_ = try await dav.download(
    currentEntry, to: destination,
    options: .init(resumeFrom: offset, expectedETag: savedETag)
)
```

只有 `offset > 0` 才发送 `Range: bytes=<offset>-`，part 的长度必须精确相等；同时发送 `If-Match`。弱 ETag（`W/`）或无强 ETag 不允许续传，也不能用作 `expectedETag`。服务端必须返回相同强 ETag、206 和正确的 `Content-Range`/长度；忽略 Range 返回 200、版本变化、416 等均失败，不会静默从头覆盖或追加。未提供强 ETag 的服务仍可从头下载，不承诺续传。`rangedDownload=true` 表示适配器实现了条件 Range 路径，不代表所有服务器都接受 Range。

## 显式启用有限重试

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
- `maxAttempts` 必须为 1…8；延时有限且 `0 <= initialDelay <= maxDelay <= 300` 秒；`totalTimeout` 若非 nil 必须在 `(0, 86400]` 秒，多次尝试要求提供总 deadline。非法策略在 source 初始化时拒绝。
- deadline 使用单调时钟；取消和 session 关闭会唤醒网络及退避等待，并收敛操作子任务。同步磁盘 IO、XML 解析和用户阻塞回调无法被强制抢占，返回后仍复查 deadline；这不是硬实时超时。最终安装前重新检查 generation、取消、deadline 和文件身份。

## Managed checkpoint 与进程重启恢复

```swift
// accountID 由 App 为逻辑账号持久保存，例如账号记录中的 UUID；不要每次下载重新生成。
let accountID = "account-uuid-stored-by-app"
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
print(downloaded.size ?? 0)
// App / 进程重启后：用同一来源根、账号 namespace、远端路径和目标路径再次调用即可。
// .none 也能在下一次显式调用中恢复，只是不在本次调用内自动重试网络失败。
```

- 只适用于**强 ETag + 已知非负总大小**的普通文件，恢复模式始终验证大小；每个 GET 都以原强 ETag 发送 `If-Match`，offset > 0 时另加 Range。版本变化、忽略 Range、错误范围、416、压缩传输或不完整 EOF 都不当作完成；不会把两个版本拼起来。
- `sourceNamespace` 为调用方分配、跨进程稳定的不透明账号 ID，1...256 UTF-8 字节、不得有 NUL；不同账号必须使用不同 ID，不放入密码、token 或 Authorization。它防止意外跨账号复用，不认证账号身份。根 URL、远端路径和目标路径也参与绑定，位置变化不会自动迁移 checkpoint。
- 文件命名为 `<目标>.part` 和 `<目标>.part.checkpoint.json`。新 part、checkpoint 临时文件使用 `0600`；checkpoint 最多 64 KiB，保存绑定 SHA256、强 ETag、预期总大小、已提交偏移、前缀 SHA256、part dev/inode 和有限 metadata，不保存密码或原 URL。**摘要不是加密或 HMAC；ETag、大小、metadata 仍可能敏感。** 调用方必须控制其目录权限。
- 每次提交先同步 part，再同步并原子替换 sidecar；恢复在同一文件描述符上以 64 KiB 分块验证已提交前缀，再回滚未提交尾部。间隔默认 8 MiB，合法范围 64 KiB…256 MiB；间隔越小，重传损失通常越小，但同步和 checkpoint 写入越频繁。已有前缀需要重算 SHA256，可能读取两次；恢复模式增加 hash、文件同步和 stat 成本，不保证比普通下载更快。
- progress 表示当前**写入**字节，不是已提交字节；取消、崩溃或自动重试后可退回最近检查点，不承诺跨重试单调。进度回调同步执行且不保证主线程，阻塞回调会延迟取消/超时返回。
- 未知旧 part、缺一配对、schema/摘要/身份/账号/路径/版本错配、符号链接、目录、FIFO 或多硬链接会保守拒绝，不自动 adopt、覆盖或删除。首次 part 创建至初始 checkpoint 的极小窗口终止也可能留下 orphan。发生 conflict 时，由调用方确认归属后显式管理/清理；SDK 不提供自动垃圾回收、配额或跨进程锁。
- `readyToInstall` 记录支持安装前恢复；rename 已完成但清理 sidecar 失败时，以目标 dev/inode/大小/hash 与远端版本确认上次安装并幂等返回。rename 成功即逻辑成功，不因后续清理失败返回假失败。完整长度但没有 ready / 已确认 EOF 的 part 不直接安装，而是条件 GET 从零重下。
- 普通下载仍可使用原手动 part；**不得混用普通与 managed 入口接管同一组持久化文件**。单 source 三路径锁只解决活动调用间冲突，不能代替跨实例/跨进程独占。TOCTOU、恶意同时改写、硬件断电或目录 rename 的断电持久性不在保证内。

恢复能力的测试范围和未验收事项见[验证状态](Validation.md)。本仓库不承诺真实 NAS 断网、公网吞吐、移动设备或断电恢复行为。
