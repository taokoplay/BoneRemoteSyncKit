# 统一浏览层

[首页](../README.md) · [通用 API](API.md) · [内容服务](ContentServices.md) · [Transfer](Transfer.md) · [完整示例](../Examples/UnifiedBrowser/README.md)

`BoneRemoteSyncBrowser` 将文件网盘、OPDS、Komga、Kavita、Audiobookshelf 的浏览结果转换为同一组展示类型，由 Kit 导出。Browser 已包含在推送的开发提交 `fe8cfc2` 中，尚无版本标签；`v0.8.2` 不包含它。本页使用的统一来源枚举仍为工作区改动，详见[版本对照](../README.md#开发源码与版本范围)。

原生来源负责认证和实际 API；Browser 负责展示模型、分页、详情、封面、下载选择和错误分类；Transfer 负责完整文件下载与 lease。Browser 不实现登录、文件写操作、后台队列、Catalog 索引、阅读器或播放器。

按接入顺序阅读：[安装](#安装与导入) → [选择来源与凭据](#来源配置与凭据) → [完整流程](#从连接到文件消费) → [页面操作](#页面操作步骤) → [下载进度与取消](#下载进度与取消) → [原生阅读与播放](#原生阅读与播放示例) → [问题排查](#常见问题与错误处理)。

## 安装与导入

要完整使用本页的统一来源枚举示例，先依赖当前本地工作区。在 Xcode 中通过 **File → Add Package Dependencies → Add Local…** 选择 `BoneRemoteSyncKit` 目录，再将 `BoneRemoteSyncKit` 产品加入宿主 target。已推送 `main` 的 `fe8cfc2` 提供 Browser 本身，但仍使用统一枚举前的来源标识；固定 `0.8.2` 没有 Browser。

SwiftPM 宿主若与 SDK 目录同级，可以使用以下完整清单；目录不同则调整 `path`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserDemo",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../BoneRemoteSyncKit")],
    targets: [
        .executableTarget(
            name: "BrowserDemo",
            dependencies: [.product(name: "BoneRemoteSyncKit", package: "BoneRemoteSyncKit")]
        )
    ]
)
```

将程序放在 `Sources/BrowserDemo/`，业务代码使用 `import Foundation`、`import BoneRemoteSyncKit`。SDK 支持 Swift 6 语言模式以及 macOS 12、iOS/tvOS 15、visionOS 1；iOS 等 App 在 Xcode target 中配置对应部署版本。

`RemoteBrowser` 等是 SDK API；下文的 `BrowserConnectionExamples`、`visitBrowserPages`、`consumeBrowserDownload` 等是**示例辅助代码**，不随 `import` 自动出现。使用它们时，将 [BrowserConnectionExamples.swift](../Examples/UnifiedBrowser/BrowserConnectionExamples.swift) 与 [UnifiedBrowserExample.swift](../Examples/UnifiedBrowser/UnifiedBrowserExample.swift) **一起加入宿主 target**，或将所需函数复制到自己的服务层。

Browser 独立产品可供按需依赖；若同时需要各来源配置和 Transfer，优先选择 Kit，避免漏配产品。

## 选择显示哪些网盘和书库

所有入口共用 `RemoteSourceKind`，接入方决定白名单，不需要字符串 ID 或额外提供方枚举：

```swift
func enabledBrowserSources() -> [BoneRemoteSyncSourceType] {
    let enabled: Set<RemoteSourceKind> = [.webdav, .oneDrive, .baidu, .opds, .komga]
    return BoneRemoteSyncIcons.sourceTypes().filter {
        enabled.contains($0.kind) && $0.kind.hasBuiltInAdapter
    }
}
```

只展示六项网盘图标目录中的部分时，用同样的集合过滤 `driveTypes()`；这里每项 `id` 和 `kind` 也都是 `RemoteSourceKind`。只选 `.oneDrive` 不会选中 `.googleDrive` 或 `.aliyun`。用户选择后才创建对应来源并连接，显示列表本身不访问网络。

需要按产品顺序展示时，使用数组而非 Set，例如 `[RemoteSourceKind.oneDrive, .webdav, .komga].map { BoneRemoteSyncSourceType(kind: $0) }`。显示名称可覆盖为宿主本地化文案；图标枚举只负责资源。`hasBuiltInAdapter` 不表示已授权或所有操作可用；枚举中预留但未实现的来源不会因有图标而获得连接能力。

从旧 `.cloudAPI` 或字符串目录 ID 升级时，请同步更新白名单、绑定/快照与恢复记录，见 [API 升级说明](API.md#来源枚举升级)。可复制的 `browserSourceChoices` 函数见 [通用示例](../Examples/UnifiedBrowser/UnifiedBrowserExample.swift)。

## 创建与使用

先按来源完成连接，再创建一个 Browser：

| 已连接来源 | 创建方法 |
| --- | --- |
| Local / iCloud / WebDAV / OneDrive / 百度，或实现文件协议的自定义来源 | `try RemoteBrowser.files(source, binding: binding)` |
| OPDS | `try await RemoteBrowser.opds(source)` |
| Komga | `try await RemoteBrowser.komga(source)` |
| Kavita | `try await RemoteBrowser.kavita(source)` |
| Audiobookshelf | `try await RemoteBrowser.audiobookshelf(source)` |

文件来源必须具备 `list/stat` 能力；提供的 binding.kind 必须匹配来源。`rootPath` 可设置浏览起点，默认 `/`，它不是新的授权根或访问沙盒。OneDrive/百度应使用原来源的 `connectedBinding()`，不随意重新拼接。

### 来源配置与凭据

九种连接方法的完整成功/失败清理代码在 [连接示例](../Examples/UnifiedBrowser/BrowserConnectionExamples.swift)。以下名称均指该示例枚举的方法：

| 来源 | 示例方法与输入 | 凭据 / 接入前提 |
| --- | --- | --- |
| 本地 | `.local(root:)`，用户选定的目录 URL | `.anonymous`；根目录须已存在，宿主持有 sandbox/security-scoped 授权 |
| iCloud | `.iCloud(configuration:)`，`ICloudDriveConfiguration` | `.anonymous` 使用系统账号；宿主配置 entitlement 和容器，见 [iCloud](ICloudDrive.md) |
| WebDAV | `.webDAV(baseURL:credential:)`，collection URL | `.anonymous` 或 `.basic(username:password:)`；见 [WebDAV](WebDAV.md) |
| OneDrive | `.oneDrive(configuration:credential:persistRefreshedToken:)` | `OneDriveToken.credential`，需要先完成宿主 OAuth；回调安全保存轮换令牌；限 Personal 主盘，见 [OneDrive](OneDrive.md) |
| 百度 | `.baidu(configuration:credential:expectedUserID:refresh:)` | `BaiduDriveToken.credential` 或 API token；已授权应用目录，SecretKey 留在宿主后端，见 [百度](BaiduDrive.md) |
| OPDS | `.opds(configuration:credential:)`，`OPDSConfiguration(rootURL:)` | `.anonymous` 或 HTTP Basic；URL 指向实际 Feed，见 [OPDS](OPDS.md) |
| Komga | `.komga(configuration:credential:expectedUserID:)` | `.basic` 为邮箱/密码 HTTP Basic，`.apiToken` 为 API key；见 [Komga](Komga.md) |
| Kavita | `.kavita(configuration:credential:expectedUserID:)` | `.basic` 为账号 JSON 登录，`.apiToken` 为 API key，`.oauth` 为已有 JWT；用户 ID 是 Int，见 [Kavita](Kavita.md) |
| Audiobookshelf | `.audiobookshelf(configuration:credential:expectedUserID:)` | `.basic` 为账号 JSON 登录，`.apiToken` 为 Bearer；用户 ID 是 String，见 [Audiobookshelf](Audiobookshelf.md) |

三种原生内容服务的配置均基于 `ContentServerConfiguration`：`baseURL` 使用服务根并保留反代挂载点，例如 `https://books.example/kavita/`，不要附加 `/api` 或 `/api/v1`。OPDS 使用实际 Feed 地址，WebDAV 使用 collection 地址。配置默认要求的安全策略、局域网 HTTP opt-in 和 App ATS 是不同层次，按各来源指南配置。

