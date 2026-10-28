# 构建与验证状态

[返回项目首页](../README.md)

本页区分实现、受控测试、平台编译与真实服务验收。当前版本为 **`v0.4.0`（2026-10-28，GMT+8）**，以 Git 附注标签发布，不另外创建 GitHub Release。原 `v0.1.0`、`v0.2.0`、`v0.3.0` 标签不变；新能力不写回旧标签。下文保留各阶段的验证快照，各阶段数量不能相加，也不是后续任意源码版本的保证。

## v0.4.0 发布前验证

实现基线为已推送的 `3cb05c3`。发布准备只更新版本说明、文档与 iCloud 示例注释，不修改生产源码、测试或 Package 配置；已核对与分片最终验证的实现哈希一致。

| 检查 | 结果与范围 |
| --- | --- |
| 本轮串行全包 | `swift test --no-parallel`：**506 项通过**，39 XCTest + 467 Swift Testing（WebDAV142、Transfer45、OneDrive92、Kit4、iCloud47、Core/Local81、Catalog56），参数化 case 不重复计数；日志 `release-v040-tests.log`。 |
| 本轮 Release | `swift build -c release` 通过；日志 `release-v040-build.log`。 |
| 本轮独立 Kit 消费端 | 仅依赖/导入 Kit，自定义区间来源经 coordinator 读取 8 片、还原 59 字节并清理 lease；合成数据不是实际云端服务，日志 `release-v040-consumer.log`。 |
| 沿用的编译与流程证据 | 八模块 macOS12、iOS15/tvOS15/visionOS1 Simulator 编译链接、Transfer Swift 示例四目标类型检查，以及恢复下载/上传的受控跨进程验证；来自同一实现的既有记录，本轮未重跑这些检查。 |
| 文档与包 | 更新 README 安装版本、能力矩阵、各模块引入版本、迁移与验收边界；检查本地链接/标题锚点、包结构、源码哈希及 diff 格式。 |

工具链为 Swift 6.4 / Swift 6 语言模式，不是 Swift 6.0 编译器或最低系统运行验收。真实 NAS 分片与写入、Microsoft 账号/Keychain、iCloud entitlement/双设备、大文件性能、磁盘故障与断电仍未验收。既有 WebDAV 并发短 deadline 风险保留，串行全包通过不证明风险消失。日志位于会话工作台，不作为运行资源分发。

## v0.4.0：统一文件服务第一阶段

本节记录 **2026-10-28（GMT+8）** 第一阶段的验证快照：新增 Core 引用/版本契约与 `BoneRemoteSyncTransfer`，由单一 Kit 入口导出；同时保留 iCloud R3 批量状态改动。**这些实现现纳入 `v0.4.0`，不属于 `v0.3.0`；以下测试数量是当时的阶段结果，不是本次最终全包结果。** 用法与生命周期边界见 [Transfer](Transfer.md)。

| 检查 | 结果与范围 |
| --- | --- |
| 最终串行全包 | **435 项通过**：39 XCTest + 396 Swift Testing（WebDAV 129、Transfer 24、OneDrive 60、Kit 3、iCloud 47、Core/Local 77、Catalog 56）；参数化 case 不另计 |
| 生命周期行为红绿 | 共享 lease 计数、独立取消/最后消费者取消、无版本不复用、来源并发限制、错误脱敏、Core 解码、SHA-256 校验、并发 release 等待、阶段字节不归零及初始 stat shutdown 有实际失败→通过证据；新增 API 与部分集成为补充验证 |
| 四来源物化 | Local 临时目录；WebDAV 强 ETag/If-Match localhost fixture；OneDrive 使用来源返回的完整 ID、CDN 不携带 bearer 的 localhost fixture；iCloud 本地容器 seam。没有真实账号验收 |
| Release/Kit consumer | Release 通过；外部包只依赖/导入 Kit，执行 Local 文件→coordinator→lease→release/shutdown，无分模块 import |
| 最低目标编译 | macOS12、iOS15/tvOS15/visionOS1 Simulator，Core/Local/ICloud/WebDAV/OneDrive/Catalog/Transfer/Kit 八模块编译链接及 iCloud 示例类型检查通过 |
| 文档/包 | Package dump/describe、15 份 Markdown 的 116 个本地文件链接、Transfer Swift 示例类型检查及 `git diff --check` 通过 |
| 独立审查 | 中断后续接完成，未确认高严重度问题；提出的 localhost URL guard 优先级问题经精确错误回归无法复现，不修改正确实现。审查不等同真实服务验收 |

工具链仍为 Swift 6.4 / Swift 6 语言模式；不是 Swift 6.0 编译器、最低系统或真机运行验收。该阶段只提供进程内物化和前台有界调度；当时尚未接入通用恢复。后续阶段4结果见下节；OneDrive 专用 Upload Session、可恢复上传与安全 session 持久化在 `v0.4.0` 已接入，但不自动加入 Transfer coordinator，真实账号/Keychain/设备验收仍待完成。

