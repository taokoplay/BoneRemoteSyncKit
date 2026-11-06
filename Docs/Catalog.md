# 配置持久化与离线目录索引

[首页](../README.md) · [通用 API](API.md) · [接入示例](../Examples/CatalogIndex/README.md) · [百度接入](BaiduDrive.md) · [验证边界](Validation.md) · [错误日志](Logging.md)

> 本页描述已发布 `v0.8.2` 的 Catalog API 与当前工作区未发布的百度配置；百度需使用包含本次实现的源码。可组合访问权限自 `v0.7.0` 提供，统计快照、缓存失效、iCloud 配置接入和 schema v2 迁移自 `v0.6.0` 提供。OPDS 尚未接入 Catalog。真实 Keychain、账号及宿主授权验收仍待完成；百度尚无真实应用或 token，fixture 不等于线上验收。

## 能力与层次

`BoneRemoteSyncCatalog` 是可选上层模块：保存 Local、WebDAV、OneDrive Personal、iCloud Drive 和百度（未发布）的非敏感配置、选定目录、文件元数据及刷新状态。`BoneRemoteSyncKit` 统一导出它；只需要传输时仍可单独依赖 Core 和来源产品，基础模块不依赖数据库。

- `RemoteSourceProfile`：稳定来源 ID、账号/端点绑定 ID、配置修订、typed configuration 和凭据引用。
- `RemoteCatalogRoot`：选定目录的路径与来源 ID、过滤规则、默认刷新范围和 selection revision。
- `SQLiteRemoteCatalogStore`：离线查询与持久化，使用系统 SQLite，无第三方运行依赖。
- `RemoteCredentialStore` / `KeychainRemoteCredentialStore`：同步线程安全的凭据存储。SQLite 只存 UUID 引用。
- `RemoteCatalogSessionFactory`：固定绑定的短生命周期连接，恢复凭据、核对 OneDrive 主盘或百度用户 ID、持有 Local 访问 lease。
- `RemoteCatalog`：保存来源、验证/保存根选择、显式刷新和查询缓存。

它不是同步引擎、内容缓存或下载队列。刷新不调用远端 mutation，不删除已下载文件，不安装定时器，不提供跨进程扫描调度。

## 路径与存储统计

`RemoteCatalogRoot.path` 是具体账号/来源保存的选定路径；它不属于静态 `driveTypes()` 网盘类型列表。`RemoteCatalog.storageSummary(rootID:)` 返回最近一次完整 subtree 扫描的 `RemoteCatalogStorageSummary`，包含递归文件数、目录数、已知总字节数、完整性/过期状态和测量时间。

统计规则：

- 只有保存 root 的完整 `subtree` 刷新成功后才写入或替换统计；`children` 刷新不会覆盖递归统计。
- 任意文件缺少可靠 `size` 时，文件数仍统计，但 `totalBytes` 为 `nil`，不会把未知大小当作 0。
- `capacityBytes` 和 `usedBytes` 只来自来源 quota 能力；Catalog 不用目录扫描推算网盘容量。
- 刷新失败、取消、超时或宿主调用 `invalidateCache(rootID:directory:)` 后，保留旧统计并标记 `isStale=true`。
- `clearIndex`、重新选择 root、binding 重绑和 profile 删除会清理对应的文件列表缓存与统计；删除只影响本地 Catalog，不删除远端文件或 Keychain 凭据。
- 保存 root 路径失效时，root 刷新只对 `notFound` 自动验证并回退到来源 `/`，旧路径统计不会沿用；权限、认证、网络和身份错误原样返回。

```swift
let root = try await catalog.store.root(id: rootID)
let summary = try await catalog.storageSummary(rootID: rootID)
print(root.path, summary?.recursiveFileCount as Any, summary?.totalBytes as Any)

// 在宿主通过来源 API 完成上传、删除或移动后标记缓存过期。
try await catalog.invalidateCache(rootID: rootID, directory: root.path)
```


## 数据库位置与所有权

宿主显式传入 `databaseURL`，并事先创建私有本地目录，通常位于 Application Support。配置库不应放在可被系统清理的 Caches、NAS/WebDAV 挂载、iCloud 或其他同步目录。

