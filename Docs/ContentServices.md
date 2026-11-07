# Komga、Kavita 与 Audiobookshelf 原生接入

[首页](../README.md) · [通用 API](API.md) · [Transfer](Transfer.md) · [验证记录](Validation.md)

三个原生适配器已包含在推送的开发提交 `fe8cfc2` 中，尚未纳入版本标签，最新标签仍为 `v0.8.2`。通过 `import BoneRemoteSyncKit` 接入，或按需依赖独立产品；统一来源枚举的新 API 需当前工作区，见[版本对照](../README.md#开发源码与版本范围)。三个原生适配器仅依赖 Core、共享 Content 与 Apple 系统框架，无第三方运行依赖。

## 服务与能力

| 能力 | Komga | Kavita | Audiobookshelf |
| --- | --- | --- | --- |
| 模块 / 来源 | `BoneRemoteSyncKomga` / `KomgaSource` | `BoneRemoteSyncKavita` / `KavitaSource` | `BoneRemoteSyncAudiobookshelf` / `AudiobookshelfSource` |
| 认证 | HTTP Basic、`X-API-Key` | 账号密码登录、API key、JWT | 账号密码登录、Bearer API/access token |
| 身份核对 | `users/me`，可固定用户 ID | `Account`，可固定整数用户 ID | `api/me`，可固定用户 ID |
| 内容模型 | 书库 → 系列 → 书籍 | 书库 → 系列 → 卷 → 章 | 书库 → 书籍或播客 → 音轨/节目 |
| 分页 / 搜索 | 原生系列/书籍分页与全文搜索 | 原生系列分页与搜索、Pagination header | 条目分页；搜索按书籍/播客分类，无搜索游标 |
| 图片 | 系列/书籍封面、逐页图片 | 封面、逐页图片与缩略图 | 条目封面 |
| 完整文件 | 书籍原文件 | 单文件章节原件；多文件/图片章节 ZIP | 显式选择具体文件或音轨，不自动拼接 |
| 用户进度 | 页数、已读/重置、EPUB Readium locator | 页数、EPUB 阅读顺序与 XPath | 收听时间/比例/完成状态，书籍或节目 |
| 播放会话 | 不适用 | 不适用 | 创建、增量同步、关闭、认证直放音轨请求 |
| Transfer | 支持 | 支持 | 支持；直放会话另行管理 |
| 文件目录 `list/walk` / Catalog | 不提供 | 不提供 | 不提供 |

完整方法、语义与宿主示例分别见 [Komga](Komga.md)、[Kavita](Kavita.md)、[Audiobookshelf](Audiobookshelf.md)。它们直接调用各自原生 API；既有 [OPDS](OPDS.md) 继续用于支持 OPDS 1.2 的书目服务。

跨来源界面可使用新增的 [统一 Browser](Browser.md)：先连接原 source，再通过 `.komga` / `.kavita` / `.audiobookshelf` 工厂得到 `RemoteBrowser`，后续统一调用 browse/search/details/artwork/downloadOptions/prepareDownload。通用快照可编码；原生阅读位置和播放仍通过 nativeReference 与同一 source 显式操作。此层也覆盖 OPDS 和文件来源，不把书库变成可写文件树。

## 配置与连接

`KomgaConfiguration`、`KavitaConfiguration`、`AudiobookshelfConfiguration` 均为 `ContentServerConfiguration` 的别名。

```swift
import Foundation
import BoneRemoteSyncKit

func listKomgaLibraries(baseURL: URL, apiKey: String) async throws -> [KomgaLibrary] {
    let configuration = try ContentServerConfiguration(
        baseURL: baseURL,
        timeout: 60,
        maxConcurrentRequests: 3,
        requestInterval: 0.2
    )
    let source = KomgaSource(configuration: configuration)
    do {
        try await source.connect(.apiToken(apiKey))
        let libraries = try await source.libraries()
        await source.disconnect()
        return libraries
    } catch {
        await source.disconnect()
        throw error
    }
}
```

`baseURL` 是规范服务根，例如 `https://books.example/komga/`，不应附加 `/api/v1`、token、用户名或密码。保留反向代理子路径，拒绝路径穿越、跨 origin 和挂载路径之外的响应链接；请求不跟随重定向。HTTPS 默认必需，LAN/测试明确使用 HTTP 时传 `allowsInsecureHTTP: true`；这不替代宿主 ATS 配置。

| 参数 | 默认 | 约束与含义 |
| --- | --- | --- |
| `timeout` | 60 秒 | 正有限值、最大 86400；单次 HTTP 操作总时间，包含请求间隔等待，取消后排空网络回调再返回 |
| `maxConcurrentRequests` | 3 | 1...8；同一连接中的元数据/图片/下载及已接纳等待共同计数，超额立即返回 `rateLimited` |
| `requestInterval` | 0 秒 | 有限 0...86400；同一连接请求放行最小间隔，0 不延迟；与并发上限独立 |
| `maxResponseBytes` | 8 MiB | 1 KiB...32 MiB；元数据和图片内存上限，完整文件流式写入，不受此内存上限限制 |
| `maxDownloadReferences` | 256 | 1...4096；同一连接可登记的下载引用数，达到上限返回 `resourceLimit`；重连清空 |

一个高层调用可能依次发出多个请求，每个请求各自受 timeout 约束，不把它视为整个书库扫描的总预算。分页页码统一从 0 开始，大小 1...500；分页期间远端仍可能变化，不能把某页缺项当作删除证据。

首次连接后宿主保存核对过的用户 ID，后续传入 `expectedUserID` 防止误连账号。凭据由宿主保护保存；配置 Codable 不包含凭据。Kavita 的显式刷新与 Audiobookshelf 的令牌重新连接详见各自指南。SDK 不自动重放进度写入或会话创建。

## 文件获取与生命周期

1. 用原生浏览接口选定书籍、章节或实际音轨/文件。
2. 调用服务的 `prepareDownload`，取得会话内 `RemoteFileReference`。
3. 用同一连接的 `sourceBinding()` 创建 `RemoteFileMaterializer`，直接物化或通过 `RemoteTransferCoordinator` 调度。
4. 在 `lease.withAccess` 中消费完整文件；异步播放器继续读取时应保留 lease，读取结束再释放。
5. 结束任务时先关闭 coordinator/materializer，再断开来源；重连后重新取得引用和 binding。

登记引用不包含服务端 URL/token；不能持久化后跨连接使用，也不能把服务端的本地文件路径手工拼成下载 URL。`stat` 返回登记描述，未知大小保持 nil。文件元数据不提供强版本：不能把书籍更新时间、阅读位置、服务端哈希字段或播放 session ID 当作文件 ETag。

下载流式写入私有临时文件，检查响应、已知大小和文件身份，再原子安装；失败或取消保留旧目标，拒绝符号链接/多硬链接目标。支持进度、取消及完整文件 lease；不支持 `resumeFrom`、`expectedETag`、Range 分片、持久恢复或后台传输。三者没有文件上传、移动、删除或管理员书库操作能力。

## 阅读与播放状态

用户进度由宿主显式写入。下载、浏览和读取封面不会自动标记已读或已听。Komga 页面从 1 开始；Kavita 图片从 0 开始，阅读进度允许完成位置；EPUB 位置应使用各服务原生模型，不能把 CFI、XPath、页码和百分比混用。并发设备的冲突策略由宿主决定。

Audiobookshelf 的 `createPlaybackSession` 返回直接播放音轨、时间偏移和 `ContentStreamRequest`。宿主播放器执行这些请求，并按实际播放提交 `timeListened` 增量，退出播放时显式关闭会话。SDK 不含播放器、解码、HLS/转码、后台音频或 DRM。

`ContentStreamRequest` 有意包含认证 headers，不可记录、持久化或转发到其他主机。其普通描述已脱敏，但宿主仍可读取 URL/headers；宿主负责播放器的重定向、Range、缓存和凭据生命周期。断开 SDK 来源不能撤回已交给宿主的请求，需同时停止播放器并丢弃旧请求。

写入超时、取消或连接中断时，服务端可能已完成修改；宿主应查询权威状态，不应凭本地失败自动重放。`disconnect()` 清理本地连接，不暗中提交阅读进度或关闭远端播放会话。

## 官方合同与验收边界

| 服务 | 核对版本 | 固定官方代码 |
| --- | --- | --- |
| Komga | 1.30.0 | [ff800c2](https://github.com/gotson/komga/tree/ff800c21253793d4d3fd855651b82d4924915950) |
| Kavita | v0.9.1.4 | [879b8b7](https://github.com/Kareadita/Kavita/tree/879b8b73eb41d66f88dde8eb874cc99a3397eb11) |
| Audiobookshelf | v2.37.2 | [edb1f7e](https://github.com/advplyr/audiobookshelf/tree/edb1f7efc92ecacdef51aafb4d9d5054ce10604f) |

本地测试使用虚构账号与合成媒体，仅监听 loopback，检查请求合同、恶意响应、账号/会话隔离、下载目标保护和取消。本轮没有真实部署地址或账号；真实服务的授权组合、代理/TLS、媒体格式、播放器 codec、最低系统与大文件性能仍待接入验收。具体已执行检查以 [验证记录](Validation.md) 为准。