验证中曾遇到主机空间不足（创建临时目录报 ENOSPC），恢复磁盘空间后重跑；这是环境失败，不作行为红灯。OneDrive 新 smoke 初版误用了原始 Graph item ID，来源按合同拒绝；测试改用 stat 返回的完整不透明 ID 后通过，没有放宽来源校验。最终日志位于会话工作台 `transfer-final-*`，不作为仓库资源分发。

## v0.4.0：阶段4 WebDAV 通用恢复适配

本节保留 **2026-10-28（GMT+8）** 阶段4的验证快照：新增 Core 可选恢复契约、只读 checkpoint 投影、Transfer 独立恢复服务及显式本地目标互斥，WebDAV 复用原有 provider checkpoint。未将物化队列改成持久任务系统；当时未更改发布标签，现随 `v0.4.0` 提供。

| 检查 | 结果与范围 |
| --- | --- |
| 最新串行全包 | **450 项通过**：39 XCTest + 411 Swift Testing（WebDAV 134、Transfer 33、OneDrive 60、Kit 3、iCloud 47、Core/Local 78、Catalog 56），参数化 case 不另计 |
| 新合同与行为 | 先运行缺失新 API 的编译失败，再接入并通过；不把该编译失败称为行为红灯。锁目录不能作为下载目标有实际断言失败→修复→通过；后补 checkpoint 不变量、祖先别名、取消/进程互斥为补充验证 |
| 生命周期/安全 | 取消后新来源实例继续；wrong binding/不支持来源提前拒绝；版本、locator、inode/前缀改变无 GET；ready 与 committed-cleanup-pending 分离；通用适配层抛错/取消后释放锁，提交后取消保留回执；残留 checkpoint 清理不重复 GET；锁文件 symlink/hardlink 拒绝，checkpoint 不存原始 binding 路径 |
| 独立进程 | 同一锁目录下第二个实际 Kit recovery 进程的 checkpoint 与 download 均被锁拒绝，原 part/sidecar 未变；首进程确认 131072 字节后 SIGKILL，新进程从 `Range: bytes=131072-` 恢复，最终 SHA-256 一致、共2 GET；仅 localhost 合成 fixture |
| Release/平台/Kit | Release、四最低目标八模块编译链接+iCloud示例通过；外部独立消费端仅依赖/导入Kit执行恢复流程；不是最低OS或真实NAS运行验收 |
| 文档/包 | 15份Markdown的118个本地文件链接、两个Transfer Swift示例类型检查、package dump/describe及diff格式检查通过 |
| 独立审查 | 已完成；未确认当前合同内的确定性缺陷。补充通用适配释放路径和实际 recovery 进程竞争验证；账号 identity 与当前凭据的关联、已有 checkpoint 权限隔离仍由宿主保证，已明确写入文档 |

日志保留在会话工作台 `recovery-*.log`，独立消费端及过程驱动为 `recovery-consumer/` 和 `verify-recovery-process.py`。默认恢复下载不覆盖已有目标；跨进程互斥以所有参与者使用同一稳定私有本地锁目录为前提，不约束绕过协议的写入。锁文件不自动删除，不提供分布式锁、断电目录项持久保证或未知已提交结果的无限期幂等识别。读取 checkpoint 只证明本地观察通过，远端版本在实际继续时重验。真实 WebDAV/NAS、大文件吞吐、磁盘故障和权限环境尚未验收。

## v0.4.0：阶段5 OneDrive Upload Session 验证

本节保留 **2026-10-28 17:30 GMT+8** 阶段5的验证快照：接入 Core 上传恢复合同、Transfer 显式 `RemoteUploadRecovery` 与 OneDrive Personal 专用 Upload Session。普通 OneDrive 构造器仍为 false，仅专用 `resumableUploadService` 构造器启用。没有自动加入 coordinator/Catalog 或后台队列；当时尚未发布版本，现随 `v0.4.0` 提供。

| 检查 | 当前结果与证明范围 |
| --- | --- |
| 最终串行全包 | **486项通过**：39 XCTest + 447 Swift Testing（WebDAV134、Transfer33、OneDrive92、Kit4、iCloud47、Core/Local81、Catalog56）。参数化case不另计；日志 `upload-reviewed-full.log`。 |
| 上传与安全定向 | 28项Upload Session + 4项URL/Keychain后端替身 + 3项Core合同。覆盖local-only prepare、默认不覆盖/拒绝条件ETag、GET/202省略URL、连续确认前缀、无进展416/202边界、长Retry-After、创建/最终/abort丢响应、明确拒绝/冲突、快照中途变化、回执持久化失败和重复领取、终态forget及核对期间取消/安全存储读失败。Kit另覆盖统一导出/能力/binding拒绝。 |
| 行为红绿 | 条件ETag、最终意图保存、回执持久化、生命周期、Core解码、创建429与最终冲突错误分类、核对中取消且存储不可读等有实际失败→修复→通过记录；其余补充测试不宣称均经历行为红灯。构建超时/测试编译错误不是有效红灯。 |
| 实际跨进程 | 原进程确认327680字节后持锁暂停，第二进程checkpoint/resume/abort均被锁拒绝，记录/快照未变；SIGKILL后新进程恢复同一session，900000字节SHA-256一致，仅1次POST与3次顺序PUT。第三进程直接领取持久回执，不再请求session。使用仅接受localhost合成URL的文件store替身，不访问真实Keychain。 |
| Release/四目标 | 最后实现后的Release通过；macOS12、iOS15/tvOS15/visionOS1 Simulator目标八模块编译链接及iCloud示例通过。工具链Swift6.4/Swift6模式；不是Swift6.0编译器或最低OS运行验收。 |
| 独立Kit消费端 | 外部包仅依赖/导入Kit，执行通用协议fixture的prepare→保存/解码handle→checkpoint→resume→回执，并构造OneDrive opt-in验证能力；无真实Keychain I/O。实际OneDrive跨进程probe另用内部测试seam，不能混称仅公共API的真实云端测试。 |
| 独立审查 | 只读审查与增量复核已收敛，确认创建拒绝/最终冲突修复；最后指出的取消时存储读取失败分支由父会话补行为红灯并修复，最终全包通过。审查者未运行测试，最后这项修复未再请求独立复核。 |