```swift
import Foundation
import BoneRemoteSyncKit

func openCatalogStore(privateDirectory: URL) throws -> SQLiteRemoteCatalogStore {
    try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
    return try SQLiteRemoteCatalogStore(databaseURL: privateDirectory.appendingPathComponent("catalog.sqlite"))
}
```

- 单进程、单 store owner；同进程按文件设备/节点身份拒绝重复 owner。数据库必须为单硬链接普通文件；不支持打开期间被替换、移动、重新链接或外部修改。
- SQLite 操作在专用串行队列执行；事务内没有 `await`、网络调用或凭据回调。网络分页暂存按最多 500 条一批写入；正式发布仍以整个目录为事务边界，大目录发布可能占用队列较久。
- 使用 WAL、外键、3 秒 busy timeout、FULL 同步和自动 checkpoint；显式 `close()` 尝试 TRUNCATE checkpoint。关闭前先取消并等待所有使用者。
- SQLite **不自行加密**。路径、文件名、账号标识同样是私密数据；目录权限、平台文件保护、设备备份策略及日志脱敏由宿主负责。
- 活跃 WAL 下不能只复制主 `.sqlite` 文件。首版未提供导出/备份 API；要做文件备份，先停止所有使用者并成功关闭数据库，再由宿主备份。不要独立复制、删改 `-wal` / `-shm`。
- 已支持 v1 → v2 的安全迁移：新增统计表并保留既有 profile/root/列表缓存，旧 root 的 summary 初始为空。未知 schema、外来数据库或初始化期间发现的损坏明确报错，不自动删库重建；不执行全库 `quick_check`/`integrity_check` 或逐表结构比对。
- 可注入 `logger: RemoteLogger`，自动记录初始化/关闭失败以及成功恢复的中断 run 数量。Catalog 高层操作继承同一 logger；默认关闭、无日志表、不保留错误原文。自动覆盖范围与宿主职责见[错误日志规范](Logging.md)。

## 配置与秘密分离

`RemoteSourceConfiguration` 的来源类型是明确枚举，对应 `RemoteCatalogProvider` 的 `.local`、`.webDAV`、`.oneDrive`、`.iCloud` 和未发布新增 `.baidu`，不能只靠 `.cloudAPI` 推断具体网盘：

| 配置 | 保存内容 | 不保存内容 |
| --- | --- | --- |
| `.local(accessReference:)` | 宿主定义的访问引用 | 已连接状态、security scope、Task |
| `.webDAV(baseURL:timeout:retry:)` | collection URL、请求与只读重试参数 | URL userinfo、密码、Authorization |
| `.oneDrive(clientID:redirectURI:driveID:timeout:)` | public-client 应用参数、已核对的 Personal 主盘 ID | token、nextLink、预授权下载 URL |
| `.iCloud(configuration)` | 容器标识和配置目录等 `ICloudDriveConfiguration` | 系统账号凭据、entitlement、已连接状态 |
| `.baidu(configuration:userID:)`（未发布） | `BaiduDriveConfiguration` 的公开 AppKey、授权根、超时/并发/上传上限及已核对用户 ID | SecretKey、token、dlink、远端 cursor；凭据仅保存 UUID 引用 |

百度配置必须指向已存在且获授权的 `/apps/{app}` 或子目录，来源 `/` 仅表示这个配置根；Catalog 选根不能扩大为全盘权限。新增 provider 沿用当前数据库 schema，无需升级表结构；旧 SDK 不能理解百度配置。

`RemoteSourceProfile.permission` 使用 `RemoteAccessPermission`（`OptionSet`）保存文件操作权限。默认只读且读取必选，编辑、新增和删除可多选：

| 权限 | 允许操作 | 说明 |
| --- | --- | --- |
| `.readOnly`（只读，必选） | 浏览、查询、下载、遍历 | 默认勾选且不可取消；与写权限组合后不会禁止已授予的写操作 |
| `.edit`（编辑） | 覆盖已有文件、移动、重命名 | 不包含新增或删除权限 |
| `.create`（新增） | 上传新文件、创建目录、来源内复制 | 自动包含必选的读取权限，不允许覆盖已有文件 |
| `.delete`（删除） | 删除文件、递归删除目录 | 自动包含必选的读取权限，不授予编辑或新增权限 |