首次连接成功后，可记录原生来源返回的用户 ID；后续用 `expectedUserID` 防止误连账号。不要把 API key、Bearer、OAuth 回调 URL 或播放器认证请求写入普通配置/日志。Browser 工厂不会替宿主弹出登录界面或刷新凭据。

### binding 怎么提供

| 场景 | 正确做法 |
| --- | --- |
| 一次独立 Local/WebDAV/iCloud 连接 | 像连接示例一样生成 `RemoteSourceBinding(kind: source.kind, identity: UUID().uuidString)`，只用于本次来源会话及 Transfer |
| OneDrive / 百度 | 连接后调用 `source.connectedBinding()`；示例将同一方法作为 `validateBinding` 回调 |
| 使用了 Catalog 的 App | Catalog 固定扫描会话是内部实现，没有公开可直接借用的 source/binding；离线文件列表走 Catalog，在线 Browser 由宿主另外建立来源连接并管理凭据/权限，见 [Catalog](Catalog.md) |
| OPDS / 三种内容服务 | 由对应 Browser 工厂读取 `sourceBinding()`，不要自己拼接 |

OneDrive/百度的 `connectedBinding()` 描述盘或账号/根范围，不是每次连接都改变的 generation；同账号重连可能返回相同 binding。回调不能检测这种重连，宿主仍必须关闭旧 Browser 并重建。`kind` 或 `displayName` 都不能单独作为多账号 binding。
Catalog 与 Browser 不会自动共享运行中的连接，也没有通过 profileID 直接创建 Browser 的工厂。`RemoteSourceProfile.permission` 只约束 Catalog 受控会话；独立 Browser 的文件来源需要宿主按同等策略限制访问，不能假设权限自动继承。共享同一可轮换凭据的多个实例还需宿主协调，避免同时刷新。


