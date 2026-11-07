# 百度网盘应用目录来源

[首页](../README.md) · [Swift 示例](../Examples/BaiduDrive/README.md) · [Catalog](Catalog.md) · [Transfer](Transfer.md) · [验证记录](Validation.md)

> 百度模块已在推送的开发源码中，尚未纳入版本标签，`v0.8.2` 不包含它；最新统一来源枚举仍需当前工作区，见[版本对照](../README.md#开发源码与版本范围)。独立 `BoneRemoteSyncBaidu` 仅依赖 Core 与系统框架，由 Kit 导出。实现依据官方开放 API；真实应用审核、OAuth、用户目录权限及线上文件操作尚未验收，本地 fixture 不能替代真实账号验收。

## 接入范围

提供 `BaiduDriveSource`，遵循 `RemoteCopyingSource`、`RemoteIDAddressableSource`。`RemoteSourceKind.baidu` 使用既有百度图标，`driveTypes()` 中百度项的 id/kind 都是 `.baidu`。具体厂商、协议与书库统一用 `RemoteSourceKind`，接入方可用 `Set<RemoteSourceKind>` 筛选显示范围，见 [来源类型 API](API.md#图标与来源类型-api)。

| 能力 | 当前范围 |
| --- | --- |
| 授权 | 官方简化模式/授权码模式的URL和回调校验；SDK不内置SecretKey |
| 连接 | OAuth或apiToken；先uinfo，再验证配置根目录；可指定expectedUserID |
| 浏览 | list按start/limit分页，单页最多1000；来源内路径映射到应用目录 |
| stat/按ID读取 | method=meta路径查询、multimedia/filemetas按fs_id查询；返回路径必须仍在授权根内 |
| 下载 | filemetas获取dlink，附access_token和固定User-Agent，流式完整下载、进度、取消、目标保护 |
| 上传 | 私有不可变快照，4 MiB分片，precreate → locateupload → superfile2 → create；0 < 大小 ≤ 4 GiB，可配置更低上限 |
| 文件管理 | 递归建目录；同步move/copy/delete，目标冲突失败；同一来源串行写入 |
| Transfer | 路径或来源签发ID引用、完整文件物化、可信SHA-256校验（宿主提供）、coordinator和lease |
| Catalog | 保存应用配置、用户ID、权限与凭据引用；目录索引及离线查询；打开前核对账号 |
| 未提供 | 共享链接/转存、全盘或其他应用目录、Range/分片下载、持久续传、后台任务、远端变更流、强条件写入、公开内容哈希 |

上传分片不等于可恢复上传，`resumableUpload=false`。不支持 `expectedETag`、下载 `resumeFrom` 或强版本策略，明确失败而非静默忽略。空文件上传和precreate非1的内部完成状态当前不支持；若服务端已产生副作用需宿主核对。

## 应用、目录和授权

官方权限文档要求第三方应用仅在权限内目录操作，默认目录是 `/apps/{appname}`，用户通常看到“我的应用数据/应用名称”。首期 SDK 要求显式 `rootPath` 位于 `/apps/` 下，支持其子目录；`/` 是该配置目录，不是用户整个网盘。不能用 `%2F` 等预编码路径替代原始路径；SDK只进行一次请求编码。

配置字段：`appKey`（公开AppKey，不是SecretKey）、`rootPath`、`timeout`（默认60秒）、`maxConcurrentTransfers`（默认3，上限8）、`maxUploadBytes`（默认4 GiB）。配置解码仍执行校验，不支持自定义生产API端点。HTTP测试端点仅为内部localhost替身，不对宿主开放。

百度授权码交换/刷新要求 SecretKey，需由宿主服务端执行。官方文档没有声明PKCE，本SDK不伪称提供PKCE；授权使用随机state、精确回调地址核对、10分钟事务期限、最多8个未完成事务和单次消费。回调取消或失败由宿主重新发起，不记录完整回调URL。简化模式返回短期token，不提供refresh_token。

```swift
import Foundation
import BoneRemoteSyncKit

func connectBaidu(appKey: String, appRoot: String, token: BaiduDriveToken,
                  refresh: BaiduDriveTokenRefresher? = nil) async throws -> BaiduDriveSource {
    let config = try BaiduDriveConfiguration(appKey: appKey, rootPath: appRoot)
    let source = BaiduDriveSource(configuration: config, refreshToken: refresh)
    try await source.connect(token.credential)
    return source // 调用方在实际使用结束后等待 disconnect()
}
```

`BaiduDriveToken` 显式承载accessToken、可选refreshToken、expiresAt，description/debugDescription脱敏；不自动落盘。普通来源的 `refreshToken` 回调由宿主调用自己的可信服务端，并安全持久化新令牌后返回。SDK在到期前30秒触发，同一实例合并并发刷新；成功后核对用户ID。刷新失败使会话失效，不使用旧refresh_token重复刷新。回调的跨实例/跨设备互斥由宿主服务端负责，因为百度refresh_token一次有效；回调必须响应取消，旧回调的持久化也应绑定账号，不能写入“当前账号”。

`.apiToken` 或缺少expiry的 `.oauth` 不执行自动到期刷新，授权错误直接返回，宿主重新授权或重建会话。SDK不会因收到认证错误自动重放写请求。建议保存完整expiry与轮换token。

## 路径、ID、分页与文件版本

- 所有公开路径相对于 `rootPath`；读写请求和返回路径都验证根目录边界，`/apps/YourApp2` 不是 `/apps/YourApp` 的子目录。
- `connect(_:expectedUserID:)` 用于已有绑定，账号不一致时在目录请求前失败。Catalog 自动使用此入口；第一次直接连接后用 `connectedUserID()` 获取用户身份。
- 条目ID包含应用、用户、根的非敏感作用域摘要及精确uint64 fs_id；必须使用SDK签发ID，不能把原始fs_id、路径或URL混用。支持按ID跟随同一根内的重命名；跨账号或移出根会拒绝。ID不是授权凭据，真正权限由百度服务端决定。
- `connectedBinding()` 可用于Transfer；不要并发重绑正在被materializer使用的来源。网络连接有独立generation，断开/重连使旧请求与游标失效。
- 分页令牌绑定路径/父ID/原始limit/includeHidden和连接；推进后旧游标失效，失败后从第一页重试。满页会生成下一游标，允许最后请求返回空页。单条分页链最多100000条目，超限失败；最多保留1024个活跃游标，新增时淘汰最旧的未消费游标。被淘汰或已消费的游标返回`invalidCursor`，不阻塞新列表请求。
- 返回列表验证直接子项、重复ID/路径和每项错误，隐藏文件按includeHidden过滤；标有unlist的结果为partial。offset分页不是瞬时快照，即使每页complete也不能推导远端删除。
- `server_ctime/server_mtime`为服务端Unix时间，缺失保留nil。MIME未由元数据可靠提供时保持nil，通用fileCategory可按扩展名提示。
- 官方列表页称md5是“云端哈希（非文件真实MD5）”，元数据页描述不同。SDK不将其作为`contentChecksums`、ETag或强版本；只在单次下载前后作内部观察比较。Transfer的size+mtime缓存是启发式指纹，不保证发现同大小同时间的内容替换；需最新内容时使用`.refresh`，强条件一致性不支持。

## 下载与写入语义

下载每次重新查询dlink，保留其签名查询串，仅在验证后的百度服务域名附加token。请求固定 `User-Agent: pan.baidu.com`；API/upload禁止重定向，下载允许最多5次经过校验的HTTPS跳转，禁止降级，不向新主机自行追加原token，不使用共享Cookie或凭据。允许的生产域名为 `pan.baidu.com`、`pcs.baidu.com`及子域、`baidupcs.com`及子域；新服务域名须核对后扩展，不能使用任意 `*.baidu.com`。

响应长度与元数据大小必须一致，下载前后重新查询同一ID并比较已观察版本，成功后原子安装；不构成远端原子快照。普通JSON/HTML文件可下载，避免把通用文件接口误限于书籍；包含`request_id`和非零`errno/error_code`的完整小JSON（≤64 KiB）作为百度错误响应拒绝，合法用户文件如果恰好同形也会被拒绝。这是明确的保守边界，不声称完整文件格式验证。

下载失败清理本次staging并保留旧目标；`overwrite=false`采用原子非覆盖。下载取消等待对应委托失效后返回，disconnect会请求取消，宿主仍应等待自己的在途任务结束。目标互斥限定同来源实例；宿主负责跨实例/进程目标协调。

上传先建立私有磁盘快照，源必须是普通单硬链接文件，拒绝符号链接/FIFO；检测复制期间源身份、大小、时间变化。约需文件大小额外空间，每块4 MiB，MD5仅用于官方分片协议。上传域名来自locateupload，验证后使用，不固定示例主机；只上传precreate指定分片，检查分片MD5，最后提交有序block_list。未知结果不自动重试、不自动远端回滚。普通覆盖是整文件替换；non-overwrite通过rtype=0要求冲突失败，不能擅自改名。

上传进度按本次服务端确认的分片字节报告，最终大小只在create成功后报告；服务端跳过重复分片时可能跳跃，不提供瞬时网络发送速率。父目录必须存在；`makeDirectory`可显式逐级创建，根目录必须预先存在，根写入/删除/移动/复制被拒绝。contentType仅校验入参，百度按文件名处理，无法保证写入MIME。

文件管理使用`async=0`、非覆盖策略，检查顶层和每个结果码；即使顶层errno=0，taskid非零仍返回`asynchronousResult`，不能把排队任务当完成。失败、超时和取消不证明远端未执行，重试前需核对目标。多个写操作在同一来源实例互斥，不是跨实例事务。

HTTP元数据响应上限8 MiB；并发上限同时作用于浏览、元数据和下载/分片请求，超额直接返回限流。SDK无隐藏自动网络重试，宿主应按接口和业务结果制定策略；`isRetryable`不能用来无条件重放写入。

## Catalog 接入

保存 `.baidu(configuration:userID:)`，userID必须来自已连接来源；存储的是公开配置、用户ID和UUID凭据引用，token仅在凭据store内。默认`.readOnly`，编辑/新增/删除按现有权限模型显式授权。枚举增加provider，无需修改数据库schema；旧SDK无法理解百度配置。

Catalog factory可传 `baiduTokenRefresher`，参数为固定配置、用户ID和旧令牌；回调经宿主后端刷新后返回新令牌，由工厂同步写入原凭据引用。撤销后的旧回调不能重新建立凭据；服务端需按固定用户/应用串行刷新并保存轮换结果。配置根或账号变化需要新的binding和重新选根。

目录刷新、离线缓存、统计和显式失效复用Catalog；文件变更后宿主调用invalidateCache或refresh。受控会话不把百度声明为强条件来源，也不自动集成后台任务。完整生命周期示例见 [BaiduDriveExample.swift](../Examples/BaiduDrive/BaiduDriveExample.swift)。

## 官方依据与验证边界

本次核对的官方入口（2026-11-05读取，网页可能更新）：

- [授权码模式](https://pan.baidu.com/union/doc/使用入门/接入授权/授权码模式/)与[简化模式](https://pan.baidu.com/union/doc/使用入门/接入授权/简化模式接入/)
- [权限与配额](https://pan.baidu.com/union/doc/使用入门/权限与配额/)
- [用户信息](https://pan.baidu.com/union/doc/基础网盘服务/获取用户信息/获取用户信息/)、[文件列表](https://pan.baidu.com/union/doc/基础网盘服务/获取文件信息/获取文件列表/)、[文件查询](https://pan.baidu.com/union/doc/基础网盘服务/获取文件信息/查询文件信息/)
- [下载](https://pan.baidu.com/union/doc/基础网盘服务/下载/)、[管理文件](https://pan.baidu.com/union/doc/基础网盘服务/管理文件/)
- [预上传](https://pan.baidu.com/union/doc/基础网盘服务/上传/预上传/)、[分片上传](https://pan.baidu.com/union/doc/基础网盘服务/上传/分片上传/)、[获取上传域名](https://pan.baidu.com/union/doc/基础网盘服务/上传/获取上传域名/)、[创建文件](https://pan.baidu.com/union/doc/基础网盘服务/上传/创建文件/)

官方权限与配额页当前写明：未审核应用仅用于开发测试，访问频率10次/小时、最多10个授权用户；生产权限与配额依审核分配。默认目录范围和接口权限并非仅由SDK配置决定。不要复用文档示例token、抓取网页Cookie或绕过服务端授权。

本次受控测试使用虚构AppKey/token、localhost和内存凭据store；没有真实百度应用、用户授权、线上写入、大文件性能、网络地区差异或Keychain entitlement验收。完成真实联调需要宿主的AppKey、已登记回调、授权应用目录和测试用户的有效token；SecretKey仍由宿主服务端保管，不需要提供给SDK。构建和测试结果记录在[验证总览](Validation.md)。