过程日志位于会话工作台 `upload-*.log`，进程驱动为 `UploadProcessProbe.swift` / `verify-upload-process.py`，外部单产品包为 `upload-consumer/`。这些是开发证据，不作为生产资源分发。15份Markdown的128个本地链接、22个标题锚点、OneDrive恢复上传及两段Transfer示例类型检查、package dump/describe与 `git diff --check` 均通过；包结构确认Transfer只依赖Core。

**仍未验收/未提供：** 真实Microsoft Graph账号与OAuth轮换、真实Keychain entitlement/签名/沙箱、移动设备/最低OS运行、断电/磁盘故障、大文件吞吐与跨设备。当前5 GiB上限、非空普通文件、路径目标、默认非覆盖；最终ETag条件替换仍unsupported。未知创建/提交/abort保留证据，不自动新建/删除，尚无人工归属确认后的通用清扫API。快照目录不得在同步根内，由宿主保证；合作锁不防绕过协议的进程。阶段6 Catalog可选集成尚未实施；本节是版本发布前的阶段证据，现有实现纳入 `v0.4.0`，发布不扩大验收范围。

## v0.4.0：可插拔单文件并行分片下载

截至 **2026-10-28（GMT+8）**，Core 新增 `RemoteByteRangeSource` / `RemoteByteRange`，Transfer 通过显式策略复用物化生命周期，首个内置适配为 WebDAV。默认仍顺序下载；此能力现随 `v0.4.0` 提供，不在 `v0.3.0` 中；本节保留分片实现阶段的验证证据。

| 检查 | 当前结果与证明范围 |
| --- | --- |
| 最终串行全包 | **506 项通过**：39 XCTest + 467 Swift Testing（WebDAV 142、Transfer 45、OneDrive 92、Kit 4、iCloud 47、Core/Local 81、Catalog 56）。参数化 case 不另计；日志 `segmented-final-full.log`。 |
| 新增公共层测试 | 12 项，覆盖非 WebDAV 来源协议复用、首片探测、乱序拼装与尾片、共享来源请求上限、普通/分片混用、进度、取消/shutdown 排空、缓存策略隔离、强版本/阈值、错误摘要与元数据变化、非法配置及溢出。 |
| 新增 WebDAV 测试 | 8 项，包含参数化场景：精确闭区间/同版本、忽略 Range 的显式降级、坏区间/ETag/长度/编码、412/416、无强版本/空文件、断开不发布、畸形 200 不降级、503 重试保持同 Range/If-Match、无 Content-Length 的 chunked 短读/超额读取。超额后保持连接 5 秒的 fixture 在 3 秒断言内退出。 |
| 红绿与补充验证 | 公共策略和 WebDAV 适配有实际行为失败→实现→通过记录。审查提出的畸形 200 误降级、Range 忽略已有有限重试也分别复现后修复；chunked 正文检查为首次即通过的补充验证。编译错误不计为行为红灯。 |
| 独立审查 | 只读对抗审查及增量复核已收敛；两项 P2 修复确认关闭，未发现新增明确阻断。审查者未运行测试，运行证据由主会话取得。 |
| Release / 最低目标 | 最终实现后 Release 通过；macOS12、iOS15/tvOS15/visionOS1 Simulator 八模块编译链接及 iCloud 示例通过，Transfer 三段完整使用示例四目标类型检查通过。仍为 Swift6.4 / Swift6 模式，不是 Swift6.0 编译器或最低系统实机验收。 |
| 独立 Kit 消费端 | 外部包只依赖/导入 Kit，自定义 `.cloudAPI` fixture 仅实现公共区间协议，经 coordinator 强制分片与强版本请求，8 片还原 59 字节并验证 lease 清理；未导入内部模块，未调用真实网盘。 |

