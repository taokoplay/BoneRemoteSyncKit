# 构建与验证状态

[返回项目首页](../README.md)

本页按实施阶段保留验证证据。旧章节的“未提交/未推送”“未集成”和测试数量描述当时状态，不覆盖后续实现；当前工作区、已推送源码和发布标签的区别以[首页版本对照](../README.md#开发源码与版本范围)为准。旧 API 名称只在迁移说明、负向测试或历史记录中保留。

## 说明文档与当前功能对齐（文档校正）

本轮复核并修正首页、API/Browser/内容服务、Catalog/Transfer、来源路线图及相关指南的现状描述：明确 `v0.8.2` 标签、已推送 `fe8cfc2` 开发源码和本地统一枚举改动的区别；补齐原生内容协议表、Browser 业务入口、OPDS 封面版本范围，澄清 Local/WebDAV 与 Transfer 调度的分工。Audiobookshelf 文档补齐导入和失败清理，示例注释区分提交前拒绝与已提交后的未知结果；生产逻辑未改动。

已通过全库 Markdown 本地链接/锚点/代码块和差异格式检查；Audiobookshelf 五个文档片段在提供宿主参数后，与其示例文件一起通过 macOS 12、iOS 15/tvOS 15/visionOS 1 Simulator 的 Swift 6 类型检查，零 warning/error。本轮没有重跑未改动生产代码的全包测试，下方 740 项结果继续作为最近完整回归；未增加真实服务或设备验收。远端 main 已用 `git ls-remote` 核对为 `fe8cfc2bad65b02fe5ef5e946619af71e7287e1f`。记录在会话工作台 `docs-alignment-links.json`、`docs-alignment-check/results.json`，不随 SDK 分发。

## 来源枚举统一（未发布，最终验证）

来源身份统一为 `RemoteSourceKind`：OneDrive、Google Drive、阿里云盘分别为 `.oneDrive`、`.googleDrive`、`.aliyun`，移除 `.cloudAPI`；网盘目录 id 改为同一枚举，Catalog 的 provider 同样返回该类型，不再单独定义 `RemoteCatalogProvider`。OneDrive 普通/恢复上传绑定已更新，新增 `hasBuiltInAdapter` 和宿主筛选示例，旧数据影响见 [来源枚举升级](API.md#来源枚举升级)。本轮核验未追加生产源码修改，来源枚举改动保留在本地，尚未推送。

| 检查 | 实际结果 |
| --- | --- |
| 旧引用清理 | 扫描 Sources/Tests/Examples 中 290 个已跟踪 Swift 文件，生产代码没有 cloudAPI、RemoteCatalogProvider 或另设的 RemoteProviderKind；只保留一个验证拒绝旧 cloudAPI 编码的负向 fixture。旧字符串 id 和 init(id:displayName:icon:kind:) 已从网盘目录模型移除 |
| 公开 API 编译 | 独立消费端模块上，新枚举/强类型 id/provider 构造和筛选编译成功；旧 .cloudAPI、RemoteCatalogProvider、旧 init(id:...) 和将新 id 赋给 String 的四个探针均按预期编译失败，并核对了具体诊断，证明不是单纯内部不再调用 |
| 全包回归 | `swift test --no-parallel` 退出 0，**740 个去重测试函数通过，0 失败、0 跳过**；运行器执行 812 次（39 XCTest + 773 Swift Testing），TestSupport 8 个函数在十个 bundle 执行，额外重复 72 次。相对上一阶段新增 Core 2 项、Kit 2 项；listing 与实际运行标识匹配 |
| 构建 | 随后 `swift build -c release`、`swift test list` 退出 0；三条命令本轮各执行一次。Release 保留既有 TestSupport 模块自导入 warning；iCloud 沙盒 Code=2 诊断对应测试通过 |
| 四个平台 | macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator：每个平台重编并链接全部 15 个生产模块，两个统一浏览示例及七个业务指南片段类型检查通过，四平台无 warning/error |
| 独立 Kit 消费端 | 构建运行通过：枚举白名单、六个 PNG 映射、OneDrive 来源类型、五种 Catalog 配置 Codable、同名厂商绑定互异、旧模糊绑定拒绝，确认 16 个来源枚举值及 9 个已有内置适配器 |
| 文档与格式 | 本地文件链接/标题锚点、代码块和 `git diff --check` 通过；旧名称在迁移说明与历史记录中作为说明保留，不是仍可调用的兼容入口 |

首轮定向验证曾在 60 秒工具时限内停于构建，随后主任务及独立任务的 `pwd` 均触发宿主 RPC 超时；这些中断不计为测试结果。当前命令通道已恢复，上表为恢复后实际执行的完整验证，无遗留执行阻塞。未进行真实网盘/书库、最低系统真机或外部账号联调；此次身份类型统一不改变这些历史验收边界。

评估结论：具体来源身份由一个枚举表达，避免泛化 cloudAPI 和重复 provider 类型造成歧义；配置关联值、图标资源及目录视图各自承担不同职责，继续保留。`hasBuiltInAdapter` 不替代权限/能力检查，闭集枚举新增来源需更新 SDK。旧绑定/上传恢复记录不自动迁移，宿主需按升级指南先核对旧任务，不能盲目改写编码或重放上传。

原始证据在会话工作台：`source-kind-reference-audit.json`、`source-kind-api-check/results.json`、`source-kind-final-full.log`、`source-kind-final-release.log`、`source-kind-final-list.log`、`source-kind-final-counts.json`、`source-kind-platform-results.json`、`source-kind-consumer.log`、`source-kind-docs-check.json`。临时探针和日志不随 SDK 分发。

## 统一 Browser 使用说明补全（未发布）

本轮只补充文档和宿主示例，未修改 `Sources`、测试目标或 Package 配置。新增 [九种来源连接示例](../Examples/UnifiedBrowser/BrowserConnectionExamples.swift)，扩充 [通用操作示例](../Examples/UnifiedBrowser/UnifiedBrowserExample.swift)和 [完整使用指南](Browser.md)，覆盖本地源码安装、凭据/binding、分页搜索、详情封面、下载进度/取消、lease、原生阅读/播放、快照重连及错误处理；纠正了 Catalog 内部扫描会话不能直接借给 Browser 的说明。

- 两份示例文件和指南的 6 个业务 Swift 代码块，在 macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator 的 Swift 6 类型检查均通过，零 warning/error；复用上一轮未改动的 SDK 编译产物。另一个安装清单代码块经 `swift package dump-package` 解析通过，并用于下面的独立消费端构建。
- 独立 SwiftPM 宿主只依赖 Kit，直接引用两份示例及提取的指南代码，构建运行通过：本地连接、三页浏览、页预算报错、详情/封面空值/下载选项、快照编解码、Transfer 文件内容、关闭后来源仍可用，以及完整 choose → consume → close/disconnect 流程。全部数据在临时本地目录，没有访问真实账号或网络服务。
- 一次读者核验确认安装、SDK/示例区分、九种连接、页面操作、下载生命周期、原生桥接、快照重连及错误层次均有明确说明；Markdown 本地链接/锚点、代码块和差异格式检查通过。

证据在会话工作台 `browser-usage-verification/results.json`、`browser-usage-verification/*-examples.log`、`browser-usage-smoke.log` 和 `browser-usage-doc-links.json`。本轮未重跑 SDK 全包测试，上一阶段 736 项结果保留如下。示例首轮的协议实例身份比较编译失败已改为先转换具体 actor 后比较，再完成上述验证。没有新增真实 iCloud/OAuth/网盘/书库或播放器验收，当前无文档交付阻塞。

## 统一 Browser 与 OPDS 封面（未发布）

新增 `BoneRemoteSyncBrowser`，由 Kit 重导出，在已连接的文件/OPDS/Komga/Kavita/Audiobookshelf 来源之上提供统一浏览、分页、搜索、详情、封面、下载选项和原生引用。展示快照可编码，live item/cursor/download 不可跨 Browser 或会话复用；不隐式扫描文件树、写阅读进度或创建播放会话。OPDS 新增 `cover(_:)`，复用现有有界传输和跨域凭据隔离。指南见 [Browser](Browser.md)、[示例](../Examples/UnifiedBrowser/README.md)和 [OPDS](OPDS.md)。本轮未提交、推送或发布。

| 检查 | 最终结果 |
| --- | --- |
| 全包回归 | `swift test --no-parallel` 退出 0，**736 个去重测试函数通过，0 失败、0 跳过**；实际执行 808 次（39 XCTest + 769 Swift Testing）。TestSupport 的 8 个函数在十个 bundle 执行，额外 72 次不重复计数；参数化 case 不另加 |
| 增量覆盖 | 相对上一阶段 700 项新增 36 项：Browser 22、OPDS 封面 13、Kit 导入 1；当前 OPDS 自有 56、Kit 9。最终 listing 与运行日志逐函数匹配 |
| Browser 测试 | 五种文件来源标识共用形状、真实 Local → Browser → Transfer、原生/缓冲分页衔接、coverage 保留、路径缺失时 ID 寻址、跨 Browser 句柄拒绝、宿主 binding 变化、缓冲/页数/并发上限、关闭取消排空、错误分类/脱敏、展示快照编码；三种原生服务层级/搜索/详情/图片/下载资源/祖先变化和旧会话均通过 |
| OPDS 封面 | 无图返回 nil、thumbnail 优先、PNG/SVG、Basic 与跨域隔离、跨域返回原域仍匿名、非法 MIME/URL、短读、响应预算、重定向上限、断开/取消/重连和共享并发预算均有通过的 fixture 测试 |
| 构建 | 最终全包完成 Debug 编译；随后 `swift build -c release` 和 `swift test list` 退出 0，各执行一次 |
| 四个平台 | macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator：全部 15 个生产模块编译链接通过（60 项），统一浏览宿主与指南完整示例类型检查通过（8 项）；四平台日志无 warning/error |
| 独立消费端 | 外部 SwiftPM 包仅依赖/导入 Kit，构建运行通过；真实临时本地文件的三页浏览、详情、下载选项、Transfer 字节读取和快照 JSON 往返均通过 |
| 一次限定复核 | 只读检查新层分页/父项/会话、数据与下载选择、封面授权/重定向/预算，未发现可具体触发的中高严重缺陷；不是运行或真实部署验收 |
| 文档与辅助 | Markdown 本地文件/标题链接、代码块、两套 Browser Python fixture 语法、清理脚本语法与 dry-run、差异格式检查通过；新增 `BoneBrowserTests-*` 清理/CI 识别 |

生产模块仍无第三方运行依赖，Swift tools/language 6；本机实际为 Swift 6.4 / Xcode 27.1。Release 与 listing 保留既有 TestSupport 同模块 import warning，iCloud 移动测试记录一次沙盒 Code=2 系统诊断但测试通过。最初整合测试遇到原生测试中嵌套 `#require` 的宏编译错误，以及 OPDS fixture 缺少 acquisition 关系被识别为导航项；修正测试写法和 fixture 后通过，没有为此放宽解析或生产校验。

原始日志留在会话工作台：`browser-final-full.log`、`browser-final-release.log`、`browser-final-test-list.log`、`browser-final-counts.json`、`browser-platform-*.log`、`browser-consumer.log`、`browser-targeted-final.log`、`opds-artwork-test.log`。不随 SDK 分发。

**剩余边界：** 文件协议没有通用连接 generation，宿主必须管理其连接并在变化前关闭旧 Browser，或通过 validateBinding 拦截宿主会话变化；快照只是展示数据，不恢复执行句柄。没有新增真实服务器、TLS/代理、最低系统真机或媒体/播放器验收；原生阅读/播放语义继续由各来源提供。当前无阻碍代码交付的已知问题。

## Komga、Kavita 与 Audiobookshelf 原生接入（未发布）

新增共享 `BoneRemoteSyncContent` 和三个原生适配器，由 Kit 统一导出；支持认证/身份验证、原生内容层级、分页搜索、详情图片、完整文件 Transfer，以及显式阅读/收听进度。Audiobookshelf 额外提供直放会话与宿主认证音轨请求。未增加 Catalog 文件树、通用文件写入、Range/续传或后台播放器。入口见 [内容服务总览](ContentServices.md)、[Komga](Komga.md)、[Kavita](Kavita.md)、[Audiobookshelf](Audiobookshelf.md)。最新发布仍为 `v0.8.2`，本轮未提交、推送或发布。

| 验证 | 最终结果与范围 |
| --- | --- |
| 全包回归 | 修复后 `swift test --no-parallel` 退出 0：**700 个去重测试函数通过，0 失败、0 跳过**。运行器实际执行 764 次（39 XCTest + 725 Swift Testing）；TestSupport 8 个函数在九个 bundle 执行，额外 64 次不重复计数；参数化 case 不另加 |
| 新模块及 Kit | Content 14、Komga 12、Kavita 20、Audiobookshelf 17、Kit 8，共 71 个定向函数通过；已包含于全包计数。相对前一阶段 636 个函数共增加 64 个 |
| 构建 | 最终 Debug 测试编译与 `swift build -c release` 退出 0；`swift test list` 与运行器逐函数匹配。首次全包 696 项通过后，一次限定复核补充 4 项回归，最终全包按相同顺序重新执行一次 |
| 四平台 | macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator，arm64 / Swift 6：全部 14 个生产模块编译链接通过，三份服务示例与总览完整示例各平台类型检查通过（56 项模块检查 + 16 项示例检查）。最后修复后重新编译 Content/三个适配器/Kit，并重验所有示例；四平台无 warning/error |
| 外部消费端 | 独立 SwiftPM 包仅依赖并导入 Kit，构建运行通过；验证三个来源、配置 Codable、能力和连接清理，最终修复后再次通过；没有真实网络账号访问 |
| 共享传输 | 配置/URL/反代子路径、认证头与 cookie 隔离、拒绝重定向、响应长度/流式预算、MIME、HTTP framing、大小验证、保护旧目标与符号/硬链接、取消排空、并发/间隔和包含等待的 timeout 均有测试 |
| 服务合同 | loopback fixture 验证 Basic/API key/账号登录/Bearer、身份与代际隔离、原生分页关系、图片、Transfer、两类 EPUB 进度、Kavita ZIP、Audiobookshelf 文件/节目/直放及会话同步关闭；无自动写入重放 |
| 包与辅助检查 | 14 个生产 target、零第三方依赖，三个适配器仅依赖 Content/Core；39 个新增文件格式、Markdown 本地链接/标题/代码块、四套 Python fixture 语法、清理脚本语法及 dry-run、`git diff --check` 通过。CI/清理规则纳入四个 fixture 前缀 |

一次只读复核定位并修复两个 Audiobookshelf 缺陷：合法排除音频使用 `index=-1`，文件元数据现接受该哨兵而播放轨道仍检查非负；close 或替换 create 在本地并发拒绝/等待取消时尚未提交，现保留旧会话句柄，仅在请求可能已送出时作废，避免结果未知时重放。新增四个回归中，三个先复现失败再通过，另一个确认已提交 close 失败仍禁止重放；修复后未再启动广泛复核。

实际工具链为 Apple Swift 6.4 / Xcode 27.1（27A9275）。Release 保留既有 `PythonFixtureTests.swift` 自导入 warning；iCloud 移动测试保留一个沙盒申请的 `NSPOSIXErrorDomain Code=2` 系统诊断，该测试通过。平台编译不代表 Swift 6.0 编译器、最低系统运行或移动真机验收。

最终证据在会话工作台：`content-postreview-full.log`、`content-postreview-release.log`、`content-postreview-test-list.log`、`content-postreview-counts.json`、`content-review-red.log`、`content-review-green.log`、`content-platform-*-postreview.log`、`content-consumer-postreview.log`。研究资料、探针与日志不随 SDK 分发。

**剩余验收：** 尚无用户授权的三种服务真实部署地址或账号。本地 fixture 不能替代真实权限配置、代理/TLS、媒体分析/格式、EPUB 内部位置、播放器 codec/后台音频或大文件性能验收。Kavita 显式 JWT 刷新已实现；Audiobookshelf 令牌轮换由宿主完成后重新连接，无 SDK 自动刷新。当前没有阻碍本次代码交付的已知问题。

## Catalog 扫描请求间隔（未发布）

新增 `RemoteCatalogRefreshOptions.requestInterval`（秒，默认 `0`，有限值 `0...86400`），同一轮扫描的并发目录、分页和前后元数据核对共用 `list/stat` 放行间隔。使用单调时钟，延迟唤醒后重新核对间隔，不积攒突发名额；等待响应取消并受原有扫描 timeout 约束。非法参数在选根预检及来源访问前拒绝。示例见 [Catalog 刷新](Catalog.md#选择目录刷新与离线查询)和 [宿主代码](../Examples/CatalogIndex/CatalogExample.swift)。

- 定向验证：Catalog 72 项和 Kit 7 项通过。新增 8 项测试覆盖默认零延迟、合法/非法取值、提前/迟到唤醒、并发目录与分页/stat 共用间隔、等待期间取消保留旧缓存，以及公共刷新 timeout 中断等待后再次刷新成功。
- 全包 `swift test --no-parallel` 退出 0：**636 个去重测试函数通过，0 失败、0 跳过**。实际 668 次执行（39 XCTest + 629 Swift Testing），扣除 TestSupport 8 项在五个 bundle 中产生的额外 32 次重复；参数化 case 不另加。
- `swift build -c release` 退出 0，保留既有 TestSupport 自导入 warning，无 error。全包测试无 warning/error；本轮全包与 Release 各执行一次。
- macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator：受影响的 Catalog/Kit 重新编译链接，以及 Catalog 宿主和指南示例类型检查均通过；四个平台日志无 warning/error。未变依赖复用此前同工具链验证产物；不是最低系统运行或真机验收。
- Markdown 本地文件/标题链接、代码块和差异格式检查通过。原始日志为会话工作台 `catalog-interval-targeted.log`、`catalog-interval-full.log`、`catalog-interval-release.log`、`catalog-interval-platform-*.log`，不随仓库分发。

参数只作用于本轮扫描的来源调用，不是跨刷新/全 App 的 HTTP 限流，不限制连接、认证、选根预检及适配器内部重试。仍需用 `concurrency: 1` 限制同时执行的目录任务；本次未增加持久扫描队列、后台执行或真实网盘配额验收。当前无本地实现阻塞，功能尚未发布。

## 百度网盘首期接入（未发布）

新增独立 `BoneRemoteSyncBaidu`、Core `.baidu`、Kit 导出和图标映射，以及 Catalog 配置/凭据轮换/账号绑定；Transfer 复用完整下载、物化与 lease。基于官方开放 API，仅访问已授权 `/apps/...` 根。最新发布标签仍为 `v0.8.2`，百度接入尚未发布。接口与宿主职责见 [百度指南](BaiduDrive.md) 和 [示例](../Examples/BaiduDrive/README.md)。

| 验证 | 结果 |
| --- | --- |
| 全包回归 | `swift test --no-parallel` 退出 0；**628 个去重测试函数通过，0 失败、0 跳过**。运行器共执行 660 次：39 XCTest + 621 Swift Testing；TestSupport 的 8 个函数在五个 bundle 中执行，额外 32 次不重复计数 |
| 各目标自有函数 | Baidu 46、Catalog 64、Core/Local 127、iCloud 52、Kit 7、OPDS 43、OneDrive 92、TestSupport 8、Transfer 45、WebDAV 144，共 628；参数化 case 不另加 |
| 百度专项 | 46 个函数覆盖 OAuth/state/单次回调、精确 ID、根边界、分页/部分列表、账号与会话隔离、刷新、下载/目标保护/取消、上传快照与跨 4 MiB 分片往返、文件管理、Catalog 与 Transfer。浏览套件 7 项另行定向通过 |
| 构建 | 全包测试完成 Debug 编译；随后 `swift build -c release` 退出 0。测试与 Release 各执行一次，无重跑或超时 |
| 四个平台 | macOS 12、iOS 15 Simulator、tvOS 15 Simulator、visionOS 1 Simulator，arm64 / Swift 6：全部十个生产模块重新编译链接通过，共 40 项；两份百度示例各平台类型检查通过，共 8 项。平台日志无 warning/error |
| 独立消费端 | 外部 SwiftPM 包只依赖并 `import BoneRemoteSyncKit`，构建与运行通过；核对百度配置/协议、OAuth 回调、Catalog Codable 和 PNG 图标资源，没有网络或真实账号访问 |
| 包与辅助检查 | Package 导出独立百度产品，Baidu 仅依赖 Core，Kit/Catalog 正确依赖 Baidu，无第三方包。Python fixture 语法、清理脚本语法、清理 dry-run、本地 Markdown 链接/标题锚点、代码块及差异格式检查通过 |
| 清理 | `BoneBaiduTests-*` 在实际系统临时目录、`/private/tmp`、工作区与会话 scratch 根均无残留；脚本与 CI 已纳入百度 fixture 名称 |

本轮有限审查发现未消费的分页游标可耗尽容量，使后续新列表全部失败。现改为容量到达 1024 时淘汰最旧游标，已淘汰/已消费游标返回 `invalidCursor`；新增容量为 2 的内部测试验证新列表、未失效游标及旧游标拒绝，不通过大量网络调用逼近上限。

实际工具链为 Apple Swift 6.4 / Xcode 27.1（27A9275）。最低部署目标编译不等于 Swift 6.0 编译器、旧系统运行、移动真机或真实 TLS/ATS 验收。Release 存在既有 `PythonFixtureTests.swift` 自导入诊断；iCloud 移动测试记录了为尚不存在的目标申请 sandbox extension 的系统诊断，随后该测试的移动/下载/内容断言通过。本轮没有为消除这些诊断修改无关代码。独立消费端首轮因临时探针的能力字段名和 throwing 断言写法错误而编译失败，修正探针后构建运行通过，SDK 未因此变更。

原始证据留在会话工作台：`baidu-final-full.log`、`baidu-final-release.log`、`baidu-final-test-list.log`、`baidu-final-counts.json`、`baidu-platform-*.log`、`baidu-consumer-final.log` 和 `baidu-clean-dry-run.log`；不随仓库分发。

**剩余验收：** 尚无真实百度应用或授权 token，未执行线上 OAuth、应用目录权限、文件操作、配额/地区差异、4 GiB 上限性能或真实 Keychain 验收。本地 fixture 使用虚构凭据，仅监听 `127.0.0.1`。真实联调需宿主 AppKey、已登记回调、已授权根和测试用户 token；SecretKey 继续由宿主后端保管。当前没有阻碍本次代码交付的已知问题。

## v0.8.2 发布修正

v0.8.1 发布前的完整远端检查通过（39 XCTest+542 Swift Testing，共581项，API无变化），但标签运行再次暴露WebDAV进度为0。仅在任务完成时转发URLSession计数仍不足以保证最终进度，因为小文件计数本身可能未更新。

修正为PUT成功且响应流完整结束后，从本次不可变上传快照报告最终大小；不修改OPDS，不将HTTP错误、取消或未完成响应当作成功。实际18字节上传/目录操作用例重复10次，搭配新增委托回调和既有写入安全测试验证。保留旧标签和CI记录，使用新v0.8.2标签分发。

## v0.8.1 发布修复

v0.8.0 分支CI的Debug、Release和全包测试曾通过；标签运行暴露了两个问题：API导出在原生SwiftPM布局下找不到模块，以及原有WebDAV上传测试偶发缺少最终进度。保留已发布v0.8.0标签，以v0.8.1修复，OPDS功能和公共API不变。

API脚本使用SwiftPM实际bin路径并同时搜索Modules子目录；本机导出仍为1361个唯一符号，与修复前逐字节一致。WebDAV成功完成时补发URLSession实际发送字节数，再唤醒响应消费者；没有中间回调也能得到最终观察值，失败不补报。新增回归已先复现旧实现缺失回调，最终测试使用不发请求的系统任务，并由本地HTTP集成用例验证实际18字节上传。

补丁验证范围与v0.8.0阶段记录分开；远端的分支/发布标签GitHub Actions负责最终全包与API比对。旧标签CI的失败记录保留，不通过改写标签隐藏。生产功能限制继续参见下方与OPDS兼容文档。

## v0.8.0 发布验证

`v0.8.0` 以 Git 附注标签分发，首次发布 OPDS 模块及兼容模式；v0.7.0 已发布的权限模型不重复计为新功能。发布整理更新文档版本和CI配置，不改变下方最终579项测试对应的生产实现；历史验证快照保留其当时范围。

发布前检查发现此前远端CI使用macos-14默认Swift5.10/Xcode15.4，无法读取Swift tools6.0清单。工作流改为macos-15并固定镜像已提供的Xcode26.3，缓存按架构/工具链分隔；同时修复临时文件零匹配导致清理检查退出失败。远端执行结果以对应GitHub Actions记录为准，不将本地Swift6.4结果冒充远端通过。

## 2026-11-05：OPDS 公开格式兼容扩展（最终验证）

新增默认 `.compatible` / 可选 `.strict`，时间元数据改为 `Date?` + `updatedRaw`，支持直接 Atom 搜索模板和标准 Atom 筛选字段，并对常见错误目录 MIME 做有界 XML 验证。未修改 Core 的日期解析、Catalog schema 或 Transfer 调度；书籍下载安全合同和跨域授权不变。详见 [兼容模式](OPDS.md)与[公开源复测](OPDSPublicCatalogValidation.md)。

| 验证 | 结果 |
| --- | --- |
| 最终 OPDS 专项 | 自有43项通过（含12项兼容测试），统一入口OPDS测试另通过且已包含于全包计数 |
| 最终全包串行 | `swift test --no-parallel` 退出0：579个去重后的测试函数通过，39 XCTest + 540 Swift Testing，0失败、0跳过。运行器603次执行包含共享TestSupport8项在四个bundle中的重复24次 |
| 自有目标计数 | WebDAV142、Transfer45、OneDrive92、OPDS43、Kit6、iCloud52、Core/Local127、Catalog64、TestSupport8，共579；参数化case不再叠加 |
| 构建 | 本轮Debug构建通过；最后一次Atom参数映射后的全包测试完成Debug编译，`swift build -c release` 退出0；最终独立Kit消费端构建通过 |
| 平台 | 最后改动后，macOS12、iOS15/tvOS15/visionOS1 Simulator的OPDS与Kit编译链接、宿主示例与指南示例类型检查均通过。未变模块沿用此前同工具链的构建产物，本轮未重编全部九模块 |
| 真实公开源 | 五站复测：Unglue、Ebooks Gratuits、Wolne各新增一次EPUB下载；arXiv根和一级分类成功；ManyBooks模板已识别但列表/搜索响应仍失败。最后补齐Atom参数后，Wolne关键词`ballady`实测返回17本书 |
| 下载文件 | 新增344306、574339、1163929字节样本，ZIP CRC、mimetype、container引用OPF存在性/XML和lease清理通过；未与远端可信摘要比较，未做排版验收 |

本轮43项OPDS测试覆盖默认兼容/严格模式、未知时间原文与nil、直接模板中的固定编码/保留字符/相对地址/命名空间、未知必填字段、跨origin与旧会话、MIME回退及HTML/非Atom/DTD/超预算拒绝。新增测试为补充覆盖，不宣称全部经过行为红绿。

最终证据：scratch中的`opds-compat-final-tests.log`、`opds-compat-final-full.log`、`opds-compat-final-release.log`、`opds-compat-final-consumer.log`、`opds-platform-<平台>-4.log`，以及`opds-compat-public/`、`opds-compat-downloads/`。兼容扩展中间版578项结果已被最终579项覆盖，不相加。Release仍有既有PythonFixtureTests同模块import警告；iCloud临时文件系统诊断对应测试通过，未顺带改动无关代码。

**剩余边界：** ManyBooks受Cloudflare/异常响应影响，arXiv代理深层响应有未声明XML前缀与空标题，不能视为已全面兼容。401/403、付费认证、错误详情链接不绕过；OPDS2、DRM、后台/续传、Catalog持久化与最低系统真机验收仍不在本次范围。该实现阶段本地检查无阻塞；当时尚未提交、推送或发布，后续版本状态见本页顶部。

## 首轮公开服务实测（兼容扩展前）

使用仅导入 Kit 的独立消费端测试文章列出的15个公开地址：7个原始根地址连接成功；Textos 改用规范地址后也成功。Gutenberg、Textos.info、The Anarchist Library 各完成一次真实 EPUB 下载，分别为609138、61767、43590字节；ZIP CRC、mimetype、container/package 存在性及 lease 清理均通过。Gutenberg 搜索需显式配置其移动站 origin；ManyBooks、Unglue.it 等仍有目录格式、访问或搜索形式限制。

本轮只新增真实服务证据和文档，不修改生产代码、不重复此前全包回归。根目录成功不能推导整站兼容；全部15个地址、失败原因、配置和样本 SHA-256 见 [公开书库实测记录](OPDSPublicCatalogValidation.md)。

## OPDS 首期实现验证（兼容扩展前，后纳入 v0.8.0）

新增独立 `BoneRemoteSyncOPDS`、Core 来源类型、Kit 导出、专用书目 API、会话内下载引用及 Transfer 接入。未改 Catalog schema 或 Transfer 调度逻辑；本次没有提交、推送或发布。

| 验证 | 实际结果与范围 |
| --- | --- |
| Debug / Release | `swift build`、`swift build -c release` 通过 |
| OPDS 定向 | OPDS 自有 **31 个测试函数**通过；覆盖解析、命名空间/xml:base、搜索、分页、详情、认证、引用隔离、下载、目标保护、取消和 Transfer。参数化 case 不另加到函数数量 |
| 全包串行 | `swift test --no-parallel` 退出 0：**567 个去重后测试函数通过**，39 XCTest + 528 Swift Testing，0 失败、0 跳过。运行器合计执行 591 次测试函数；共享 TestSupport 的 8 个函数在四个 bundle 中运行，额外的 24 次不计为独立测试 |
| 自有目标函数数 | WebDAV142、Transfer45、OneDrive92、OPDS31、Kit6、iCloud52（含5 XCTest）、Core/Local127（含34 XCTest）、Catalog64、TestSupport8，共567 |
| 统一入口 | `swift test --no-parallel --filter UnifiedImportTests`：6项通过，已含于全包计数 |
| 独立消费端 | 外部临时 SwiftPM 包仅依赖/导入 Kit；完成浏览、取详情、选择 EPUB、coordinator → materializer → lease，验证210000字节原文并确认 release 后文件清理 |
| 最低部署目标编译 | macOS12、iOS15/tvOS15/visionOS1 Simulator，九模块逐个编译链接；四目标的宿主示例和指南代码均类型检查通过。最终分组日志无编译警告或错误 |
| 包与文档 | Package 导出 OPDS 产品且该模块仅依赖 Core；Markdown 本地文件链接、Python fixture 语法、清理脚本语法及 diff 格式检查通过 |
| 一次只读审查 | 识别并修复 XHTML 标题、带前缀的标准 OpenSearch 参数、通用 MIME 获取返回具体格式、注释/CDATA 含声明字样四个边界；新增回归先复现错误再通过。修复后未发起第二轮审查 |

工具链为 Swift 6.4 / Swift 6 语言模式、Xcode 27.1、Python 3.13.2。HTTP fixture 只监听 localhost、使用虚构凭据及合成内容；生产代码不依赖 Python。最低部署目标编译不等于 Swift 6.0 编译器或最低 OS/真机运行验收。

全包首次执行触及60秒工具时限，随后使用足够时限完整重跑通过。平台首次整组编译也触及时限，之后显式指定 SDK 环境并按模块组完整重跑；不把中断的输出当作通过证据。全包/Release 留有既有 `PythonFixtureTests` 同模块 import 警告；iCloud 用例输出一次临时 moved.txt 的系统诊断，该测试通过，未修改无关源码。

本轮日志位于会话工作台：`opds-final-build.log`、`opds-final-release.log`、`opds-final-kit.log`、`opds-final-full.log`、`opds-tests.log`、`opds-review-red.log`、`opds-platform-<平台>-<组>.log`、`opds-consumer-build.log`、`opds-consumer-run.log`。过程脚本和独立消费端均在 scratch，不作为包资源分发。

**未验收/不在首期范围：** 真实 Calibre/Komga/Kavita 部署、真实 TLS/ATS/设备、最低系统运行、大文件内存/吞吐与磁盘故障；OPDS 2.0、购买借阅、DRM、Cookie/OAuth、后台/续传/强版本和 Catalog 持久化。当前没有阻碍本次实现交付的已知问题。接口合同见 [OPDS](OPDS.md)，完整接入见 [宿主示例](../Examples/OPDSReadOnly/README.md)。

## 历史验证记录

以下为截至 **`v0.4.0`（2026-10-28，GMT+8）**的历史验证记录，当时以 Git 附注标签发布，不另外创建 GitHub Release。既有标签不变；各阶段数量不能相加，也不是后续任意源码版本的保证。当前版本的验证范围见本页顶部。

## CI 与测试可移植性（本次改动）

本节记录自动验证基础设施的建立：此前该仓库**没有任何 CI 配置**，506 项测试全靠发布前手工执行，回归无法持续拦截。改动只涉及测试基础设施、CI 与脚本，**不修改任何生产源码**。

| 检查 | 结果与范围 |
| --- | --- |
| 串行全包 | `swift test --no-parallel`：**526 项通过**，0 失败（Swift Testing 487 + XCTest 39）。数量高于既有 506 项，原因是新增 8 项解释器解析测试及其参数化展开。 |
| Debug / Release | `swift build` 与 `swift build -c release` 均通过（Release 冷构建 36.9s）。 |
| 解释器可移植性 | 4 处 `/usr/bin/python3` 硬编码改为 `PythonFixture` 解析链（`BONE_PYTHON` → 系统路径 → `PATH`），实测 `/usr/bin/python3` 为 3.9.6、`/usr/local/bin/python3` 为 3.13.2，覆盖生效。 |
| 无解释器行为 | 通过注入式 `isExecutable` 判据覆盖“完全没有解释器”分支（8 项单元测试）；41 个依赖 fixture 的 suite 声明 `.enabled(if:)`，缺解释器时显式跳过而非崩溃。宿主无法真正隐藏受 SIP 保护的 `/usr/bin/python3`，此点已记录。 |
| 公共 API 基线 | 基于 symbol graph 导出 7 个模块共 **1118 个公共符号**；两次导出结果字节一致。移除检测验证：基线多一个符号时退出码 2 并精确列出。v0.3.0 交叉导出得 **791 个符号 / 6 个模块**（无 Transfer），符合版本事实。 |
| 缓存回收 | `.build` 实测 **679 MB**；`script/clean.sh` 回收后可用空间 8.2G → 8.8G。`--dry-run` 不做删除，未知参数退出码 1。 |

**仍未验证：** CI 未在 GitHub 真实 runner（`macos-14`）上运行过；上述结论全部来自本机 Swift 6.4 的等价命令序列。`api-compat` job 对上一标签的比对依赖 `git worktree` 与完整 tag 历史，仅在发布标签触发，尚未实跑。真实 NAS / Microsoft 账号 / iCloud entitlement 验收状态不变。

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
| 百度网盘（未发布） | localhost：OAuth 回调、账号绑定/刷新、分页、文件传输/管理、Catalog/Transfer、目标保护与取消 | 真实百度应用审核、用户授权、应用目录权限、线上文件操作、配额与大文件性能 |

真实服务验收清单见 [WebDAV 示例](../Examples/WebDAVReadWrite/README.md)、[OneDrive 示例](../Examples/OneDriveReadOnly/README.md)和 [百度示例](../Examples/BaiduDrive/README.md)。只在明确授权的专用测试目录中写入；失败后先核实远端状态，不依据错误返回推断“没有创建”。

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

1. 完成 WebDAV、OneDrive 与百度的真实服务读写及异常验收；百度 SecretKey 留在宿主后端。
2. 完成 OneDrive Upload Session 的真实 Microsoft 账号、Keychain entitlement、大文件、断电/权限和最低系统验收；实现已在受控 localhost fixture 中覆盖。
3. iCloud Drive 已有文件来源、Catalog 配置与离线索引；继续真实宿主/系统账号切换/多设备验收，以及 NSFileVersion、元数据观察和持久账号身份约束设计。SMB 或其他来源按产品需求选择。
4. 独立同步层：快照、差异、可预览计划、执行与状态存储，再考虑双向冲突策略。

当前没有自动同步、后台传输、变更流、统一跨来源上传续传或统一跨来源事务。OneDrive 专用 Upload Session 不由 Transfer 自动调度，且只有专用构造器声明可恢复上传；尚未实现的来源不得通过空实现或能力声明伪装为可用。
