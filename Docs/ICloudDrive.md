# iCloud Drive 来源（未发布）

[返回项目首页](../README.md) · [通用 API](API.md) · [验证状态](Validation.md) · [只读宿主示例](../Examples/ICloudDrive/ICloudDriveExample.swift)

`BoneRemoteSyncICloud` 提供独立的 `ICloudDriveSource`，由统一入口 `BoneRemoteSyncKit` 重新导出。它是 **iCloud Drive 文件访问与传输适配器**，不是 CloudKit 数据库、`CKSyncEngine`、File Provider 扩展或自动双向同步引擎。本功能在当前开发源码中，**不在 `v0.2.0` 中，也尚未发布**。

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
| `download` | 对 ubiquitous 文件请求系统下载，轮询直到 `.current`，随后协调读取内容；超时或取消不安装最终目标 |
| 手动续传 | 使用 `<destination>.part`、`resumeFrom`、可选 `expectedETag`；校验偏移、part 长度、文件身份和复制期间源版本。无 checkpoint/跨进程恢复协议 |
| `upload` | 在目标目录写随机 staging，完成后原子 rename；支持非覆盖。拒绝目录、symlink/hardlink 等不安全覆盖目标。不承诺设置 `contentType` |
| `makeDirectory` | 显式创建目录及缺失父目录；根 `/` 为 no-op |
| `remove` | `.forDeleting` 协调后删除；不是“仅清理本地缓存”，删除会由系统传播到云端。禁止删除来源根及其别名 |
| `move` | 同时协调源和目标，使用移动意图及通知；目标必须不存在；拒绝移动符号链接，禁止根操作和目录移入自身后代 |
| `copy` | 同时协调源读与目标写，先确保源文件已下载；目标必须不存在。**当前只支持普通文件复制，不支持符号链接或递归目录复制** |

上传、创建、移动、复制或删除返回成功，表示本地文件系统操作完成，**不表示 iCloud 已上传，也不表示另一设备已接收**。覆盖上传默认开启；进行破坏性测试前必须取得用户授权，使用专用测试目录。

文件工作在每个 source 的 utility 串行队列执行，不在主线程获取 ubiquitous container。`maxConcurrentTransfers == 1` 是该实例的建议值，不是全局调度。取消经线程安全标记传播到同步复制循环；断开或重连使旧操作失效。系统文件协调等待或单次同步系统调用无法保证即时中止；取消也不能撤回已完成的 rename、移动或删除。

文件协调不等于防恶意进程的 sandbox。来源边界检查包括尚不存在目标的 symlink 父目录；宿主仍须独占本地目标与 part，避免其他实例/进程恶意替换父目录。上传输入应保持稳定。下载返回的是协调读取时的源元数据，不是下载目标文件的元数据。

## 状态与版本

`await source.status(path: "/file.txt")` 无需先 connect，返回本机快照：

- `availability` / `isAvailable`：配置的目录当前能否在本机找到，不是网络连通性或全局同步完成状态。
- `containerURL`、`rootURL`：本机容器及来源根；不要把它们作为跨设备稳定标识或写入公开日志。
- `accountIdentifierAvailable`：是否存在系统 ubiquity identity token；不暴露 token 或 Apple ID，也不证明指定容器权限。临时目录测试不伪造此状态。
- `isUbiquitous`：该条目的 Foundation ubiquitous 元数据。
- `downloadState`：`.notDownloaded`、`.downloading`、`.downloaded`、`.current`、`.unknown` 或 nil。`.downloaded` 只表示已有本地副本，不保证是当前云端版本，因此下载仍等待 `.current`；离线时可能超时。
- `percentDownloaded`：当前固定 nil；未接入 `NSMetadataQuery`，不虚构百分比进度。传输 progress 是本地复制字节数，不是 iCloud 网络下载/上传进度。

未知路径、元数据读取失败或取消时，status 可能缺少 item 字段；需要精确失败原因请用 `stat`。status 不改变连接状态。

iCloud 不支持 `RemoteIDAddressableSource` 或 `RemoteUploadOptions.expectedETag`；其 `RemoteEntry.id` 仍是路径相对标识，不应冒充云端稳定 ID。

`RemoteEntry.etag` 为本地大小与毫秒级修改时间的启发式指纹，**不是 iCloud 服务端版本号、change token 或内容哈希**。不能用它单独决定双向覆盖或删除。账号 token 在操作开始及复制检查点比较；检测变化后拒绝继续，宿主应断开并重新建立来源，且重新绑定账号相关业务状态。未实现账户通知流或持久化身份绑定。

检测到 `ubiquitousItemHasUnresolvedConflicts` 时，读取/写入拒绝该条目并映射为 `.conflict`；SDK **不选择获胜版本、不自动清除冲突、不调用 `NSFileVersion` 合并/回滚**。递归删除或移动目录不递归审查所有后代版本冲突，宿主须事先确认目录级操作范围。涉及实际文件协调、容器/系统错误和冲突的归一化以 `RemoteSyncError` 为主，`ICloudDriveError` 提供专项描述及共享错误映射；不要按本地化描述字符串控制流程。

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
- [ ] 大文件、部分下载续传、同名覆盖与不可覆盖、每个目标平台的实机运行。

只读示例可先核验容器访问；写验收必须另选用户确认的专用目录。验收失败先核对真实目录和云端状态，不因错误返回推断写入没有发生。