使用 `[.readOnly, .edit, .create]` 组合权限，`.all` 表示全部。配置初始化、解码和受控会话会补齐 `.readOnly`：传入 `[]` 等价于只读，传入 `.create` 会保存为 `[.readOnly, .create]`。集合本身保留标准 `OptionSet` 运算语义，移除读取位后再用于配置或会话仍会补齐。`RemoteAccessPermission.allCases` 列出四个选项；宿主多选界面应将只读固定勾选并禁用取消，另外三项使用 `contains`、`insert`、`remove` 管理。

创建或替换来源时通过 `saveSource` 保存权限；不传时默认 `.readOnly`。`catalog.store.profiles()` 和 `catalog.store.profile(id:)` 返回保存的组合。持久化配置的 `permission` 必须是权限名称数组，例如 `["readOnly","create"]`；只读保存为 `["readOnly"]`。旧角色 API、字符串格式和缺失字段兼容均已移除，字符串、缺失字段、null 及未知权限名称都会导致解码失败，数据库读取返回 `RemoteCatalogError.invalidConfiguration`。已有旧格式配置需按新模型重新配置；SDK 不自动授予权限或转换旧角色。

```swift
let profile = try await catalog.saveSource(
    displayName: "可读取和新增的资料盘",
    configuration: .webDAV(baseURL: url),
    credential: .basic(username: username, password: password),
    permission: [.readOnly, .create]
)

var selection = profile.permission
selection.insert(.edit)
selection.remove(.create)
let canDelete = selection.contains(.delete)
```

Catalog 会话按保存的权限检查文件操作，并裁剪 `capabilities` 供 UI 隐藏入口；未授予权限时返回 `RemoteSyncError.permissionDenied`。上传 `overwrite=false` 需要新增权限，`expectedETag` 条件上传需要编辑权限；普通上传仅选编辑或新增时检查目标是否存在，只有 `notFound` 才视为新文件。新增上传强制禁止覆盖，避免并发创建后覆盖他人文件。仅编辑时，若来源支持条件上传且返回 ETag，会固定该版本；不支持条件上传的来源仍采用存在性预检，预检与实际写入之间的外部删除竞争须由宿主协调，不能将此检查当作跨进程原子授权。

`permission` 是网盘实例的 SDK 访问控制，不会修改远端账号权限，也不替代 WebDAV、OneDrive、百度、iCloud 或本地系统权限。直接使用未包装的适配器不受此配置约束。百度默认 `.readOnly`，编辑/新增/删除需显式组合；受控会话不会给百度增加强条件读写能力。

`connect()` 不隐式持久化任何内容。`RemoteEntry` 不携带凭据。Keychain 实现以宿主指定的 service 和 UUID account 存完整凭据，使用 generic-password、AfterFirstUnlockThisDeviceOnly，不启用同步、不擅设共享 access group。构造 store 不访问 Keychain，实际 read/insert/replace/remove 才访问。

```swift
import Foundation
import BoneRemoteSyncKit

func saveDAV(catalog: RemoteCatalog, url: URL, username: String, password: String) async throws -> RemoteSourceProfile {
    try await catalog.saveSource(displayName: "我的 NAS", configuration: .webDAV(baseURL: url),
                                 credential: .basic(username: username, password: password))
}
```

`saveSource` 每次创建或重绑使用新的独占凭据引用，先保存秘密，再提交 DB。修改已有来源需要 `replacing` 和精确 `expectedRevision`；会建立新 binding，旧根必须重新选择。只改超时/显示名等非绑定参数时，可构造保留 binding/reference、revision 加一的 profile，调用 store 的 `saveProfile(_:expectedRevision:)`；旧缓存变 stale，旧刷新发布资格失效。

