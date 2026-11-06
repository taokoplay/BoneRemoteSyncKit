# Komga 原生客户端（当前未发布）

本适配器面向 Komga **1.30.0**，合同固定在官方 commit `ff800c21253793d4d3fd855651b82d4924915950`。实现提供原生 REST 浏览、认证、图片、完整文件下载和显式阅读进度操作；与 OPDS 适配器分别使用。当前属于未发布代码，**没有完成真实 Komga 服务验收**。本地 Python fixture 检查请求协议和客户端行为，不能替代真实书库、媒体分析和部署环境的兼容性验证。

Swift tools 6.0 / Swift 6，最低 macOS 12、iOS/tvOS 15、visionOS 1。宿主统一 `import BoneRemoteSyncKit`；按需模块为 `BoneRemoteSyncKomga`，依赖共享 Content/Core。运行时没有第三方依赖或 Python 依赖。

## 连接与账号隔离

`KomgaConfiguration` 是 `ContentServerConfiguration` 的别名。`baseURL` 指向实例公开根地址，例如 `https://books.example.invalid/komga/`，保留反代子路径。认证验证使用 `GET api/v2/users/me`，其余主要端点使用 `api/v1`。不要将 baseURL 配置为 `/api/v1`。

```swift
import BoneRemoteSyncKit

func connectKomga(
    configuration: KomgaConfiguration,
    credential: RemoteCredential,
    expectedUserID: String?
) async throws -> KomgaSource {
    let source = KomgaSource(configuration: configuration)
    try await source.connect(credential, expectedUserID: expectedUserID)
    return source
}
```

凭据由宿主从 Keychain 等凭据存储读取，再显式传入：

- `.basic(username: email, password: password)`：每次请求发送 HTTP Basic，用户名为邮箱。
- `.apiToken(apiKey)`：每次请求发送原始 `X-API-Key`；不添加 Bearer，不放进 URL。
- 不支持 anonymous、OAuth、登录 Cookie、会话 token 或 API key 管理。

默认要求 HTTPS；局域网明文 HTTP 必须显式设置 `allowsInsecureHTTP: true`。客户端拒绝重定向，需配置最终服务地址。客户端不保存凭据、不使用全局 Cookie/URL cache，也不会自动重放进度写入。

`currentUser()` 与 `connectedUserID()` 会重新请求当前用户并核对连接时的 ID；身份变化抛 `ContentServerError.identityChanged` 并断开连接。`expectedUserID` 可防止宿主选择错误账号。公开用户模型保留 roles、共享库、年龄限制和标签限制；判断下载权限使用真实 `FILE_DOWNLOAD` role，不以 ADMIN 代替。

每次 connect/disconnect 都推进连接代际、取消旧客户端、清空已登记文件引用。旧请求不能发布新会话结果或安装旧下载；连接尚未验证时，内容 API 返回 `notConnected`。`sourceBinding()` 是会话内标识，重连后需重建物化器。宿主长期内容缓存应另以规范化 baseURL + 已验证用户 ID + 原生内容 ID 分区。

## 浏览、搜索与图片

| API | 返回/含义 |
| --- | --- |
| `libraries()` / `library(id:)` | 可访问库列表/详情，保留 id、name、unavailable |
| `series(libraryID:search:page:pageSize:sort:)` | 一页系列；可限定库并全文搜索 |
| `series(id:libraryID:)` | 系列详情，可核对预期库关系 |
| `books(libraryID:seriesID:search:page:pageSize:sort:)` | 一页书籍；可限定库和/或系列 |
| `book(id:seriesID:libraryID:)` | 书籍详情及当前用户 readProgress，可核对预期父关系 |
| `seriesCover(seriesID:)` / `bookCover(bookID:)` | 有界 JPEG 封面 Data |
| `pages(bookID:)` | 原生非分页页目录，页号从 1 开始 |
| `pageImage(bookID:page:)` | 页图 Data，需要 PAGE_STREAMING |

列表使用 `POST api/v1/series/list` 或 `POST api/v1/books/list`，body 中的 `condition.libraryId` / `condition.seriesId` 使用 `{"operator":"is","value":"…"}`。同时提供两个父筛选时使用 `allOf`，搜索文本放在 `fullTextSearch`，不使用已弃用 GET 列表参数。

`ContentPage` 的 `page` 从 0 开始。显式发送 `page` 与 `size`，SDK 接受 page 0...1,000,000、pageSize 1...500（SDK 防护范围，**不是宣称服务器配置的最大值**），默认大小 50。每次只请求一页，宿主通过 `hasNextPage` 按需继续。返回分页形状、重复 ID 和已知父关系不一致时抛 `invalidResponse`，不把部分错误当空页。

