# BoneRemoteSyncKit

**面向 Apple 平台的 Swift 文件访问 SDK，以统一 API 连接本地目录、iCloud Drive、WebDAV 和 OneDrive Personal。**

一次 `import BoneRemoteSyncKit`，即可使用目录浏览、文件上传与下载、目录创建、移动、删除及按来源提供的复制能力。基于 Swift Concurrency，无第三方运行依赖。

> 当前版本为 **`v0.3.0`**，包含 [Catalog 配置持久化与目录缓存](Docs/Catalog.md)、结构化日志、[iCloud Drive 来源及备份 R1/R2 契约](Docs/ICloudDrive.md)、OneDrive 稳定 ID 与条件上传等通用文件语义。相对 `v0.2.0` 的变化及迁移要求见[更新说明](CHANGELOG.md)；真实账号与云端验收边界仍保留。

> 当前提供文件访问与传输能力，**不包含自动同步引擎**。SMB 和其他网盘适配器尚未实现；iCloud Drive 来源已新增，真实云端验收待完成。接口统一不代表每个来源的能力与失败语义完全相同。

[安装](#安装) · [快速上手](#快速上手) · [能力矩阵](#能力矩阵) · [更新说明](CHANGELOG.md) · [详细文档](#详细文档) · [验证状态](Docs/Validation.md)

## 适用场景

- 为 App 接入本地文件夹、iCloud 容器、WebDAV NAS 或 OneDrive Personal 主盘。
- 用统一条目、路径、错误和能力声明构建文件浏览与传输界面。
- 作为上层备份或同步功能的来源层；调度、快照比较与冲突策略由宿主实现。

不提供系统磁盘挂载、File Provider 扩展、后台传输调度或跨来源事务。

## 能力矩阵

下表表示当前实现范围，不代表账号权限或任意服务端兼容性。

| 能力 | 本地目录 | WebDAV | OneDrive Personal | iCloud Drive |
| --- | --- | --- | --- | --- |
| 浏览目录、文件信息、递归遍历 | 支持 | 支持 | 支持 | 支持，见列表完整性边界 |
| 可选创建时间、文件类型分类提示 | 支持 | 取决于服务端属性 | 取决于 Graph 条目属性 | 支持，本机元数据 |
| 游标分页 | 不支持，返回单层结果 | 不支持，返回单层结果 | 支持 | 不支持，返回单层结果 |
| 文件下载 | 支持 | 支持 | 支持 | 协调读取，触发占位下载 |
| 手动下载续传 | 支持 | 需要强 ETag 与 Range 支持 | 不支持 | 支持，本地启发式指纹 |
| checkpoint / 跨进程下载恢复 | 不支持 | 需要强 ETag 与已知大小 | 不支持 | 不支持 |
| 文件上传 | 支持 | 完整 PUT | Simple upload，最大 250 MiB | 本地原子写入，不等待云端上传 |
| 递归创建目录、删除、移动／重命名 | 支持 | 支持 | 支持 | 支持，使用文件协调 |
| 来源内文件／目录复制 | 支持 | 服务端 COPY | 不支持 | 仅文件，不支持目录复制 |
| 上传续传 | 不支持 | 不支持 | 不支持 | 不支持 |
| 变更流、对外内容哈希 | 不支持 | 不支持 | 不支持 | 不支持 |

当前开发 API 的列表完整性以 `coverage` 为准；单页和无下一页都不自动证明目录完整，见 [API](Docs/API.md)。

**验收边界：** WebDAV 只有有限的真实飞牛只读验收；写入和恢复能力通过本地合成服务验证，真实 NAS 写入待验收。OneDrive 通过本地合成服务测试，真实 Microsoft 账号验收待完成。iCloud 仅完成临时目录及注入状态测试，真实 entitlement、占位文件和双设备验收待完成。详情见[验证状态](Docs/Validation.md)。

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

在宿主 `Package.swift` 的相应数组中添加以下配置。示例固定使用当前发布版本 `0.3.0`；升级时显式调整版本并核对[更新说明](CHANGELOG.md)。需要跟随开发分支时，可将 `exact: "0.3.0"` 改为 `branch: "main"`。

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
| [更新说明](CHANGELOG.md) | 版本功能、缺陷修复、版本策略与行为变化、已知限制 |
| [配置持久化与离线目录索引](Docs/Catalog.md) | 非敏感配置、Keychain 桥接、根选择、目录/子树刷新与恢复 |
| [通用 API 与生命周期](Docs/API.md) | 模块、协议、路径、分页、遍历、错误、进度与宿主职责 |
| [本地目录](Docs/Local.md) | 本地读写、落盘、符号链接和权限边界 |
| [iCloud Drive](Docs/ICloudDrive.md) | entitlement、容器、占位下载、协调、状态与真机验收边界 |
| [WebDAV](Docs/WebDAV.md) | 连接、文件管理、条件覆盖、重试、Range 与 checkpoint 恢复 |
| [OneDrive Personal](Docs/OneDrive.md) | OAuth/PKCE、token 刷新、分页、安全下载和写入限制 |
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

本轮专项与完整结果见[验证状态](Docs/Validation.md#v030-icloud-备份-r1r2-验证)。历史 WebDAV 并发短 deadline 风险仍保留；旧 `v0.1.0`、`v0.2.0` 标签不变，不包含本版本新增功能。

### 错误日志

`v0.3.0` 提供可注入的结构化 `RemoteLogger`，默认不输出、不落盘；数据库初始化与 Catalog 高层操作已接入。直接使用来源模块可在宿主调用边界复用，详见[错误日志规范](Docs/Logging.md)。不要直接记录包含路径或底层消息的原始错误描述。