下面的完整函数演示 Komga 第一层浏览；其他工厂返回相同类型，后续页面代码无需服务分支：

```swift
import Foundation
import BoneRemoteSyncKit

func librarySnapshots(
    configuration: KomgaConfiguration,
    credential: RemoteCredential
) async throws -> [RemoteBrowseSnapshot] {
    let source = KomgaSource(configuration: configuration)
    var browser: RemoteBrowser?
    do {
        try await source.connect(credential)
        let session = try await RemoteBrowser.komga(source)
        browser = session
        let page = try await session.browse(pageSize: 50)
        let snapshots = page.items.map(\.snapshot)
        await session.close()
        await source.disconnect()
        return snapshots
    } catch {
        await browser?.close()
        await source.disconnect()
        throw error
    }
}
```

该函数仅返回第一页展示快照。实际 UI 应保留 Browser 和 live item，按 `nextCursor` 加载后续页，不在每次翻页后断开。完整的页面加载、用户选择文件和 Transfer 清理函数见 [UnifiedBrowserExample.swift](../Examples/UnifiedBrowser/UnifiedBrowserExample.swift)。

## 从连接到文件消费

以下函数使用前面两个示例文件，以本地文件为例展示完整生命周期。`choose` 由宿主实现：可以调用 Browser 浏览多层目录、加载下一页，再返回用户选中的下载选项；用户取消时返回 nil。`consume` 必须等读取真正结束后才返回。

```swift
func browseLocalAndConsume(
    root: URL,
    cacheDirectory: URL,
    choose: @Sendable (RemoteBrowser) async throws -> RemoteBrowseDownload?,
    consume: @escaping @Sendable (URL) async throws -> Void
) async throws {
    let (source, browser) = try await BrowserConnectionExamples.local(root: root)
    do {
        if let selected = try await choose(browser) {
            try await consumeBrowserDownload(
                browser: browser, selection: selected,
                cacheDirectory: cacheDirectory, consume: consume
            )
        }
        await browser.close()
        await source.disconnect()
    } catch {
        await browser.close()
        await source.disconnect()
        throw error
    }
}
```

这里的缓存目录由宿主管理，应是 App 私有的普通本地目录，与来源根、同步目录分离。`consumeBrowserDownload` 会等待 coordinator/materializer 清理后返回；若读取器在函数返回后继续读取 URL，应改成宿主持有 `MaterializedFileLease`，并在读取器关闭后 `release()`。长期保存或编辑文件时，将内容复制到宿主自己的目录。

切换成其他来源只需使用对应连接示例；保存 typed source 供原生进度或播放操作使用。已有来源连接的 App 可以直接调用 `RemoteBrowser` 工厂，不必再调用连接辅助函数。

## 页面操作步骤