`KomgaSeriesSort` 和 `KomgaBookSort` 提供已核对的排序字段与升降序，多个排序生成重复 `sort` query。未指定排序时，浏览默认 series 的 `metadata.titleSort,asc` / books 的 `metadata.numberSort,asc`；全文搜索不发送默认 sort，让服务器使用 relevance。

```swift
let seriesPage = try await source.series(libraryID: selectedLibraryID, pageSize: 30)
let matches = try await source.books(
    libraryID: selectedLibraryID,
    search: searchText,
    page: 0,
    pageSize: 30
)
let detail = try await source.book(id: selectedBookID)
let image = try await source.bookCover(bookID: detail.id)
```

页图明确发送 `contentNegotiation=false&convert=jpeg` 和 image Accept，避免把 PDF 页响应误当图像。所有图像请求通过共享 MIME 和响应预算检查；下载二进制走独立文件流。没有封面、媒体尚未分析或源文件不可用都可能返回 404，不能仅凭 404 推断书籍已删除。

普通 EPUB 可有计算得到的 media.pagesCount，却没有 Divina 图片页；此时 `pages` 返回空目录，`pageImage` 明确返回 unsupported。宿主应下载原始 EPUB 交给阅读器渲染，并使用 Readium progression 保存定位。此边界依据固定版本 BookAnalyzer 的普通 EPUB 分支。

公开 DTO 只投影内容字段。LibraryDto.root、SeriesDto.url、BookDto.url 的服务器本地路径不会进入公开模型，也不会用于下载。标题使用 `metadata.title`；book.number、metadata.number 和 metadata.numberSort 保持各自语义。时间戳解码为 Date（接受 ISO-8601 小数秒），releaseDate 保留经校验的 `yyyy-MM-dd` 日历日期；缺失可选元数据保持 nil。未建模的元数据编辑锁、管理设置和外部链接不向宿主透传。

## 显式阅读进度

`readProgress(bookID:)` 读取 `GET api/v1/books/{id}` 的 `.readProgress`。Komga **没有 GET `/read-progress`**。无记录返回 nil；读取 `page` 允许 0，因为普通 EPUB 的 Readium 路径可能计算出零页。

| 宿主动作 | API / 实际请求 |
| --- | --- |
| 保存当前页 | `updateReadProgress(bookID:page:)` → PATCH `{"page":N}` |
| 标记完成 | `markRead(bookID:)` → PATCH `{"completed":true}` |
| 重置未读 | `resetReadProgress(bookID:)` → DELETE，无 body |
| 读取 Readium locator | `progression(bookID:)` → GET `/progression`，200 或无记录 204 |
| 保存 Readium locator | `updateProgression(bookID:progression:)` → PUT `/progression`，成功 204 |

页码 PATCH 只接受 1...media.pagesCount；最后一页会自动完成。普通 EPUB（`epubDivinaCompatible != true`）明确返回 unsupported 并提示改用 Readium；Divina EPUB 支持页码。markRead 可以用于普通 EPUB，reset 通过 DELETE 完成，不能发送 `completed:false` 来重置。所有成功写入按 204 无内容处理。

Readium 公开模型包含 `KomgaReadiumProgression(modified:device:locator:)`、device.id/name、locator.href/type/title/locations/text/koboSpan，以及 locations.fragments/progression/position/totalProgression、text.before/after/highlight。例如宿主已经获得真实 EPUB 内部资源定位时：

```swift
let progression = KomgaReadiumProgression(
    modified: readerModifiedDate,
    device: .init(id: readerDeviceID, name: readerDeviceName),
    locator: .init(
        href: readerResourceHref,
        type: "application/xhtml+xml",
        locations: .init(progression: readerResourceProgression)
    )
)
try await source.updateProgression(bookID: selectedBookID, progression: progression)
```

EPUB 必须提供现存内部资源 href 和资源内 progression（有限数 0...1），实际 href 与服务器 positions 的匹配由服务器检查；SDK不提供 EPUB 解析器或 WebPub manifest/positions 客户端，宿主阅读器需从原始出版物取得定位。DIVINA/PDF 需要 position 1...N。GET 的 vendor MIME 为 `application/vnd.readium.progression+json`；页码 PATCH/markRead 创建的旧式记录可能返回空 locator，SDK保留为空 href/type。

Readium 的相同或更早 modified 返回 HTTP 409，映射为 `RemoteSyncError.conflict`。服务器重新计算 EPUB totalProgression；不要假设返回值与提交值恒等。DELETE read-progress 会清除共享存储记录，包括 Readium；没有独立 DELETE progression。

