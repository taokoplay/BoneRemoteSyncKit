# 未支持来源开发计划

> 本文是 `BoneRemoteSyncKit` 当前开发路线图，不代表下列来源已经实现或已纳入发布版本。当前已实现的来源仍是 Local、WebDAV、OneDrive Personal 和自 `v0.3.0` 发布的 iCloud Drive；本计划不会把预留枚举值或空目标描述成可用适配器。

[返回项目首页](../README.md) · [通用 API](API.md) · [验证状态](Validation.md)

## 目标与边界

将当前尚未匹配的来源按共同文件语义拆分为可独立验收的适配器：

- **API 网盘**：Google Drive、Dropbox，以及后续经过授权和产品评估的百度网盘、阿里云盘、腾讯微云等。
- **网络文件系统**：SMB、SFTP、FTP、NFS。
- **通用基础**：稳定条目标识、目录分页、版本条件写入、内容校验、可恢复传输、变更发现和认证会话隔离。

本计划不包含自动双向同步引擎、后台调度、跨来源事务、系统挂载、File Provider 扩展或统一冲突解决器。适配器只提供来源层能力；快照比较、任务调度、删除策略和冲突决策由宿主或后续独立模块负责。

## 当前已知缺口

| 缺口 | 当前状态 | 规划处理 |
| --- | --- | --- |
| Google Drive | 未实现 | 作为第一批 API 网盘，优先支持 My Drive 文件读写和稳定 ID |
| Dropbox | 未实现 | 与 Google Drive 并列第一批，优先使用 `id`、`rev` 和 content hash |
| SMB | 未实现 | 作为第一批网络文件系统；先明确 Apple 平台 API、认证和依赖方案 |
| SFTP | 未实现 | 第二批；需要明确 SSH host-key 校验和可接受的 Swift SSH 依赖 |
| FTP / FTPS | 未实现 | 第二批低优先级；默认只考虑显式 FTPS，明文 FTP 必须由宿主明确选择 |
| NFS | 未实现 | 研究项；先验证目标 Apple 平台是否有稳定、可分发的客户端方案 |
| 百度网盘 / 阿里云盘 / 腾讯微云等 | 未实现 | 第三批候选；逐家核对公开 API、商业授权、地区限制、配额和审核要求 |
| 自动同步 / 增量引擎 | 未实现 | 不随适配器实现；另行设计 change feed、tombstone、冲突和后台任务模型 |

## 优先级与阶段

### 阶段 0：共性合同和测试基建

**目标：** 让新的来源可以表达真实能力，而不是被迫套用路径型或整文件型假设。

1. 继续沿用 Core 的 `RemoteSource`、`RemoteWritableSource` 和可选 `RemoteIDAddressableSource`，不为未支持来源创建空实现。
2. 明确并补齐以下能力合同：
   - 稳定 ID 与可变路径分离；ID 必须绑定来源账号、盘或会话的适用范围。
   - 父目录 ID 浏览和分页游标隔离；禁止把 URL、token、路径或服务端私密游标写入公开条目。
   - `expectedETag` / `rev` / `version` 条件写入；来源不支持时在网络或磁盘副作用前返回 `.unsupported`。
   - `RemoteContentChecksum` 与 ETag 分离；声明来源提供摘要不等于 SDK 已验证下载内容。
   - 大文件上传会话、Range 下载和 checkpoint 的能力边界；不把简单上传伪装为可恢复上传。
   - `RemoteListPage.coverage`、部分结果和服务端变更语义；分页未完成时不能推导远端删除。
3. 抽取受控 HTTP 测试服务器、分页/重试/认证 fixture 和文件安全测试工具，但不让测试替身扩大生产能力。
4. 为每个适配器建立独立 target、独立测试 target 和独立文档；统一 Kit 只重新导出真实存在的产品。

**验收门槛：** Core Codable 向后兼容；能力为 false 的入口有明确拒绝测试；分页、取消、认证刷新、条件写入、半成品清理和路径/ID 注入均有回归覆盖。

