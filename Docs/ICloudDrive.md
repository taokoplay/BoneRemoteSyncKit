# iCloud Drive 来源

[返回项目首页](../README.md) · [通用 API](API.md) · [验证状态](Validation.md) · [宿主示例](../Examples/ICloudDrive/ICloudDriveExample.swift)

`BoneRemoteSyncICloud` 提供独立的 `ICloudDriveSource`，由统一入口 `BoneRemoteSyncKit` 重新导出。它是 **iCloud Drive 文件访问与传输适配器**，不是 CloudKit 数据库、`CKSyncEngine`、File Provider 扩展或自动双向同步引擎。本功能自 **`v0.3.0`** 发布，不在 `v0.2.0` 中；版本发布不代表真实 iCloud 或最低系统真机已经验收。

## 宿主配置与权限

1. 在 Xcode 的宿主 App target 启用 iCloud capability，勾选 iCloud Documents，并选择已在开发者账号中配置的容器。签名和 provisioning profile 必须与容器匹配。
2. 按目标平台和分发方式由 Xcode 配置相应的 `com.apple.developer.ubiquity-container-identifiers`、iCloud container/service 和必要的 kvstore 标识等 entitlement；不要把别人的 Team ID 或示例容器原样用于签名。SDK 本身不添加 entitlement、不创建容器、不扩大 sandbox 权限。
3. 用户在系统设置中登录 Apple 账号并启用 iCloud Drive。SDK 不提供登录 UI、账户选择、OAuth、密码或 token 存储。
4. `containerIdentifier == nil` 使用 `FileManager` 返回的宿主默认 ubiquitous container；指定标识符时必须与宿主获授权的容器一致。这不是访问用户整个 iCloud Drive 的入口，也不支持任意 App 的容器。
5. `directoryPath` 相对容器根，默认 `/`；例如 `/Documents`。目标目录必须已存在，`connect` 和 `status` 不隐式创建目录。需要初始化 Documents 时，应在已连接的容器根显式调用 `makeDirectory(path: "/Documents")`，再使用相应子目录配置。

只有具有匹配 entitlement 的真实宿主才能验证这些条件。命令行 `swift test` 的临时目录注入不能证明 Apple 账号、云端权限或容器配置正确。平台 API 可编译也不意味着 tvOS 等平台与 iOS/macOS 具备完全相同的产品行为，须分别实机验收。

## 最小只读示例

```swift
import Foundation
import BoneRemoteSyncKit

func browseICloudContainer() async throws -> [RemoteEntry] {
    let configuration = try ICloudDriveConfiguration(
        containerIdentifier: nil,
        directoryPath: "/",
        downloadTimeout: 120,
        pollInterval: 0.25
    )
    let source = ICloudDriveSource(configuration: configuration)
    do {
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        guard page.coverage == .complete else {
            throw RemoteSyncError.unsupported(operation: "iCloud 目录列表不完整")
        }
        await source.disconnect()
        return page.entries
    } catch {
        await source.disconnect()
        throw error
    }
}
```

`connect` 仅接受 `.anonymous`，其含义是**使用系统 Apple 账号**，而不是公共匿名云盘。传入 Basic 或 OAuth 凭据会抛出 `.authenticationFailed`。配置初始化与 Codable 解码均校验容器名、路径穿越和有限正数时间参数。

## 当前能力与协调语义

