# Kavita 宿主示例

[KavitaExample.swift](KavitaExample.swift) 只导入 `BoneRemoteSyncKit`，展示 API key 登录、书库/分页 series/搜索/卷章节、封面和进度读取，以及完整章节下载到 Transfer 租约。宿主传入 `KavitaConfiguration`、安全存储中的 key、自己管理的缓存目录路径和文件消费闭包。示例没有内置服务器地址、凭据、UI 或自动执行入口。

调用 `kavitaNativeExample` 时，`consume` 内可以把 `lease.url` 交给宿主阅读器；在闭包返回前完成使用，因为示例会释放租约并关闭 materializer。实际应用如需长时间打开文件，应由应用持有租约到阅读器关闭。多文件或 Image 章节下载为 ZIP，需要宿主明确支持该文件类型；SDK 不把 ZIP 内多个 CBZ 合并为一本漫画。

`saveKavitaEPUBPosition` 是单独的显式写入示例，主下载流程不调用它。传入的是 Kavita reading-order index 与 Kavita DOM XPath；首次 index=0 保存可能被服务忽略，EPUB CFI 或另一引擎的页数不可直接替代。非 EPUB 的普通阅读进度使用 `source.updateProgress(reference, pageNum: value)`，完成时可写总 pages。

密码登录可调用 `source.connect(.basic(username: username, password: password))`。已有 JWT 使用 `connectJWT`；`explicitlyRefreshKavitaJWT` 展示显式刷新和预期账号检查，返回的 token 对由宿主安全保存。成功刷新会使此前的章节引用、下载引用和 sourceBinding 失效，之后需重新获取引用并建立 materializer。

API 合同固定为官方 v0.9.1.4 / `879b8b73eb41d66f88dde8eb874cc99a3397eb11`。本示例及自动测试基于固定源码与虚构 localhost fixture，尚未进行真实部署验收。详细行为、错误含义和固定官方证据见 [Docs/Kavita.md](../../Docs/Kavita.md)。