### 阶段 1A：Google Drive Personal / My Drive

**目标：** 首先支持文件来源中最典型的“稳定 file ID + 可变路径/多父目录”语义。

建议新增 `BoneRemoteSyncGoogleDrive`，初版范围：

- OAuth 2.0/PKCE 由宿主管理授权 UI 和安全 token 存储，SDK 只处理已取得的凭据和刷新回调。
- `files.list` 目录浏览、分页 token、字段白名单和 query 注入防护。
- `fileId` 作为稳定 ID；读取条目时保留可选路径，不把同名文件或多父目录强制折叠成唯一路径。
- 元数据查询、文件下载、简单上传、目录创建、移动/重命名、删除和条件更新。
- 根据 Google Drive 的 `version` / `modifiedTime` 设计条件写入，不把 HTTP ETag 误作内容哈希。
- 大文件 `resumable upload` 作为独立能力；上传会话 URL 只存在于内存任务状态，不进入日志、条目或持久化 Catalog。
- `changes` / start page token 只作为后续增量发现预留，第一版不宣称自动同步。

首版不包含：共享云端硬盘、快捷方式、Google Docs/Sheets/Slides 导出、评论/权限管理、离线同步和自动删除。

**验收：** 本地 fixture 覆盖多父目录、同名文件、分页 token 失效、ID 重命名、404/403/429、断点上传取消和条件更新；随后用专用 Google 测试账号验证 OAuth、真实大文件、权限和版本冲突。

### 阶段 1B：Dropbox

建议新增 `BoneRemoteSyncDropbox`，优先支持：

- OAuth 2.0 PKCE 和 `Dropbox-API-Arg` / `Dropbox-API-Result` 的严格 JSON 边界。
- `/files/list_folder` 及分页 cursor，cursor 绑定账号、根空间、路径和请求选项。
- Dropbox 条目 `id` 作为稳定 ID，`rev` 作为版本条件，`content_hash` 映射为 `RemoteContentChecksum.dropboxContentHash`；不得把 `rev` 或 content hash 混成 ETag。
- 临时链接下载、内容上传、创建目录、移动、复制、删除和 `If-...` 等价的服务端版本条件（按 Dropbox API 实际合同实现）。
- 明确区分个人空间、团队空间、`path_root` 和共享链接；第一版只支持一种已验证空间模式。

首版不包含团队管理、共享链接发布、Paper、权限变更、批量异步任务和自动同步。

**验收：** fixture 覆盖 cursor 复用/失效、`rev` 冲突、content hash 长度与算法、临时链接安全、API 错误映射和上传中断；真实账号验证空间切换、配额、限流和文件名边界。

### 阶段 1C：SMB

建议新增 `BoneRemoteSyncSMB`，但先完成技术选型再编码：

1. 确认 Apple 平台可分发的 SMB 客户端方案，明确是否引入第三方依赖；不能用 Foundation 的本地文件 API 冒充远端 SMB。
2. 定义凭据模型：匿名、用户名/密码、Keychain 引用和会话生命周期；禁止日志记录密码、NTLM 响应或票据。
3. 验证目录枚举、文件句柄读写、Range/续传、服务器端 rename/delete/copy、大小写和 Unicode 文件名语义。
4. 明确 SMB signing、TLS/加密、服务器证书/主机身份、DFS 和软链接边界。
5. 先支持受控 SMB2/3 文件服务器，再决定是否支持 guest、DFS、并发写和目录复制。

**验收：** 至少覆盖 macOS 真机或受支持模拟环境、专用测试服务器、断线重连、权限拒绝、锁定文件、并发修改和恶意路径/软链接；没有真实服务器验收前不能发布 target。

### 阶段 2：SFTP、FTPS 和有限 FTP

#### SFTP

