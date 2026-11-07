# OPDS 1.2 只读书库

[首页](../README.md) · [宿主示例](../Examples/OPDSReadOnly/README.md) · [Transfer](Transfer.md) · [验证记录](Validation.md)

> 自 **v0.8.0** 提供：`BoneRemoteSyncOPDS` 实现 [OPDS 1.2](https://specs.opds.io/opds-1.2) 核心客户端子集，不是全部 OPDS 扩展的兼容承诺。没有真实 Calibre、Komga 或 Kavita 部署验收。
>
> 2026-11-05 首轮测试15个公开地址；兼容扩展后复测五个。两轮分别在 Gutenberg、Textos.info、The Anarchist Library 和 Unglue.it、Ebooks Gratuits、Wolne Lektury 完成 EPUB 下载与本地文件检查；其余服务限制见 [公开书库实测](OPDSPublicCatalogValidation.md)。
>
> 本页 `cover(_:)` 与上层 Browser 属于已推送开发提交 `fe8cfc2` 的新增能力，**不包含在 `v0.8.2` 标签中**；基础书目接口仍自 v0.8.0 提供，安装范围见[版本对照](../README.md#开发源码与版本范围)。

## 业务定位与模块

模块负责“发现出版物 → 选择获取方式 → 取得完整本地文件”。书目解析、远端搜索和文件获取在 SDK 内；阅读器、文件格式解析、封面展示、长期收藏和阅读进度由宿主实现。

产品可单独依赖 `BoneRemoteSyncOPDS`，其运行依赖仅为 Core 和系统框架；统一入口 `BoneRemoteSyncKit` 已重新导出。平台与主包一致：Swift 6 语言模式、macOS 12、iOS/tvOS 15、visionOS 1 起。

`RemoteSourceKind.opds` 显示名为 OPDS，没有内置图标。`sourceTypes()` 包含它，`driveTypes()` 仍为网盘图标目录。

需要与网盘、Komga/Kavita/Audiobookshelf 共用页面模型时，可在已连接 OPDS 来源上创建 `RemoteBrowser.opds(source)`；原生 Feed/Entry 模型仍保留，见 [统一浏览指南](Browser.md)。

## 兼容模式与时间字段

`OPDSConfiguration` 默认 `compatibility: .compatible`；要求严格输入时显式传 `.strict`。模式不会改变凭据、允许的 origin、明文 HTTP、重定向或文件落盘规则。

| 输入差异 | compatible（默认） | strict |
| --- | --- | --- |
| Feed/条目没有 updated | 接受，`updated=nil`、`updatedRaw=nil` | 拒绝 |
| 无时区或无法解析的 updated | 接受，`updated=nil`，`updatedRaw` 保留去掉首尾空白的原文 | 拒绝 |
| 有效带时区日期 | 正常解析，同时保留原文 | 正常解析 |
| 目录误标为 HTML/plain/octet-stream 或无 MIME | 有界读取后验证 XML；只接受 Atom feed/entry 或 OpenSearch 根和命名空间 | 拒绝 |
| `rel=search` 的 Atom GET 模板 | 支持原始或百分号编码的花括号、相对链接与命名空间参数 | 只支持 OpenSearch 描述文档 |

**时间字段：** 首次发布的 `OPDSPage.updated` 和 `OPDSPublication.updated` 为 `Date?`，并提供 `updatedRaw: String?`。使用过开发快照的宿主应同步处理 nil；未知日期不会填为当前时间、Unix epoch、父 Feed 时间或按本地时区猜测。它们依旧不能作为文件版本或缓存依据。导航条目原本没有公开 updated 字段，但同样允许缺失时间。

每个 Feed/条目仍须各有一个非空 ID 和标题；重复 updated、错误 XML、DTD/实体、错误命名空间不会被容错。真正的 HTML 登录页或错误页仍拒绝，文件下载的 MIME/前缀检查不因目录兼容而放宽。MIME 回退只限 `text/html`、`application/xhtml+xml`、`text/plain`、`application/octet-stream` 或缺失类型；JSON、图片等其他类型不尝试解释为目录。

## 浏览与选择

| API | 行为 |
| --- | --- |
| `OPDSSource(configuration:)` | 创建来源，不请求网络 |
| `connect(_:)` | 匿名或 Basic 连接，获取并验证根 Feed；每次连接生成新会话 |
| `sourceBinding()` | 返回当前会话非敏感 binding，供 Transfer 使用 |
| `browse(refresh:)` | 默认返回连接时的根页面；显式 refresh 重新获取 |
| `browse(_ link:)` | 跟随当前会话的 Atom Feed 链接 |
| `nextPage(_:)` | 获取游标对应的下一页；不预取后续页面 |
| `publication(_:)` | 有合适 `alternate` 链接时请求完整 Atom Entry 并核对 ID；否则返回当前书目 |
| `cover(_:) async throws -> Data?` | 验证当前会话书目，优先 thumbnail，其次 image；无图片链接返回 nil |
| `search(_:in:count:)` | 优先使用 OpenSearch 描述文档；兼容模式还支持 Atom 直接 GET 搜索模板；默认 count 为 100 |
| `prepareDownload(_:acquisition:)` | 验证书目与显式选中的获取方式，签发文件引用 |
| `disconnect()` | 取消请求、清空会话状态，使书目/链接/游标/文件引用失效；已提交文件不回滚 |

`OPDSPage.items` 保留服务器条目顺序；`navigation`、`publications` 是过滤视图。同一本书可出现在多个分类，不代表多份文件。页面的 nil `nextCursor` 只表示没有下一页，不证明整个书库完整。游标包含原分页链上下文，可重复请求同一页，但不能跨连接或来源使用；循环和预算超限报错。

`OPDSPublication` 提供 Atom ID、标题、作者、简介、分类、语言、出版社、出版时间字符串、书目更新时间、链接及获取方式。大小未知不是零。`summary`/`content` 的 text、HTML、XHTML 有类型区分；不执行远端标记，宿主渲染前须净化。封面链接由 `imageLinks` 提供，浏览时不自动请求；URL 可能含敏感参数，不应记录到日志。

需要封面时调用 `try await source.cover(publication)`。仅使用该书目已有的 `http://opds-spec.org/image/thumbnail` 或 `http://opds-spec.org/image` 链接，同一关系按模型顺序选择第一个；不隐式请求详情，已选图片失败时直接抛错，不重试另一个链接。无图片返回 nil；断开后为 `notConnected`，重连或跨来源使用旧书目为 `invalidReference`，在途取消或会话替换为 `cancelled`。

封面经现有独立 HTTP 客户端有界读取，响应须声明合法、具体的 `image/*` MIME（包括 `image/svg+xml`），不使用 Feed 的兼容 MIME 回退。`maxResponseBytes` 同时约束已知长度和流式接收字节数；拒绝短读、部分响应和内容编码。返回值是原始、不可信的 `Data`，传输检查不验证图片能否解码，也不净化 SVG。宿主须使用安全图片解码器并限制解码后的资源用量，不直接执行 SVG、脚本或其他远端内容，不因 MIME 为图片而信任内容。

搜索支持 OpenSearch 1.1 GET 模板的 `searchTerms`、`count`、`startIndex`、`startPage`、`language`、`inputEncoding`、`outputEncoding`，也支持绑定到 OpenSearch 命名空间的前缀（如 `{os:searchTerms}`），按 indexOffset/pageOffset 起始值填充。未知必填参数和 POST 模板明确不支持；未知可选参数替换为空值。参数只允许出现在路径或查询值中，UTF-8 百分号编码防止查询注入；搜索结果按 Feed 的 next 链接翻页。不扫描分类猜测搜索接口，不支持高级字段搜索。

直接搜索模板来自当前会话 Feed 的 `rel=search`、Atom 类型链接；保留原始 href 和 xml:base，识别 `{searchTerms}` 或 `%7BsearchTerms%7D`，不会把固定 `%26`、`%2F` 参数解码成分隔符。不接受双重编码占位符。直接模板的 startIndex/startPage 默认1，OpenSearch 描述仍使用声明的偏移；两者均执行同一查询长度、页大小、参数位置与 origin 校验。优先使用页面声明的 OpenSearch 描述，网络/认证错误不触发另一路隐藏重试。

标准 Atom 命名空间下的 `author`、`contributor`、`title` 模板字段也可识别（前缀名称不固定）；当前关键词搜索为它们传空值，表示不限定作者、贡献者和标题。未知命名空间或其他未知必填字段仍拒绝，不提供高级字段筛选 UI 或 API。Wolne Lektury 的该类模板已用真实关键词搜索验证。

## 下载方式与 Transfer

首期直接下载仅接受通用 acquisition 或 open-access 关系、没有 `indirectAcquisition` 的已识别文件 MIME：EPUB、PDF、CBZ/CBR、ZIP、Mobipocket、纯文本、MP3/M4A、JPEG/PNG、octet-stream。响应使用 CBZ/CBR/PDF 常见 MIME 别名时可接受。实际文件是否可以解码仍由宿主验证。

buy、borrow、subscribe、sample、未知关系、DRM 类型和间接获取保留在模型中，但 `isDirectDownload=false`。不自动打开购买页，不把中间文件当最终出版物。

```swift
import Foundation
import BoneRemoteSyncKit

// source 已连接；publication/acquisition 均由该会话返回并经用户选择。
func prepareOPDSFile(source: OPDSSource,
                     publication: OPDSPublication,
                     acquisition: OPDSAcquisition,
                     cacheDirectory: URL,
                     consume: @Sendable (URL) async throws -> Void) async throws {
    let reference = try await source.prepareDownload(publication, acquisition: acquisition)
    let materializer = RemoteFileMaterializer(
        source: source, sourceBinding: try await source.sourceBinding(), cacheDirectory: cacheDirectory
    )
    do {
        let lease = try await materializer.materialize(reference)
        try await lease.withAccess { url in try await consume(url) }
        await materializer.shutdown()
    } catch {
        await materializer.shutdown()
        throw error
    }
}
```

完整连接、UI 选择回调、coordinator 和断开生命周期见[可编译示例](../Examples/OPDSReadOnly/OPDSReadOnly.swift)。宿主应复用长生命周期会话及 materializer，待消费完成再释放 lease；长期保留需复制到宿主自己的目录。

### 通用文件接口的准确含义

| 接口/能力 | OPDS 行为 |
| --- | --- |
| `list` / 文件树 `walk` | 不支持；使用专用 browse API |
| `stat(path:)` | 只解析登记时的描述，不做 HEAD，不承诺实时远端版本 |
| `download` | 根据登记记录下载，拒绝修改过的 RemoteEntry 和旧会话引用 |
| 路径 | `/resources/<随机标识>`，无远端 URL；仅为会话内句柄 |
| 稳定 ID 寻址 | 未实现；书目 Atom ID 与具体格式文件不同 |
| 文件版本/大小 | 首期登记描述的 size、etag、modifiedAt 保持 nil |
| 缓存复用 | 无可靠文件版本，Transfer 不复用旧内容、不合并同版本在途请求 |
| 写入、复制、删除、Range、恢复、强版本 | 均不支持；不支持的请求显式失败 |

Feed ETag、书目 updated 与出版日期不能当作文件版本。下载响应提供的长度仅用于本次 HTTP 完整性和进度，不更新已登记描述。`RemoteMaterializationOptions.expectedChecksum` 可使用宿主提供的可信 SHA-256；ETag 或成功传输不是内容有效性证明。

下载流式写入随机 staging，按已知 Content-Length 检测短读，拒绝明确的 HTML/JSON/XML 错误类型和常见 HTML 前缀；未知总长度的比例为 nil。前缀检测是有限的错误页识别，不是文件格式验证。完整传输后才原子安装；取消/失败清理自己的 staging，保留旧目标。默认下载选项 overwrite=true，与其他来源一致，需要非覆盖时显式设 false。同实例目标互斥，不提供跨进程锁；路径校验不构成对恶意外部文件系统竞争的完整沙箱。

取消会等待该 HTTP 操作的 delegate 失效后返回，避免清理仍在写入的文件；`disconnect()` 本身使会话失效并请求取消，调用方仍应等待正在执行的任务退出。引用登记不自动淘汰，达到上限明确失败；新连接才清空登记。

## 网络策略与预算

- 默认 HTTPS；明文 HTTP 要求 `allowsInsecureHTTP=true`，宿主负责 ATS。系统证书校验不绕过。
- 目录、详情与搜索默认同源，额外 origin 通过 `allowedCatalogOrigins` 明确配置（只能是 scheme/host/port，无路径和查询）。Basic 只发给根 origin；跨域重定向后即使回到原 origin 也不恢复凭据。
- 下载与封面允许跨源 HTTPS，启用 HTTP 时也可用于本地测试/局域网；禁止 HTTPS → HTTP 重定向降级。每跳验证，最多 5 次，不带共享 Cookie、共享凭据和隐式磁盘缓存。封面的 CDN 请求不需要加入 `allowedCatalogOrigins`，跨域不携带 Basic 凭据。
- 不接受 URL userinfo、非 HTTP(S) URL、无效端口；合法查询保留，fragment 不参与请求。无隐藏重试或无限重新认证。
- Feed 有界读取，XML 拒绝 DTD/实体声明和外部实体；额外限制 100,000 XML 节点。未知扩展不会混入标题等字段。外置 atom:content 不自动下载。

| 配置 | 默认值 | 可配置范围 |
| --- | --- | --- |
| timeout | 60 秒 | >0，≤86400；每个 HTTP 请求/重定向跳适用 |
| maxResponseBytes | 8 MiB | 1…64 MiB；Feed、搜索描述和封面共用单次响应上限 |
| maxEntriesPerPage | 5000 | 1…100000 |
| maxXMLDepth | 64 | 2…256 |
| maxPages | 1000 | 1…100000，按一条分页链 |
| maxDownloadReferences | 10000 | 1…100000，按一次连接 |
| maxConcurrentTransfers | 3 | 1…16 |
| compatibility | `.compatible` | `.compatible` / `.strict` |

HTTP 客户端共享当前来源的请求上限（包含浏览/搜索/封面/下载），直接超额请求返回 `resourceLimit`；Transfer 下载还受 materializer 和 coordinator 上限限制。预算是明确拒绝，不把截断结果当成功列表或封面；书籍文件下载不受元数据与封面的字节上限限制。

## 错误与当前边界

`OPDSError` 描述配置、URL、跨域策略、XML/文档、预算、引用/游标、不支持的搜索/获取方式、响应类型和重定向错误，不携带原始 URL/正文。HTTP 401、403、404/410、429、5xx、传输完整性及取消使用 `RemoteSyncError`；限流携带可解析的 Retry-After。业务判断不应依赖错误文本。

首期不支持 OPDS 2.0、OAuth/Digest、Cookie 登录、DRM、购买借阅、正文解析、后台传输、续传、强版本或 Catalog 持久化。与现有 Catalog 配置、目录索引和容量统计没有自动集成，不新增数据库 schema。已完成有限的[公开书库实测](OPDSPublicCatalogValidation.md)；Calibre/Komga/Kavita 私有部署、真实账号、Apple 设备 ATS/沙箱、最低系统运行及大文件内存/吞吐仍未验收，详见[验证记录](Validation.md)。
