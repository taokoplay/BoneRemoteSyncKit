# 通用文件物化、前台调度与恢复传输

[首页](../README.md) · [通用 API](API.md) · [验证记录](Validation.md)

> 本页描述**未发布开发版本**的 Transfer API，不包含在 `v0.3.0` 标签中；截至 2026-10-28（GMT+8），本地 Git 提交尚未推送。它是通用文件能力，不解析文件格式，也不是自动同步引擎。

## 一个 Kit，内部按职责分层

宿主只需依赖 `BoneRemoteSyncKit` 产品并 `import BoneRemoteSyncKit`。新增 `BoneRemoteSyncTransfer` target 依赖 Core，不依赖 Catalog、SQLite 或具体来源。Kit 重新导出所有模块，不复制公共类型。

- **Core**：来源协议、条目、绑定引用、版本强度、条件读写值类型、任务状态。
- **Providers**：Local、iCloud、WebDAV、OneDrive 各自实现会话、路径、网络/文件协调及底层下载。
- **Transfer**：本地文件物化、受管理 staging、校验、原子发布、lease、前台任务调度，以及独立的显式恢复下载/上传入口。
- **Catalog**：来源配置与远端目录元数据索引；不存正文，不因查询或刷新而下载。

来源连接、账号授权、entitlement、安全作用域和文件访问授权仍由宿主负责。Transfer 不自动 connect/disconnect，不迁移账号或根目录绑定。

## 基本使用

以下示例可以放入仅依赖 Kit 的消费端。`connectedSource` 必须已连接且在整个调用期间不切换账号/根；`cacheDirectory` 必须是宿主拥有的私有本地目录，不能位于同步盘或来源根内。

```swift
import Foundation
import BoneRemoteSyncKit

func consumeFile(
    connectedSource: any RemoteSource,
    bindingID: String,
    path: String,
    cacheDirectory: URL,
    consume: @Sendable (URL) async throws -> Void
) async throws {
    let binding = RemoteSourceBinding(kind: connectedSource.kind, identity: bindingID)
    let materializer = RemoteFileMaterializer(
        source: connectedSource,
        sourceBinding: binding,
        cacheDirectory: cacheDirectory
    )
    let coordinator = RemoteTransferCoordinator(
        materializer: materializer,
        maxConcurrentTransfers: 2
    )
    do {
        let reference = RemoteFileReference(source: binding, path: path)
        let id = await coordinator.submit(RemoteTransferRequest(reference: reference))
        let lease = try await coordinator.wait(for: id)
        try await lease.withAccess { url in try await consume(url) }
        await coordinator.shutdown()
        await materializer.shutdown()
    } catch {
        await coordinator.shutdown()
        await materializer.shutdown()
        throw error
    }
}
```

长生命周期宿主应复用 materializer/coordinator，而不是每个文件都重新构建。也可以直接 `materializer.materialize(reference)`；直接调用不经过 coordinator 的任务上限，但同一 materializer 的普通下载与分片读取仍共享来源 I/O 上限（不含 stat）。

## 引用、绑定与版本

`RemoteFileReference` 由 `RemoteSourceBinding` 和 `RemoteLocator` 组成。路径在引用构造和解码时归一化；`.itemID` 只交给遵循 `RemoteIDAddressableSource` 的来源。不能把路径伪装为 ID，也不能跨账号/盘/配置根复用一个 binding。

`binding.identity` 是宿主提供的**非秘密、不透明会话/配置标识**，不是 token、签名 URL 或 cookie。SDK 比较绑定但不能从标识推导真实账号。重连到不同账号或根时必须创建新 binding 和 materializer，不能复用旧缓存实例。不要并发改变来源会话。

`RemoteVersion` 同时绑定来源与 locator；value 不是内容摘要。三种强度分别是：

- `strongConditional`：来源明确支持条件读取。普通路径通过可选 `RemoteConditionalDownloadSource`；显式分片策略可使用 `RemoteByteRangeSource` 的强版本，不通过 `.webdav` 名称猜测。
- `metadataFingerprint`：ETag 或 size+mtime 的启发式变化检测，不能保证字节内容锁定。
- `observedOnly`：仅观察到值，不具备可靠条件保证。