页码进度没有客户端修改时间、设备或乐观版本条件。显式回退页码会覆盖远端较新位置，重复请求也可能更新时间。宿主负责冲突策略与重试决策。取消已发送的写请求不保证服务器未提交；需要时重新读取进度核对。

## 完整文件下载与 Transfer

`prepareDownload(bookID:)` 验证当前 Book DTO 并登记 `GET api/v1/books/{id}/file` 的一个文件。返回 `RemoteFileReference`，在当前连接内可反复用于 `stat`、`download`、`RemoteFileMaterializer` 或 `RemoteTransferCoordinator`。引用不是原生 book ID，也不是永久 URL；默认最多登记 256 个引用，可通过配置调整。重复调用 prepareDownload 会占用新的登记项，宿主应复用已有引用。

`RemoteSource.capabilities` 为 list=false、stat=true、download=true，目录列表返回 unsupported。stat 只返回登记描述；未登记路径、篡改的 RemoteEntry 和旧连接引用均被拒绝。没有文件树、上传、移动、删除或后台执行能力。阅读进度修改不代表文件写权限。

```swift
let reference = try await source.prepareDownload(bookID: selectedBookID)
let materializer = RemoteFileMaterializer(
    source: source,
    sourceBinding: try await source.sourceBinding(),
    cacheDirectory: privateCacheDirectory
)
let lease = try await materializer.materialize(reference)
// 阅读器在租约有效期间消费 lease.url。
await lease.release()
await materializer.shutdown()
```

文件大小来自原生 sizeBytes，缺失则保持 nil；不发布假的强 ETag、mtime 或条件版本。Komga 1.30 的该下载端点没有已核对的 Range/强版本保证，因此 resumeFrom、expectedETag、分段下载不受支持。共享传输校验已知长度、流完整性并原子安装；错误或取消保留原目标，旧下载结束前保留目标锁。文件下载不会暗中更新阅读进度。

## 错误与验证范围

401→authenticationFailed；403→permissionDenied；404/410→notFound；409/412→conflict；429→rateLimited；5xx→network；无效响应、400 和格式错误使用 ContentServerError.invalidResponse。错误不包含远端 body、服务器 URL 或凭据；未提供服务器验证消息透传。没有自动重试或自动刷新 API key。

正式测试位于 `Tests/BoneRemoteSyncKomgaTests`：macOS Swift Testing + Python 标准库 fixture，绑定 127.0.0.1，临时目录 `BoneKomgaTests-*`。覆盖 Basic/API key、反代路径、身份及关系验证、POST 分页/搜索/排序、详情/图片、页码和 Readium 进度、204/409、完整下载与 Transfer 租约、旧引用、重连和取消。Python 只用于测试，通过 `PythonFixture.executableURL()` 定位。

```sh
swift test --scratch-path "$PI_SCRATCH_DIR/komga-build" --filter KomgaTests
```

真实服务尚未验收：真实 Basic/API key 权限组合、反代 TLS/子路径、不同媒体格式的分析/图片转换、大文件下载、真实 EPUB 内部 href/positions 与多设备时间冲突均待真实 Komga 1.30.0 验证。其他 Komga 版本、SSO/OAuth、OPDS 兼容行为不在本原生适配器验证范围。

## 固定官方证据

- [Komga 1.30.0 release](https://github.com/gotson/komga/releases/tag/1.30.0) 与 [tag ref](https://api.github.com/repos/gotson/komga/git/ref/tags/1.30.0)。
- [固定 commit 完整 OpenAPI 3.1](https://raw.githubusercontent.com/gotson/komga/ff800c21253793d4d3fd855651b82d4924915950/komga/docs/openapi.json)。
- [UserController](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/interfaces/api/rest/UserController.kt) 与 [BookController](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/interfaces/api/rest/BookController.kt)：用户、分页、页目录和 read-progress。
- [CommonBookController](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/interfaces/api/CommonBookController.kt#L317)：完整文件下载、Readium GET/PUT 与实际状态码。
- [BookLifecycle](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/domain/service/BookLifecycle.kt#L410)：页码范围、EPUB Divina 限制、完成/重置、modified 冲突、Readium 计算页码零值。
- [R2Locator](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/domain/model/R2Locator.kt) 与 [R2Progression](https://github.com/gotson/komga/blob/ff800c21253793d4d3fd855651b82d4924915950/komga/src/main/kotlin/org/gotson/komga/domain/model/R2Progression.kt)：typed locator/device/modified 合同。

[完整宿主示例](../Examples/Komga/KomgaExample.swift) 只导入统一 Kit，凭据由调用方传入，包含成功和失败时的租约/物化器/连接清理。
