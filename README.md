# BoneRemoteSyncKit

**面向 Apple 平台的 Swift 文件访问 SDK，以统一 API 连接本地目录、iCloud Drive、WebDAV 和 OneDrive Personal。**

一次 `import BoneRemoteSyncKit`，即可使用目录浏览、文件上传与下载、目录创建、移动、删除及按来源提供的复制能力。基于 Swift Concurrency，无第三方运行依赖。

> 当前发布版本为 **`v0.3.0`**，包含 [Catalog 配置持久化与目录缓存](Docs/Catalog.md)、结构化日志、[iCloud Drive 来源及备份 R1/R2 契约](Docs/ICloudDrive.md)、OneDrive 稳定 ID 读取和 WebDAV 条件上传。当前工作树另含**尚未发布**的 iCloud R3 批量状态、[Transfer 物化/前台调度/分片下载/显式恢复](Docs/Transfer.md)及 OneDrive Upload Session 可恢复上传。这些未发布能力不在 `v0.3.0` 标签中；业务适用性见[场景指南](Docs/UseCases.md)，版本变化及迁移要求见[更新说明](CHANGELOG.md)。

> 当前提供文件访问与传输能力，**不包含自动同步引擎**。SMB 和其他网盘适配器尚未实现；iCloud Drive 来源已新增，真实云端验收待完成。接口统一不代表每个来源的能力与失败语义完全相同。