默认 `.latestObserved` 在下载前观察元数据，下载后再核对 ID 和版本观察。不是远端原子快照；即使元数据相同也不能证明字节完全相同。缺少可用版本或只有弱 ETag 且无 size+mtime 时，不复用或合并。

`.requireVersion(version)` 当前只接受可执行的 `strongConditional`；来源不支持、弱版本或绑定/locator 不匹配时在读取来源或创建缓存之前拒绝。WebDAV 实现将强 ETag 传给原有 `If-Match` 下载。值不匹配时抛 conflict，不静默降级。Local/iCloud 的启发式指纹和 OneDrive 普通元数据并未被宣称为强条件读取。

`RemoteWriteCondition` 是后续统一写入接口的值类型；本轮没有通用上传调度入口，不应把类型存在理解为已经执行条件上传。

## 缓存与 lease

- `.lease`：最后一个消费者释放后删除文件及本次私有目录。
- `.persistent`：在当前 materializer 生命周期内保留，释放 lease 后可用 `clearPersistentCache()` 清理；**不代表跨进程索引持久化或重启恢复**。
- `.matchingVersion`：相同绑定、引用、版本、校验/一致性策略及下载策略配置才复用或合并在途下载，允许默认策略下的启发式指纹。
- `.refresh`：新建独立下载代际，不覆盖现有 lease；不把强制刷新结果自动替换成其他调用的 lease。

同一个在途下载的每个消费者都有独立 release token。复制 `MaterializedFileLease` 值不增加消费者计数，副本共享同一个 token；重复 release 无副作用。调用 `withAccess` 会在成功和抛错路径都等待 release。没有自动析构释放：宿主必须显式 release/withAccess，并在退出时 shutdown。

lease 期间 URL 不会被 SDK 淘汰，但它是**只读约定**：宿主不得写入、移动或替换受管理文件/目录；SDK 不提供防恶意进程修改的访问控制。文件 identity/size/mtime/ctime 在缓存命中时复验。缓存无自动配额/LRU；宿主显式清理，终态任务用 `forget(id)` 移除历史。进程崩溃后可能留下目录，本轮无自动扫描或恢复。

## 文件事务与校验

每次下载写到私有随机目录的 staging，来源自己的 `.part` 也隔离在其中。完成后执行：

1. 验证 staging 是普通文件、无符号链接且 link count 为 1；可选验证已知大小。
2. 若提供 `expectedChecksum`，有界读取并验证整文件 SHA-256。其他算法在 I/O 前明确拒绝；来源上报的 checksum 不自动等于已经验证。
3. 再读远端元数据，检查 ID、大小与版本未变化，检查取消。
4. 复验 staging identity、时间与大小，在同目录使用排他 rename 原子发布，不覆盖已有目标，不降级为跨卷复制。

新下载失败不破坏旧 lease。缓存目录必须独占、祖先稳定且受宿主管理；根目录 symlink、staging symlink/hardlink、校验后的文件替换会被拒绝。**不保证抵御可重命名祖先目录的恶意进程，不提供跨进程锁，也不承诺断电 fsync 持久性**。内存传输缓冲由 provider 决定；SHA-256 校验按约 1 MiB 分块，不把整个文件装入内存。

当前物化只返回 SDK 所有的 URL；导出到用户指定目标目录、空间预估/配额、跨卷安装策略尚未提供。清理失败保留已登记记录以便后续显式清理；崩溃或未登记 staging 的清理失败不具备持久恢复保证。

## 调度、进度与取消

单 coordinator 可以通过 `init(materializers:maxConcurrentTransfers:)` 注册多个 binding；重复 binding 被拒绝。调度器同时限制全局活动任务和各 binding 的活动任务，后者不超过来源 `capabilities.maxConcurrentTransfers`，非法非正值按 1 处理。只限制同一 coordinator 所管理的调用，不约束宿主绕过它的低层调用或另一个 coordinator。

每来源 FIFO；被限流的来源不会阻塞其他有可用名额的来源。未设置任务级自动重试、优先级、后台调度或持久队列；来源内部的请求重试仍按其已有合同。`attempt == 0` 表示当前唯一一次任务尝试。没有额外指数退避层。