1. **首次进入**：`browser.browse(pageSize: 50)` 获取根页面。保存完整 `RemoteBrowseItem` 供后续操作，使用 `item.id` 做当前会话内的列表 diff。
2. **进入子层**：仅对 `item.capabilities.contains(.browse)` 的条目调用 `browser.browse(in: item)`。父导航栈由宿主保存；Browser 不维护 UI 路由或返回按钮。
3. **加载更多**：原样传 `page.nextCursor` 给 `nextPage`。一次只推进一个 cursor；如果返回空 items 但仍有 cursor，应允许继续，而不是直接当作结束。
4. **刷新或切换范围**：重新调用 browse/search 首页面并替换当前列表和 cursor。取消旧加载任务，使用宿主请求序号丢弃迟到的旧响应；不要把旧范围下一页追加到新列表。
5. **搜索**：使用支持 `.search` 的当前 parent；Komga 可从根搜书，Kavita/Audiobookshelf 必须先选库。搜索下一页仍用 `nextPage`，不能自行给页号加一。
6. **查看内容**：调用 `details(for:)` 后以返回的新 item 更新展示及能力提示；封面和下载选项分别请求，避免一个封面 404 阻塞阅读内容。

搜索函数示例，不把不支持的搜索静默变成目录扫描：

```swift
func searchBrowserScope(
    browser: RemoteBrowser, parent: RemoteBrowseItem?, query: String
) async throws -> RemoteBrowsePage {
    let capabilities = parent?.capabilities ?? browser.capabilities
    guard capabilities.contains(.search) else {
        throw RemoteBrowserError(code: .unsupported)
    }
    return try await browser.search(query, in: parent, pageSize: 50)
}
```

`visitBrowserPages` 示例可在不累积整个结果的情况下逐页回调，支持当前层与当前搜索结果；默认最多 100 页。达到预算仍有下一页时抛 `UnifiedBrowserExampleError.pageBudgetExceeded`，不会返回“已完整加载”。它不递归展开系列或文件夹，分页完整性仍以各页 coverage 和来源合同为准。

### 详情、封面与下载选择

```swift
func browserDownloadChoices(
    browser: RemoteBrowser, item: RemoteBrowseItem
) async throws -> [RemoteBrowseDownload] {
    let detail = try await browser.details(for: item)
    return try await browser.downloadOptions(for: detail)
}
```

调用方将全部选项交给用户选择，可展示 `title`、`filename`、`contentType`、`size`、`kind`。未知大小显示“未知”，不要填 0；没有选项表示当前条目/权限/格式无法直接下载，不要再拼接原生 URL。不要把列表标题或 `id.value` 当下载定位器。先展示 `downloadOptions`，只对最终选定项调用一次 `prepareDownload`，避免消耗会话下载引用预算。

封面入口为 `browser.artwork(for: detail)`：nil 表示没有可用入口/链接；notFound 可显示占位图；认证、限流等错误应按各自分类处理。返回 Data 未保证图片已经解码，也未净化 SVG；用宿主图片解码器显示，不直接执行远端内容。`loadBrowserSelection` 是串行加载详情、封面、下载选项的简化示例，UI 可按需要拆分。


## 公共接口

| 方法 / 属性 | 结果与行为 |
| --- | --- |
| `browse(in:pageSize:includeHidden:)` | `RemoteBrowsePage`；parent=nil 表示当前浏览根 |
| `nextPage(_:)` | 原样消费 `RemoteBrowseCursor`，保留父项、搜索词和请求选项 |
| `search(_:in:pageSize:)` | `RemoteBrowsePage`；仅服务支持的搜索，不自动递归扫描 |
| `details(for:)` | 刷新后的 `RemoteBrowseItem`，保持同一来源、种类和标识，父关系变化时拒绝 |
| `artwork(for:)` | `Data?`；无封面入口或链接返回 nil，网络/认证/404 仍抛错 |
| `downloadOptions(for:)` | `[RemoteBrowseDownload]`；枚举实际格式或文件，不登记下载，不下载正文 |
| `prepareDownload(_:)` | 选中一个选项后返回 `RemoteFileReference`，交给 Transfer |
| `nativeReference(for:)` | `RemoteBrowseNativeReference`，显式取回类型安全的原生定位信息 |
| `source` / `sourceBinding` | 同一来源和绑定，用于构造 materializer |
| `capabilities` | 创建 Browser 时的根能力提示；每页和每项另有自己的能力提示 |
| `close()` | 关闭 Browser、取消并排空其在途操作；不调用 source.disconnect、不提交进度 |

## 统一数据结构

`RemoteBrowsePage` 包含 `items`、可选 `nextCursor`、可选 `total`、`coverage` 和当前范围的 `capabilities`，并提供 `hasNextPage`。所有来源都返回 `[RemoteBrowseItem]`，不要求 App 再解析厂商 JSON 或 XML。

