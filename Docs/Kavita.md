# Kavita 原生客户端

`KavitaSource` 是独立 actor，使用 Kavita 原生 HTTP API。统一入口为 `import BoneRemoteSyncKit`。最低平台为 macOS 12、iOS 15、tvOS 15、visionOS 1，Swift tools / language mode 6。目录模型是 library → series → volume → chapter；下载继续使用现有 Transfer 物化与租约接口。

合同固定为官方 **Kareadita/Kavita v0.9.1.4**，commit **879b8b73eb41d66f88dde8eb874cc99a3397eb11**。实现和 localhost fixture 根据该版本源码及 OpenAPI 编写，**尚未在真实部署、真实账号或反向代理上验收**。其他版本的认证、分页和 reader 行为不在此次验证范围内。

模块已在推送的开发提交 `fe8cfc2` 中，未纳入 `v0.8.2` 标签；与工作区统一枚举的版本区别见[版本对照](../README.md#开发源码与版本范围)。跨来源页面可以使用 [Browser](Browser.md)，章节祖先引用和 XPath 进度仍按本页原生合同执行。

```swift
import BoneRemoteSyncKit

let configuration = try KavitaConfiguration(
    baseURL: .init(string: "https://books.example.invalid/kavita/")!,
    maxResponseBytes: 8 * 1024 * 1024
)
let source = KavitaSource(configuration: configuration)
// apiKey 由宿主的安全凭据存储提供。
try await source.connect(.apiToken(apiKey))
let identity = try await source.connectedUserID()
let libraries = try await source.libraries()
```

部署 URL 必须指向服务实际挂载点；`/kavita/` 会保留在每个请求中。默认要求 HTTPS；仅在明确的局域网或测试配置下启用 `allowsInsecureHTTP`。SDK 不发送 cookie、不使用共享凭据缓存，不跟随重定向；请配置最终的规范 URL。

| 入口 | 认证行为 |
| --- | --- |
| `connect(.apiToken(key))` | 直接发送 `X-API-Key`，不交换 JWT，不把 key 写入 URL |
| `connect(.basic(username:password:))` | JSON POST `api/Account/login`，之后使用返回的 JWT Bearer；不是 HTTP Basic header |
| `connect(.oauth(accessToken:refreshToken:expiresAt:))` | 显式提供已有 JWT；`expiresAt` 不触发自动刷新 |
| `connectJWT(KavitaTokens, expectedUserID:)` | JWT 的专属入口 |
| `refreshTokens()` | 显式 POST `api/Account/refresh-token`，串行执行、返回完整新 token 对；不自动重试 |

所有认证都通过 `GET api/Account` 确认真实整数账号 ID、roles 和版本。可使用 `connect(_:expectedUserID:)` 拒绝账号变化。Account 返回的 OPDS `apiKey` 和空 token 不覆盖现有凭据。实现不使用 Plugin/authenticate：该入口在固定版本会返回未填写的 `id=0`，不能用作身份。

`currentTokens()` 仅为密码/JWT 会话返回 `KavitaTokens`；key 会话返回 nil。token 模型不提供 Codable，description、debugDescription、Mirror 均脱敏；实际字符串字段供宿主显式写入 Keychain 等安全存储。刷新成功后会重新验证 Account，旋转会话绑定并作废旧章节/下载引用；刷新失败不重放，请由宿主决定重新登录。服务可能已经旋转了 token，不能把一次网络失败理解为服务端没有执行。

| 专属 API | 固定版原生请求和结果 |
| --- | --- |
| `libraries()` | GET `api/Library/libraries`，可访问书库数组 |
| `series(libraryID:page:pageSize:)` | POST `api/Series/v2`，裸 series 数组与 `Pagination` header |
| `searchSeries(_:libraryID:page:pageSize:)` | 同一分页入口添加 series 名称 Matches 过滤 |
| `series(seriesID:)` | GET `api/Series/{id}` |
| `volumes(seriesID:)` | GET `api/Series/volumes?seriesId=...`，含 chapters |
| `volume(volumeID:)` / `chapter(chapterID:)` | GET `api/Series/volume` / `api/Series/chapter` |
| `chapterReference(chapterID:)` | 获取 chapter、volume、series，核对成员关系，形成完整祖先引用 |
| `cover(_:)` | GET `api/Image/{library,series,volume,chapter}-cover`，有预算上限的图片 Data |
| `pageImage(_:page:)` / `thumbnail(_:page:)` | GET `api/Reader/image?page=` / `thumbnail?pageNum=`，有预算上限的图片 Data |
| `prepareDownload(_:)` | 核对当前章节和祖先后登记 `api/Download/chapter` 文件引用 |
| `progress(_:)` / `updateProgress(_:pageNum:bookScrollID:)` | GET `api/Reader/get-progress` / 显式 POST `api/Reader/progress` |
| `bookInfo(_:)` / `bookChapters(_:)` | 原生 EPUB 信息和目录，目录页数为 reading-order index |

公开 `ContentPage` 从 0 开始；请求把 page 转为 `PageNumber=page+1`，始终发送正数 `PageSize`。每页 1...500，page 0...1,000,000。过滤 body 固定包含 field 19 的 library ID **字符串**、field 34 的 `"false"`（关闭 series 关系折叠），`combination=1`、`sortField=1`、`isAscending=true`、`limitTo=0`。搜索增加 `field=1, comparison=7, value=query`，不使用最多只返回 15 条的 Search/search 作为分页入口。

`Pagination` 必须包含一致的 `currentPage/itemsPerPage/totalItems/totalPages`；缺头、坏 JSON、总数/页数不一致、部分数组、重复 ID、错误 library 都失败，不被解释成无限列表或空书库。反向代理必须保留该响应头。非分页集合受响应字节上限及最多 10,000 个实体限制；EPUB 目录额外限制 10,000 个节点和 64 层。不会自动 fetch-all。ID 为正 Int32 范围的服务器 ID；章节小数编号保留为 Double，文件大小/wordCount 使用 Int64，未知 format 原始值保留。未返回的可选元数据保持 nil；时间字段保留服务端原始字符串。

公开 DTO 不含 server `filePath`、library folders 或 series folderPath；文件只保留清理后的 basename。DTO 的 `coverImage` 内部文件名不作为下载地址。原始 ID 在当前服务/账号下解释；`KavitaChapterReference` 则不可由宿主构造、不可跨连接复用。reader、进度和下载准备会重新取得章节与祖先，核对 library/series/volume/chapter，代价是每次操作增加三次元数据请求。服务端在核对后仍可能发生并发修改；这些 API 没有事务性条件写保证。

下载以 **chapter** 为单位：

- 恰好一个非 Image 文件：返回原始 EPUB/PDF/CBZ/CBR 等文件，登记已知源文件 bytes；缺少大小则保留 nil。
- 多文件 chapter 或任意纯 Image chapter（即便只有一张图）：返回 ZIP；内部仍包含原文件，多 CBZ 不会 flatten。登记大小为 nil，绝不使用源文件大小之和。登记 MIME 描述为 `application/zip`，固定版本实际 wire MIME 可为 `application/octet-stream`。
- `KavitaChapter.downloadKind` 表示 `.originalFile` 或 `.archiveOfFiles`。文件元数据没有独立 mangaFile 下载 API，不能拿 chapter URL 代表任一文件。

`RemoteSource.capabilities.list=false, stat=true, download=true`；stat 仅查询本会话登记的下载描述，不提供虚构文件树。`RemoteFileMaterializer` / `RemoteTransferCoordinator` 接收 `prepareDownload` 返回的 `RemoteFileReference`，消费后释放 `MaterializedFileLease`。下载完整文件，校验已知长度，原子安装；不支持 resume、expectedETag、分段必需模式或强版本重用。下载不会隐式写阅读进度。重连、断开或刷新取消旧请求并清空登记表；旧下载描述、伪造条目和旧章节引用均被拒绝。

图片 page 有效范围为 `0..<pages`，PDF 请求显式 `extractPdf=true`；越界在客户端失败，避免依赖服务器夹取。EPUB `pageImage` 不支持 XHTML 页面渲染。缩略图使用 `pageNum` 参数；图片/封面读取统一受 `maxResponseBytes` 控制，验证 image MIME。

进度 pageNum 范围为 **0...pages**，等于 pages 表示完成；不做统一 +1 转换。EPUB pageNum 是服务器 reading-order XHTML 索引，`bookScrollID` 是 Kavita 重写 DOM 的 XPath，例如 `//body/div[1]/p[3]`；它不是 EPUB CFI，也不等价于另一阅读引擎重新排版后的 locator。接口拒绝显式 `epubcfi(...)`，并限制 XPath 大小与控制字符，但不负责验证 XPath 在服务端 DOM 中实际可解析。PDF 官方 UI 使用 1-based currentPage，漫画阅读器通常使用 0-based 当前索引并在读完最后一页时写 pages，宿主必须按阅读器语义选择数值。

GET 没有历史时，服务返回 chapterId 加全零祖先和 pageNum=0。SDK 保留已验证祖先，`hasRecordedProgress=false`，不暴露默认年份的假修改时间。首次 `pageNum=0` 写入即便附 XPath 也会被服务忽略；200 空 body 只表示请求被接受，SDK 不伪造已持久化状态。进度写入带所有五个必填整数，成功不 decode 空 body，不做自动写重放、离线冲突合并或 ETag/CAS；最后到达的写入可能覆盖更新位置。

错误按 HTTP 状态映射，不假定统一 error body：401 为认证失败，403 为权限不足（下载通常缺 Download/Admin 角色），404 可表示资源不存在或无权访问，400 为无效响应/业务拒绝，429 为限流，5xx 为网络服务错误。错误不附服务响应 body、凭据或请求 URL。不要依据单次 404 删除本地书籍，也不要自动反复登录导致账号锁定。

完整宿主用例见 [Examples/Kavita](../Examples/Kavita/README.md)。此版本不包含嵌入式 HTML/CSS 阅读器、EPUB 内部资源代理、CFI 转换、两套书签 API、管理操作或上传功能。

固定版本官方证据：

- [v0.9.1.4 release](https://github.com/Kareadita/Kavita/releases/tag/v0.9.1.4)；[固定 OpenAPI](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/openapi.json)；[当前官方 API 文档](https://wiki.kavitareader.com/guides/api)。
- [AccountController](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Controllers/AccountController.cs#L226)：login、Account 身份、refresh；[AuthKeyAuthenticationHandler](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Middleware/AuthKeyAuthenticationHandler.cs#L113)：header key。
- [SeriesController](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Controllers/SeriesController.cs#L64)；[HttpExtensions](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Extensions/HttpExtensions.cs#L22)：数组及 Pagination header。
- [DownloadController](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Controllers/DownloadController.cs#L197)：单文件和 ZIP 分支；[ReaderController](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Server/Controllers/ReaderController.cs#L601)：进度响应与写入。
- [ReaderService](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/Kavita.Services/Reading/ReaderService.cs#L216)：范围和首个零进度写入；[官方 reader.service.ts](https://github.com/Kareadita/Kavita/blob/879b8b73eb41d66f88dde8eb874cc99a3397eb11/UI/Web/src/app/_services/reader.service.ts#L391)：XPath 存取。

验证入口：`swift test --filter Kavita`。测试使用 macOS Swift Testing、Python 标准库 localhost fixture 和虚构凭据，临时目录前缀 `BoneKavitaTests-`；包含认证、子路径、分页坏头、元数据和关系、图片/PDF、原始与 ZIP 下载/Transfer、进度边界/空响应、旧引用、重连/取消及错误不重放。共享传输层的恶意 URL、响应预算和文件保护由 Content 测试覆盖。真实服务器角色配置、反向代理保头、实际 EPUB DOM XPath 兼容仍需宿主部署验收。