`submit` 返回稳定 UUID。`wait(for:)` 成功结果只能领取一次；取消一个 wait 调用只退出该观察者，不自动取消已提交任务。需要取消任务时调用 `cancel(id)`。成功后未领取的 lease 由 coordinator 持有，可通过 cancel、forget 或 shutdown 释放。

- 共享物化的一个等待者取消，不影响其他消费者。
- 最后一个物化等待者取消，取消底层下载并等待其退出/清理；不能强杀同步系统 I/O 或不配合取消的来源。
- 取消在提交前生效时不对消费者发布；若取消与提交/返回交错，已发出的 lease 表示完成，不将其假称为回滚。SDK 管理且无人领取的结果可被清理。
- coordinator `shutdown()` 停止接收任务、取消并等待它拥有的活动任务收敛，但不关闭共享 materializer 或断开来源；materializer 的 shutdown 拒绝新请求，取消并等待初始 stat、在途下载及其清理。取消仍依赖来源配合；调用方应等待自己持有的 API task，不能强杀不配合取消的系统 I/O。

`phaseProgress` 保留来源准备/传输的原始回调；`transferProgress` 增加 verifying/committing。两者是同步 Sendable 回调，必须快速、线程安全；UI 切 MainActor 由宿主处理。跨执行器已在途回调可能晚到，不能当作终态。

coordinator 使用有界最新值缓冲，允许丢弃中间进度；sequence 严格用于拒绝旧事件，不承诺连续无缺号。`snapshot(id)` 是权威状态，晚到进度不能覆盖终态。completed 快照中的 URL 是完成时位置，不延长 lease 生命周期；释放后可能已失效。

快照错误只保存固定分类描述，不复制底层字符串/签名 URL。`wait` 仍抛原始 typed error 供调用方判断，宿主应遵循[日志脱敏规范](Logging.md)，不要直接记录其 description。

## 可插拔的单文件并行分片下载

**未发布工作树能力。** 这是单文件的有界区间并发读取，不是“一文件一线程”，也不是跨进程分片续传。它直接接入 materializer，沿用完整文件校验、原子发布与 lease；coordinator 提交时也可通过 `RemoteTransferRequest.options` 指定同一策略。

### 业务调用

默认仍为 `.sequential`，不改变原有下载选择。显式启用方式如下；来源已连接，缓存目录的要求与基本示例一致：

```swift
import Foundation
import BoneRemoteSyncKit

func consumeSegmentedFile(
    source: any RemoteSource,
    bindingID: String,
    path: String,
    cacheDirectory: URL,
    consume: @Sendable (URL) async throws -> Void
) async throws {
    let binding = RemoteSourceBinding(kind: source.kind, identity: bindingID)
    let materializer = RemoteFileMaterializer(
        source: source, sourceBinding: binding, cacheDirectory: cacheDirectory
    )
    let options = RemoteMaterializationOptions(
        downloadStrategy: .segmentedIfSupported(.init(
            segmentSize: 4 * 1024 * 1024,
            maxConcurrentSegments: 3,
            minimumFileSize: 8 * 1024 * 1024
        ))
    )
    do {
        let lease = try await materializer.materialize(
            .init(source: binding, path: path), options: options
        )
        try await lease.withAccess { url in try await consume(url) }
        await materializer.shutdown()
    } catch {
        await materializer.shutdown()
        throw error
    }
}
```

| 策略 | 行为 |
| --- | --- |
| `.sequential` | 默认，使用来源普通下载接口 |
| `.segmentedIfSupported()` | 来源实现协议、条目非空且大小已知、具有强版本并达到阈值时尝试分片；否则使用普通下载。首片明确返回 `RemoteByteRangeError.unavailable` 时也可回退 |
| `.segmentedRequired()` | 必须分片；忽略小文件阈值，但不支持的来源、空文件、未知大小或缺少强版本均失败，不偷偷普通下载 |

配置默认片大小 **4 MiB**、每文件片并发 **3**、启用阈值 **8 MiB**。单片必须在 **1 字节…8 MiB**、并发在 **1…16**、阈值非负；非法配置在来源 I/O 前拒绝。实际片并发还受来源 `maxConcurrentTransfers` 约束。多连接不保证加速，不能仅凭配置推断吞吐。

