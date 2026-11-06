# 百度网盘接入示例

[完整指南](../../Docs/BaiduDrive.md) · [Swift 示例](BaiduDriveExample.swift)

依赖 `BoneRemoteSyncKit` 产品并 `import BoneRemoteSyncKit`。百度适配器当前为未发布新增能力；固定 `v0.8.2` 版本不包含此模块，开发接入需使用包含本次实现的源码。

1. 在百度开放平台创建应用，配置回调和所需接口权限；配置 `BaiduDriveConfiguration(appKey:rootPath:)`，rootPath 如 `/apps/你的应用名称`，目录必须已存在并获授权。
2. 使用 `BaiduDriveOAuth` 生成授权事务，由宿主展示系统授权页面；使用同一实例的 `complete(_:callbackURL:)` 校验回调。
3. 无后端时选择 `.implicit`，token 到期需重新授权；有后端时选择 `.authorizationCode`，把 code 交给服务端交换 token。SecretKey 不能打包进 App。
4. `readBaiduFile` 示范完整连接、Transfer、消费 lease、清理和断开。`uploadBaiduFile` 仅上传用户指定的非空文件，非覆盖；父目录需已存在。
5. `saveBaiduCatalog` 保存配置、用户ID和凭据引用，默认只读。需要写入时由宿主显式选择对应权限。

原始来源的 `refreshToken` 回调应向服务端刷新并安全持久化完整新令牌后返回；Catalog 使用 `BaiduCatalogTokenRefresher`，由工厂写入固定凭据引用。百度 refresh token 一次有效，刷新失败不得无限重试。示例不向任何真实账号发请求，不包含账号、密钥或真实下载链接。

下载文件的长期保留由宿主另存到自己的目录。写入失败、取消或异步结果不等于远端回滚；不要自动删除远端文件进行补偿。本期没有持久续传、共享链接或后台传输。