`RemoteBrowseItem` 包含：

| 字段 | 含义 |
| --- | --- |
| `id` | `RemoteBrowseID(source, kind, value)`；source 为来源绑定，value 为原生定位信息派生的不透明键 |
| `kind` | directory / file / navigation / library / series / volume / chapter / book / podcast / episode / track |
| `metadata` | `RemoteBrowseMetadata`，统一的可选展示信息 |
| `capabilities` | browse / search / download / artwork / nativeProgress / nativePlayback |
| `snapshot` | 可 Codable 的 `RemoteBrowseSnapshot`，包含 id、metadata、capabilities |

`metadata` 字段包括 `title`、`subtitle`、`summary`、`authors`、`narrators`、`tags`、`language`、`contentType`、`size`、`duration`、`pageCount`、`createdAt`、`modifiedAt`、`createdAtRaw`、`modifiedAtRaw`、`publicationDate`、`progress`。

- 大小单位为字节，时长单位为秒；未知值为 nil。内容条目的 size 可能是书籍的汇总大小，不应当作选定下载文件的长度；以下载选项和来源实际校验为准。
- 有明确时区的时间统一为 Date；缺少时区或无法确定的时间保留 raw 字段，不猜测用户时区。仅年份或出版日期保留字符串。
- `progress` 仅用于展示比例，不是可回写的阅读位置。EPUB 不按未知排版页数伪造百分比。
- `summary` 的 `RemoteBrowseText` 保留 text/html/xhtml 格式；宿主渲染前净化远端 markup。
- 同一服务器中不同类型的相同原始 ID 不会混淆；不同来源绑定的 ID 不相等。内容来源重连会改变 binding，因此这些 ID 不承诺跨重连稳定，也不是长期收藏定位协议。
- 原生 ID 可通过 `nativeReference(for:)` 显式取得；统一 id.value 不可反向解析，也不是授权凭据。

## 各来源的层级和搜索

| 来源 | 浏览层级 | 搜索范围 / 分页 |
| --- | --- | --- |
| 文件来源 | 目录 → 子目录/文件 | 不提供通用服务器搜索；保留来源游标与 coverage；无原生分页时本地切片 |
| OPDS | Feed → 导航项/书籍；一个导航项的不同 Feed 链接分别展示 | 按 Feed 声明的 OpenSearch/模板搜索；服务 next 链接与本地切片组合；coverage 始终 unknown |
| Komga | 书库 → 系列 → 书籍 | 根、书库和系列可搜索书籍；原生页码转为不透明游标 |
| Kavita | 书库 → 系列 → 卷 → 章 | 仅选定书库内搜索系列；卷/章数组本地切片 |
| Audiobookshelf | 书库 → 书籍/播客；书籍 → 音轨及其他文件；播客 → 节目 → 音轨 | 仅书库内搜索，结果受原生 limit 限制，没有服务器搜索游标或可靠总数；total=nil、coverage=unknown |

`pageSize` 为 1...500，默认 50，是 Browser 单次返回数量上限。底层服务可能先返回完整单层数组，Browser 将尾部保存在不透明 cursor 中，之后才继续读取原生下一页；这不把 WebDAV 或库列表变成服务器分页，也不减少其首次元数据读取量。游标应顺序消费一次，不能改页大小、换父项、跨 Browser 使用或持久化。

`coverage=.complete` 仅表示该来源响应在其过滤条件下没有已知遗漏；仍需消费所有页。`hasNextPage=false` 不能证明全书库完整，更不能据此删除业务记录。分页期间服务器可能变化，没有事务快照保证。`includeHidden` 仅影响文件来源，书库可见性由服务账号权限决定。

能力是提示而非授权。ABS 精简列表中的 book 可能尚未提供音轨详情，browse/download/nativePlayback 会先作为可请求能力展示；获取详情明确为空后移除相应提示。服务权限变化和不存在的封面仍需处理错误。OPDS 导航项可尝试在其目标 Feed 内搜索，若目标 Feed 没有搜索入口返回 unsupported。

## 下载与原生进度

`downloadOptions` 不把“内容条目”和“单个文件”混为一谈：