首片是实际数据，不是额外完整 GET 或仅检查 `Accept-Ranges`。只有首片确认不可用才允许 IfSupported 降级；畸形响应、版本冲突、认证/网络失败、取消，或首片成功之后其他片不可用，都会失败且不发布。默认 `.latestObserved` 的普通下载回退仍是其原有元数据观察语义；需要拒绝弱化时同时指定 `.requireVersion`。如果来源只有分片强版本而没有普通条件下载能力，required-version 请求在回退时明确失败。

### 新网盘怎样复用

Swift 使用**协议遵循**，不要求继承某个具体网盘类。已有来源在 `RemoteSource` 基础上实现 Core 的 `RemoteByteRangeSource` 两个方法即可接入；Transfer 不导入 WebDAV，也不按 `kind` 或旧 `rangedDownload` 标记分支：

```swift
// 公共协议签名；适配器需提供自己的真实实现。
public protocol RemoteByteRangeSource: RemoteSource {
    func byteRangeVersion(for entry: RemoteEntry) -> String?
    func readBytes(
        _ entry: RemoteEntry,
        range: RemoteByteRange,
        requiringVersion: String
    ) async throws -> Data
}
```

来源实现必须满足以下合同：

1. `byteRangeVersion` 无 I/O，返回可在读取时**原子约束**的强版本；不能保证时返回 nil。mtime、大小或仅“读取前后 stat 一致”不够。
2. `RemoteByteRange` 是非空半开区间 `[offset, endExclusive)`，构造时检查负数、长度与溢出。服务端若使用闭区间，末字节是 `endExclusive - 1`。
3. 每次读取锁定相同条目、账号/根会话和强版本，验证实际响应的起止、总大小、版本以及正文字节数；返回长度必须精确等于 `range.length`。不得把完整 200 或不同版本切片伪装为有效结果。
4. 限制接收缓冲，超额、取消与断开时及时取消请求；允许多个调用并发，不写目标文件、不自动连接、不把凭据或签名 URL 放入错误。
5. 只有确定不支持这类读取时抛 `.unavailable`，不能把坏响应、权限、网络或版本冲突转换为该错误。来源仍须正确实现 `stat`、普通 `download` 与相应 capabilities。

公共层负责切片、首片探测、有界滑动窗口、按偏移合并、进度、取消排空和最终发布。来源负责协议/服务商差异、认证、会话隔离、真实区间及版本校验。首个内置适配为 **WebDAV**；Local、iCloud、OneDrive 当前未实现该协议，不能因为普通下载或 offset 续传可用就自动加入。

### 资源、一致性与恢复边界

- 同一 materializer 内，普通下载和分片请求共用来源 I/O gate，多个文件也共享。每文件另有片并发限制；metadata 请求不在 gate 中。不同 materializer、直接调用 `readBytes` 或 provider 的请求不受这个实例的上限约束。
- 子任务返回有界 Data，父任务独占 staging 文件，按偏移写入乱序返回的片。不为整个文件预建全部任务，也不同时装入整文件。缓冲随活动文件数、每文件窗口和片大小增长；首片、待写结果及 URLSession/系统内部缓冲也占内存，**来源请求上限不是进程总内存上限**。
- 分片长度及总长检查不可由 `verifySize: false` 关闭；可另传可信 `expectedChecksum` 做整文件 SHA-256。ETag 不等于摘要。下载后仍复查条目身份、大小与版本。
- 分片进度是已校验并写入的各区间**累计字节数**，不是连续前缀或持久 checkpoint。100% 后仍有校验与提交，不提供未完成文件给播放器。
- 错误/取消先等待所有分片子任务退出再清理未发布 staging。没有分片 bitmap、断点文件复用、跨进程恢复或自动后台重开；需要 WebDAV 持久恢复时使用下节的独立恢复入口，不能混用其 part。
- 策略及配置参与 cache/flight key；强制分片不会复用普通下载的缓存或在途请求。没有任务级自动重试或自适应测速。WebDAV 分片在请求/响应头阶段沿用其显式有限重试策略，始终保持原区间/原版本；开始处理 body 后不重试该片。

