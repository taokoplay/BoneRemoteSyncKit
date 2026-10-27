# 错误日志规范

[首页](../README.md) · [通用 API](API.md) · [Catalog](Catalog.md) · [验证状态](Validation.md)

> 本页描述当前未发布源码，不包含在 `v0.2.0` 中。日志是可选诊断输出，不是错误处理、审计账本、数据库备份或刷新状态的替代品。

## 默认行为与职责

Core 提供 `RemoteLogger`、`RemoteLogEvent` 和固定枚举字段，由 Kit 统一导出。默认 `RemoteLogger.disabled`，**没有控制台输出、磁盘写入、数据库日志表、网络上报或全局可变 logger**。宿主显式注入 sink 后才交付事件。

- SDK 负责固定字段、错误归类、默认脱敏，以及已列明的操作边界记录。
- 宿主负责输出目标、访问权限、容量限制、轮转/保留期限、采样、删除和经授权的导出。开启系统日志也要纳入宿主隐私策略。
- 原错误仍按原路径抛出，刷新报告仍按原语义返回。日志不触发自动重试、重建数据库或重新授权。
- sink 的 Swift `throw` 会被吞掉，不递归记录、不重试交付，业务错误不会被日志错误替换。这不是审计级可靠投递。

## 事件结构 v1

所有 SDK 生成的事件使用白名单字段，不提供自由文本 message 或 metadata 字典。

| 字段 | 含义与规则 |
| --- | --- |
| `schemaVersion` | 事件格式版本，当前为 1；与 SQLite schema 无关 |
| `timestamp` | `Date` 事件创建时间；用于排查，不作为跨线程严格排序或单调耗时 |
| `level` | `info` / `warning` / `error`，由错误码确定 |
| `component` | `core`、`local`、`webDAV`、`oneDrive`、`catalog`、`sqlite`、`credentials` |
| `operation` | 固定操作枚举，如 `databaseOpen`、`refresh`、`listCached`、`download` |
| `code` | 固定机器可读分类，例如 `storage.unsupported_schema`；不能解析中文错误描述作为代码 |
| `correlationID` | 可选 UUID；Catalog 刷新开始后使用 `refreshID`，开始前及其他高层调用用本次随机 ID；不使用路径/账号/凭据引用 |
| `numericCode` | 可选数字；SDK 仅从 SQLite 错误或 Security OSStatus 提取，不读取任意 NSError domain/userInfo/code |
| `occurrenceCount` | 单事件代表的次数，至少 1；刷新报告按固定失败类别聚合 |

`RemoteLogEvent` 支持 Codable，宿主选择 JSON 时建议 ISO 8601 时间和一行一个事件。默认 `JSONEncoder` 的 Date 策略仍是 Foundation 默认值，SDK 不隐式替宿主选择。不要把可解码事件视为可信审计输入；由宿主自行构造/解码的事件仍需校验并遵守本规范。

### 级别

- **info**：协作式取消，不当作系统故障报警。
- **warning**：未连接、资源不存在、不支持操作、限流、冲突、过期 revision/page token、busy、预算耗尽，以及恢复时发现中断。
- **error**：认证/授权、权限、网络、完整性、无效配置/路径、schema/SQLite、存储关闭、列表不完整、身份变化、deadline、凭据存储失败和未知错误。

最低级别默认为 info；可配置 `minimumLevel: .warning` 或 `.error`。日志级别仅用于诊断筛选，不等于是否向用户弹窗，也不是能安全重放远端写入的依据。

### 错误码分组

| 分组 | 代码 |
| --- | --- |
| 来源 | `source.not_connected`、`source.authentication`、`source.rate_limited`、`source.network` |
| 资源 | `resource.not_found`、`resource.permission`、`resource.conflict`、`resource.integrity` |
| 操作 | `operation.unsupported`、`operation.cancelled`、`operation.busy`、`operation.deadline` |
| Catalog | `catalog.invalid_configuration`、`catalog.invalid_path`、`catalog.stale_revision`、`catalog.invalid_page_token`、`catalog.authorization_required`、`catalog.incomplete_listing`、`catalog.identity_changed`、`catalog.budget_exceeded`、`catalog.interrupted` |
| 存储 | `storage.unsupported_schema`、`storage.sqlite`、`storage.closed`、`storage.failure` |
| 凭据 | `credential.unavailable`、`credential.missing`、`credential.already_exists`、`credential.invalid_record`、`credential.revoked` |
| 未知 | `error.unknown` |

`RemoteSyncError` 和 `CancellationError` 在 Core 直接映射；Catalog 的错误及凭据错误通过 `RemoteLogClassifiableError` 提供安全分类。第三方错误可以实现该协议，但只应返回固定代码及有明确含义的非敏感数字；public initializer/协议不会校验数字来源，禁止用其夹带账号标识等信息。普通未知 Error 一律记 `error.unknown`，不展开底层对象。

## 记录位置与去重

