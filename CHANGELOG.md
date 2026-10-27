# 更新说明

[返回项目首页](README.md) · [通用 API](Docs/API.md) · [验证记录](Docs/Validation.md)

本文件记录对使用者有影响的功能、修复、版本策略与行为变化。实现完成、测试通过和版本发布是不同状态；标为“未发布”的内容不代表已包含在远程分支或版本标签中。

## 未发布 — 配置持久化与目录缓存

- 新增 Core 结构化错误日志规范与 `RemoteLogger`：固定分类/级别/操作、默认关闭、宿主注入输出，Catalog 初始化/恢复/关闭及高层操作自动接入。丢弃原始错误文本，sink 抛错不替换业务错误，刷新失败按类别聚合；详见[日志规范](Docs/Logging.md)。
- 新增可选 `BoneRemoteSyncCatalog`，由统一 Kit 导出：系统 SQLite 配置/根选择/离线分页，显式 children/subtree 刷新、目录级原子发布、失败保留旧缓存与中断恢复。
- 新增可替换同步凭据 store 和 Apple Keychain 桥接，固定引用轮换回调、引用级会话互斥、Local 宿主访问 lease。没有真实 Keychain/账号验收。
- `RemoteListPage` 构造必须显式指定 coverage；Local/WebDAV 不再把已知漏项报告为完整目录。visitor walk 拒绝 partial/unknown，stream walk 仍仅用于部分浏览。
- 细化 `RemoteCatalogFailureReason`：保留未连接、不支持、限流、冲突、完整性不匹配及取消分类，不再统一折叠成 network/other；宿主的穷尽 switch 需同步更新。
- 新增 OneDrive `connectedDriveID()` 以核对持久账号绑定；不保存 token 到 SQLite、不持久化远端 cursor。
- 本次没有发布新版本、移动旧 tag 或创建 GitHub Release。API 与行为边界见 [Catalog](Docs/Catalog.md)，实际检查结果见 [验证记录](Docs/Validation.md)。

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
- 本轮没有增加图片尺寸、EXIF、音视频时长、封面、缩略图、转码或真实格式检测，也未增加 iCloud、Upload Session、后台传输或同步引擎。

完整验证范围、历史失败和未验收项见[构建与验证状态](Docs/Validation.md)。本次发布准备仅修改文档，没有重新运行全包测试；上述结果引用此前对同一实现完成的验证。