SQLite 与 Keychain **没有跨存储事务**：DB 失败只清理能证明是本次新建且无人引用的秘密；无法核对归属的孤立项保留，旧秘密不自动删除。成功保存的轮换 token 不因后续 DB 记账失败回退，旧 refresh token 可能已失效。删除 profile 与删除 Keychain 项是分开的宿主操作。

## OneDrive 身份与轮换

先由宿主完成 OAuth/PKCE 并取得完整 `RemoteCredential.oauth`；首次授权结果通过 `saveSource` 保存。配置中的 `driveID` 必须来自已成功连接的 `OneDriveSource.connectedDriveID()`，不能从首个文件推测，空目录同样需要身份检查。

工厂每次连接均核对实际主盘与保存的 `driveID`。轮换通过同步 throwing 回调保存完整 access token、refresh token 和过期时间。回调固定引用，不读取可变的“当前账号”，不进入 SQLite、不等待 Catalog actor；保存失败使 OneDrive 会话失效并要求重新授权。

同一个 `coordinationID + credentialReference` 在进程内最多一个活动使用会话，跨 factory/root/profile 也互斥。冲突返回 busy（公开刷新报告可能表现为启动失败），不无界排队。同一子树共用一个 source，允许受限并发，并利用该 source 的 token 刷新合并。多个 profile 共享引用时必须是同一 binding/OAuth 应用配置；自定义 store 的 `coordinationID` 必须准确代表底层凭据域。

`revokeCredential(reference:remove:)` 序列化撤销与写入，旧回调不能重新创建已删除凭据；撤销不代表旧会话已经断开或远端 token 已撤销。宿主仍须取消并等待关联任务。活动引用上的重绑返回 busy，不中断另一个合法会话正在保存的 token。

## 百度身份与后端刷新（未发布）

首次用 `BaiduDriveSource` 连接后，从 `connectedUserID()` 获取已核对的用户 ID，再保存 `.baidu(configuration:userID:)` 与完整 OAuth 凭据或 `.apiToken`。`uk` 以精确 uint64 值读取并保留为字符串，不从文件、路径或浮点数推测用户。百度条目 ID 和来源 binding 包含应用/用户/根作用域；AppKey、账号或 `rootPath` 变化需要新的 binding、凭据引用及重新选根。

工厂每次用 `connect(_:expectedUserID:)` 核对固定用户，账号不匹配在目录请求前失败，映射为 `RemoteCatalogError.identityChanged`。即使应用目录为空也必须核对身份；公开配置不包含授权秘密。

通过 `RemoteCatalogSessionFactory(credentials:localResolver:baiduTokenRefresher:)` 注入 `BaiduCatalogTokenRefresher`，其签名为 `@Sendable (BaiduDriveConfiguration, String, BaiduDriveToken) async throws -> BaiduDriveToken`。回调收到固定配置、固定用户 ID 和旧令牌，调用宿主可信后端交换刷新结果并返回完整新令牌；SecretKey 只在后端保管，SDK 不承诺 PKCE。与原始来源的 `refreshToken` 回调不同，Catalog 工厂负责同步写回原 UUID 凭据引用，不查找可变的“当前账号”，也不在回调内进入 SQLite 或 Catalog actor。

到期前刷新在同一来源实例合并，成功后再核对用户；刷新或凭据保存失败使会话失效，不能用旧 refresh token 无限重试。引用级进程内会话互斥、固定引用保存和 `revokeCredential(reference:remove:)` 的撤销规则同样适用，旧回调不能重建撤销后的凭据。百度 refresh token 一次有效，跨实例/设备仍需宿主后端按固定应用和用户串行刷新、保存轮换结果，并响应取消。`.apiToken` 或缺少 expiry 的 OAuth 不自动到期刷新，过期时由宿主重新授权。

目录索引、离线查询、统计和显式失效复用现有 Catalog；文件变更后调用 `invalidateCache` 或 `refresh`，没有后台任务、变更订阅或强版本缓存。完整保存与清理生命周期见 [百度指南](BaiduDrive.md) 和 [百度示例](../Examples/BaiduDrive/README.md)。

## Local 访问 lease

