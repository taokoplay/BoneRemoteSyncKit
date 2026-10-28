# 更新说明

[返回项目首页](README.md) · [通用 API](Docs/API.md) · [验证记录](Docs/Validation.md)

## v0.4.0 — 2026-10-28

本版本以 Git 附注标签 `v0.4.0` 发布，不另外创建 GitHub Release。包含实现提交 `3cb05c3` 与发布文档更新；原 `v0.1.0`、`v0.2.0`、`v0.3.0` 标签不变。以下为相对 `v0.3.0` 的变化。

### 新增

- 新增 `BoneRemoteSyncTransfer`，由统一 `BoneRemoteSyncKit` 导出；Core 增加绑定引用、locator 作用域版本、读写条件值类型与传输快照。
- 提供通用文件物化、lease/进程内保留缓存、同版本在途合并、独立消费者取消、私有 staging 与排他原子发布；可选大小/SHA-256 校验，不解析文件格式。
- 新增前台 coordinator：全局和每来源上限、任务 ID/单次结果领取、权威快照、晚到事件过滤、取消与 shutdown。快照不保存原始错误文本；该队列的任务级重试、跨进程恢复和跨来源可恢复上传未实现；OneDrive 专用 Upload Session 另提供显式 opt-in API。
- 新增可选 `RemoteByteRangeSource` 和有界 `RemoteByteRange`；Transfer 提供显式 IfSupported/Required 分片策略、首片验证、有界窗口、普通下载/分片共享来源上限、乱序合并与原子发布。其他网盘实现强版本区间协议即可复用；首个内置适配为 WebDAV。默认仍顺序下载，不含持久分片恢复或性能保证，详见 [Transfer](Docs/Transfer.md#可插拔的单文件并行分片下载)。
- WebDAV 分片严格验证闭区间、强 ETag、响应和正文长度；畸形 200 不降级，请求/响应头阶段沿用显式有限重试，不换区间或版本。
- 新增可选 `RemoteConditionalDownloadSource`；WebDAV 复用强 ETag `If-Match`，其他来源不冒充强条件读取。`.requireVersion` 不支持时显式拒绝，详情见 [Transfer](Docs/Transfer.md)。

- 新增独立 `RemoteDownloadRecovery`、可选 Core 恢复协议与 checkpoint 只读投影，WebDAV 复用既有强 ETag/Range、确认偏移与 part 身份校验；默认不覆盖目标。显式私有本地锁目录提供合作进程间目标互斥，不自动加入物化队列。
- `WebDAVSource.downloadResumableResult` 区分已提交与已提交但 checkpoint 清理未完成；原 `downloadResumable` 保持返回 `RemoteEntry`。未提供其他来源恢复下载适配或自动后台重试。

- 新增Core可恢复上传句柄/状态/回执与Transfer `RemoteUploadRecovery`。OneDrive Personal专用构造器启用设备内非同步Keychain session store；先本地prepare/保存句柄，再创建远端session，默认不覆盖，不支持最终ETag条件替换。
- Upload Session提供顺序分片、服务端确认进度、独立无bearer请求、有界重试、私有快照分块摘要和合作跨进程锁；区分明确冲突、创建/提交/abort未知、已提交但本地持久化/清理待处理。保留终态回执供重复领取，支持显式终态forget。详见[OneDrive](Docs/OneDrive.md)；不包含真实账号/Keychain/最低系统运行验收。

- R3：`ICloudDriveSource.statuses(paths:)` 批量读取 iCloud 本机条目状态；按输入顺序返回逐项结果，不触发 hydration 或目录创建，取消/断开/账号变化会丢弃整批。该 API 自 `v0.4.0` 提供。

### 接入与迁移

- 继续推荐单产品 `import BoneRemoteSyncKit`；Transfer 只依赖 Core，不依赖 Catalog、SQLite 或具体来源。默认顺序下载，分片和 OneDrive Upload Session 均须显式启用。
- `RemoteSyncError` 新增 `uploadSessionExpired`、`sourceSnapshotMissing`、`uploadCommitUnknown` 和 `secureStorageUnavailable`；宿主需更新穷尽 switch。恢复上传默认不覆盖，与普通上传默认覆盖不同。
- 成功提交、清理待处理与结果未知必须分别处理；未知结果不授权重新创建 session 或重放写入。新恢复入口独立于 coordinator，不提供通用后台或跨进程持久任务队列。
- 继续以当前 API 和数据格式为准，不提供旧接口、旧序列化或检查点的跨版本迁移承诺。阶段6 Catalog/Transfer 可选集成未实施，没有新增网盘适配器。

### 验证与范围

- 发布前重新运行串行全包：**506 项通过**（39 XCTest + 467 Swift Testing），Release 与独立 Kit 分片消费端通过。参数化 case 不重复计数。
- 八模块四最低目标编译链接、Swift 文档示例类型检查和恢复传输受控跨进程验证沿用同一实现的既有结果。工具链为 Swift 6.4 / Swift 6 模式；不是 Swift 6.0 编译器或最低系统真机验收。
- 真实 NAS 分片兼容性、Microsoft 账号/Keychain、iCloud 双设备、大文件性能与故障验收仍待完成；已有 WebDAV 并发短 deadline 风险仍保留。版本发布不扩大能力或验证范围，完整证据见 [v0.4.0 发布前验证](Docs/Validation.md#v040-发布前验证)。

本文件记录对使用者有影响的功能、修复、版本策略与行为变化。实现完成、测试通过和版本发布是不同状态；版本标签也不代表真实账号、服务端或全部平台已经验收。

## v0.3.0 — 2026-10-27

本版本以 Git 附注标签 `v0.3.0` 发布，不另外创建 GitHub Release。以下为相对 `v0.2.0` 的变化，包含此前已合入 main 的 Catalog、日志、首轮 iCloud 与通用文件语义，以及本轮 iCloud 备份 R1/R2 契约；既有 `v0.1.0`、`v0.2.0` 标签保持不变。

### iCloud Drive 文件来源与备份接入

- 新增独立 `BoneRemoteSyncICloud` 产品、`ICloudDriveSource` 和配置/状态/错误模型，统一 Kit 导出；系统账号通过 `.anonymous` 使用，宿主负责 entitlement 与容器。
- 增加文件协调、占位下载请求及有界轮询、原子 upload/download、手动下载续传、取消/断开隔离、根/链接路径保护及冲突拒绝。
- 支持 list/stat、文件传输、建目录、删除、移动和仅文件 copy；不支持目录 copy、Catalog iCloud provider、变更流、版本选版、CloudKit 或自动同步。
- iCloud 特有错误保留 `ICloudDriveError`，不先折叠成 network/conflict；新增账号身份不可用、Drive/容器不可用、配置目录不存在分类，`status.unavailableReason` 可用于无副作用查询。不能可靠识别的系统状态不强判为 Drive 关闭。
- 已连接配置根被删除时保留可识别目录错误，权限/IO 失败不误报为目录不存在；元数据读取晚到后再次核验账号，避免旧账号 ready 回调。覆盖账号切换、超时、取消、准备/传输顺序、空文件及续传回归。
- 新增备份目录显式初始化、带阶段恢复、上传和宿主选定旧备份清理示例，补齐 Q1–Q7 与错误迁移说明。接入与限制见 [iCloud 指南](Docs/ICloudDrive.md)。

### 通用文件语义与 OneDrive 稳定 ID

- Core 新增 `RemoteDownloadPhase` / `RemoteDownloadPreparationState` / `RemoteDownloadProgress` 与 `RemoteDownloadOptions.phaseProgress`。iCloud 准备阶段采样状态变化并去重；Local、iCloud、WebDAV、OneDrive 普通下载报告传输字节。无可靠比例时返回 nil，不引入 NSMetadataQuery 或伪造网络百分比。
- 新增可选 `RemoteIDAddressableSource` 和 `RemoteCapabilities.idAddressing`；OneDrive 支持按稳定条目 ID 查询、目录浏览、分页和下载，ID 分页游标绑定当前会话及寻址模式。
- `RemoteUploadOptions.expectedETag` 表达调用方读取版本的条件覆盖；WebDAV 用强 ETag 执行 `If-Match`，本地、iCloud Drive、OneDrive 明确拒绝，不静默降级。
- 新增独立 `RemoteContentChecksum` / `RemoteContentChecksumAlgorithm` 模型，保留摘要原始字节并校验算法长度；不将 ETag 冒充内容哈希，当前各来源仍不自动提供或验证内容摘要。

### 配置持久化、目录缓存与日志

- 新增可选 `BoneRemoteSyncCatalog`，由统一 Kit 导出：系统 SQLite 配置/根选择/离线分页，显式 children/subtree 刷新、目录级原子发布、失败保留旧缓存与中断恢复。
- 新增可替换同步凭据 store 和 Apple Keychain 桥接，固定引用轮换回调、引用级会话互斥、Local 宿主访问 lease；没有真实 Keychain/账号验收。
- 新增 OneDrive `connectedDriveID()` 以核对持久账号绑定；不保存 token 到 SQLite、不持久化远端 cursor。API 与行为边界见 [Catalog](Docs/Catalog.md)。
- 新增 Core 结构化错误日志规范与 `RemoteLogger`：固定分类/级别/操作、默认关闭、宿主注入输出，Catalog 初始化/恢复/关闭及高层操作自动接入。丢弃原始错误文本，sink 抛错不替换业务错误，刷新失败按类别聚合；详见[日志规范](Docs/Logging.md)。

### 契约变化与迁移

- 继续采用当前 API 优先策略，不保留旧 API、序列化格式或 checkpoint 的兼容层。宿主应同步更新调用代码及穷尽 switch。
- `RemoteListPage` 构造必须显式指定 coverage；Local/WebDAV 不再把已知漏项报告为完整目录。visitor walk 拒绝 partial/unknown，stream walk 仍仅用于部分浏览。
- 细化 `RemoteCatalogFailureReason`：保留未连接、不支持、限流、冲突、完整性不匹配及取消分类，不再统一折叠成 network/other。
- 开发分支原 `ICloudDriveError.unavailable` 已删除，宿主应优先 catch iCloud 错误；只需要通用分类时显式使用 `remoteSyncError` 投影。iCloud 来源本身不在 `v0.2.0` 中。
- 两阶段比例相互独立，达到 1 不等于最终安装完成。网络来源已在途回调可能晚于取消返回，宿主按任务 ID 过滤过期事件，不将 async 终态视作回调排空屏障。

### 验证与范围

- 最终串行全包 **392 项通过**：39 XCTest + 353 Swift Testing；参数化 case 不额外相加。Release、独立 Kit 消费端、七模块及 iCloud 示例的四目标编译/链接通过，指南 3 个 Swift 片段四目标类型检查通过。
- 使用 Swift 6.4 / Xcode 27.1、Swift 6 模式；最低声明平台不变。平台编译不等于 Swift 6.0 编译器或最低 OS 真机验收。
- 真实 iCloud entitlement、账号、Drive 开关、真正占位文件、离线/空间不足、双设备传播与冲突版本仍未验收；真实 Graph/WebDAV 写入及 Keychain 验收也未完成。既有 WebDAV 并发短 deadline 风险仍保留，串行通过不证明其消失。
- 新增[未支持来源开发计划](Docs/CloudDriveRoadmap.md)，按阶段规划 Google Drive、Dropbox、SMB、SFTP、FTP/FTPS、NFS 及区域性 API 网盘。计划文档不代表这些来源已经实现；本版本不含新网盘适配器或自动同步引擎。

各阶段的原始失败、审查修复、测试数量及未验收项见[验证记录](Docs/Validation.md)，不将历史定向结果与最终全包相加。

## v0.2.0 — 2026-10-26

本版本以 Git 附注标签 `v0.2.0` 发布，包含实现提交 `0579c64` 及发布文档更新，不另外创建 GitHub Release。以下为相对 `v0.1.0`（`ae52fe9`）的变化；原 `v0.1.0` 标签保持不变，不包含下列更新。

### 新增

- **可选创建时间 `RemoteEntry.createdAt`。** Local 读取文件系统 `creationDate`，WebDAV 读取成功 DAV 属性中的 `creationdate`，OneDrive 读取 Graph `driveItem.createdDateTime`。缺失或无效时返回 `nil`，不使用修改时间或当前时间填充。
- **统一文件分类 `RemoteEntry.fileCategory`。** 新增 `RemoteFileCategory`，支持目录、图片、音频、视频、文档、归档和未知类型。目录优先，其次使用可识别的具体 MIME；仅在 MIME 缺失、无效或为通用二进制类型时按常见扩展名回退。未识别的具体 MIME 保守返回 `.unknown`。
- **下载元数据保留。** 普通下载及 WebDAV managed 恢复下载保留来源创建时间；在相同 ETag 与大小的恢复中，本次响应缺少时间时保留检查点已有值。检查点没有创建时间时不伪造值。

分类仅处理已有元数据，不打开文件、不读取文件头、不隐式下载。创建时间不是拍摄或录制时间，也不保证跨来源语义完全一致；下载不会主动把来源创建时间设置到本地目标。使用方式见[文件时间与类型分类](Docs/API.md#文件时间与类型分类)。

### 修复

#### 本地目录

- 修复源文件与下载目标或派生 `.part` 路径重合时可能破坏源数据的问题，覆盖直接路径、父目录别名和硬链接场景；在破坏性写入前校验文件身份与类型。
- 修复 `overwrite: false` 仅在开始时检查目标，导致传输期间新建的目标仍可能被覆盖的问题。最终安装改为原子非覆盖操作。
- 拒绝负数、超过源大小或与既有 part 长度不符的续传偏移；预检失败不截断既有 part。提交前复验源身份、大小与时间等元数据，检测到变化时拒绝安装。
- 覆盖已有目标时保留普通 POSIX 权限位，不继承 setuid、setgid 或 sticky 特殊位。不承诺复制 ACL、扩展属性、所有者或源文件权限。

#### WebDAV

- 兼容 collection 规范化尾斜杠：仅在 PROPFIND 收到 301/308，且重定向严格同源、原编码路径仅追加一个 `/` 时，在原 deadline 内重建并重发一次请求。继续拒绝任意自动重定向；GET 与写请求不使用此例外。
- 修复 HTTP 207 响应中的目标资源错误被过滤成“不存在”的问题。浏览、stat、下载恢复预检与写预检保留目标资源的认证、权限、冲突等错误语义；目标存在却缺少属性时明确报错。
- 将目标资源的瞬态错误纳入既有只读重试策略，写请求仍不自动重试。

#### OneDrive

- 修复上传忽略指定 `Content-Type` 的问题；未指定时使用 `application/octet-stream`，认证刷新重放时保留同一请求头。空值、控制字符或超长值在额外网络请求前拒绝。

### 版本策略与行为说明

- **以当前版本为准，不将向后兼容作为维护约束。** 不承诺保留旧 API、读取旧序列化格式或迁移旧检查点；宿主应同步更新依赖与调用代码。已有可选字段的自然缺省行为不为制造不兼容而删除。
- 使用单产品 `import BoneRemoteSyncKit` 作为推荐入口，分模块产品用于按需依赖；没有新增第三方运行依赖，也没有提高声明的最低系统版本。
- `createdAt` 是默认 `nil` 的可选参数，当前合成 Codable 对缺失字段返回 `nil`。`fileCategory` 是计算属性，不作为重复状态写入 Codable 数据；这些是当前数据语义，不是跨版本保证。
- `createdAt` 参与条目合成的相等性与哈希。完整条目相等不是内容一致性证明；`hasReliableFingerprint` 仍只依据 ETag 或修改时间，不因新增创建时间改变规则。
- 网络创建时间严格校验完整时间戳、年月日和时区偏移，拒绝非法日期及尾随垃圾；使用延伸公历计算，避免历史历法切换造成日期偏移。原 `modifiedAt` 解析规则不变。OneDrive 仅对新增的可选创建时间字段容忍 JSON 类型错误，其他关键字段仍严格解码。
- WebDAV PUT 成功后不为补齐时间额外发起 stat，因此上传返回的 `createdAt` 仍可能为 `nil`；需要当前远端属性时，由调用方显式查询。
- 一些原本被错误接受的危险路径、续传参数或上传 MIME 现在会明确拒绝；调用方应处理对应错误，而不是依赖旧行为。

### 验证与已知限制

- 相比 `v0.1.0` 的 224 项测试，缺陷修复新增 19 项、元数据扩展新增 17 项；最终全包复测 **260 项通过**。参数化 case 不额外计数。
- Release、两份接入示例、独立单产品消费端，以及五模块和两示例的 arm64 macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator 编译检查通过。
- 使用 Swift 6.4 / Xcode 27.1；未用 Swift 6.0 编译器重测，最低平台编译不等于设备或旧系统运行验收。
- 并发全包运行中仍观察到已有 WebDAV 短 deadline 与上传进度最终值断言的间歇失败；单独运行及最终完整复测通过，**不能据此认定该风险已消除**。历史 fixture 清理挂起已调整为预注册退出回调及有界等待，失败和复测记录均保留。
- 真实 NAS 写入、Microsoft 账号和移动设备验收仍待完成。本轮仅使用临时目录和 localhost fixture，不能据此承诺任意服务端兼容性。
- `v0.2.0` 没有增加图片尺寸、EXIF、音视频时长、封面、缩略图、转码或真实格式检测，也不包含 iCloud、OneDrive Upload Session、后台传输或同步引擎。后续能力以本文对应版本条目为准。

完整验证范围、历史失败和未验收项见[构建与验证状态](Docs/Validation.md)。以上为 `v0.2.0` 的历史验证结果，不代表后续版本新增能力已包含在该标签中。
