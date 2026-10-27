# 本地目录来源

[返回项目首页](../README.md) · [通用 API](API.md)

`LocalFileSource(root:)` 将已有本地目录作为来源根，使用 `.anonymous` 连接。通过 `import BoneRemoteSyncKit` 可访问所有类型。根目录须已存在且获得宿主授权；该适配器不是 iCloud Drive 实现，不处理云端占位文件或 `NSFileCoordinator`。

## 操作语义

| 操作 | 语义与限制 |
| --- | --- |
| 列目录、stat、walk | 目录优先排序，可包含隐藏文件；原 stream 式 walk 是顺序遍历，新 visitor 式 walk 可配置有界并发；本地 list 一次返回全部，不实现分页，但仍校验 `limit` 为正数并拒绝任何非 nil `cursor`（包括空字符串） |
| 下载 | `.part` 写入、字节数校验、续传、可选 etag 复验、进度与取消 |
| 上传 | 仅普通文件，支持空文件；自动创建父目录；默认覆盖普通文件；不覆盖目录或 symlink；同目录随机 staging，完成后原子安装 |
| 上传取消/失败 | 清理本次 staging，保留原目标；已自动创建的空父目录可能保留；**不支持上传续传** |
| 新建目录 | 递归且幂等，文件同名时报冲突 |
| 删除 | 文件或非空目录，目录递归删除；禁止删除来源根及指向根的 symlink 别名 |
| 移动、复制 | 文件和目录均支持；不覆盖已有目标；目标父目录必须已存在；拒绝目录移入/复制到自身子目录 |
| 变更流、内容哈希、调度 | 未实现；size+mtime 仅是元数据指纹，不是内容校验哈希；并发数是建议值，不代表已有调度器 |

移动/复制在开始前检查取消，不承诺在 Foundation 的整目录操作中途抢占或回滚。复制目录保留其中的符号链接本身，不读取链接的外部目标；通过来源 API 直接访问外跳链接仍会被拒绝。

## 文件元数据

`createdAt` 读取文件系统的 `creationDate`，`modifiedAt` 读取修改时间；类型由系统提供的可选 MIME 与通用 `fileCategory` 规则提示。它们不解析 EXIF 或音视频内容。下载返回源条目的时间，不主动设置目标文件的创建时间；上传、复制的返回时间属于新目标，而不是承诺保留源时间。分类与时间的完整语义见[通用 API](API.md#文件时间与类型分类)。

## 下载安全与续传

- 在创建或截断 `.part` 前固定源文件身份，并检查源、目标和 part 的 inode。源与目标或 part 相同（含父目录别名、硬链接）时拒绝；目标和 part 的符号链接、多硬链接及非普通文件也拒绝。
- `resumeFrom` 须在 `0...源文件大小` 内；大于零时要求已有普通 part 的长度恰好等于偏移。非法参数或预检冲突不会截断现有 part。续传前缀由调用方保证属于同一来源版本；SDK 不对前缀做内容哈希比对。
- `overwrite: false` 在最终安装时使用原子非覆盖操作，即使其他写者在下载期间创建目标，也不会替换它。覆盖模式使用同目录原子 rename；提交前检查源身份、大小和修改时间等元数据，检测到变化则拒绝安装，但这不是内容哈希证明。
- 新建 part 使用 `0600`。覆盖已有目标时保留其普通 POSIX 权限位（`0777`），不继承 setuid/setgid/sticky 位；不承诺复制旧目标的 ACL、扩展属性、所有者或其他元数据。来源文件的权限也不会自动复制到目标。
- 取消或传输失败不安装目标，已写 part 可能保留；最终 rename 是提交点，提交后的取消不能撤回结果。调用方应独占目标及其 part，不应同时运行多个下载写同一路径。

## 路径与权限边界

- 写操作检查规范路径、根目录保护与父目录符号链接，包括目标文件尚不存在的情况；悬空/循环链接及含 NUL 的非法路径保守拒绝。
- 这是应用层路径边界检查，**不是安全 sandbox**，不保证抵抗其他进程在检查与执行之间恶意替换目录（TOCTOU）。调用方应使用自己控制的根目录。
- iOS/macOS sandbox、security-scoped URL 的授权生命周期由调用方管理；来源模块不封装 bookmark 或 iCloud 文件协调。未发布 [Catalog](Catalog.md) 支持宿主 resolver/lease 桥接，不把保存路径视为永久授权。
- 所有测试仅使用各自创建的临时目录，不会删除或改写用户真实文件。

## 使用方式

根目录的连接、错误处理与清理可沿用[首页快速上手](../README.md#快速上手)。以下函数在已经连接的来源上创建并上传一个文件；它不会删除调用方的数据：

```swift
import Foundation
import BoneRemoteSyncKit

func uploadLocalFile(source: LocalFileSource, input: URL) async throws -> RemoteEntry {
    try await source.makeDirectory(path: "/archive")
    return try await source.upload(
        from: input,
        to: "/archive/report.txt",
        options: .init(overwrite: false)
    )
}
```

`RemoteUploadOptions.contentType` 不会写入本地文件 MIME 元数据；返回值依据扩展名推导。进度回调同步执行，不保证主线程，UI 更新由宿主切换到 `MainActor`。

## 列表与持久化

元数据读取失败会保留可读取项并将 page.coverage 标为 partial；无法无损表示的名称或冲突路径会失败。Catalog 不以部分列表替换旧索引。枚举映射逐项检查取消，但 Foundation 目录 URL 数组物化和排序仍是同步操作；maxEntries 不能限制适配器单页的初始物化内存。