| 操作 | 行为与边界 |
| --- | --- |
| `list` / `stat` | 使用 `NSFileCoordinator` 的立即可用元数据读取；不把浏览当作所有内容已下载。列表不分页，`limit` 仅为提示，任何非 nil cursor 均拒绝 |
| 列表完整性 | 元数据读取失败、越界 symlink 或冲突条目被遗漏时返回 `.partial`；不能安全表示的路径名称报错。发现旧式隐藏 `.name.icloud` 占位标记时也返回 partial，不把占位标记伪装为内容文件 |
| `download` | 对 ubiquitous 文件请求系统下载，轮询直到 `.current`，随后协调读取内容；提交前超时或取消不安装最终目标 |
| 手动续传 | 使用 `<destination>.part`、`resumeFrom`、可选 `expectedETag`；校验偏移、part 长度、文件身份和复制期间源版本。无 checkpoint/跨进程恢复协议 |
| `upload` | 在目标目录写随机 staging，完成后原子 rename；支持非覆盖。拒绝目录、symlink/hardlink 等不安全覆盖目标。不承诺设置 `contentType` |
| `makeDirectory` | 显式创建目录及缺失父目录；根 `/` 为 no-op |
| `remove` | `.forDeleting` 协调后删除；不是“仅清理本地缓存”，删除会由系统传播到云端。禁止删除来源根及其别名 |
| `move` | 同时协调源和目标，使用移动意图及通知；目标必须不存在；拒绝移动符号链接，禁止根操作和目录移入自身后代 |
| `copy` | 同时协调源读与目标写，先确保源文件已下载；目标必须不存在。**当前只支持普通文件复制，不支持符号链接或递归目录复制** |

上传、创建、移动、复制或删除返回成功，表示本地文件系统操作完成，**不表示 iCloud 已上传，也不表示另一设备已接收**。覆盖上传默认开启；进行破坏性测试前必须取得用户授权，使用专用测试目录。

文件工作在每个 source 的 utility 串行队列执行，不在主线程获取 ubiquitous container。`maxConcurrentTransfers == 1` 对应该实例实际串行执行的文件 I/O；等待占位文件下载时 actor 可重入，多个准备阶段可交错。它不是“整个 async 调用排他”的互斥锁，也不是跨实例/进程全局调度。宿主仍须串行编排备份保留策略和同一目标的业务流程。取消经线程安全标记传播到同步复制循环；断开或重连使旧操作失效。系统文件协调等待或单次同步系统调用无法保证即时中止；取消也不能撤回已完成的 rename、移动或删除。

文件协调不等于防恶意进程的 sandbox。来源边界检查包括尚不存在目标的 symlink 父目录；宿主仍须独占本地目标与 part，避免其他实例/进程恶意替换父目录。上传输入应保持稳定。下载返回的是协调读取时的源元数据，不是下载目标文件的元数据。

## 状态与版本

`await source.status(path: "/file.txt")` 无需先 connect，返回本机快照：

- `availability` / `isAvailable`：配置的目录当前能否在本机找到，不是网络连通性或全局同步完成状态。不可用时 `unavailableReason` 为 `.notSignedIn`、`.driveUnavailable`、`.containerNotFound`、`.directoryNotFound` 或 `.unknown`；可用时为 nil。
- `containerURL`、`rootURL`：本机容器及来源根；不要把它们作为跨设备稳定标识或写入公开日志。
- `accountIdentifierAvailable`：是否存在系统 ubiquity identity token；不暴露 token 或 Apple ID，也不证明指定容器权限。临时目录测试不伪造此状态。
- `isUbiquitous`：该条目的 Foundation ubiquitous 元数据。
- `downloadState`：`.notDownloaded`、`.downloading`、`.downloaded`、`.current`、`.unknown` 或 nil。`.downloaded` 只表示已有本地副本，不保证是当前云端版本，因此下载仍等待 `.current`；离线时可能超时。
- `percentDownloaded`：当前固定 nil；未接入 `NSMetadataQuery`，不虚构百分比进度。`phaseProgress` 提供准备状态变化；原 `progress` 仍只报告本地复制字节数，不是 iCloud 网络下载/上传进度。

未知路径、元数据读取失败或取消时，status 可能缺少 item 字段；需要精确失败原因请用 `stat`。status 不改变连接状态。

iCloud 不支持 `RemoteIDAddressableSource` 或 `RemoteUploadOptions.expectedETag`；其 `RemoteEntry.id` 仍是路径相对标识，不应冒充云端稳定 ID。