文档包括 [Transfer 接入与扩展合同](Transfer.md#可插拔的单文件并行分片下载)、WebDAV 行为、业务场景、README 与更新说明。开发证据位于会话工作台 `segmented-*.log`、`segmented-consumer/`、`SegmentedTransferDocExamples.swift`，不是生产资源。

**仍未提供或验收：** 持久分片 bitmap、跨进程分片续传、自动后台调度、自适应测速、分片上传，以及其他内置来源的闭区间适配。真实 NAS/网盘兼容性、公网吞吐、大文件峰值内存、磁盘故障、最低系统及真机运行未验收。并发 gate 只约束同一 materializer 的普通下载/区间请求，不约束 metadata、其他实例或绕过入口的调用；没有进程总内存保证。分片并发不等于必然加速，localhost 通过不能推广为真实服务验收。

## 本地验证命令

```bash
swift build
swift test --no-parallel
swift build -c release
```

仅运行统一导入的公共 API 测试：

```bash
swift test --filter UnifiedImportTests
```

要求：

- Swift tools 6.0+，Swift 6 语言模式；最低声明平台为 iOS 15、macOS 12、tvOS 15、visionOS 1。
- WebDAV 与 OneDrive 的 HTTP fixture 测试仅在 macOS 运行，使用 `/usr/bin/python3`（Python 3.8+）及标准库。
- fixture 只监听 `127.0.0.1` 动态端口，使用合成数据、虚构凭据与自建临时目录，不需要真实 NAS 或 Microsoft 账号。
- 生产模块不依赖 Python，也不提供 Linux 支持。

## v0.3.0 iCloud 备份 R1/R2 验证

截至 **2026-10-27（GMT+8）**，本节记录纳入 `v0.3.0` 的 R1 结构化错误/可用性与 R2 准备状态/本地传输阶段改动验证。本轮保持 Swift 6.4 / Xcode 27.1、Swift 6 模式和原最低平台要求；未用 Swift 6.0 编译器或最低 OS 真机运行。

| 检查 | 结果与范围 |
| --- | --- |
| 行为红绿 | typed hydration timeout、命名容器与默认容器区分、Core/Local 进度、OneDrive 空文件进度、status Codable 原因约束、权限误分类及账号变化时 metadata 晚到均有实际失败→通过；编译错误及首次通过的账号/容器测试不算红灯 |
| 最终串行全包 | **392 项通过**：39 XCTest + 353 Swift Testing（WebDAV 127、OneDrive 59、Kit 2、iCloud 38、Core/Local 71、Catalog 56）；含审查修复、status Codable 和 Kit 新契约断言，不将定向结果或参数化 case 再相加 |
| Release | `swift build -c release` 在最终审查修复后通过 |
| Kit 公共入口 | 仅 import Kit 的统一入口测试及独立单产品消费端通过，包含新错误、availability reason 和阶段类型；未连接账号 |
| 最低目标 | macOS12、iOS15/tvOS15/visionOS1 四目标，七模块编译/链接、完整 iCloud 示例与指南中 3 个 Swift 片段的类型检查通过 |
| 文档与包 | Package dump/describe、11 份 Markdown 的 99 个本地文件链接与 `git diff --check` 通过；发布前另检查 18 个本地 Markdown 标题锚点 |
| 独立对抗审查 | 发现根目录权限误分类、metadata 晚到发布旧账号 ready 两项问题；父会话先复现失败再修复。审查者只读复核确认两项闭环；复核未独立运行测试，也不是真实系统验收 |

新增覆盖包含：无 identity、服务无法解析、指定容器失败但默认可访问、配置根不存在/连接后删除、账号切换及退出（含 metadata 查询期间）、根目录权限错误不误报不存在、typed timeout、准备状态去重、ready/transfer 顺序、准备期间取消、空文件、续传偏移及比例、统一 Kit 导出、Codable 不绕过原因约束。iCloud 准备百分比采用可靠状态 fallback，`percentDownloaded` 仍 nil；本轮没有 NSMetadataQuery 连续百分比。部分实现先于测试，按补充验证记录，不声称全部新增测试经过红绿。

Q1–Q7、显式 `/Documents/Backup` 初始化与恢复/上传/保留清理示例见 [iCloud 指南](ICloudDrive.md)。Core 不依赖 iCloud，业务命名/打包/保留策略仍属宿主。没有新增 R3 批量状态、R5 批量删除、Catalog iCloud provider 或自动同步。

真实 Apple 账号、Drive 开关、entitlement/签名、≥50 MB 真正占位文件、存储不足/离线、双设备传播和系统冲突版本均未验收；状态 seam 不能替代这些条件。此次串行全包也不证明既有 WebDAV 并发短 deadline 风险已消失。OneDrive 在途阶段/字节回调可晚于取消返回，已明确宿主按任务 ID 过滤；没有新增回调排空保证。审查修复后的平台命令曾在完成 macOS/iOS 两目标后触及 240 秒命令时限，串行重跑后四目标通过；超时不当作实现缺陷、测试红灯或四目标已通过的证据。较早重新编译曾出现既有 OneDrive 上传测试未使用返回值的警告，未顺带修改它们；不宣称全部历史编译日志无警告。发布前再次执行串行全包、Release、独立 Kit 消费端和 Package 检查，结果通过，测试仍为 392 项；发布整理仅更新文档状态，未再次修改实现。四目标编译与示例检查沿用最终审查修复后同一实现的通过结果。原始日志以开发会话工作台的 `r3-*`、`v030-*` 文件记录，不作为仓库资源分发。

## 历史开发阶段：第二轮通用语义与 OneDrive 验证

该阶段源码已随 `df92320` 提交并推送，当时未创建新版本 tag，现纳入 `v0.3.0`。以下是当时本机源码/fixture 验证，不是真实账号或远端服务验收。

| 检查 | 结果与范围 |
| --- | --- |
| 条件上传红绿 | 先用回归测试证明旧 WebDAV 实现忽略调用方 ETag；随后 WebDAV `If-Match`、Local/iCloud/OneDrive 拒绝分支通过 |
| 内容校验值红绿 | 算法长度校验、Codable 不绕过校验、原始摘要字节与 ETag 独立性通过 |
| OneDrive 稳定 ID 红绿 | 按 ID 查询、重命名后 `path=nil`、父 ID 分页、游标绑定/消费、下载及错误输入边界通过 |
| 第二轮全包 | **336 个测试运行项通过**（SwiftPM 按 target 输出 126、58、2、25、69、56 的测试运行汇总；参数化 case 不额外相加） |
| Release | `swift build -c release` 通过 |
| 独立 Kit 消费端 | 通过，确认新 Core/OneDrive API 由单一 Kit 产品暴露；未连接真实账号 |
| 最低目标 | macOS12、iOS15/tvOS15/visionOS1 四目标，七模块编译/链接与 iCloud 示例类型检查通过 |
| Package/文档 | `dump-package`、`describe`、Markdown 本地链接、`git diff --check` 通过 |

本轮未进行真实 WebDAV/OneDrive 服务、Microsoft/Apple 账号、跨设备传播或发布验收；OneDrive ID 与 Upload Session 语义均在本地 HTTP fixture 中验证，不能据此声称真实 Graph 行为已验收。未实现 OneDrive ID 写接口、内容摘要自动采集/下载校验、Catalog 稳定 ID 缓存或自动同步引擎。Upload Session 仍是专用构造器 opt-in，普通 OneDrive 构造器不启用。

## 历史开发阶段：首轮 iCloud Drive 验证

首轮 iCloud 源码已随 `df92320` 提交并推送，当时尚未版本发布，现纳入 `v0.3.0`，不在 `v0.2.0` 中。以下为首轮验证快照，使用 Swift 6.4 / Xcode 27.1、Swift 6 语言模式，不是 Swift 6.0 编译器或最低系统实机验收。

| 检查 | 结果与范围 |
| --- | --- |
| `swift test --no-parallel` | **361 项通过**：39 XCTest（原 34 + iCloud 5）+ WebDAV 122、OneDrive 53、Kit 2、iCloud 24、Core/Local 65、Catalog 56；参数化 case 不额外累计 |
| iCloud 专项 | 共 **29 项**；临时目录、真实本地 NSFileCoordinator 调用与注入 ubiquitous 状态，不连接真实 iCloud |
| Release | 来源与安全修复后构建通过 |
| 最低平台目标 | Core、Local、ICloud、WebDAV、OneDrive、Catalog、Kit 七模块编译/链接通过；macOS12、iOS15/tvOS15/visionOS1 Simulator；新的 iCloud 示例四目标类型检查通过 |
| 独立 Kit 消费端 | 只依赖/导入 Kit，构建并运行 iCloud 类型、协议和能力断言；没有连接 Apple 账号 |
| 文档 | iCloud 指南 Swift 示例类型检查；本地链接与 `git diff --check` 检查 |
| 独立只读复核 | 多次等待未得到结果后取消，**没有形成独立审查结论**；不把任务启动/终止当作审查通过 |

新增覆盖：配置与 Codable 校验、来源根和子目录、系统凭据约束、list/stat/status、文件读写/复制/移动/删除、无分页、根与根别名保护、尚不存在路径的 symlink 越界、目录覆盖保护、source/part symlink 或 hardlink 身份冲突、本地复制取消、占位下载触发一次并等待 current、超时、断开/重连隔离、续传偏移/长度/ETag、冲突拒绝与 partial coverage、旧式隐藏占位标记、未知或缺失元数据。

12 项安全回归先记录行为失败再修复通过；最初 10 项测试发现目录覆盖删除、后台取消不传播、symlink 越界/part 安全、配置解码绕过校验及名称路径别名等问题，随后另补根别名与 symlink copy/move 的失败→通过记录。状态与轮询测试是实现后的补充验证，不能宣称每项新增测试均独立经历红绿闭环。首轮全包 359 项通过，追加两项安全回归与实现后，最终全包 361 项通过；不是把定向测试与全包结果相加。

测试中的移动通知曾出现 Foundation `NSFileSandboxingRequestRelatedItemExtension` 的不存在目标扩展诊断，测试断言和退出码通过；未通过关闭协调或忽略失败断言隐藏它。平台检查脚本初次缺少 package-name / 依赖链接参数，修正脚本后四目标通过；这些脚本错误不是平台实现缺陷或测试红灯。既有 WebDAV 并行短 deadline 风险仍保留，本轮串行通过不证明其已消除。

本轮未完成：真实 entitlement/ubiquitous container、Apple 账号/账号切换、真正云端占位内容、断网与双设备、真实系统冲突版本、其他进程文件 presenter 协调及四平台实机运行。状态模拟和临时目录不构成上述验收。Catalog iCloud provider、递归目录 copy、NSMetadataQuery 变更/百分比、NSFileVersion 选版或合并、CloudKit 与自动同步均未实现，详见 [iCloud 指南](ICloudDrive.md)。

原始日志、独立消费端与平台脚本位于开发会话工作台 `74fc24c1-0635-4eeb-b7b4-18393242010b/`，未作为仓库资源分发。

## 历史开发阶段：错误日志验证

本阶段在 Catalog 基线上新增结构化日志，已随 main 推送，当时未创建新版本 tag，现纳入 `v0.3.0`。该阶段最后一次完整验证为 **332 项通过**，不是将定向与全包结果相加。该阶段提交前已核对 66 个文件与验证快照一致，之后仅修改文档状态表述并重跑文档检查，没有重复运行全包测试；`v0.3.0` 最终完整结果见本页前文。

| 检查 | 结果与范围 |
| --- | --- |
| `swift test --no-parallel` | 332 项：34 XCTest + 122 WebDAV + 53 OneDrive + 65 Core/Local + 56 Catalog + 2 Kit；本轮新增 16 项日志测试 |
| Release | 最后审查修复后构建通过 |
| 独立 Kit 消费端 | 2 项通过，包含统一入口日志契约；两段日志示例在消费端编译 |
| 最低平台目标 | macOS12、iOS15/tvOS15/visionOS1 Simulator；六模块编译/链接、原三份示例及两段日志示例通过 |
| 文档 | 11 份文档、24 个 Swift 片段通过类型检查，本地链接检查通过 |
| 独立只读审查 | 三项诊断遗漏已修复并复核；审查者不运行测试，红绿证据由父会话执行 |

新增测试覆盖：原错误敏感文本/NSError userInfo 不进入事件、全部来源与 Catalog/凭据错误分类、取消级别、级别过滤、并发 sink、sink 抛错、未知 schema/损坏库保留、重复 owner、关闭失败、成功恢复与恢复失败、成功刷新无错误日志、报告聚合及状态写库失败不吞扫描失败日志。

Core 的空实现契约先出现 4 项行为失败，Catalog 接入先出现 6 项行为失败，再分别实现；审查追加的 3 项诊断缺口也有实际失败→通过记录。其余边界用例为补充验证，不宣称全部新增测试都独立经历红灯。早期重新编译出现既有 OneDrive 测试未使用返回值警告；未修改这些业务测试以掩盖警告。

本轮无日志文件轮转/落盘服务、真实 Keychain、真实 provider 或真实宿主 sink 验收。OSLog 示例经过编译，没有替宿主开启系统日志；自定义 sink 仍须线程安全、快速返回、不阻塞或同步回入 SDK。已知默认并行 WebDAV 时序风险未因此消除。证据在开发工作台 `verification/logging-20261026/`；规范及自动覆盖范围见[错误日志](Logging.md)。

## 历史开发阶段：Catalog 验证

| 检查 | 结果 | 证明范围 |
| --- | --- | --- |
| 全包测试（显式串行） | **316 项通过** | `swift test --no-parallel`：34 XCTest + 122 WebDAV、53 OneDrive、61 Core/Local、44 Catalog、2 统一入口 Swift Testing；参数化 case 不另计 |
| Release | 通过 | 最后实现修复后的生产配置构建 |
| 独立单产品消费端 | 3 项通过 | 仅依赖/导入 Kit，验证来源协议、Catalog 保存/扫描/重开离线查询；不使用 `@testable` |
| 独立进程持久化 | 通过 | 写进程正常关闭退出，第二进程在原来源目录已删除后仍读取配置、根选择及完整缓存；不等于强杀/断电测试 |
| 接入文档与示例 | 22 个 Swift 片段及三份示例通过 | Catalog、WebDAV、OneDrive 示例；本地 Markdown 链接检查通过 |
| 最低平台目标 | 六模块编译与链接通过 | Core→Local/WebDAV/OneDrive→Catalog→Kit，macOS 12、iOS 15/tvOS 15/visionOS 1 Simulator 目标；包含系统 SQLite 与 Security 链接 |
| 规模检查 | 100,100 条合成元数据通过 | 100 个目录、各 1,000 文件；检查父目录排序索引和版本化分页，不是网络或性能 SLA |

本轮仍使用 Swift 6.4 / Xcode 27.1、Swift 6 语言模式；没有用 Swift 6.0 编译器、最低 OS 或真机运行验证。初版平台脚本有 sysroot 警告并被工具时限中断，随后改为显式 SDKROOT 与平台 xcrun 的新脚本；最终四平台日志无 warning/error，保留初版记录而不当作最终证据。

最终串行全包中的规模观测约 7.18 秒、测试宿主峰值 RSS 50,315,264 字节、WAL 1,577,992 字节。早期独立/并行运行有不同时间和内存数据；环境负载、构建配置和测试宿主都会影响结果，不能作为吞吐或内存上限承诺。

### 本轮失败及修复记录

- 默认 `swift test` 的首次全包失败集中于既有 WebDAV retry 套件：4 项测试、5 个 issue，包含 5 秒总时限及请求数断言；相关定向测试通过。显式 `--no-parallel` 后完整 122 项 WebDAV 测试通过，最终全包通过。**这不是默认并行稳定性的证明**，未放宽生产时限或删除断言，旧短时限及上传最终进度间歇风险仍保留。
- 串行全包两次停在 OneDrive 测试 fixture 清理。进程采样分别定位到 read/write fixture 的 `Process.waitUntilExit()`；只停止本轮已确认挂起的测试进程，将两个 helper 改为启动前注册的退出回调与 10 秒有界等待。OneDrive 53 项和最终全包随后通过；没有修改生产 OneDrive 超时或网络行为。
- Catalog 独立只读审查发现并修复历史 binding 复用、提交前取消、旧根重选、长路径分页 token、旧 binding 离线清索引以及配置更新中断记录等问题。关键修复有实际行为红灯与通过回归；审查者复核实现并由父会话等待收敛，但未独立运行测试。
- 硬链接准入验证在已关闭数据库上进行：有多链接时拒绝原路径/别名，去掉别名后数据可重开读取。外部给活跃数据库加链接曾产生系统 SQLite `SQLITE_IOERR_VNODE`，不承诺该非法生命周期操作后连接继续可用；独立 C probe 未复现相同行为，不能声称已证明系统库根因。

### 验证范围与明确限制

- 凭据测试使用内存 store/注入 Security backend；OneDrive 轮换集成为 localhost 合成服务。未访问真实 Keychain、Microsoft 账号或 NAS。
- 恢复测试验证正常关闭含未终结 run 的 DB 后重开：已发布目录保留，staging 丢弃，run/目录中断状态有结束时间；不是硬件断电或 Catalog SIGKILL 验收。
- Local/WebDAV 单个大目录仍可能先全量物化。Local 已增加逐项和排序前后取消检查，预算不等于初始物化内存上限。
- 不可见旧代次与运行历史没有自动保留期限；宿主可离线 `clearIndex`，包括旧 binding 根。自动 GC、备份导出、后台调度均未实现。
- 初始失败、行为红绿日志、两次挂起采样、最终串行全包、消费端及平台结果保存在开发工作台 `verification/catalog-20261026/`，未作为仓库资源分发。

## 历史 v0.2.0 验证摘要

| 检查 | 结果 | 证明范围 |
| --- | --- | --- |
| 全包测试 | 260 项复测通过 | 34 XCTest；119 WebDAV、50 OneDrive、55 Core/Local、2 统一入口 Swift Testing（参数化用例计入所属测试，不额外累加） |
| Release 构建 | 通过 | 当前工具链的生产配置编译 |
| 单产品消费端 | 2 项通过 | 只依赖 `BoneRemoteSyncKit`，无分模块 import，也能使用来源、Core 类型及协议扩展 |
| 接入示例 | 两份示例编译通过 | WebDAV 与 OneDrive 宿主片段的类型和依赖正确，不代表完成外部登录 |
| 最低平台目标 | 五模块及两示例编译通过 | arm64 macOS 12，以及 iOS 15 / tvOS 15 / visionOS 1 的 Simulator SDK 目标 |

该历史阶段使用 **Swift 6.4 / Xcode 27.1、Swift 6 语言模式**。未用 Swift 6.0 编译器重测；最低平台编译不等于模拟器、旧系统或真机运行验收。

此前按失败回归 → 实现 → 通过回归的顺序修复 Local 源/part 冲突、非覆盖竞争、非法续传偏移，WebDAV collection 尾斜杠与 207 目标资源错误，以及 OneDrive 上传 MIME。独立复核进一步发现并修复覆盖下载普通权限保留、207 目标瞬态状态重试两项问题。新增 19 项测试覆盖链接/身份、权限、源变化、取消、308 规范化、原 deadline、拒绝任意重定向、认证重放等边界。

此前缺陷修复首轮并发全包产生 12 个 issue，涉及 WebDAV 短 deadline 和请求数断言。将新增多进程兼容矩阵串行化后，又观察到两次测试清理挂起；采样定位于 `Process.waitUntilExit`，改用运行前注册的退出回调和有界等待断言。没有删除断言或放宽生产超时；原 deadline 相关 17 项测试单独通过，最终完整复测 243 项通过。首次失败、挂起采样与复测日志均保留在开发工作台，不能用最终绿灯隐去时序敏感性，也不把串行化视为在所有负载下稳定的证明。

本次文件元数据扩展新增 17 项测试，覆盖可选创建时间、三个来源映射、普通/managed 下载、JSON/检查点缺少可选字段的解码行为，以及无 I/O 分类的 MIME 优先级与未知回退；统一入口和独立消费端也增加新 API 断言。历史用例包含旧格式样本，这些测试保留为当前可选字段行为验证，不构成跨版本兼容承诺。来源映射与检查点验证先取得行为失败再实现；分类及 Core Codable 为新增 API 后的通过验证，不把 API 缺失编译错误算作行为红灯。

本次首轮全包中新增测试均通过，但已有 `WebDAVRetryTests` 再次出现 3 个短 deadline issue。重试/日期/元数据合计 21 项单独回归通过，之后**未修改生产时限、断言或重试测试**，完整复测 255 项通过。之后独立复核补修严格日期解析（包括古日期历法）、OneDrive 新增可选字段类型容错和恢复时已知日期保留，并补充测试。再次全包出现 2 个短 deadline issue，以及原有上传进度最终字节断言失败；对应 8 项重试/写测试单独通过，未改其实现或断言。最终完整复测 **260 项通过**。所有失败与复测均留存；短时限与上传进度断言在并发运行下的间歇失败尚未稳定复现或闭环，不能宣称已消除该风险。

2026-10-26 后续版本策略调整取消向后兼容承诺，仅更新说明及 Package 注释；未修改生产逻辑、测试、产品配置或最低平台要求，也未重新运行全包测试。上列 260 项为此前实现验证结果。

中间一次重新编译测试时出现 `OneDriveWritingTests.swift:144,166` 的两条未使用 upload 返回值警告，未顺带修改这些既有测试。最终 Release 与最低平台编译日志无 warning/error；这不等于所有历史测试编译日志均无警告。

## 真实服务验收

| 范围 | 已完成 | 尚未完成 |
| --- | --- | --- |
| iCloud Drive | 临时目录及注入状态测试；平台编译 | 真实 entitlement、占位文件、账号切换、离线、双设备、冲突版本和真机 |
| 本地目录 | 临时目录中的功能与安全测试 | 所有磁盘类型、外部并发攻击、断电持久性等穷尽验证 |
| WebDAV 真实飞牛 | 有限只读：账号可见非隐藏树、3 个小样本下载、条件续传 | 写入、真实 NAS 故障恢复、大文件公网性能、其他厂商与移动端运行 |
| WebDAV 写入 | localhost：PUT、MKCOL、DELETE、MOVE、COPY；覆盖竞争、取消、重连、错误映射等 | 真实 NAS 写权限、ETag 与方法兼容性 |
| WebDAV managed 恢复 | localhost 故障注入、独立进程取消／SIGKILL 后恢复、ready／rename 窗口 | 真实网络、硬件断电、移动设备运行 |
| OneDrive Personal | localhost：OAuth 请求合同、分页、文件读写、生命周期与安全边界 | 真实 Microsoft 应用／账号、CDN、刷新轮换与授权撤销验收 |

真实服务验收清单见 [WebDAV 示例](../Examples/WebDAVReadWrite/README.md)和 [OneDrive 示例](../Examples/OneDriveReadOnly/README.md)。只在明确授权的专用测试目录中写入；失败后先核实远端状态，不依据错误返回推断“没有创建”。

## 历史验证与性能记录

- 历史只读与下载恢复验证使用 Swift 6.2 / Xcode 26.0。
- WebDAV 写能力阶段全包 222 项通过；统一入口增加 2 项公共 API 测试后，全包复测为 224 项。缺陷修复增加 19 项后为 243 项；文件元数据扩展含复核回归共增加 17 项后为 260 项。
- 统一入口阶段曾有一次并发执行触发已有 WebDAV 重试套件的 3 个失败测试、4 个 issue；未改其断言，单独套件及全包复测通过。
- 曾使用 localhost 合成服务和独立 Release runner 比较优化前后的目录解析、下载及遍历；场景包含 32 MiB payload、2,000 项元数据及 30 目录／30 文件的内容或请求数核对。
- 历史原始日志、进程故障探针及性能 runner 保存在开发会话工作台，**未随本仓库分发**。本仓库不存在可直接执行的 `benchmarks/webdav-performance/run.py`，因此不将该路径作为公开复跑命令，也不据此给出公网吞吐承诺。

若需要发布性能数字，应先把测量工具、固定样本、工具链与复现步骤纳入仓库，再重新测量。

## 未实现与后续方向

完整的未支持来源路线图见[未支持来源开发计划](CloudDriveRoadmap.md)，其中区分 API 网盘、网络文件系统、共性 Core 合同和真实服务验收门槛。

以下是候选方向，不是已发布能力、承诺日期或既定开发顺序：

1. 完成 WebDAV 与 OneDrive 的真实服务读写及异常验收。
2. 完成 OneDrive Upload Session 的真实 Microsoft 账号、Keychain entitlement、大文件、断电/权限和最低系统验收；实现已在受控 localhost fixture 中覆盖。
3. iCloud Drive 已有文件来源实现；继续真实宿主验收、NSFileVersion/元数据观察与 Catalog 账号绑定设计。SMB 或其他来源按产品需求选择。
4. 独立同步层：快照、差异、可预览计划、执行与状态存储，再考虑双向冲突策略。

当前没有自动同步、后台传输、变更流、统一跨来源上传续传或统一跨来源事务。OneDrive 专用 Upload Session 不由 Transfer 自动调度，且只有专用构造器声明可恢复上传；尚未实现的来源不得通过空实现或能力声明伪装为可用。
