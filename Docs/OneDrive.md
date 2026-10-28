# OneDrive Personal 接入

[返回项目首页](../README.md) · [通用 API](API.md) · [宿主授权示例](../Examples/OneDriveReadOnly/README.md)

`OneDriveSource` 支持 Personal 主盘文件访问与写入，使用 `import BoneRemoteSyncKit`。组织账号、SharePoint 与共享 `remoteItem` 仍未接入。OneDrive Upload Session 可恢复上传通过专用构造器 opt-in；普通 `OneDriveSource(configuration:)` 不启用该能力。真实 Microsoft 账号、大文件与 Keychain entitlement 验收仍待完成。

## 授权接入步骤

1. 在 Microsoft Entra 注册支持个人账号的原生 public-client 应用，取得公开 client ID，配置与宿主一致的 redirect URI。
2. 创建 `OneDriveConfiguration` 和 `OneDriveOAuth`，调用 `authorize()` 得到授权事务。
3. 宿主通过系统授权会话打开事务 URL，保存 state/PKCE 对应事务；不记录 URL、verifier 或回调内容。
4. 收到回调后先一次性消费宿主事务，再调用 `authorizationCode(from:transaction:)` 和 `exchange(code:transaction:)`。
5. 先将首次 token 保存到当前账号 Keychain，再以 `token.credential` 连接。为后续刷新提供同步、线程安全、账号隔离的持久化回调。
6. 成功、失败或用户退出时等待 `disconnect()`。退出账号后的 Keychain 清理由宿主负责。

上述授权 UI 和 URL scheme 注册不是 SDK 内置能力。来源模块的凭据保存仍由宿主负责；[Catalog](Catalog.md) 提供可选 Keychain 桥接与固定引用会话。可编译的事务管理示例见 [OneDriveExample.swift](../Examples/OneDriveReadOnly/OneDriveExample.swift)。

## 使用已取得的凭据

下面的函数不触发登录 UI。调用方提供安全保存的凭据，以及刷新后原子保存新 token 的回调；完整读取根目录需要逐页消费游标。

```swift
import Foundation
import BoneRemoteSyncKit

func listOneDriveRoot(
    configuration: OneDriveConfiguration,
    credential: RemoteCredential,
    persistRefreshedToken: @escaping @Sendable (OneDriveToken) throws -> Void
) async throws -> [RemoteEntry] {
    let source = OneDriveSource(configuration: configuration, onTokenRefresh: persistRefreshedToken)
    do {
        try await source.connect(credential)
        var entries: [RemoteEntry] = []
        var request = RemoteListRequest(limit: 100)
        while true {
            let page = try await source.list(path: "/", request: request)
            entries.append(contentsOf: page.entries)
            guard let cursor = page.nextCursor else { break }
            request = request.nextPage(cursor: cursor)
        }
        await source.disconnect()
        return entries
    } catch {
        await source.disconnect()
        throw error
    }
}
```

此函数把目录结果收集到内存，适用于大小可控的目录；大型目录应逐页消费，而非一直累积。

## 文件元数据