`RemoteEntry.etag` 为本地大小与毫秒级修改时间的启发式指纹，**不是 iCloud 服务端版本号、change token 或内容哈希**。不能用它单独决定双向覆盖或删除。账号 token 在操作开始及复制检查点比较；检测变化后拒绝继续，宿主应断开并重新建立来源，且重新绑定账号相关业务状态。未实现账户通知流或持久化身份绑定。

检测到 `ubiquitousItemHasUnresolvedConflicts` 时，读取/写入拒绝该条目并抛 `ICloudDriveError.unresolvedConflict`；SDK **不选择获胜版本、不自动清除冲突、不调用 `NSFileVersion` 合并/回滚**。递归删除或移动目录不递归审查所有后代版本冲突，宿主须事先确认目录级操作范围。iCloud 特有错误保留 `ICloudDriveError` 类型；普通路径/权限/目标冲突/取消仍使用 `RemoteSyncError`，无法归类的系统错误由共享 `.underlying` 兜底。不要按本地化描述字符串控制流程。

## 宿主错误映射与迁移

以下为 `v0.3.0` 的契约，不在 `v0.2.0` 中。本项目不保留旧 API 兼容层；使用过开发分支旧接口的宿主应更新穷尽 switch 和旧的“所有错误均为 RemoteSyncError”假设。

| 错误 / status 原因 | 证据与推荐处理 | 可选 `remoteSyncError` 投影 |
| --- | --- | --- |
| `accountNotSignedIn` / `notSignedIn` | 当前进程没有 ubiquity identity；提示检查系统 Apple 账号与宿主 iCloud 配置。**不能据此证明系统设置中一定没有登录** | authenticationFailed |
| `driveUnavailable` / 同名原因 | 有身份，但默认/指定容器无法解析，且不能确认另一个默认容器可访问；检查 Drive 开关、entitlement、签名、容器与服务状态 | network |
| `containerNotFound(identifier:)` / `containerNotFound` | 指定容器无法解析，而默认容器可访问；检查指定标识与权限，不表示开发者后台一定不存在容器 | network |
| `directoryNotFound(path:)` / `directoryNotFound` | 已解析容器中配置目录不存在或不是目录；显式初始化后重试。操作前发现已连接配置根被删除时也返回此类型 | notFound |
| `accountChanged` | 已连接会话的 identity 消失或变化；停止旧业务，断开并重新连接、重新绑定账号状态 | network |
| `downloadTimedOut(path:)` | 在配置时限内未观察到 current；可稍后重试或调整超时，不保证系统已停止后台 hydration | network |
| `unresolvedConflict(path:)` | 发现系统未解决版本冲突，交由宿主决定处理，不自动选版 | conflict |
| `coordinationFailed(path:)` | 协调器未给出可用结果，重新核验后决定是否重试 | conflict |
| `invalidContainer` | 配置的容器标识/路径无效；修正配置 | unsupported |
| status `unknown` | 快照被取消、根目录权限/IO 查询失败、配置根路径解析失败或其他不能可靠归类的查询问题；不猜测为 Drive 关闭 | 不作为操作错误投影 |

系统公开 API 不提供“账号已登录但用户关闭 Drive”和“entitlement/容器/服务不可用”的可靠完全区分。本轮返回保守分类，**不宣称已完成真实设备的精确 Drive 开关检测**。status 不抛错误；配置目录可用但所查 item 不存在/元数据失败时仍可为 available，item 字段缺省。需要具体文件错误请调用 stat。

```swift
func restoreBackup(source: ICloudDriveSource, path: String, destination: URL) async throws {
    do {
        _ = try await source.download(path: path, to: destination)
    } catch let error as ICloudDriveError {
        switch error {
        case .accountNotSignedIn, .driveUnavailable, .containerNotFound:
            // 宿主展示账号/Drive/配置检查引导，不自动断言是某一个系统开关。
            throw error
        case .directoryNotFound, .accountChanged, .downloadTimedOut,
             .unresolvedConflict, .coordinationFailed, .invalidContainer:
            throw error
        }
    } catch {
        // 包括 RemoteSyncError.cancelled、permissionDenied、conflict 等。
        throw error
    }
}
```