- 普通文件、Komga 书籍：一个原文件选项。
- OPDS：所有支持的直接获取格式；购买、借阅和间接获取不伪装成下载。
- Kavita 章节：一个原文件或一个服务端 ZIP，ZIP 大小保持未知。
- Audiobookshelf：每个实际文件独立选择，按 fileID 去重；多音轨不会自动拼接，播放序列仍由原服务提供。

下载选项的 `id/title/filename/contentType/size/kind` 可用于展示；选中后调用 `prepareDownload`，再用 `browser.source` 和 `browser.sourceBinding` 创建 `RemoteFileMaterializer`。原有 coordinator、进度、取消和 lease 合同保持不变，见 [Transfer](Transfer.md)。Browser 的 close 不取消已经移交 Transfer 的下载，需先关闭对应 coordinator/materializer。

`nativeProgress`、`nativePlayback` 表示可以通过原生接口继续操作，Browser 本身没有通用的“保存百分比”或隐藏播放请求。例如 `.kavitaChapter(reference)` 可直接传给同一 `KavitaSource.updateProgress`；`.komgaBook(id)` 用于该 source 的页进度或 Readium progression；`.audiobookshelfItem(id)`、episode/track 引用用于收听进度和播放会话。更新期间宿主必须保持原 source 不重连、不切换账号；原生 source 继续负责请求校验和错误语义。

## 下载进度与取消

一次性读取可使用 `consumeBrowserDownload`，传入 `RemoteMaterializationOptions(transferProgress:)` 获取进度；该回调为 `@Sendable`，不保证在主线程执行，UI 更新需切回 MainActor。`totalBytes == nil` 时展示已传输字节或不确定进度，不计算虚构百分比。

需要任务 ID、取消按钮或多文件下载时，宿主为同一个 Browser 保留并复用 materializer/coordinator。以下两个函数只封装任务提交和快照读取；仍由宿主负责等待、取消和最终 shutdown：

```swift
func enqueueBrowserDownload(
    browser: RemoteBrowser, selection: RemoteBrowseDownload,
    coordinator: RemoteTransferCoordinator,
    progress: @escaping @Sendable (RemoteTransferProgress) -> Void
) async throws -> RemoteTransferID {
    let reference = try await browser.prepareDownload(selection)
    return await coordinator.submit(.init(
        reference: reference,
        options: .init(transferProgress: progress)
    ))
}

func browserDownloadSnapshot(
    coordinator: RemoteTransferCoordinator, id: RemoteTransferID
) async -> RemoteTransferSnapshot? {
    await coordinator.snapshot(id)
}
```

coordinator 必须注册由 `browser.source` 和 `browser.sourceBinding` 创建的 materializer。提交后，成功时 `let lease = try await coordinator.wait(for: id)` 领取结果，然后 `try await lease.withAccess { url in ... }` 或保存 lease 到真实读取结束。每个任务成功结果只能领取一次；每个提交任务都应被等待或显式取消。

| 操作 | 影响 |
| --- | --- |
| `loadingTask.cancel()`，任务正在调用 browse/search/artwork | 取消这次 Browser 请求，Browser 可继续使用 |
| 取消等待 `coordinator.wait(for:)` 的 Swift Task | 只取消等待者，已提交下载可能继续 |
| `await coordinator.cancel(id)` | 请求取消对应下载，并释放未领取的完成结果；不是最终状态证明，应观察 snapshot |
| `await coordinator.shutdown()` | 取消并排空该协调器拥有的任务；不自动关闭 materializer/source |
| `await browser.close()` | 取消并排空 Browser 自己的操作；不取消已交给 Transfer 的下载 |

任务完成与失败以 `snapshot.phase` / `snapshot.isTerminal` 为准。单 materializer 的 coordinator 默认并发为 1；需要并行时显式传 `maxConcurrentTransfers`，同时受来源上限约束。内容服务共享请求预算时，浏览和下载可能竞争额度，rateLimited 应交由宿主退避/排队。不要对不支持 Range 的内容服务强制使用分片下载策略。

## 原生阅读与播放示例

通用 `metadata.progress` 仅用于展示。选中内容后，通过 `nativeReference(for:)` 取得对应原生引用，再使用创建 Browser 时保留的同一个 typed source：