`createdAt` 使用 Graph `driveItem.createdDateTime`，不是 `fileSystemInfo.createdDateTime` 或拍摄/录制时间；缺失、字段类型错误或日期无法解析返回 nil，不使用修改时间兜底；其他关键字段仍严格解码。list、stat、下载及收到 driveItem 的写入返回值共用映射，下载仍返回远端条目时间，不主动设置本地目标时间。`contentType` 来自 `file.mimeType`，由[通用分类规则](API.md#文件时间与类型分类)转换为列表展示提示；不下载或分析文件内容。

## 认证与生命周期

- **只支持 Personal 主盘**，不包含组织/SharePoint、共享 `remoteItem`、package、已删除条目；遇到不支持的 facet 明确报错，不静默漏掉。
- SDK 提供授权 URL、严格 state/redirect/重复参数校验、PKCE S256、code 兑换和刷新；来源模块不包含授权 UI、账号凭据 Keychain、账号选择、回调注册、device code flow 或 app secret。
- 使用 `Files.ReadWrite offline_access`，`consumers` authority。写入能力（`upload`/`makeDirectory`/`remove`/`move`）要求写权限，`Files.Read` 不包含写权限，写请求可能被服务端以 403 拒绝（不是本项目的真实账号验收结果）；库固定申请写权限，只读宿主也会被要求同意“完全访问文件”。helper 无状态，宿主应一次性消费授权事务；原生 public client 不嵌入 secret。
- `onTokenRefresh` 是同步 throwing `@Sendable` 提交回调，必须原子保存到所属账号，不能回调 source 或长期阻塞。回调成功才发布新凭据；失败关闭连接且错误不包含宿主异常细节。省略时只更新内存，**不会持久化轮换 token**。
- 并发请求共享一次刷新。单个等待者取消时，仍会等待刷新收敛并提交当前账号已轮换的凭据，再抛取消；可能等待至该 HTTP 请求的 timeout。`disconnect()` 会取消共享请求。连接代次检查防止旧会话回写新会话。
- 刷新发生网络或认证失败时，会关闭当前连接，避免重复使用可能已轮换的旧 refresh token；是否重新授权由宿主决定。
- 普通 Graph API 的 HTTP 401 最多触发一次刷新与重放（Upload Session 创建例外，见下节）；CDN 401/403 只在尚未打开 staging 时重新获取一次链接。普通读写不对 429 / 5xx 自动重试；Upload Session 使用独立有界重试。429 映射为 `.rateLimited(retryAfter:)`，支持整数秒或 HTTP 日期；不能仅依据 `isRetryable` 重试令牌兑换。
- `timeout` 是每次 HTTP 请求的时间预算，不是整个分页、授权或多阶段下载的共享截止时间。同步宿主回调和本地 I/O 不可强制抢占。

## 条目、分页与下载安全

- `RemoteEntry.id` 是 `driveID + itemID` 的不透明编码，`path` 只用于展示/路径定位，下载始终重新按 ID 查元数据。Graph eTag 仅用于元数据变化检查，不作为 CDN HTTP validator。
- `RemoteIDAddressableSource` 支持 `stat(id:)`、`list(parentID:request:)` 和 `download(id:to:options:)`。按 ID 读取不依赖旧路径；重命名后条目可能 `path == nil`。ID 只在当前 Personal 主盘和连接会话内有效，不能拼接 Graph URL、下载 URL 或跨账号复用。
### 分页与游标

- `list` 保留服务端顺序，默认过滤点开头的隐藏名称。`limit` 可为 nil，非 nil 时必须为正数；向 Graph 发送 `min(limit, 200)`，不保证返回条数精确等于该值。
- `RemoteListRequest.all` 不会自动读完所有页面，必须继续消费 `nextCursor`。通用参数约定见[分页说明](API.md#分页)。
- 游标绑定当前连接、路径/父 ID 寻址模式、父标识及选项；成功推进后旧游标失效，断开连接会清空。按 ID 获得的页面条目不虚构路径。最多保留 256 个待推进游标，满时淘汰最早的未推进项；已消费或已淘汰的游标明确报错。
- `nextLink` 必须同源、同 API 版本，并指向同一目录的 children 资源。检测游标循环，只保存 URL 的 SHA-256，单目录最多 10,000 页。这不是整个 App 的内存硬上限；Core visitor 遍历另行检查整次条目预算。

### 网络与下载链接

- Graph 固定为 `https://graph.microsoft.com/v1.0/`，token 端点固定使用微软 `consumers`。JSON 响应最多 8 MiB，token 响应最多 1 MiB。
- 使用系统 TLS 校验，不带系统 Cookie 或环境认证，不自动跟随重定向。
- 预授权下载 URL 只来自受认证 Graph 响应，不进入公开条目、稳定 ID、游标或日志。CDN 请求不携带 Graph bearer 或 Graph `If-Match`。
- 下载链接仅允许 HTTPS，拒绝 userinfo、fragment 及明显本地／私网字面量地址；不限定微软 CDN 域名后缀。这不是完整 SSRF 或 DNS rebinding 防护，仍需信任 Graph 和当前网络环境。

### 下载、落盘与并发

- **仅完整下载，无 Range 续传。** 任何非 nil `resumeFrom`（包括 0）均报不支持；拒绝 206、非 identity 编码、Content-Range 及长度异常。
- 默认校验 Graph 大小；关闭 `verifySize` 也不允许超出 Graph 大小，并始终检查已声明的 HTTP 长度。下载前后查询 Graph 元数据，发现 eTag 或大小变化则不安装。
- 上述检查不是 Graph/CDN 之间的事务快照或内容哈希验证。`contentHash == false`，缺少可靠 eTag 时不保证强版本校验。
- 使用同目录随机 `0600` staging，独占创建、NOFOLLOW、分块写、fsync、身份和硬链接检查，最后原子 rename。失败只清理本次 staging，已有目标、`.part` 和 checkpoint 不变；自动创建的父目录可能保留。
- 拒绝目标 symlink、目录和多硬链接。同一 source 内对大小写、字符宽度与 Unicode 等价目标保守互斥；跨实例／进程仍须由宿主协调。
- progress 在串行 HTTP delegate 队列回调，必须线程安全且快速返回；取消时已经进入的回调可能仍在返回中，不是硬实时抢占。
- 恶意父目录 TOCTOU、系统 sandbox、后台传输、断电持久性与 security-scoped bookmark 均不在这些保证内。

## 写入能力与限制

`OneDriveSource` 同时遵循 `RemoteWritableSource` 和 `RemoteIDAddressableSource`。普通构造器的能力位为 `idAddressing`、`upload`/`makeDirectory`/`remove`/`move` 为 true，`conditionalUpload`、`resumableUpload`/`rangedDownload`/`copy` 为 false；传入独立 `resumableUploadService` 的专用构造器才将 `resumableUpload` 设为 true。该 service 使用 OneDrive 私有、设备内、不参与同步的 Keychain 会话记录。宿主仍负责 service 选择、私有快照目录、连接生命周期和授权。

以下写片段在已连接的 `source` 上执行，`staging` 必须指向宿主提供的真实普通文件。示例路径及删除动作需由调用方明确授权。

```swift
let staging = URL(fileURLWithPath: "/tmp/report.txt")
try await source.makeDirectory(path: "/归档/2026")
let uploaded = try await source.upload(
    from: staging,
    to: "/归档/2026/report.txt",
    options: .init(overwrite: false, contentType: "text/plain")
)
try await source.move(from: "/归档/2026/report.txt", to: "/归档/2026/final.txt")
try await source.remove(path: "/归档/2026/final.txt")
print(uploaded.path ?? uploaded.id)
```

| 操作 | 语义与限制 |
| --- | --- |
| `upload` | Graph simple upload 单次 PUT，**上限 250 MiB**，超出抛 `.unsupported`，不降级到 upload session。只接受普通文件，不能用文件覆盖根目录。 |
| MIME 请求头 | `RemoteUploadOptions.contentType` 作为 PUT 的 `Content-Type` 发送，默认 `application/octet-stream`；401 刷新后的认证重放保留该值。空值、控制字符或超过 1024 UTF-8 字节的值在请求前拒绝；此检查不等于完整 MIME 语法校验，也不保证 Graph 最终返回相同 MIME。 |
| 覆盖行为 | `RemoteUploadOptions.overwrite == true` 时发 `@microsoft.graph.conflictBehavior=replace`，否则发 `fail`；不在本地抢先判断，冲突由服务端结果决定。 |
| `makeDirectory` | 逐级递归创建，已存在目录视为成功，同名文件抛 `.conflict`；目标为根目录时直接返回。 |
| `remove` | 删除文件或整棵目录；拒绝删除根目录；不存在时按 Graph 结果映射错误。 |
| `move` | Graph PATCH 改名或移动；先查询并拒绝已存在的目标，随后发出 PATCH。当前没有为 MOVE 显式附带原子非覆盖条件，不应将预检描述为并发竞争保护；不实现服务端复制。 |
| 进度与取消 | `upload` 的 `progress` 来自 URLSession delegate 串行队列，必须线程安全且不长期阻塞；取消后已发出的请求可能仍到达服务端，库不做补偿删除。 |

写操作同样在返回前做 generation 检查，连接断开或重连后的旧会话结果不会回写；但普通写入不提供事务语义或写入后自动校验（上传结果校验 Graph 条目类型、名称及驱动归属等字段；不做回读或哈希比对，也未将返回 size 与本地源长度作相等校验）。

### Upload Session 可恢复上传（显式 opt-in）

使用 `try OneDriveSource(configuration:resumableUploadService:onTokenRefresh:)` 启用；普通初始化器仍为 `resumableUpload == false`。`resumableUploadService` 是宿主选择的独立 Keychain service，不与 Catalog 的账号凭据混用。生产 API 不开放 session store 注入；内部 seam 仅用于测试。构造器本身不访问 Keychain。

#### 准备、持久化句柄与继续

`prepareResumableUpload` **只进行本地准备，不创建远端 session**：复制源文件为私有快照，并保存安全记录后返回 `RemoteUploadHandle`。宿主应先持久化这个 handle，再调用 `uploadResuming`；也可使用仅依赖 Core 的 [RemoteUploadRecovery](Transfer.md#显式恢复上传onedrive) 通用入口。

```swift
import Foundation
import BoneRemoteSyncKit

func prepareOneDriveUpload(
    source: OneDriveSource, // 已通过专用构造器启用并连接
    input: URL,
    targetPath: String,
    privateSnapshotDirectory: URL,
    saveHandle: @Sendable (RemoteUploadHandle) throws -> Void
) async throws -> RemoteUploadHandle {
    let binding = try await source.connectedBinding()
    let recovery = RemoteUploadRecovery(source: source, binding: binding)
    let handle = try await recovery.prepare(
        from: input,
        to: RemoteFileReference(source: binding, path: targetPath),
        options: .init(snapshotDirectory: privateSnapshotDirectory)
    )
    // 保存失败时尚未发出远端写请求，显式取消本地准备。
    // 生产宿主若还需重试保存，应在其自己的任务状态中保留 handle。
    do {
        try saveHandle(handle)
    } catch {
        try await recovery.abort(handle)
        throw error
    }
    return handle
}

func resumeOneDriveUpload(
    source: OneDriveSource,
    savedHandle: RemoteUploadHandle
) async throws -> RemoteResumableUploadResult {
    let recovery = RemoteUploadRecovery(source: source, binding: try await source.connectedBinding())
    return try await recovery.resume(savedHandle)
}
```

- 当前仅支持路径目标、Personal 主盘、**大于0且不超过5 GiB** 的普通文件；空文件请使用 simple upload。默认 `overwrite == false`，替换必须显式指定 true。`expectedETag` 在本地准备前拒绝，**不支持最终条件替换**；不能将创建时检查误称为提交 CAS。
- 默认分片5 MiB；配置须为320 KiB正整数倍且小于60 MiB。GET原session后选择首个缺口，顺序发送；不支持安全对齐的、越界或重叠range拒绝继续。GET/202不要求重复返回uploadUrl。
- `progress` 与 checkpoint 的 `confirmedBytes` 都表示服务端确认的连续前缀，不是本地发送字节数，也不是全部非连续已收区间的总和。持久checkpoint是最近观察，不自动联网刷新；确认100%仍不能代替有效提交回执。

#### 秘密、快照与互斥

- 预认证uploadUrl仅保存在OneDrive私有记录中，使用 `kSecAttrSynchronizable=false`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不隐式指定共享access group。设备首次解锁后锁屏仍可访问；跨设备恢复不支持。公共handle/checkpoint不包含URL、token、cookie或FileHandle，但目标路径和源SHA-256仍属于可能敏感的元数据，宿主须妥善保存。
- 宿主提供当前用户拥有、权限私有、祖先稳定且**在所有同步根之外**的本地快照目录。SDK不探测是否被iCloud或其他网盘同步。快照用0600、独占创建、NOFOLLOW、单hardlink、device/inode/大小与SHA-256校验；每320 KiB块另存摘要，在读入不可变Data后、发出前校验，避免校验后原inode被修改而上传不同内容。
- 同一快照目录内所有上传共享 `flock(LOCK_EX | LOCK_NB)`，冲突立即失败；它是目录级而非每handle并行锁。锁后重读安全记录；锁文件永久保留，不可在参与者存活时替换/删除。实际进程退出由内核释放锁。不同目录、绕过协议、恶意祖先替换不在合作互斥保证内，不提供分布式锁或断电目录项持久保证。
- Graph创建POST携带bearer；session PUT/GET/DELETE绝不附加bearer或cookie，不自动跟随重定向。session URL仅接受受约束HTTPS（测试显式loopback除外），不是任意调用方URL入口，也不宣称完整DNS rebinding防护。

#### 明确结果与未知结果

| 状态/返回 | 处理语义 |
| --- | --- |
| `.preparing` | 尚未创建session；首次resume预写创建意图后发送POST。明确400/401/403/404/409/412/429拒绝恢复为preparing并抛具体错误，允许后续显式重试/abort；创建POST不自动401重放，需由宿主处理授权。 |
| `.creationUnknown` | POST已进入可能发出窗口，响应丢失、无法验证或安全保存失败。保留句柄和快照，不重新POST，不自动abort/forget；没有拿到URL时无法查询该session，需人工核对和服务端过期清理。 |
| `.uploading` | 每次resume先GET原session；429/5xx有界退避，416重新查询，连续无进展最多5轮。Retry-After超过30秒则原样返回rateLimited，而非提前重试。过期/权限/源快照错误通过typed error报告，checkpoint可能仍保留上次持久phase。 |
| `.conflict` | 完整PUT 409/412明确拒绝；不再重放PUT，可显式abort原session。未实现Personal的手动冲突提交或改名恢复。 |
| `.reconciling` / `uploadCommitUnknown` | 最终PUT前已持久提交风险；丢失或不可信回执不能推断失败。核对期间取消仍为未知；404、同名同大小文件或观察到ETag均不能证明本次归属。保留证据，不自动新建、删除或覆盖；GET证明仍有合法缺口时可继续同session。 |
| `.committed` / `.committedCleanupPending` 结果 | 两者都表示收到经类型、大小、名称、drive、父ID验证的200/201回执。后者是本地回执保存或清理待处理，不是远端失败。宿主应持久保存返回结果；若安全回执保存失败，后续checkpoint仍可能是reconciling，不能重复创建上传。 |
| `.abortUnknown` | DELETE前已持久意图，响应丢失或无法验证；不自动重发DELETE或丢弃证据。 |
| `.aborted` | local-only准备已取消，或原session DELETE已确认204；不代表撤销已提交的远端文件。 |

成功回执持久保留，重复resume直接领取原结果，并清除记录中的秘密URL。快照清理失败不会把已知成功降为未知。宿主先保存终态结果，再显式 `source.forgetResumableUpload(handle)` 删除本地终态记录；仅committed/aborted可forget，替换过的快照不会被误删。未知创建/提交/abort不允许以abort或forget丢弃证据，当前没有自动核对归属或孤立记录清扫API。

已完成localhost故障fixture、内存存储与Security后端替身、实际进程竞争/SIGKILL恢复检查；**并非真实Microsoft账号、真实Keychain entitlement、移动平台运行、断电或性能验收**。完整证据见[验证记录](Validation.md)。

## 官方接口依据

- [原生授权码与PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [注册应用](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
- [列出子项与分页](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0)
- [driveItem及预授权下载URL](https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0)
- [Upload Session合同](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
- [文件下载、短期URL与Range语义](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0)

## 可选配置与离线索引

[Catalog](Catalog.md) 保存应用配置、已核对的主盘 ID、选定目录及列表元数据，不保存 nextLink/cursor/预授权下载 URL。`connectedDriveID()` 仅在成功连接期间可用，供宿主初始化绑定，不泄露 token。首次授权与每次轮换都要保存完整凭据，同 reference 的独立 source 不能并发轮换；Catalog 以引用级 lease 协调。根按路径绑定，改名需重新选择，不把旧子树自动改写为新路径。