只需共享分类的宿主可显式使用 `error.remoteSyncError`，但投影会丢失来源细节；SDK 不再先投影再抛出。自动日志应按 case 写宿主自定义固定分类，避免公开容器/本地路径和原始错误描述。

## 下载阶段状态机

`RemoteDownloadOptions.phaseProgress` 使用 Core 通用类型，不依赖 iCloud 模块：

```text
preparing(notStarted / inProgress / unknown, fraction=nil)
  → preparing(ready, fraction=1)
  → transferring(bytes including resume offset)
  → async download returns successfully after atomic installation
```

- notDownloaded 映射 notStarted；downloading / downloaded 映射 inProgress；未知映射 unknown。current 才映射 ready，已有非 ubiquitous 本地文件直接进入 transferring。
- 状态是按 `pollInterval` 读取的快照，不保证看见所有短暂状态；首次即 current 时可只有 ready → transferring。相同 preparing 快照去重，直到超时、取消或就绪。
- 准备阶段没有可靠字节数时 `completedBytes=0`、`totalBytes=nil`、比例 nil；这不表示没有网络流量。不用时长/文件大小估造网络下载比例。
- 当前 Foundation 的 URL 资源百分比 key 在目标 SDK 上不可用，公开支持的百分比来自 NSMetadataQuery/NSMetadataItem。本轮没有引入长期查询，`status.percentDownloaded` 仍为 nil，UI 用阶段/状态加不定进度，不承诺 0–100 的体验等同于宿主原查询实现。
- 比例单位为 **0...1**，若有值才乘 100 展示。preparing 与 transferring **各自独立**，切换阶段不把两者拼成单调总百分比。ready 只代表可以协调读取，不是最终目标已安装。
- transferring 在打开并准备写入 staging/part 后、每批写入后回调。字节数含 `resumeFrom`；单次尝试内不递减，网络来源重试可从更小偏移重报。未知总量和空文件比例为 nil；即使报告 1，后续源版本校验/原子安装仍可能失败，只有 async 成功返回才算成功。
- 回调同步、@Sendable，不保证在主线程执行；须快速且线程安全，UI 由宿主切到 MainActor。无固定回调频率，宿主自行节流。OneDrive 已从内部锁取出的在途回调可能晚于取消返回，取消也不能撤回已排队的宿主 UI 更新；宿主用自己的任务标识过滤过期事件/UI。不要依赖“async 返回后绝不会再有回调”。
- 原 `progress` 仍仅报告本地写入字节。Local、WebDAV、OneDrive 普通 download 报 transferring；WebDAV 独立 managed 恢复 API 沿用自己的 options/进度，不是新回调接口。

## 备份目录的显式初始化

配置根为 `/Documents/Backup` 且首次不存在时，不能先 connect 这个子目录再 makeDirectory；应先连接容器根，显式建目录，再使用受限来源。查询和连接不负责初始化：

```swift
func openBackupSource(containerIdentifier: String) async throws -> ICloudDriveSource {
    let bootstrap = ICloudDriveSource(configuration: try .init(containerIdentifier: containerIdentifier))
    do {
        try await bootstrap.connect(.anonymous)
        try await bootstrap.makeDirectory(path: "/Documents/Backup")
        await bootstrap.disconnect()
    } catch {
        await bootstrap.disconnect()
        throw error
    }
    let source = ICloudDriveSource(configuration: try .init(
        containerIdentifier: containerIdentifier,
        directoryPath: "/Documents/Backup",
        downloadTimeout: 120,
        pollInterval: 0.25
    ))
    try await source.connect(.anonymous)
    return source
}
```

两个连接之间若切换系统账号，本 helper 不提供跨连接身份事务；宿主应在账号变化后重新建立全部备份上下文。对 ≥50 MB 备份，120 秒是否合适必须实机测量；可以通过配置提高时限，但时限也不是对系统协调调用的强制抢占。