保存路径不等于保存 sandbox 授权。宿主提供 `RemoteLocalAccessResolver`，按 `accessReference` 恢复 bookmark/目录权限，并返回 `RemoteLocalAccessLease(rootURL:release:)`。成功、连接失败和取消都释放 lease，正常路径会先等待来源断开。

```swift
import Foundation
import BoneRemoteSyncKit

struct AppFolderResolver: RemoteLocalAccessResolver {
    let resolveFolder: @Sendable (String) async throws -> RemoteLocalAccessLease
    func resolve(reference: String) async throws -> RemoteLocalAccessLease {
        try await resolveFolder(reference)
    }
}
```

bookmark 更新、stale 检测、start/stopAccessingSecurityScopedResource 和用户重新选择 UI 归宿主。resolver 应响应取消；SDK 无法强制中断一个不返回的宿主闭包。缓存不授予文件权限，也不增加 iCloud 文件协调。Catalog 已通过独立的 `ICloudDriveSource` provider/configuration 和固定会话支持 iCloud 目录索引；宿主仍需配置 entitlement 和容器，不应使用 `.local` 绕过 iCloud 语义。

## 选择目录、刷新与离线查询

```swift
import BoneRemoteSyncKit

func indexSelection(catalog: RemoteCatalog, profile: RemoteSourceProfile) async throws -> RemoteCatalogRoot {
    let root = try await catalog.selectRoot(sourceID: profile.id, path: "/资料", defaultScope: .children)
    let report = try await catalog.refresh(rootID: root.id, options: .init(
        scope: .subtree, concurrency: 1, timeout: 3_600, requestInterval: 0.5
    ))
    // 检查 success/partial/failed/cancelled；不能仅以函数返回认定全树成功。
    if report.state == .success {
        _ = try await catalog.listCached(rootID: root.id, directory: root.path)
    }
    return root
}
```

- `children` 只更新该目录直接子项；`subtree` 从入口逐层枚举。省略 options 时使用根保存的默认范围，默认是 children。
- 省略 directory 时使用选定根。刷新前会验证保存的 root 路径；如果只确认该路径不存在，Catalog 会自动验证来源 `/`，将 root 持久化回 `/` 并继续刷新。权限、认证、网络和身份错误不会触发回退。显式传入 `directory:` 时不会修改保存的 root。
- 刷新已缓存的子目录可传其规范来源路径；不是任意越过缓存父链的路径查询。
- 同根同一时间只接受一轮刷新，重复或冲突请求返回 busy；首版不合并等待。
- 默认并发 4、最大 16；条目数、目录数、深度、单目录页数和整轮 timeout 均有限。pageSize 是提示，Local/WebDAV 可能一次物化整个大目录。
- **未发布新增 `requestInterval`**：扫描阶段 `list/stat` 调用之间的最小放行间隔，单位秒，默认 `0`，合法范围 `0...86400`（有限值）。首个调用立即放行；同一轮扫描的所有并发目录和分页共享间隔，唤醒延迟不会积攒可突发放行的名额。不是每个目录各自计时，也不是每个文件等待一次。
- 请求间隔与并发数分别控制频率和同时执行的目录任务数；慢请求仍可能重叠。对限制严格的网盘，建议先设 `concurrency: 1, requestInterval: 0.5`，再按实际配额调整。间隔等待计入扫描 timeout，取消或超时会中断等待并保留旧完整缓存。
- 间隔仅约束本轮扫描主动调用来源的 `list/stat`；连接、认证、刷新前选根预检、适配器内部重试及其他刷新/下载不共用此限制，不保证每条底层 HTTP 请求的发送间隔。它适用于所有 Catalog 来源，不改变直接使用 `source.walk/list/stat` 的行为。参数按次传入，不自动持久化。
- 整轮 timeout 使用单调时钟计时，关闭后续提交资格并取消任务，但仍等待网络/lease 清理。取消是协作式的，不保证精确时间点返回；已提交目录不回滚。
- `refresh` 参数、存储和启动资格错误可能抛出；已开始扫描的来源错误通常在报告 `failures` 中以脱敏类别返回。不要持久化底层响应或 token 到错误日志。

