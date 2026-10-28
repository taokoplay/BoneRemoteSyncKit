# OneDrive Personal 宿主接入示例

[返回项目首页](../../README.md) · [OneDrive 详细语义](../../Docs/OneDrive.md)

[OneDriveExample.swift](OneDriveExample.swift) 演示授权事务管理、连接、分页与下载。目录名保留 `OneDriveReadOnly`，表示**该示例只使用读路径**，不是 SDK 只支持读取，也不是只读授权。

此文件是可编译的宿主片段，不是已注册的 Microsoft 应用；不会自动读取真实凭据、打开登录页面或存储 token。不要把 fixture 中的虚构 token 用于真实账号。

## 依赖与宿主准备

只需为宿主 target 添加 `BoneRemoteSyncKit` 产品，并将示例 Swift 文件加入该 target：

```swift
.product(name: "BoneRemoteSyncKit", package: "BoneRemoteSyncKit")
```

源码统一使用 `import BoneRemoteSyncKit`，无需再分别导入 Core 或 OneDrive。

宿主还需准备：

- 支持个人 Microsoft 账号的 public-client 应用注册和公开 client ID。
- 与注册配置完全一致的 redirect URI，以及 URL scheme／回调处理。
- 系统授权 UI、账号选择与账号隔离的 Keychain 存储。
- 应用可写、可独占的下载目录。

## 应用注册与权限

1. 在 Microsoft Entra 注册支持 **Personal Microsoft accounts** 的应用。SDK 使用 `consumers` authority，不支持组织账号或 SharePoint。
2. 配置原生 public client 和精确回调 URI。SDK 不注册 URL scheme，也不创建 loopback listener。
3. SDK 固定请求 **`Files.ReadWrite offline_access`**。即使这个示例只读取，也会请求写权限；`Files.Read` 不含写权限，不能用于证明 SDK 写操作可用。实际同意页面文案由微软决定。
4. 不创建或嵌入 `client_secret`。原生 public-client 流程不会读取应用密钥。
5. 在支持的平台使用系统授权会话（通常为 `ASWebAuthenticationSession`）。tvOS 没有本示例提供的登录 UI，需由宿主另行提供已取得的 OAuth 凭据。

平台编译通过不代表上述授权流程已在设备上验收。

## 调用顺序

| 阶段 | 调用 | 宿主职责 |
| --- | --- | --- |
| 初始化 | `OneDriveExample(clientID:redirectURI:persistRefreshedToken:)` | 刷新回调同步、线程安全且按账号原子保存 token |
| 发起授权 | `beginAuthorization()` | 用系统 UI 打开返回 URL；不打印 URL、state 或 verifier |
| 处理回调 | `completeAuthorization(callback:)` | 先完成安全存储，再连接；示例在 await 前消费事务，避免重复兑换 |
| 建立连接 | `connect(savedCredential:)` | 传入已保存 token 的 `credential` |
| 分页 | `page(path:cursor:)` | 保持路径及选项一致，逐页推进，不保存或跨连接复用游标 |
| 下载 | `download(_:to:)` | 提供独占目标；示例显式禁止覆盖 |
| 结束 | `disconnect()` | 成功／异常路径都等待调用；退出账号时另外清理对应 Keychain |

`persistRefreshedToken` 只负责后续刷新；**首次 token 必须由宿主在 `connect` 前保存**。刷新回调不能长期阻塞或回调 source；失败应抛错，连接会关闭。省略持久化回调不会自动保存轮换 token。

`disconnect()` 取消会话并清除内存状态，不撤销微软授权，也不删除宿主凭据。用户切换账号时，应取消并隔离未完成的授权流程。

## 写入与大文件

SDK 还支持上传、递归建目录、删除和移动，见 [OneDrive 写入能力](../../Docs/OneDrive.md#写入能力与限制)。Simple upload 上限为 250 MiB；Upload Session 可恢复上传需使用专用构造器显式 opt-in，普通构造器不启用。下载续传和服务端复制仍不支持。

## 真实账号验收清单

**当前尚未完成真实 Microsoft 应用与账号验收。** 本地 fixture 不能证明 CDN、国内网络、组织策略或设备授权行为。

1. 用测试个人账号验证首次授权、拒绝授权、回调状态不符、取消与账号切换。
2. 核对同意范围，验证分页超过 200 项、中文及特殊字符路径，以及文件改名后的 ID 下载。
3. 测试空文件、普通文件及接近上传限制的文件，下载后比较长度与内容；不把进度回调当作远端完成证明。
4. 在专用目录验证创建、上传、移动和删除；确认同名冲突，并检查并发竞争后的实际状态。
5. 验证 token 刷新轮换、重启后读取新凭据、授权撤销、网络失败与限流。
6. 验证取消、disconnect/reconnect、预授权链接过期、远端版本变化；失败时确认已有本地目标未被破坏。
7. 检查实际 CDN 是否依赖重定向。当前拒绝自动重定向，若不兼容需设计安全策略，不能直接放行凭据跨域。
8. 调试日志只保留必要的域名、状态和步骤，不记录 token、完整授权回调或预授权下载 URL。