- 选择并锁定经过许可证、安全审查和平台编译验证的 Swift SSH 方案。
- 实现 host-key pinning/known-hosts 校验、密码或 SSH key 引用、连接超时和会话取消。
- 初版优先支持目录、stat、完整下载/上传、Range（若服务端稳定支持）、mkdir、rename、remove。
- 明确不支持服务器端 copy、递归原子事务和后台传输；先不做密码明文 fallback。

#### FTP / FTPS

- 默认只启用显式 FTPS；明文 FTP 必须由宿主显式配置并在文档中标记风险。
- 处理 PASV/EPSV、TLS 会话复用、UTF-8 文件名、SIZE/MDTM 不可靠和服务器能力差异。
- 不把路径、大小和修改时间冒充稳定 ID 或内容哈希；默认能力保守为非续传/非条件写，除非真实服务器合同验证通过。

**阶段门槛：** SFTP/FTP 的依赖、许可证、最低 OS 和安全方案确认前，只做研究与 fixture，不创建公开可用产品 target。

### 阶段 3：区域性 API 网盘候选

针对百度网盘、阿里云盘、腾讯微云等逐家建立候选评估表，再决定是否实现：

- 是否有面向第三方应用的公开、稳定 API 和明确授权模式。
- 是否允许 SDK 分发 OAuth client、回调 scheme 和刷新 token 管理。
- 文件 ID、路径、版本、分片上传、断点下载、批量删除和变更列表语义。
- 地区/账号类型限制、API 配额、审核/商业授权、隐私和数据驻留要求。
- 是否能在本地 fixture 之外获得专用测试账号和真实服务验收。

只有满足“公开 API 可依赖、许可证/商业边界清楚、可写测试账号可用、错误和版本语义可落入 Core 合同”四项条件，才进入实现；否则保留为宿主自定义适配器或研究记录，不在 SDK 中放置半成品 target。

## 统一实现约束

- 每个来源独立 actor 管理会话；断开、重连、账号切换必须隔离旧请求和迟到响应。
- 所有远端写入都必须区分本地 staging/原子落盘与远端提交；成功不代表跨设备同步完成。
- 不保存 Apple/Microsoft/Google/Dropbox 或其他供应商凭据；宿主负责授权 UI、Keychain、容器 entitlement、回调和账号选择。
- 任何 URL、cursor、upload session、临时链接和 token 都不能进入 `RemoteEntry.id`、公开错误、普通日志或长期 Catalog。
- 能力声明必须与实际实现同步；不支持的操作显式 `.unsupported`，不通过空实现或本地退化掩盖缺口。
- 目录列表的 partial/unknown 不能驱动删除；版本冲突只能在已有来源策略明确后交给上层处理。
- 依赖增加前先做许可证、供应链、平台编译、最小 OS 和维护状态评估；不能为了支持单一协议绕过系统安全校验。

## 发布与验证门槛

每个来源独立完成以下阶段后才能标记为“已实现”：

1. **合同阶段**：Core 能力、错误、ID、版本和摘要语义评审通过。
2. **受控测试阶段**：正常路径、分页、限流、取消、断线、权限、冲突、半成品清理和安全边界 fixture 通过。
3. **平台阶段**：macOS 12、iOS 15、tvOS 15、visionOS 1 的可用性/编译边界按目标能力验证；需要系统网络或文件 API 的来源增加真机检查。
4. **真实服务阶段**：专用测试账号/服务器、上传下载、重命名、删除、并发修改、配额、账号切换和恢复流程通过；不能用 fixture 结果替代。
5. **文档阶段**：接入、凭据、能力矩阵、失败语义、隐私/安全和限制文档齐全。
6. **发布阶段**：全包串行测试、Release、独立 Kit 消费端、Package 元数据、文档链接、差异检查和版本变更核对通过；提交、推送和发布分别记录。

建议交付顺序：**阶段 0 → Google Drive → Dropbox → SMB → SFTP → FTPS/有限 FTP → 区域性 API 网盘评估 → NFS 研究结论**。每一阶段都可以独立暂停，不阻塞已有 Local/WebDAV/OneDrive/iCloud 来源的维护。