`listCached` 完全离线。`notInitialized` 与“成功空目录”不同；`current` 表示最近该目录完整扫描成功，**不表示远端目前没有变化**；`stale` 表示后续尝试失败/中断或配置变化。返回版本、最近成功/尝试时间和本地分页 token。

分页顺序是目录优先，再按二进制名称与路径排序，不使用区域化自然排序。token 绑定根选择、目录 epoch、目录版本、limit 和位置；刷新后旧 token 报错，不把不同版本悄悄拼接。token 是本地查询数据，不是服务端 cursor，也不是授权凭据。

`store.status(rootID:)` 读取最近一轮开始/结束时间、状态、已发布目录/条目数、脱敏失败范围，以及 `lastFullSubtreeSuccessfulAt`。只有选定根的完整 subtree 成功才更新该时间；子树结果是扫描区间的组合，不是远端瞬时快照。

## 完整性与发布边界

所有来源页都必须显式声明 `RemoteListingCoverage`。`nextCursor == nil` 仅表示没有下一页。Catalog 必须消费全部页，允许有 cursor 的空中间页，但拒绝 partial/unknown、循环 cursor、重复路径/ID、缺路径、非直接子项、身份变化或预算耗尽。

- 分页写入 staging，不进入普通查询；每目录全部成功后，单个原子事务再次检查 binding/configuration/selection/epoch/run 资格并发布。
- 失败保留旧完整列表和版本；没有旧列表仍是未初始化。403/404 不当成功空目录。
- 完整列表中未见项退出缓存，不解释成 provider 删除事件，不删除远端或本地下载文件。
- 成功兄弟目录独立提交，失败目录保留旧缓存，整轮可为 partial；未成功扫描的目录不凭旧缓存继续下钻。
- 父目录退出、变文件或 ID 替换使旧后代直接查询也不可见。路径改名按旧路径退出+新路径出现处理，不自动搬移旧子树。物理旧记录可能保留至清索引。
- OneDrive 与百度选定根按路径绑定，扫描前后核对 ID，改名或同路径换对象需重选；Local/WebDAV 的路径型 ID 无法完全识别同路径替换。百度来源根始终限制在配置的应用目录，回退 `/` 也不能越过此边界。前后校验及 offset 分页不构成瞬时快照证明。
- 首版每次重新枚举请求范围，仅避免重写未变的 DB 条目；不是服务端增量拉取，不根据目录 ETag/mtime 跳过后代。

## 恢复与清理

重开数据库将未终结 run 标记 interrupted，丢弃 staging，保留已经提交的目录和旧有效列表。不持久化远端 cursor，不自动恢复网络任务；下一次显式刷新从第一页开始。

`clearIndex(rootID:)` 保留配置和凭据，清该根的缓存/扫描记录；旧 binding 的根无需连接新来源也可离线清理，普通缓存查询仍拒绝旧 binding。`removeProfile(id:)` 只移除本地 profile、根和索引，不移除 Keychain、不操作远端。低层修改会让旧提交资格失效，但不能替宿主取消已经发出的网络任务；宿主应先取消并等待刷新，再改根/清缓存/删除来源。配置重绑的高层操作遇到活动凭据会返回 busy。

底层 store 的退役 binding 记录是数据库全局的：任一共享 profile 离开该 binding 后，已有同 binding profile 仍可运行，但不能新增使用该退役 ID 的 profile。新绑定应创建新 ID 和新凭据引用，不要恢复使用历史 ID。

运行历史和不可见旧代次记录没有自动保留期限；长期宿主应规划清索引和私有数据库体积管理。不能把清索引当作安全擦除已存储元数据；SQLite/WAL/备份可能仍含旧字节。

## 验证边界

测试使用临时文件、注入的内存/Security backend 和 localhost 合成服务，未访问真实 Keychain、Microsoft 账号或 NAS；百度也没有真实应用或 token，fixture 不能替代线上授权与目录操作验收。本地重开验证不等于硬件断电保证。十万条规模测试不是延迟 SLA，峰值内存包含测试宿主；最低平台编译/链接也不是旧系统或真机运行验收。本轮构建与测试结论以[验证状态](Validation.md)的最终记录为准。
