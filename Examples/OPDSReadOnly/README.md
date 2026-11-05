# OPDS 只读书库示例

[接入指南](../../Docs/OPDS.md) · [Swift 示例](OPDSReadOnly.swift)

此示例只需 `import BoneRemoteSyncKit`，通过 `importOPDSPublication` 完成连接、选择、下载、使用 lease 和清理。`choose` 回调由宿主展示书目、导航和格式，返回用户明确选定的 `(OPDSPublication, OPDSAcquisition)`；没有默认选择第一本或第一种格式的行为。

- 创建 `OPDSConfiguration(rootURL:)`，传 `.anonymous` 或 `.basic(username:password:)`。
- `choose` 可调用 `source.browse(link)`、`source.nextPage(cursor)`、`source.search(query)` 和 `source.publication(book)`；最终检查 `acquisition.isDirectDownload`。
- `cacheDirectory` 应为宿主拥有的私有本地目录。`consume` 必须等待消费者结束读取；如需长期收藏，复制到宿主管理的目录。
- 返回失败时也会依次等待 coordinator、materializer 清理，再断开来源。
- HTTP 局域网入口必须显式 `allowsInsecureHTTP: true`，宿主自行配置 ATS；默认不接受明文 HTTP。

示例不提供登录 UI、书目数据库、文件解析、DRM 或后台任务。不保存 URL、凭据、书目或下载引用。本地 fixture 验证不代表真实书库服务已验收。