## 显式恢复下载（WebDAV）

`RemoteDownloadRecovery` 提供独立的通用恢复入口，不改变现有 materializer 的失败清理行为，也**不自动加入 coordinator 的进程内队列**。宿主传入已连接来源、稳定 binding 和明确的目标互斥实现；来源必须实现 `RemoteResumableDownloadSource`，不能仅凭 `resumableDownload` 能力标记或手动 offset 推断支持。当前仅 WebDAV 接入；Local、iCloud、OneDrive 会在来源/锁文件 I/O 前返回 unsupported。错误 binding 同样提前拒绝。

```swift
func recoverDownload(
    connectedSource: any RemoteSource,
    bindingID: String,
    path: String,
    destination: URL,
    privateLockDirectory: URL
) async throws -> RemoteResumableDownloadResult {
    let binding = RemoteSourceBinding(kind: connectedSource.kind, identity: bindingID)
    let reference = RemoteFileReference(source: binding, path: path)
    let recovery = RemoteDownloadRecovery(
        source: connectedSource,
        binding: binding,
        destinationLocks: LocalDownloadDestinationLocks(directory: privateLockDirectory)
    )
    // 默认不覆盖已有目标；来源自己读取 checkpoint，不接受调用方计算的 offset。
    return try await recovery.download(reference, to: destination)
}
```

### Checkpoint 与提交结果

- WebDAV 继续拥有 checkpoint 存储格式和恢复流程。通用层不保存第二套偏移或 session 信息；重启时宿主用相同账号/根绑定、远端路径、目标及锁目录重建服务即可。binding identity 仍须是非秘密、不透明标识，WebDAV 限制为 1–256 UTF-8 字节。该标识不是账号认证：SDK 无法从宿主提供的 ID 证明当前凭据属于原账号。账号切换必须使用新 binding 和 recovery；即使两个账号返回相同 ETag/大小，也不得复用旧 checkpoint。
- provider sidecar 为 `目标.part.checkpoint.json`，绑定账号 namespace、根、路径、目标的哈希，以及强 ETag、大小、已确认偏移、前缀 SHA-256 和 part device/inode。目标、part 和 checkpoint 必须位于宿主管理的稳定、私有**本地**目录；不要放进 NAS/WebDAV/iCloud 同步目录。哈希不是加密；ETag、大小和 metadata 仍可能敏感。新 sidecar 使用 `0600`，但读取已有 sidecar 不重新验证所有者/权限位，也不恢复被宿主放宽的权限；目录访问隔离由宿主持续保证。
- `checkpoint(reference,destination:)` 在互斥期间检查持久 binding、part 身份和前缀，返回只读 `RemoteDownloadCheckpoint?`；没有 checkpoint 且没有 orphan part 才返回 nil。它不是可自行修改/反序列化后用于续传的授权记录，也不保证远端此刻仍为同一版本。
- 实际 `download` 总会重新 stat/验证强 ETag 和大小，再用 `If-Match`/`Range` 继续；版本变化、链接、inode 替换、摘要/JSON 错误或孤立 part 时拒绝继续，不自动删除证据或覆盖原文件。checkpoint 的 confirmedBytes 不是最后一次进度回调字节数；已有尾部可按最后确认的 checkpoint 回退。全长但未确认 EOF 不能视为完成。
- 观察阶段为 `downloading`、`readyToInstall`、`committedCleanupPending`。成功结果的 `.committed` 和 `.committedCleanupPending` **都表示目标已提交**；后者表示 checkpoint 清理未完成，不带底层错误文本。提交点之后的取消不能将已提交文件报成未安装。
- 默认 `overwrite == false`。原子安装完成但残留 checkpoint 时，重建服务能核对已安装文件并继续清理，不重复 GET。若 checkpoint 已清理，再调用 download 是**新请求**，会因目标存在而拒绝；该 API 不是无限期幂等任务记录。显式 `overwrite: true` 允许替换目标，宿主必须先核对未知结果，不能自动盲目重试。
- 提交前取消/网络失败保留可恢复 pair，不返回 materialized lease，不自动删除；宿主仍需等待自己的 API Task 退出后再断开来源或人工清理。没有自动重试服务、后台任务、任务重开扫描或通用删除 checkpoint API。