| 用户操作 | 示例函数 | 原生语义 |
| --- | --- | --- |
| 保存 Komga 漫画/PDF 页码 | `saveBrowserKomgaPage` | currentPage 为 1-based，下载不自动保存 |
| 保存 Komga EPUB 位置 | `saveBrowserKomgaEPUB` | 宿主提供 `KomgaReadiumProgression`，不能仅由百分比构造正确 locator |
| 保存 Kavita 章节位置 | `saveBrowserKavitaPosition` | pageNum 按原生 reader 语义；EPUB 使用 reading-order 与 Kavita DOM XPath |
| 启动 Audiobookshelf 播放 | `beginBrowserPlayback` | 返回整个书籍/节目的直放会话及认证轨道；不负责播放器或跳转选中音轨 |

这些函数在 [通用示例文件](../Examples/UnifiedBrowser/UnifiedBrowserExample.swift) 中。示例检查来源 actor 实例一致，但不锁住跨 await 的连接；调用期间宿主不得重连或切换账号。`nativeProgress/nativePlayback` 是能力提示，服务端仍可能因格式、权限或内容状态拒绝。

Audiobookshelf 的会话开始后，播放器使用 `session.tracks` 中的请求。播放的实际累计位置和**自上次同步以来的收听增量**来自宿主，显式传入下面的函数：

```swift
func syncBrowserPlayback(
    source: AudiobookshelfSource,
    session: AudiobookshelfPlaybackSession,
    absoluteItemTime: Double,
    listenedSinceLastSync: Double
) async throws {
    try await source.syncPlaybackSession(session, update: .init(
        currentTime: absoluteItemTime,
        timeListened: listenedSinceLastSync,
        duration: session.duration
    ))
}

func finishBrowserPlayback(
    source: AudiobookshelfSource,
    session: AudiobookshelfPlaybackSession
) async throws {
    try await source.closePlaybackSession(session)
}
```

`timeListened` 不能重复传累计总时长，也不等于 seek 的距离。会话结束后先停止宿主播放器，显式 close，再关闭 Browser/source。写入超时或网络中断可能已有远端效果，不自动重放；当前来源的会话句柄失效规则见 [Audiobookshelf](Audiobookshelf.md)。播放器已持有的 URL/认证头不会被 `browser.close()` 撤销，必须同时清理宿主播放器。OPDS 和普通文件来源不提供通用阅读进度写入。

## 生命周期、快照和错误

Browser 不拥有原 source 的登录状态。宿主结束时应先停止播放器/Transfer，再 `await browser.close()`，最后 `await source.disconnect()`。关闭会取消并等待 Browser 自己的在途操作退出；它不干扰同一 source 的其他使用者。单个调用取消后 Browser 可以继续使用。

四种内容来源通过 `sourceBinding()` 在操作前后校验会话，重连或刷新令牌旋转 binding 后拒绝旧 item/cursor/download。文件协议没有通用连接 generation：宿主必须在重连、换账号/根或权限会话变化前关闭旧 Browser；可用 `validateBinding` 闭包结合宿主 generation 检查，并返回当前 binding。没有该回调时，Browser 无法识别外部悄悄重连的同一文件 source。

`RemoteBrowseSnapshot` 可以用 JSONEncoder/Decoder 保存展示数据，日期编码策略由宿主选择。快照不保存 SDK 的请求 URL、认证头或可执行句柄；远端标题、简介等本身仍是不可信/可能敏感的用户数据。解码快照不能恢复 live item、cursor、download 或原生引用，不是正文缓存或跨启动恢复协议。live 句柄默认描述与 Mirror 脱敏，但显式原生引用中的原生模型仍应按服务文档保护。

Browser 方法将失败映射为 `RemoteBrowserError`：统一 `code` 包括认证、权限、notFound、unsupported、sessionExpired、invalidReference、invalidResponse、rateLimited、resourceLimit、cancelled、network、conflict 等；`retryAfter` 保留合法限流等待值。`underlyingError` 显式保留原始服务错误，常规 description/debugDescription 不包含其内容。Transfer 或直接调用原生 API 时仍使用这些模块自己的错误合同。限流/网络错误也不授权自动重放写入。

### 保存展示快照与重新连接

示例 `encodeBrowserSnapshots(page)` 使用 JSONEncoder 的 `.iso8601` 日期策略，`decodeBrowserSnapshots(data)` 使用相同策略读取。示例编码方便展示，但不承诺保留 Date 的亚秒精度；若业务需精度一致，自行选择相同的高精度编码/解码策略。SDK 不提供跨版本快照迁移承诺。

