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

## 路径与权限边界

- 写操作检查规范路径、根目录保护与父目录符号链接，包括目标文件尚不存在的情况；悬空/循环链接及含 NUL 的非法路径保守拒绝。
- 这是应用层路径边界检查，**不是安全 sandbox**，不保证抵抗其他进程在检查与执行之间恶意替换目录（TOCTOU）。调用方应使用自己控制的根目录。
- iOS/macOS sandbox、security-scoped URL 的授权生命周期由调用方管理；目前不封装 bookmark、Keychain 或 iCloud 文件协调。
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
