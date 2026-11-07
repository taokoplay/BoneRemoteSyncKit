# 统一浏览接入示例

[完整使用指南](../../Docs/Browser.md) · [连接示例](BrowserConnectionExamples.swift) · [通用操作示例](UnifiedBrowserExample.swift) · [内容服务](../../Docs/ContentServices.md)

适用于统一展示五种文件来源及 OPDS/Komga/Kavita/Audiobookshelf 的 Apple App。Browser 已在推送的开发提交 `fe8cfc2` 中，尚未发布版本标签，`v0.8.2` 不包含它；本目录的枚举筛选示例使用尚未推送的统一来源 API，需要当前工作区。安装前见[版本对照](../../README.md#开发源码与版本范围)和[本地源码安装](../../Docs/Browser.md#安装与导入)。

## 如何使用示例

1. 宿主 target 添加 `BoneRemoteSyncKit` 产品，源码 `import Foundation`、`import BoneRemoteSyncKit`。
2. **将本目录两个 Swift 文件一起加入宿主 target**，或复制需要的函数。`BrowserConnectionExamples` 和下面的辅助函数都是示例代码，不是 SDK 自带 API。
3. 从安全存储、用户选定目录或账号授权流程取得输入；示例不包含真实服务地址、账号或 token，不负责登录 UI。
4. 选择对应连接函数，保留返回的 typed `source` 和 `browser`。已有连接时直接用 SDK 的 `RemoteBrowser` 工厂。
5. 用统一接口展示页面、取得详情和下载选项。选择由宿主 UI 完成；不自动选择第一个文件或格式。
6. 消费结束后先清理播放器/Transfer，再 `await browser.close()`，最后 `await source.disconnect()`；失败路径同样清理。

显示范围用同一个来源枚举管理，例如 `browserSourceChoices(enabled: [.webdav, .oneDrive, .baidu, .komga])`。该函数过滤 SDK 已有内置适配器的来源，不连接服务；`driveTypes()` 和 `sourceTypes()` 的 id/kind 都为 `RemoteSourceKind`。详细用法与顺序控制见 [入口筛选](../../Docs/Browser.md#选择显示哪些网盘和书库)。

## 连接示例索引

[BrowserConnectionExamples.swift](BrowserConnectionExamples.swift) 的方法均返回 `(source, browser)`，供宿主继续使用：

| 方法 | 宿主提供的输入 |
| --- | --- |
| `local(root:)` | 已存在、已授权的本地目录 |
| `iCloud(configuration:)` | 容器与根配置；宿主须有 iCloud entitlement |
| `webDAV(baseURL:credential:)` | collection URL 与匿名/Basic 凭据 |
| `oneDrive(configuration:credential:persistRefreshedToken:)` | OAuth 配置、已授权凭据、对应账号的安全令牌保存回调 |
| `baidu(configuration:credential:expectedUserID:refresh:)` | 授权应用目录配置、凭据、可选账号约束与后端刷新回调 |
| `opds(configuration:credential:)` | Feed 地址配置与匿名/Basic 凭据 |
| `komga(configuration:credential:expectedUserID:)` | 服务根配置、Basic/API key、可选 String 用户 ID |
| `kavita(configuration:credential:expectedUserID:)` | 服务根配置、账号/API key/JWT、可选 Int 用户 ID |
| `audiobookshelf(configuration:credential:expectedUserID:)` | 服务根配置、账号/Bearer、可选 String 用户 ID |

独立 Local/WebDAV/iCloud 会话生成随机 binding；OneDrive/百度读取 source 的 `connectedBinding()`。这些文件来源的同账号重连不能仅靠 binding 判别，重连前仍须关闭旧 Browser。详情见 [binding 规则](../../Docs/Browser.md#binding-怎么提供)。

## 通用操作示例索引

[UnifiedBrowserExample.swift](UnifiedBrowserExample.swift) 中的函数：

| 函数 | 用途与边界 |
| --- | --- |
| `browserSourceChoices` | 用 `Set<RemoteSourceKind>` 筛选网盘、协议及书库入口，并排除未实现的预留来源 |
| `connectKomgaBrowser` | 原有 Komga 连接入口，成功返回来源与 Browser；连接失败会断开 |
| `loadBrowserPage` | 加载根/子层或下一页；传 cursor 时忽略 parent，以 cursor 原有范围为准 |
| `visitBrowserPages` | 逐页回调当前层或搜索结果，不递归；最多 maxPages 页，未耗尽时显式抛错 |
| `loadBrowserSelection` | 依次获取详情、封面和下载选项；封面错误向上传递，UI 可拆分任务 |
| `consumeBrowserDownload` | 用户选择一个资源后，经 coordinator 获取 lease；支持 materialization options/进度回调，成功失败都 shutdown |
| `encodeBrowserSnapshots` / `decodeBrowserSnapshots` | 使用一致的 ISO-8601 日期策略保存/读取展示快照；不恢复执行句柄，不承诺亚秒精度 |
| `saveBrowserKomgaPage` / `saveBrowserKomgaEPUB` | 显式保存页码或 Readium 位置 |
| `saveBrowserKavitaPosition` | 显式保存章节位置及可选 Kavita XPath |
| `beginBrowserPlayback` | 显式创建 ABS 书籍/节目直放会话，之后由宿主播放、同步和关闭 |
| `closeKomgaBrowser` | 通用顺序的具体示例：先 close Browser，再 disconnect source |

原生进度函数检查 typed source 实例一致；这不替代宿主串行管理连接，也不允许在保存过程中换账号。书库层级、搜索范围和页码差异见 [使用指南](../../Docs/Browser.md#各来源的层级和搜索)。

## 生命周期与取消

`consume` 回调结束就会释放 lease。如果播放器/预览器仍异步读取 URL，应等待它结束，或在宿主中保留 lease 并显式释放；需要长期保存时复制到自己的目录。示例每次消费新建 coordinator，适合一次性操作；批量/长生命周期 UI 应复用同一 Browser 对应的 materializer/coordinator。

Browser 请求可通过调用 Task 的 cancel 取消；关闭 Browser 不断开 source，也不取消已经交给 Transfer 的下载。取消 `coordinator.wait` 的等待者不等于取消下载，真正取消任务调用 `coordinator.cancel(id)`；退出时 shutdown 协调器和 materializer。参见 [下载进度与取消](../../Docs/Browser.md#下载进度与取消)。

阅读/收听进度只在用户真实阅读或播放后显式提交。`nativeReference` 供原生 API 使用，snapshot 只供展示；两者都不能替代账号授权。封面/下载选项可以合法为空，未知大小或时间保持 nil。常见失败处理见 [问题排查](../../Docs/Browser.md#常见问题与错误处理)。

本目录不提供现成 UI、跨进程任务恢复或自动后台执行。示例编译与本地流程检查不代表真实服务器、iCloud、OAuth 或播放器验收；已执行范围见 [验证记录](../../Docs/Validation.md)。