### 目标互斥与安全前提

`LocalDownloadDestinationLocks` 使用本机 `flock(LOCK_EX | LOCK_NB)`，锁冲突立即失败，不忙等。规范化路径、大小写/Unicode 和祖先 symlink 别名后，对目标、part、checkpoint 三个路径取锁；大小写敏感卷也保守拒绝别名并发。不同目标可以并行。

所有进程/实例必须选择**同一个稳定、私有本地锁目录**，包括任何直接调用低层 provider API 的参与者；不同目录、绕过协议的调用或不遵守 advisory lock 的外部程序不受约束。默认文件实现不提供分布式锁、恶意进程 sandbox 或全局自动注册。锁目录不能作为下载目标或其祖先，不能有可被外部写入/重命名的祖先；SDK 检查根不是 symlink、属当前用户、非组/其他可写，锁文件普通且无额外硬链接、权限私有。

锁文件永久保留以避免 unlink 后的锁 inode 分裂；内容为空，文件名仅是规范化目标路径的 SHA-256。正常返回/抛错前关闭描述符；进程退出/崩溃由内核释放。宿主不得在参与进程存活时清理或替换锁目录/文件；停用所有参与者后才可人工清理。checkpoint 保留与目标原子 rename 不等于断电后目录项 fsync 保证。

## 显式恢复上传（OneDrive）

`RemoteUploadRecovery(source:binding:)` 提供 `prepare`、`resume`、`checkpoint`、`abort`，只依赖 Core 的 `RemoteResumableUploadSource`；不包含具体云服务、Keychain或sessionURL逻辑，不自动连接或加入coordinator。必须同时满足capabilities.resumableUpload和协议实现；错误binding/不支持来源在provider操作前拒绝。当前内置provider仅OneDrive专用构造器启用，binding应取自 `connectedBinding()`，不能随意改名。

流程为：**本地prepare → 宿主持久化handle → resume → 保存提交结果**。后续进程以相同账号/drive、Keychain service和私有快照目录恢复原handle；秘密持久化、快照身份、确认字节、原session查询与合作互斥均由provider负责。通用层没有第二套持久任务/偏移，也不重试未知提交。上传回执不是下载lease，不用release删除远端内容。

`RemoteResumableUploadOptions`默认不覆盖；结果的committed与committedCleanupPending都表示已提交。后者要求宿主保存返回回执并处理本地保存/清理问题，不能当作重新上传授权。`abort`不是撤销已完成写入；未知状态不可丢弃。OneDrive额外提供仅终态可用的 `forgetResumableUpload`，通用协议当前不包含遗忘接口。

具体可编译例子、安全存储、320 KiB分片、5 GiB上限、未知状态与人工核对限制见 [OneDrive Upload Session](OneDrive.md#upload-session-可恢复上传显式-opt-in)。这不扩展WebDAV/NAS服务器能力，不把完整PUT伪装为分片恢复。

## 尚未实现与验收边界

- 除 WebDAV 分片/恢复下载、OneDrive 恢复上传之外的对应 provider 适配；分片持久恢复、上传调度、持久任务队列和跨来源事务。
- OneDrive 可恢复上传必须通过专用构造器显式 opt-in；普通 `OneDriveSource(configuration:)` 不声明 `resumableUpload`，Transfer 不会自动替宿主选择该 service，也不会自动加入 coordinator 或后台调度。
- Catalog 任务/缓存记录集成、自动淘汰/配额、跨来源事务、自动双向同步。
- OneDrive Upload Session 的受控 fixture 已覆盖分片、范围、session/PUT HTTP 错误、快照与提交未知边界；真实 iCloud/Microsoft/NAS、Keychain entitlement、大文件吞吐、空间不足、权限/掉电和最低系统真机仍需单独验收。

四来源已有下载合同已接入同一 materializer 并通过最小集成测试：Local 临时目录、WebDAV/OneDrive localhost HTTP fixture、iCloud 本地容器 seam。OneDrive 引用使用来源返回的完整不透明 entry ID，不手工拼装底层 Graph item ID。这些结果均不能替代真实服务物化验收。
