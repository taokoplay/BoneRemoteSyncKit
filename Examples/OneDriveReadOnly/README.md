# OneDrive Personal 联调（本示例只用读路径）

本目录是可编译的宿主接入片段，不是已注册的 Microsoft 应用，不会自动读取凭据、登录账号或发出真实请求。不得把 fixture token 当作真实凭据。

## 应用注册

1. 在 Microsoft Entra 注册支持 **Personal Microsoft accounts** 的应用（本 SDK 固定 `consumers` authority，不支持组织租户/SharePoint）。是否能注册及账号权限需实际确认。
2. 取得公开的 Application (client) ID，配置原生 public client 及精确回调 URI。回调 URI 必须与注册值一致，SDK 不创建 scheme handler 或 loopback listener。
3. delegated 文件权限：本示例只用读路径，但库固定申请 `Files.ReadWrite`（写能力需要它，`Files.Read` 会在真实账号上以 403 拒绝写操作），因此同意页会显示“完全访问文件”。请求 `offline_access` 以取得 refresh token。不要创建、分发或写入 `client_secret`；此模块也不读取 client secret。
4. 在支持的平台由宿主用系统授权会话（通常为 `ASWebAuthenticationSession`）打开授权 URL，再将回调传回。tvOS 不包含浏览器授权 UI，可由宿主提供已取得的 OAuth 凭据；模块编译支持不等于设备授权流程已验证。

## 接入顺序

- 初始化 `OneDriveExample(clientID:redirectURI:persistRefreshedToken:)`，回调同步、线程安全地将轮换后的令牌写入当前账号 Keychain；不得阻塞或在内部调用 source。失败应抛错，连接将关闭；不要把令牌写日志或 UserDefaults。
- `beginAuthorization()` 返回 URL；宿主打开系统授权 UI，保存并隔离账号流程；勿记录 URL、state、codeVerifier 或回调。
- 收到 callback 后调用 `completeAuthorization(callback:)`。示例在 await 前消费事务；库 helper 本身为无状态值，直接使用 helper 的宿主也必须一次性消费事务，避免重复兑换。
- **先将首次 OneDriveToken 写入 Keychain**，再 `connect(savedCredential: token.credential)`。自动刷新只通过 `onTokenRefresh` 回传后续令牌。省略该 callback 可用于临时会话，但不会替宿主持久化轮换凭据。
- `page(path:cursor:)` 逐页读取；游标短期、当前连接内有效，下一页保持 path、limit、includeHidden 一致。成功推进会消费旧游标；不得持久化、记录或跨连接使用。
- 选择普通文件后 `download(_:to:)`；目标需在应用可写且独占控制的目录内。示例默认不覆盖已有文件。
- 退出账号时调用 `disconnect()`，由宿主删除该账号 Keychain。库内 disconnect 只取消会话并清内存，不撤销远端授权、不删除宿主凭据。

## 真实账号最小验收（尚未执行）

1. 用专门的测试个人账号完成首次授权、拒绝授权、回调状态不符与取消；核对同意范围。
2. 验证主盘、中文/空格/`#`/`%`路径、大于200条目录分页及文件重命名后ID下载。
3. 用空文件、小文件和大文件检验长度、内容及progress；抓包只记录请求域名/是否有Authorization，不记录token或预授权URL。
4. 验证刷新轮换、重新启动后读取新凭据、授权撤销、网络失败与限流。刷新失败后库关闭连接，避免反复使用可能已消费的refresh token；重新连接或交互授权由宿主决定。
5. 验证下载取消、disconnect/reconnect、链接过期、远端版本变化；失败时旧目标不变。
6. 检查实际CDN是否需要重定向。v1拒绝所有自动重定向；若真实服务依赖它，必须另行设计安全策略，不直接放开凭据跨域。

本地 HTTP fixture 只证明 SDK 在合成服务下的语义，不证明微软 CDN、国内网络、组织策略、移动端或真实大文件行为。