| 调用边界 | 自动输出 |
| --- | --- |
| `SQLiteRemoteCatalogStore(databaseURL:logger:)` | 路径/文件准入、重复 owner、schema、SQLite 打开或初始化失败时一条 `databaseOpen`；仍抛原错误 |
| 数据库重开恢复 | 失败时一条 `databaseRecovery` 并抛原错误；成功且确有 running run 被改为 interrupted 时一条 warning，数量为被中断的 run 数，不是 staging 行数 |
| `store.close()` | 失败时一条；成功不输出 |
| `RemoteCatalog.saveSource` / `selectRoot` / `listCached` | 对外抛错时一条；成功不输出 |
| `RemoteCatalog.refresh` | 对外抛错时一条；已生成的扫描报告在状态写库前按 `failures` 类别聚合，每类一条，共用 refreshID。后续写库失败另记一条，扫描失败不因此丢失 |
| 其他低层 store 方法 | 不自动记录；直接调用时由宿主在最外层错误处理处记录 |
| 直接调用 Local / WebDAV / OneDrive / session factory / credential store | 不自动逐请求插桩；宿主使用同一 `logger.record` 接口记录最终错误 |

`RemoteCatalog` 使用 `store.logger`，不额外配置第二个输出器。内部网络重试、每页/每个文件、SQLite 每条 SQL 不重复记录同一个失败。刷新报告的事件数受固定失败类别数量约束，不随目录数量线性增加；事件不含目录路径。

扫描失败日志不证明 `finishRun` 已提交；数据库状态以查询结果为准。内部 best-effort 补偿失败（例如保存来源失败后的秘密清理）目前不单独自动输出，不能将缺少日志理解为不存在孤立凭据。

不要在已自动记录的 Catalog 调用外再无条件记录同一错误。尚未自动记录的底层 API 可由宿主统一包装；不要在每层 catch 都重复输出。日志缺失不证明没有失败：例如 sink 抛错、进程退出、最低级别过滤都可能使事件未保存。

## 隐私与安全红线

以下内容**不得**进入普通日志、统计标签或错误消息拼接：

- 密码、Authorization/Cookie、access/refresh token、OAuth code/verifier/state、完整授权回调。
- 完整 URL/query/nextLink、预授权下载 URL、请求/响应 body、原始 header。
- 数据库/本地/远端路径、文件名、用户名、账号/drive/provider ID、credential reference、bookmark 数据。
- 原始 SQL 参数、profile/entry/credential 对象、`Error.description`、`localizedDescription`、NSError userInfo 或完整调用参数。

已有业务错误描述可含路径或底层消息，**不能直接当安全日志**。使用 `logger.record(error, ...)` 会丢弃这些文本；如需用户可见错误，应通过另行设计的 UI 映射处理。默认不对路径做散列替代，因为可猜测名称仍可能被反查。

关联 UUID、时间和错误频率也可能用于跨事件关联；宿主仍应限制保留期限和访问。自定义 sink 不得再捕获并附加 token、profile 或原始 Error，否则 SDK 的脱敏不能保护宿主主动追加的数据。

## 线程与故障隔离

sink 为 `@Sendable (RemoteLogEvent) throws -> Void`，同步调用，可能来自不同任务/线程。宿主应线程安全、快速返回，不使用无界队列，不在回调中同步等待或回入 SDK。没有主线程保证。

SQLite 初始化/恢复/关闭的日志交付发生在 SQLite 队列和事务之外；Catalog 日志仍可能在 actor 隔离的调用中交付。SDK 不持有日志全局锁，不替宿主串行化 sink。

`throw` 被隔离不代表任意宿主代码都可被隔离：死锁、无限阻塞、进程崩溃、`fatalError` 或 sink 主动改变外部状态无法由 SDK 防止。不得把“日志不改变业务结果”理解为可安全执行任意阻塞副作用。

## 接入示例

以下示例显式启用 Apple Unified Logging，不会由 SDK 自动开启。只输出已归类枚举，关联 ID 保持 private；不输出错误原文。宿主可按需补安全数字码及聚合计数。

```swift
import Foundation
import OSLog
import BoneRemoteSyncKit

func makeAppRemoteLogger() -> RemoteLogger {
    let output = Logger(subsystem: "com.example.app", category: "RemoteSync")
    return RemoteLogger { event in
        let code = event.code.rawValue
        let component = event.component.rawValue
        let operation = event.operation.rawValue
        let correlation = event.correlationID?.uuidString ?? "none"
        switch event.level {
        case .info:
            output.info("\(component, privacy: .public) \(operation, privacy: .public) \(code, privacy: .public) id=\(correlation, privacy: .private)")
        case .warning:
            output.warning("\(component, privacy: .public) \(operation, privacy: .public) \(code, privacy: .public) id=\(correlation, privacy: .private)")
        case .error:
            output.error("\(component, privacy: .public) \(operation, privacy: .public) \(code, privacy: .public) id=\(correlation, privacy: .private)")
        }
    }
}

func openLoggedCatalog(databaseURL: URL) throws -> SQLiteRemoteCatalogStore {
    try SQLiteRemoteCatalogStore(databaseURL: databaseURL, logger: makeAppRemoteLogger())
}
```

直接调用来源时，宿主在最外层失败边界记录一次；示例不重试，仍抛出原错误。

```swift
import Foundation
import BoneRemoteSyncKit

func listWithDiagnostics(source: any RemoteSource, component: RemoteLogComponent,
                         path: String, logger: RemoteLogger) async throws -> RemoteListPage {
    let correlation = UUID()
    do {
        return try await source.list(path: path)
    } catch {
        logger.record(error, component: component, operation: .list, correlationID: correlation)
        throw error
    }
}
```

## 验证要求

新增错误类别或日志接入点应补测试：原错误/结果不变、默认无输出、sink 失败不替换业务错误、敏感标记不进入编码事件、并发 sink 合同、失败聚合与取消级别。不要只断言调用过一次 logger；同时核对缓存/数据库和返回报告的事实。