[支持的来源](#支持的来源) · [能力矩阵](#能力矩阵) · [业务场景](Docs/UseCases.md) · [安装](#安装) · [快速上手](#快速上手) · [更新说明](CHANGELOG.md) · [详细文档](#详细文档) · [验证状态](Docs/Validation.md)

## 适用场景

本库适合承担 App 的**文件访问与传输层**，不是带 UI 的完整文件管理、备份或同步产品。业务代码决定处理哪些文件、如何解析内容以及何时覆盖或删除，SDK 负责按来源合同执行文件操作。

| 业务方向 | 当前能提供什么 | App 仍需实现什么 |
| --- | --- | --- |
| 多来源文件管理器 / NAS 浏览器 | 统一浏览、文件信息、读写与目录管理；NAS 通过 WebDAV 接入 | UI、账号和目录授权、破坏性操作确认；不是 SMB 客户端 |
| 文档阅读 / 笔记附件 / 媒体导入 | 下载完整文件；未发布 Transfer 提供本地 URL、复用与 lease | 解析、预览、播放、缩略图和编辑；不支持通用边下边播 |
| 离线目录浏览 | Catalog 保存来源、选定根和最近完整列表，离线查询 | 正文离线保存、刷新触发与状态展示；Catalog 暂不支持 iCloud |
| 备份与恢复 | 上传宿主生成的备份包、列出备份、下载及显式删除 | 数据一致性导出、打包/加密、保留策略、恢复安装；iCloud 写成功不等于云端已同步 |
| 前台批量获取与中断恢复 | 未发布 Transfer 限制下载并发，并提供可插拔单文件分片下载（首个适配 WebDAV）；WebDAV 可恢复下载，未发布 OneDrive 可恢复上传 | 持久任务、后台执行、显式继续与未知结果核对；不是所有来源双向都能续传 |
| 跨来源一次性导入 / 导出 | 宿主可组合“下载到本地 → 上传到另一来源” | 两段操作的编排与结果核对；没有跨来源直传、原子移动或回滚 |

完整的业务流程、模块选择、版本范围及宿主职责见 **[业务能力与适用场景](Docs/UseCases.md)**。

不提供自动双向同步、系统磁盘挂载、File Provider 扩展、后台传输调度或跨来源事务。

## 支持的来源

目前内置 **4 类文件来源**，均从 `BoneRemoteSyncKit` 统一使用。以下是实际接入范围，不是对同品牌全部服务的支持承诺。

| 来源 | 适配器 | 当前接入范围与前提 |
| --- | --- | --- |
| 本地目录 | `LocalFileSource` | 宿主获授权且已存在的本地根目录；sandbox / security-scoped URL 权限由宿主管理 |
| WebDAV / NAS | `WebDAVSource` | 提供 WebDAV 接口的 NAS 或服务器，支持匿名 / Basic 认证；优先 HTTPS，具体操作取决于服务端实现与账号权限；不是 SMB 接入 |
| OneDrive Personal | `OneDriveSource` | Microsoft 个人账号的主盘，OAuth / PKCE 授权；不含 Business、SharePoint、共享 `remoteItem` 或跨盘访问 |
| iCloud Drive | `ICloudDriveSource` | 系统 Apple 账号及宿主获授权的 ubiquitous container，需正确 entitlement；不是任意浏览用户整个 iCloud Drive，也不是 CloudKit |

Google Drive、Dropbox、百度网盘、阿里云盘等独立网盘适配器，以及 SMB、SFTP、FTP/FTPS、NFS 等协议尚未实现，见[未支持来源开发计划](Docs/CloudDriveRoadmap.md)。第三方服务即使提供 WebDAV，也仅可按其 WebDAV 接口尝试接入，不代表已实现该品牌原生 API 或完成兼容性验收。

## 能力矩阵

下表按**当前工作树**列出。标记 **「未发布」** 的 Transfer 队列、物化、分片及 OneDrive Upload Session 不包含在 `v0.3.0` 中；“支持”表示已有实现，不代表账号具备权限或所有服务端已经验收。**“未适配”表示公共扩展入口存在，但该内置来源尚未接入，不能直接使用。**

| 功能 | 本地目录 | WebDAV | OneDrive Personal | iCloud Drive |
| --- | --- | --- | --- | --- |
| 读取目录列表 `list` | 支持 | 支持，Depth:1 | 支持 | 支持，本机可见元数据 |
| 查询文件信息 `stat` | 支持 | 支持 | 支持 | 支持，协调读取 |
| 递归遍历目录 `walk` | 支持 | 支持 | 支持 | 支持，需检查列表完整性 |
| 游标分页 | 不支持，返回单层列表 | 不支持，返回单层列表 | 支持，逐页消费 cursor | 不支持，返回单层列表 |
| 创建时间 / 类型分类提示 | 支持，元数据可缺失 | 取决于服务端属性 | 取决于 Graph 条目属性 | 支持，本机元数据可缺失 |
| 按稳定 ID 查询 / 列表 / 下载 | 不支持 | 不支持 | 支持，仅当前主盘内读取 | 不支持 |
| 普通文件下载 | 支持，复制到本地目标 | 支持，流式 GET | 支持，完整文件下载 | 支持，等待占位文件就绪后协调复制 |
| 普通文件上传 | 支持，本地写入 | 支持，完整 PUT | 支持，Simple upload ≤250 MiB | 支持，本地原子写入；不等待云端同步 |
| 修改文件内容：整文件替换 | 支持，覆盖上传 | 支持，已有文件须有强 ETag | 支持，覆盖上传；普通入口 ≤250 MiB | 支持，覆盖上传；仅确认本地完成 |
| 指定 `expectedETag` 条件上传 | 不支持 | 支持，强 ETag / If-Match | 不支持，Upload Session 也不支持最终条件替换 | 不支持 |
| 创建目录 / 递归创建父目录 | 支持 | 支持，逐级 MKCOL | 支持 | 支持，协调创建 |
| 重命名 / 移动文件或目录 | 支持，目标须不存在 | 支持，MOVE / 非覆盖 | 支持，先查目标再 PATCH；不保证原子非覆盖 | 支持，协调移动 / 非覆盖 |
| 删除文件 / 递归删除目录 | 支持 | 支持 | 支持 | 支持；不是仅清理本地缓存 |
| 来源内复制文件 / 目录 | 均支持 | 均支持，服务端 COPY | 不支持 | 仅普通文件，不支持目录复制 |
| 多文件下载队列与并发 **「未发布」** | 可批量提交；单实例同步复制仍串行 | 支持多文件并发，受调度上限约束 | 支持多文件并发，受调度上限约束 | 可批量排队；同一 binding 串行调度 |
| 来源声明的传输上限输入¹ | 4 | 3 | 3 | 1 |
| 单文件并行分片下载 **「未发布」** | 未适配 | 支持，需强 ETag、已知非零大小及正确 Range 响应；显式启用 | 未适配 | 未适配 |
| 手动指定 offset 下载续传 | 支持，宿主管理 part 与偏移 | 支持，需强 ETag / Range | 不支持 | 支持，本地启发式指纹；不是云端分片 |
| checkpoint / 跨进程下载恢复² | 不支持 | 支持，需强 ETag、已知大小及持久 part / checkpoint | 不支持 | 不支持 |
| 分片上传 / 上传续传 **「未发布」** | 不支持 | 不支持 | Upload Session 顺序分片与恢复；专用构造器 opt-in，0 < 文件大小 ≤5 GiB | 不支持 |
| 传输字节进度 / 协作式取消 | 支持 | 支持 | 支持 | 支持本地复制进度；不提供云端传输百分比 |
| 完整文件物化 / lease / 进程内缓存 **「未发布」** | 支持 | 支持 | 支持 | 支持 |
| Catalog 配置与离线目录索引 | 支持 | 支持 | 支持 | 未接入 |
| 来源提供内容哈希 / 远端变更流 | 均不支持 | 均不支持 | 均不支持 | 均不支持 |

**表格说明：**

- **¹ 并发不是线程数。** `capabilities.maxConcurrentTransfers` 在低层是建议值，Transfer 将它作为各 binding 的上限输入，同时受 coordinator 的全局任务上限限制；单 materializer 构造的 coordinator 默认全局上限为 **1**，需要多文件并发时显式调高。同一 materializer 的普通下载和分片请求还共享来源 I/O 上限，但不包含 stat。不同实例或绕过入口的调用不受同一上限约束。本地来源虽声明 4，当前单实例同步复制仍在 actor 内串行执行，不能据此承诺 4 路磁盘复制；iCloud 声明 1，文件 I/O 使用串行协调队列。详见 [Transfer 调度](Docs/Transfer.md#调度进度与取消)。
- **多文件并发、分片下载与续传是三种能力。** 分片下载默认关闭，WebDAV 可通过 `.segmentedIfSupported()` / `.segmentedRequired()` 启用；默认每片 4 MiB、片并发 3、阈值 8 MiB。它不保存持久分片进度，不能与 checkpoint 恢复混用。其他网盘实现 `RemoteByteRangeSource` 后可复用公共调度与合并，见[分片下载扩展合同](Docs/Transfer.md#可插拔的单文件并行分片下载)。多连接不保证加速。
- **² 恢复入口有版本区别。** WebDAV 原有 `downloadResumable` 已提供 checkpoint；通用 `RemoteDownloadRecovery`、提交回执与合作进程锁属于未发布扩展。OneDrive Upload Session 是**顺序分片上传，不是并行上传**。当前没有通用上传调度队列；显式恢复入口也不自动加入下载 coordinator。
- **“修改内容”不是在线编辑。** 宿主先取得完整文件、自行编辑，再上传整个文件；SDK 不提供文档编辑器、局部字节写入或增量补丁。重命名与移动走独立接口。取消、超时或丢失写入响应不证明远端操作未发生，不能当作自动回滚。
- **元数据与缓存有边界。** 列表完整性以 `coverage` 为准；单页或无下一页不证明完整。文件分类只是 MIME / 扩展名提示。Catalog 只存配置和目录元数据，不存文件正文；Transfer 缓存仅在当前 materializer 生命周期内保留。来源不提供内容哈希，但 Transfer 可用宿主提供的可信 SHA-256 验证完整下载；ETag 不是内容哈希。详见 [API](Docs/API.md) 与 [Transfer](Docs/Transfer.md)。

当前均不提供自动双向同步、后台持久传输队列、跨来源直传 / 事务或通用边下边播；这些需要宿主另行实现或后续扩展。

**验收边界：** WebDAV 只有有限的真实飞牛只读验收；写入、恢复与分片下载通过本地合成服务验证，真实 NAS 写入、分片兼容性及性能待验收。OneDrive 普通写入与 Upload Session 可恢复上传通过本地合成服务测试；Upload Session 仅由专用构造器 opt-in，真实 Microsoft 账号、真实 Keychain entitlement、大文件与性能验收待完成。iCloud 仅完成临时目录及注入状态测试，真实 entitlement、占位文件和双设备验收待完成。详情见[验证状态](Docs/Validation.md)。

## 平台要求

| 项目 | 要求 |
| --- | --- |
| 工具链 | Swift tools 6.0+，Swift 6 语言模式 |
| 系统 | iOS 15+、macOS 12+、tvOS 15+、visionOS 1+ |
| 依赖 | 无第三方运行依赖；HTTP 集成测试使用系统 Python |
| Linux / Windows | 不支持；文件安全实现使用 Apple 平台与 Darwin API |

最低系统版本是声明与编译目标，不是已在所有旧系统或真机上完成运行验收的保证。

## 安装

### Xcode

添加仓库 `https://github.com/taokoplay/BoneRemoteSyncKit.git`，选择版本 **`0.3.0`**，为 App target 选择 **`BoneRemoteSyncKit`** 产品。无需再分别选择 Core 或来源产品。

### Swift Package Manager

在宿主 `Package.swift` 的相应数组中添加以下配置。示例固定使用当前发布版本 `0.3.0`；升级时显式调整版本并核对[更新说明](CHANGELOG.md)。需要跟随开发分支时，可将 `exact: "0.3.0"` 改为 `branch: "main"`。截至 2026-10-28（GMT+8），R3、Transfer 和 OneDrive Upload Session 仅在本地 Git 提交中，尚未推送；切换到远端 `main` 不会取得它们。

```swift
// Package.dependencies
.package(url: "https://github.com/taokoplay/BoneRemoteSyncKit.git", exact: "0.3.0")
```

```swift
// 宿主 target.dependencies
.product(name: "BoneRemoteSyncKit", package: "BoneRemoteSyncKit")
```

源码统一导入：

```swift
import BoneRemoteSyncKit
```

**版本策略：** 直接按当前版本 API 和数据格式接入，不将旧 API、旧序列化数据或旧检查点的向后兼容作为维护约束，也不提供跨版本迁移承诺。宿主应同步更新依赖与调用代码；分模块产品用于按需依赖，不是旧版兼容层。文件元数据与传输修复包含在 `v0.2.0`，不属于 `v0.1.0`；使用 `main` 时，其内容可能领先于最新版本标签。

## 快速上手

### 1. 连接并浏览

下面的函数适用于四个现有来源，在同一连接中读取根目录的全部页面，并在成功和异常路径等待断开。它适合大小可控的目录；大型目录应使用[逐页消费或有界遍历](Docs/API.md)，避免累积全部结果。

```swift
import Foundation
import BoneRemoteSyncKit

func readRootDirectory(
    from source: any RemoteSource,
    credential: RemoteCredential
) async throws -> [RemoteEntry] {
    do {
        try await source.connect(credential)
        var entries: [RemoteEntry] = []
        var request = RemoteListRequest(limit: 100)
        while true {
            let page = try await source.list(path: "/", request: request)
            entries.append(contentsOf: page.entries)
            guard let cursor = page.nextCursor else { break }
            request = request.nextPage(cursor: cursor)
        }
        await source.disconnect()
        return entries
    } catch {
        await source.disconnect()
        throw error
    }
}
```

来源与凭据的选择：

| 来源 | 创建方式 | 连接凭据 |
| --- | --- | --- |
| 本地目录 | `LocalFileSource(root: directoryURL)` | `.anonymous`；目录已存在且宿主有权限 |
| iCloud Drive | `ICloudDriveSource(configuration: configuration)` | `.anonymous` 使用系统账号；宿主配置 entitlement 和容器，见 [iCloud 指南](Docs/ICloudDrive.md) |
| WebDAV | `try WebDAVSource(baseURL: collectionURL)` | `.anonymous` 或 `.basic(username:password:)`；优先 HTTPS |
| OneDrive | `OneDriveSource(configuration: configuration, onTokenRefresh: persistToken)` | OAuth token；首次授权和刷新持久化见 [OneDrive 指南](Docs/OneDrive.md) |

表中的 URL、配置和 token 保存回调由宿主提供，不是库内全局变量。`/` 总是指当前来源的根，而不是服务器或本机的系统根。

### 2. 上传与下载

以下函数在一个**已连接**的可写来源上创建父目录、非覆盖上传，再下载到本地新目标。外层调用方负责 `disconnect()`；路径需由调用方明确授权。

```swift
import Foundation
import BoneRemoteSyncKit

func transferFile(
    using source: any RemoteWritableSource,
    localFile: URL,
    downloadDestination: URL
) async throws -> RemoteEntry {
    try await source.makeDirectory(path: "/demo")
    let uploaded = try await source.upload(
        from: localFile,
        to: "/demo/report.txt",
        options: .init(overwrite: false, contentType: "text/plain")
    )
    _ = try await source.download(
        uploaded,
        to: downloadDestination,
        options: .init(overwrite: false)
    )
    return uploaded
}
```

上传成功但下载失败时，远端上传文件可能已存在；这不是一个可回滚事务。`overwrite` 默认是 `true`，示例显式关闭覆盖。

### 3. 按能力调用

- `RemoteSource`：连接、浏览、查询、下载与遍历扩展。
- `RemoteWritableSource`：增加上传、建目录、删除、移动。
- `RemoteCopyingSource`：增加来源内复制。

本地、iCloud 与 WebDAV 遵循 `RemoteCopyingSource`，OneDrive 遵循 `RemoteWritableSource` 和 `RemoteIDAddressableSource`。UI 可读取 `capabilities` 决定展示哪些入口，执行时仍需处理权限、冲突及服务端错误。OneDrive 的稳定 ID 读取不等于支持按 ID 写入。

## 接入前需要了解

- **覆盖与父目录：** WebDAV、OneDrive 上传要求父目录存在；本地和 iCloud 上传可自动创建。WebDAV 覆盖已有文件要求强 ETag，缺失或弱 ETag 会拒绝覆盖。使用 `expectedETag` 做条件上传时只有 WebDAV 支持；其他来源明确拒绝。各来源的[写入语义](Docs/API.md#写入与失败语义)不可互换。
- **远端写入不能回滚：** 取消、超时或丢失响应不证明操作未发生。WebDAV 写请求不自动重试；不要只根据 `isRetryable` 重放写入或补偿删除。
- **授权由宿主管理：** SDK 不包含登录界面或账号选择。Catalog 提供可选 Keychain 桥接；直接使用来源模块时仍由宿主保存凭据。不要记录密码、token、授权回调或预授权下载 URL。
- **文件信息与分类：** `RemoteEntry.createdAt` 返回来源报告的创建时间，缺失为 nil；`fileCategory` 按 MIME/扩展名给出图片、音频、视频、文档等提示，不解析文件内容、EXIF 或音视频时长。见[元数据 API](Docs/API.md#文件时间与类型分类)。
- **传输完整性不是内容相同证明：** ETag 是版本标识，不保证为内容哈希；`size`、`modifiedAt` 或 `hasReliableFingerprint` 不能代替内容比对。
- **文件权限与并发：** sandbox、security-scoped URL 和跨实例／跨进程目标独占由宿主负责；路径校验不构成防恶意 TOCTOU 的文件系统 sandbox。
- **iCloud 是文件来源而非同步引擎：** 使用独立 `ICloudDriveSource`，不要用本地来源替代；本地写入成功不等于云端上传完成。Catalog 暂未纳入 iCloud，冲突仅检测并拒绝，不自动选版。

## 详细文档

| 文档 | 内容 |
| --- | --- |
| [业务能力与适用场景](Docs/UseCases.md) | 能构建哪些业务、典型流程、模块选择、宿主职责与不适用范围 |
| [更新说明](CHANGELOG.md) | 版本功能、缺陷修复、版本策略与行为变化、已知限制 |
| [文件物化、前台调度与恢复传输](Docs/Transfer.md) | 未发布：本地文件 lease、缓存复用、有界下载队列、可插拔分片下载、WebDAV 恢复下载与 OneDrive 恢复上传 |
| [配置持久化与离线目录索引](Docs/Catalog.md) | 非敏感配置、Keychain 桥接、根选择、目录/子树刷新与恢复 |
| [通用 API 与生命周期](Docs/API.md) | 模块、协议、路径、分页、遍历、错误、进度与宿主职责 |
| [本地目录](Docs/Local.md) | 本地读写、落盘、符号链接和权限边界 |
| [iCloud Drive](Docs/ICloudDrive.md) | entitlement、容器、占位下载、协调、状态与真机验收边界 |
| [WebDAV](Docs/WebDAV.md) | 连接、文件管理、条件覆盖、重试、Range 与 checkpoint 恢复 |
| [OneDrive Personal](Docs/OneDrive.md) | OAuth/PKCE、token 刷新、分页、安全下载、普通写入及 opt-in Upload Session |
| [未支持来源开发计划](Docs/CloudDriveRoadmap.md) | Google Drive、Dropbox、SMB、SFTP、FTP/FTPS、NFS 与区域性网盘的分阶段路线图 |
| [构建与验证状态](Docs/Validation.md) | 构建命令、验证记录、真实服务验收边界与待办方向 |
| [WebDAV 完整示例](Examples/WebDAVReadWrite/README.md) | 读写操作生命周期及真实 NAS 验收清单 |
| [OneDrive 宿主示例](Examples/OneDriveReadOnly/README.md) | 授权事务管理、读路径及账号验收清单 |

## 构建与测试

```bash
swift build
swift test
swift build -c release
```

HTTP 集成测试在 macOS 上运行，需要 `/usr/bin/python3`（Python 3.8+，仅标准库），只访问本机临时 fixture。生产模块不依赖 Python。

截至 **2026-10-27（GMT+8）**，`v0.3.0` 所含实现最终串行全包 **392 项测试通过**，Release、独立 Kit 消费端、七模块及 iCloud 示例的四目标编译/链接检查通过；指南 3 个 Swift 片段四目标类型检查通过。这些结果不等于真实服务兼容性、最低 OS 真机或云端传播验收。

截至 **2026-10-28（GMT+8）**，当前未发布工作树最近一轮分片下载实现验证为 **506 项全包测试通过**，另通过 Release、八模块四目标编译链接及独立 Kit 分片消费端检查；此前恢复传输另有受控跨进程验证。这些是已有实现验证记录，本次介绍表格更新未重跑实现测试，不代表真实账号、Keychain、最低系统运行或大文件性能已验收。

发布版本结果见 [v0.3.0 验证](Docs/Validation.md#v030-icloud-备份-r1r2-验证)，当前开发能力见[分片下载验证](Docs/Validation.md#未发布可插拔单文件并行分片下载)与[阶段5上传验证](Docs/Validation.md#未发布阶段5-onedrive-upload-session-验证)。历史 WebDAV 并发短 deadline 风险仍保留；旧 `v0.1.0`、`v0.2.0` 标签不变，不包含后续新增功能。

### 错误日志

`v0.3.0` 提供可注入的结构化 `RemoteLogger`，默认不输出、不落盘；数据库初始化与 Catalog 高层操作已接入。直接使用来源模块可在宿主调用边界复用，详见[错误日志规范](Docs/Logging.md)。不要直接记录包含路径或底层消息的原始错误描述。
