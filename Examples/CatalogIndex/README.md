# 配置与目录缓存示例

[Catalog 设计与 API](../../Docs/Catalog.md) · [首页](../../README.md)

`CatalogExample.swift` 是宿主接入片段，不是独立 App。API 尚未发布，不在 `v0.2.0` 标签中。

1. 只依赖 `BoneRemoteSyncKit` 产品。
2. 创建私有 Application Support 子目录，将其中的普通本地文件 URL 传为 `databaseURL`。不要使用同步目录或可清理 Caches。
3. 提供 `RemoteCredentialStore`，生产可采用 `KeychainRemoteCredentialStore(service:)`；自定义实现必须线程安全，并正确设置稳定 `coordinationID`。测试不使用真实 Keychain。
4. Local resolver 从宿主 bookmark/accessReference 恢复授权，返回 rootURL 与匹配的 release 动作；不要把未授权的裸路径当作持久访问权限。
5. 首次调用 `catalogLocalIndexExample` 保存配置、验证选定目录、扫描子树。它每次创建新 profile/root，实际 App 应读取并复用已有记录，而不是每次启动重复注册。
6. 后续使用 `store.profiles()` / `roots(sourceID:)` 恢复导航，调用 `catalogOfflineExample` 可完全离线读取。用户刷新时再构建 Catalog/session factory，并显式调用 `refresh`。

日常目录刷新使用 `.children`；初始化或明确重扫才使用 `.subtree`。处理 `.partial/.failed/.cancelled` 和 `failures`，不要把返回报告当作全树成功。取消后等待 task 返回再关闭数据库。数据库打开期间不要移动、硬链接或手动复制 WAL 文件。

示例不建立系统后台任务、不下载内容、不删除远端文件，也不演示真实账号或真实 Keychain 验收。
