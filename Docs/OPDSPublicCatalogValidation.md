# OPDS 公开书库实测记录

[OPDS 接入指南](OPDS.md) · [验证总览](Validation.md)

测试日期：**2026-11-05（UTC）**。地址来自用户指定的 [HandyReader 开发者文章](https://handyreader.top/blog/zh/posts/opds-catalogs-developer-notes/)。结果仅代表本次网络环境、当时服务响应和已测试路径，不是站点长期可用性或全部内容兼容承诺。

## 兼容扩展后的复测结果

当前默认使用 `OPDSCompatibilityMode.compatible`，保留 `.strict`。兼容范围包括未知时间保留为 nil+原文、验证 XML 后接受常见错误目录 MIME、直接 Atom 搜索模板，以及关键词搜索中的标准 Atom 作者/贡献者/标题筛选参数。凭据转发、origin 白名单、HTTP 开关和文件下载校验不变。

在本轮兼容实现上，使用独立 Kit 消费端复测以下五个公开书库，随后在最终 Atom 参数修复后单独复测 Wolne 搜索。没有将其余十个站点重新全量测试；每个站点只下载至多一个样本。

| 书库 | 格式兼容前 | 兼容扩展后 |
| --- | --- | --- |
| Unglue.it | 根目录可读，书目无时区日期导致失败 | 热门书目10本、下一页10本及 EPUB 下载成功；根目录没有搜索入口 |
| Ebooks Gratuits | Feed/导航缺少 updated，连接失败 | 根目录、100本列表、下一页100本、搜索和 EPUB 下载成功；`history` 返回合法空结果 |
| Wolne Lektury | 导航缺少 updated，连接失败 | 根目录、579项作者列表、42本书目及 EPUB 下载成功；补齐 Atom 筛选参数后，`ballady` 搜索返回17本书 |
| arXiv Maplepop | Atom 被标为 HTML，连接失败 | 根目录与 Computer Science 分类成功；下一层响应有未声明 `arxiv:` XML 前缀和空标题，仍拒绝；搜索亦失败，未验证下载 |
| ManyBooks | 根目录可读，直接搜索模板不支持 | 搜索模板已能展开并请求，但列表/搜索返回 `invalidDocument`；独立列表诊断仍为 Cloudflare 403 HTML。未验证下载 |

Wolne 测试显式允许 `http://wolnelektury.pl`，因为其搜索描述使用 HTTP；Unglue 显式允许 `https://unglue.it`。均使用匿名凭据，未自动增加其他 origin。没有独立详情链接的 `publication()` 仅返回当前书目，不能算作真实远端 Entry 验收。

三份新增下载均通过 ZIP CRC、EPUB mimetype、container 引用的 OPF 存在性和 XML 解析检查，文件字节数一致，lease 释放后 SDK 文件已清理：

| 站点 | 样本 | 字节数 | 本地 SHA-256 |
| --- | --- | ---: | --- |
| Unglue.it | So You Want to Be a Librarian | 344306 | `cc26e20285c2eb36cfb730966961a24887736c37afecc478cfd41ec200763d5e` |
| Ebooks Gratuits | Henry Esmond | 574339 | `e12363f8a5301f5068bcfbb6bc36102d22338a0599cf436890e947f0937a48a3` |
| Wolne Lektury | Agady talmudyczne | 1163929 | `ba52f5f759424c1ee9b693b864dc309c0cbeec6d1862cc3834b4378b42236bc9` |

这些哈希仅标识本地样本，不是与远端可信摘要的比较，也未进行阅读器排版验收。结合首轮，六个不同站点已有下载样本证据；首轮三个站点未在本轮重复下载。

ManyBooks 的独立响应与 SDK 响应不是同一次请求，不能把全部解析失败确定归因于 Cloudflare。arXiv 响应还使用 `rel=related` 表达 PDF，而非 OPDS acquisition；即使服务端修复 XML，也需提供可识别的获取关系。SDK 不猜测缺失命名空间、标题或下载语义，不绕过403/401或人机验证。

复测证据在 scratch：`opds-compat-public/<站点>-deep.jsonl`、`wolne-final-search.jsonl`、`raw-analysis.json`、`epub-validation.json`；下载副本在 `opds-compat-downloads/`。最终单元测试与构建结果见[验证总览](Validation.md)。

## 首轮记录（兼容扩展前）

以下保留首轮测试时的行为和原始证据；其中“当前”“本轮”指首轮实现，不覆盖上方的最新复测结论。

## 方法与结论

使用独立 SwiftPM 消费端，仅依赖和导入 `BoneRemoteSyncKit`，直接调用当前工作区的 `OPDSSource`、`RemoteFileMaterializer` 与 `RemoteTransferCoordinator`。生产源码和默认安全/解析策略未修改；本轮没有重新执行此前的全包单元测试。

- 文章中 **15 个原始根地址均已使用 SDK 测试**，其中 7 个至少一次根目录连接解析成功。原始首轮用 15 秒超时，深入测试用 30 秒；部分公网请求发生过暂时超时。
- Textos 改用重定向后的规范地址后，根目录和下载也通过。它不计入上述“原始地址 7 个成功”。
- **三个真实站点完成 EPUB 下载、结构检查和 lease 清理**：Gutenberg、Textos.info、The Anarchist Library。
- 根目录成功不代表子目录、搜索或下载成功。ManyBooks、Unglue.it、OpenEdition、lib.rus.ec 均存在后续路径限制。
- 仅下载三本样本，没有批量抓取；未使用账号或付费入口。测试程序、原始响应和下载副本均存放在会话 scratch，不作为包资源分发。

## 15 个原始地址的结果

| 书库 | 文章给出的地址 | 实测结果 |
| --- | --- | --- |
| Project Gutenberg | `https://www.gutenberg.org/ebooks/search.opds/` | 根目录25项、分页、进入单书格式页及 EPUB 下载成功；默认搜索被跨 origin 策略拒绝，显式配置后搜索成功（28项） |
| ManyBooks | `https://manybooks.net/opds` | 根目录4项成功；`new_titles` 导航返回 `invalidDocument`，独立原始请求遭 Cloudflare 403；直接 Atom 搜索模板尚不支持；未发出书籍下载请求 |
| Gallica | `https://gallica.bnf.fr/opds` | SDK 权限拒绝；独立请求确认 HTTP 403，无法继续 |
| Unglue.it | `https://www.unglue.it/api/opds/` | 根目录18项成功；热门书目页返回 `invalidDocument`，原始样本中的更新时间无时区；未发出书籍下载请求 |
| 文渊阁 | `https://wenyuange.org/opds/` | SDK 网络连接丢失（-1005）；curl HTTP/2 协议错误，HTTP/1.1 空响应；本网络环境未能取得目录 |
| Standard Ebooks | `https://standardebooks.org/opds/all` | 跳转到 `/feeds/opds/all` 后 HTTP 401，需相应凭据；匿名测试不能继续 |
| OpenEdition | `https://opds.openedition.org/` | 根目录2项成功；HTTP 子目录链接默认因 origin 不同被拒；显式允许 HTTP origin 后子目录仍 `invalidDocument`，独立抓取超时，原因未完全定位 |
| arXiv Maplepop | `http://arxiv.maplepop.com/catalog/` | SDK 返回 `unexpectedContentType`；独立请求 HTTP 200、正文为 Atom，但 Content-Type 是 `text/html`，与当前类型检查不兼容 |
| Textos.info | `https://textos.info/opds` | 原地址跨域跳转被拒；规范地址 `https://www.textos.info/catalogo.atom` 可浏览、分页、搜索及下载；独立书目详情链接错误，见下文 |
| Ebooks Gratuits | `https://www.ebooksgratuits.com/opds/` | HTTP 200 XML；Feed 和检查到的导航条目均缺少 `updated`，当前严格解析返回 `invalidDocument` |
| Wolne Lektury | `https://wolnelektury.pl/opds/` | HTTP 200 Atom；Feed 更新时间存在，但导航条目缺少 `updated`，当前严格解析返回 `invalidDocument` |
| Wikisource | `https://en.wikisource.org` | 给出的地址是网站首页；SDK 返回 `unexpectedContentType`。这不是可用的 OPDS 目录入口；独立抓取另遇超时 |
| The Anarchist Library | `https://theanarchistlibrary.org/opds` | 根目录4项、新书页5项、分页、搜索（10项）及 EPUB 下载均成功 |
| Flibusta | `http://flibusta.is/opds` | 根目录5项、两级导航、20项书目页及分页成功；搜索返回 HTTP 503；本次仅测目录，未下载 |
| lib.rus.ec | `https://lib.rus.ec/opds` | 根目录8项成功；导航/搜索链接使用 HTTP origin，默认策略拒绝；未验证下载 |

HTTP 原始地址通过测试配置 `allowsInsecureHTTP=true` 显式启用。未向任何站点发送 Basic 凭据，也未自动给未知 origin 增加信任。

## 三个下载样本

下载实际经过 `prepareDownload → coordinator → materializer → lease`；将样本复制到临时检查目录后释放 lease，三例均确认 SDK 管理文件已清理。

| 站点 | 书名 | 大小 | EPUB 检查 |
| --- | --- | ---: | --- |
| Gutenberg | Pride and Prejudice | 609,138 字节 | ZIP CRC通过；mimetype正确；container引用的 `OEBPS/content.opf` 存在 |
| Textos.info | La Metamorfosis | 61,767 字节 | ZIP CRC通过；mimetype正确；container引用的 `OEBPS/book.opf` 存在 |
| The Anarchist Library | A Sex Revolution | 43,590 字节 | ZIP CRC通过；mimetype正确；container引用的 `OPS/content.opf` 存在 |

下载入口分别为：

- `https://www.gutenberg.org/ebooks/1342.epub.noimages`
- `https://www.textos.info/franz-kafka/la-metamorfosis/epub`
- `https://theanarchistlibrary.org/library/lois-waisbrooker-a-sex-revolution.epub`

本地 SHA-256：

| 样本 | SHA-256 |
| --- | --- |
| Gutenberg | `2172db6a64d45b02f239cc7b46b50d7117fcd527e2a7a1386694f5eeccd26381` |
| Textos.info | `eaa254651f71be5a6568af7745c054d63fb15970796f06f7652304f819b3d83a` |
| The Anarchist Library | `f39da74cd016ea09fbb0151843b6acb6d1cfa2ea696ca8f53dcdef0b55a7cf80` |

哈希只标识本地样本，没有与远端可信摘要对照。ZIP/EPUB 容器检查不等同于完整 EPUB 规范验证，也没有在阅读器中进行排版/渲染验收。

## 关键兼容性说明

### Gutenberg：搜索需要显式 origin 配置

官方 OpenSearch 描述声明了 `http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}`，与 HTTPS `www.gutenberg.org` 不同。默认返回 `disallowedOrigin`。

实测保持根 URL 不变，使用 `allowsInsecureHTTP=true`，将 `http://m.gutenberg.org` 和 `https://m.gutenberg.org` 放入 `allowedCatalogOrigins` 后，`source.search("history", count: 5)` 返回标题 `Books: history`、28个导航条目和下一页游标。服务端没有按提示值5限制结果条数。此配置只验证了该公开来源，不改变默认凭据转发或 HTTPS 降级规则。

Gutenberg 的单书格式信息由 Feed 返回；本次 `publication` 因没有独立详情链接而返回已有书目，不计作单独 Atom Entry 请求验证。

### Textos：使用规范地址，详情链接存在服务端错误

原 URL 重定向到 `https://www.textos.info/catalogo.atom`。直接以此为根连接后：热门列表50本、下一页50本、搜索接口和 EPUB 下载均成功。本次搜索词 `history` 返回0条合法结果，没有把零结果当失败。

《La Metamorfosis》的 `alternate` 声明 `application/atom+xml;type=entry;profile=opds-catalog`，实际 href 为 `https://www.textos.info/autores.atom&`。该 URL 返回的是作者列表 Feed（26项），不是对应书目的 Entry。当前 SDK 返回 `invalidDocument`；不能把此响应当成功详情。直接获取链接仍有效，下载成功。

### 严格元数据和 MIME 检查的覆盖边界

- Unglue.it 热门页原始样本中的 `<updated>2020-06-20T16:40:44</updated>` 没有时区；严格 Internet 时间解析拒绝它。独立抓取因超时只保存部分 XML，足以观察该字段，但不代表已检查整份 Feed。
- Ebooks Gratuits 缺少 Feed/导航更新时间，Wolne Lektury 缺少导航条目更新时间；当前模型要求这些必要字段存在。
- arXiv 代理把 Atom 正文标记为 `text/html`，当前 HTTP 类型检查拒绝它。
- ManyBooks 搜索直接声明 Atom URL 模板；当前实现只支持 OpenSearch 描述文档，返回 `unsupportedSearch`。其新书列表的 SDK 原始解析响应没有截获；另一次 HTTP 请求确实被 Cloudflare 403 拦截，两者不能认定为完全相同的响应。

这些观察说明需要评估“显式兼容模式”的价值：缺失/无时区元数据处理、可信目录的 MIME 容错、直接搜索模板。它们不在本轮测试中被自动放宽；目录缺陷不能通过伪造更新时间或不加区分接受 HTML 掩盖。

## 证据与复现入口

临时消费端位于会话 scratch 的 `opds-consumer/`，其 `Package.swift` 仅依赖 Kit，生产包为当前工作区路径。调用模式为 `OPDSConsumer <rootURL> root|deep|download [downloadDirectory]`；`OPDS_TEST_ORIGINS` 提供逗号分隔的显式额外 origin。

证据目录：

- `opds-public-catalogs.json`：文章列出的15个地址。
- `opds-public-results/00-root.jsonl` 至 `14-root.jsonl`：首轮 SDK 原始连接记录。
- `opds-public-results/{gutenberg,manybooks,unglue,anarchist}-download.jsonl`：四站点深入测试。
- `opds-public-results/textos-configured.jsonl`、`openedition-configured.jsonl`、`gutenberg-configured-search.jsonl`：规范地址/显式配置测试。
- `opds-public-results/flibusta-deep.jsonl`、`librusec-deep.jsonl`：目录限定测试。
- `opds-public-responses/` 与 `opds-public-results/*-navigation.xml`：独立 HTTP 诊断响应，部分请求超时；不冒充 SDK 同一次响应。
- `opds-public-results/four-catalog-epub-validation.json`、`textos-epub-validation.json`：本地文件检查。
- `opds-public-downloads/`：三份下载检查副本；其余样本未下载。

本轮独立消费端构建成功；新增记录的链接和差异格式检查另行完成。此前的567项全包回归是实现阶段证据，本轮不重复计数，也不将公开站点请求加入依赖公网的 CI 测试。Calibre/Komga/Kavita 私有部署、真实账号、Apple 设备 ATS/沙箱、最低系统运行及大文件性能仍未验收。