重启后可以展示这些快照并标明“缓存内容”；点击时重新连接、重新浏览取得 live item，而不是用快照 ID 构造下载句柄。需要长期收藏时，由宿主保存账号/服务器配置引用和适合该服务的稳定定位信息；短期链接、游标和 Browser 的哈希 ID 不应作为通用收藏恢复协议。

换账号、根目录或刷新令牌后导致 binding 变化时：停止旧 UI 请求和播放器 → 释放正在读取的 lease → shutdown Transfer → close 旧 Browser → 按来源要求断开/重连 → 创建新 Browser 与 materializer → 重新浏览。不得复用旧 item、cursor 或下载选项。关闭后 Browser 不可重新打开，应新建实例。

## 常见问题与错误处理

先判断失败来自哪一层：Browser 方法抛 `RemoteBrowserError`；`source.connect`、原生进度/播放和 Transfer 方法继续抛各模块原生错误。不要把完整接入流程都强制转换成单一错误类型。

| 现象 / 分类 | 处理方式 |
| --- | --- |
| 找不到 `RemoteBrowser` | 确认依赖包含未发布实现的源码并选择 Kit/Browser 产品；`0.8.2` 没有该类型 |
| 找不到 `BrowserConnectionExamples` 等函数 | 将两个示例 Swift 文件加入宿主 target；它们不是 SDK 内置 API |
| `notConnected` / `authentication` | 检查 source 是否连接、凭据类型和用户身份；重新授权由宿主负责 |
| `sessionExpired` / `invalidReference` | 丢弃旧浏览器的条目、游标和选项，重新建立 Browser 并获取新结果；不要篡改 ID |
| `unsupported` | 检查当前项能力和搜索范围；文件来源不搜索，Kavita/ABS 根只列库 |
| `permissionDenied` | 核对服务账号下载/阅读权限；UI 能力标记不等于服务器授权 |
| `notFound` | 刷新当前项；封面 404 可显示占位图，不能据单次 404 删除书架记录 |
| `rateLimited` | 可能是服务端限流，也可能本地操作/请求并发已满；参考 retryAfter，降低并发，按宿主策略退避后重新请求 |
| `resourceLimit` | 检查缓冲、页数、响应字节及下载引用预算；减少同层结果或按需适度调高相应来源配置，不截断后声称完整 |
| `invalidInput` | pageSize 必须 1...500，搜索词非空且不超输入限制，配置必须在允许范围内 |
| `invalidResponse` / `network` | 核对最终服务 URL、反向代理路径、响应类型；Kavita 反代需保留 Pagination 头 |
| `conflict` / `integrityMismatch` | 内容可能变化或文件完整性检查失败，重新获取元数据并让用户决定是否重试 |
| `cancelled` | 通常是主动取消/退出界面，不展示为服务故障；清理仍需等待完成 |
| `provider` | 在受控诊断中检查 underlyingError 的类型/结构；不直接记录其原始描述 |
| `hasNextPage=false` 但不是全库 | 检查 coverage；OPDS 和 ABS 搜索保持 unknown，nil total 表示不知道总数 |
| 页面 size 与下载大小不同 | 展示项可能是聚合内容；下载按用户选择的具体文件/ZIP处理 |
| 第一次翻页仍拉了很多条 | 文件/库/卷等无原生分页接口可能先返回完整一层；pageSize 仅限制统一层返回数量 |
| 已收到 100% 进度但还不能打开 | 还可能正在校验/提交；等待 coordinator 完成并领取 lease |

空列表只代表这次查询没有返回条目；过滤、权限、未知 coverage 都可能影响结果。`artwork == nil` 与 `downloadOptions == []` 是有效业务状态，不必当作连接失败。需要自定义权限、Catalog 离线索引或上传操作时，继续使用对应模块的指南，Browser 不替代这些合同。


## 资源上限与验证

`RemoteBrowserOptions`：`maxBufferedItems` 默认 10000、范围 1...100000；`maxPageCount` 默认 10000、范围 1...100000；`maxConcurrentOperations` 默认 8、范围 1...32。超出缓冲/页链预算明确返回 resourceLimit，不截断后声称完整；在途操作超额立即 rateLimited。原生来源的请求间隔、并发与响应字节限制同时生效，不被 Browser 绕过。

Browser 与 OPDS 封面使用 localhost fixture 验证，另有真实临时本地文件 → Browser → Transfer → lease 的测试。此层不增加任何真实服务器验收承诺；最低平台和最终构建/测试结果见 [验证记录](Validation.md)。
