# Komga 宿主示例（当前未发布）

[KomgaExample.swift](KomgaExample.swift) 只导入 `BoneRemoteSyncKit`。代码面向 Komga 1.30.0 的原生 REST 合同，凭据、实例配置、选择的 book ID 和应用私有缓存路径均由调用方传入；文件中没有实际账号、密码或 API key。

- `openKomgaBook`：验证用户、登记一个原始文件、通过 Transfer 物化并交给宿主闭包消费，在成功或失败时释放租约、关闭物化器并断开连接。`consume` 返回后不得继续使用租约 URL。
- `searchKomgaBooks`：对已连接来源执行库内全文搜索，每次只取一页，页号从零开始。
- `saveKomgaPage`：宿主明确保存页码时调用，页号从一开始；普通 EPUB 应使用 Readium 接口。
- `saveKomgaEPUB`：宿主传入实际阅读器生成的 `KomgaReadiumProgression`；409 冲突由宿主读取远端进度后决定如何处理。

配置 baseURL 必须保留反代子路径，例如 `https://books.example.invalid/komga/`；不要包含 `/api/v1`。Basic 凭据的 username 为邮箱；`.apiToken` 使用 `X-API-Key`。默认 HTTPS，明文 HTTP 需要显式 opt-in。每次重连都使旧文件引用和 source binding 失效，需重建物化器。

示例没有提供阅读器 UI、EPUB locator 解析器、后台任务或自动进度同步。下载不会写入阅读进度。当前尚未完成真实 Komga 服务验收，本地 HTTP fixture 的验证范围与固定官方证据见 [Docs/Komga.md](../../Docs/Komga.md)。