完整的显式初始化、列表、带阶段恢复、上传和保留清理参考[宿主示例](../Examples/ICloudDrive/ICloudDriveExample.swift)。文件名规则、打包/解包、保留数量及选择要删除的条目都由宿主负责；SDK 不建立备份调度或批量事务。

## Q1–Q7 契约速查

| 编号 | 答复 |
| --- | --- |
| Q1 | 已下载文件仍复制到指定目标。非 ubiquitous 或已 current 不调用 startDownloading；downloaded（可能为旧版）仍请求并等待 current。`overwrite=false` 且目标存在为共享 conflict。准备阶段可发生在目标冲突被最终检测之前；失败 part 通常保留，宿主只在确认来源版本、偏移和 part 长度后手动续传。 |
| Q2 | partial 表示旧 `.name.icloud` 标记、冲突项、越界 symlink 或元数据失败导致漏项；没有逐项失败清单，不能据此认定未列出项被远端删除。不可表示的名称直接报错。1–5 项列表可逐条 status 获取角标，不新增 R3 批量接口。 |
| Q3 | upload 非覆盖且目标存在返回共享 conflict；随机 staging 在调用退出时尽力清理，进程崩溃/断电或清理本身失败不能保证无残留。提交后的返回错误不能证明文件未安装。上传可显式形成父目录。 |
| Q4 | remove 对非空目录递归删除；只检查操作项冲突，不递归审查所有后代版本。清理备份应只传宿主已选定的文件路径，不能删除来源根。 |
| Q5 | connect/status 不创建目录，不调用 startDownloading，也不主动读取占位内容；容器解析和元数据查询仍由系统处理，不能承诺系统后台完全零网络流量。 |
| Q6 | 单实例阻塞文件工作确实串行；占位等待可交错，不保证整次操作或业务序列排他，多实例可并行。自动备份/恢复的业务互斥由宿主负责。 |
| Q7 | upload 返回只确认本地协调与原子提交，没有“云端已传播”查询保证。建议文案：“已保存，iCloud 将继续同步，其他设备可能稍后可见”。 |

## 未集成范围

- **Catalog：** `RemoteCatalogProvider`、`RemoteSourceConfiguration` 和默认 session factory 仍只支持 Local、WebDAV、OneDrive。不要把 iCloud 容器作为 `.local` 绕过来源语义；直接持有 `ICloudDriveSource` 使用。Catalog 的持久化 iCloud 配置与账户绑定需后续独立设计。
- 无 `NSMetadataQuery` 变更监听、`NSFilePresenter` 长期观察者、后台传输队列、跨设备一致性协议、tombstone、差异计划或自动同步。
- 无 CloudKit record/zone、`CKSyncEngine`、Core Data/SwiftData 同步接入。
- 无递归目录复制、上传续传、对外内容哈希、云端上传完成等待或真实账号自动测试。

## 真实宿主验收清单

以下均待在具备 entitlement 的宿主完成，不能用本地 seam 测试替代：

- [ ] 默认与指定容器；配置不匹配、目录不存在、退出 Apple 账号、iCloud Drive 关闭。
- [ ] 真正未下载的文件、系统“移除下载”后的文件、旧式占位标记；列表、stat、按路径下载及下载超时。
- [ ] `.downloaded` 旧版本与 `.current`；断网、恢复网络、存储不足、下载期间取消/断开。
- [ ] 两台设备先后上传/更新/移动/删除；记录本地成功与另一设备可见之间的差异。
- [ ] 账号切换、系统权限/容器变化、旧任务晚到不进入新会话。
- [ ] 文档在其他 App/进程中打开时的协调等待、移动通知和写冲突。
- [ ] `NSFileVersion` 未解决冲突、目录后代冲突，确认 SDK 不自行选版或清除版本。
- [ ] ≥50 MB 占位文件的阶段序列、120 秒时限适用性、部分下载续传、同名覆盖与不可覆盖、每个目标平台的实机运行。

只读示例可先核验容器访问；写验收必须另选用户确认的专用目录。验收失败先核对真实目录和云端状态，不因错误返回推断写入没有发生。
