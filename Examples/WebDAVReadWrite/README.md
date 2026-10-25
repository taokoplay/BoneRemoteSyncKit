# WebDAV 读写接入示例

[返回项目首页](../../README.md) · [WebDAV 详细语义](../../Docs/WebDAV.md)

[WebDAVExample.swift](WebDAVExample.swift) 提供 `webDAVFileManagementExample(...)` 函数，演示建目录、上传、复制、移动、下载和删除。它是加入宿主 target 的可编译片段，不是独立 App，也不会自动访问真实服务器。

## 接入

1. 为宿主 target 添加 `BoneRemoteSyncKit` 产品。
2. 将 `WebDAVExample.swift` 加入该 target；代码统一 `import BoneRemoteSyncKit`。
3. 准备下表参数，并在调用前确认对测试目录的写入授权。

| 参数 | 要求 |
| --- | --- |
| `baseURL` | 最终 WebDAV collection URL；优先 HTTPS，SDK 不跟随重定向 |
| `credential` | `.anonymous` 或从安全存储取得的 Basic 凭据 |
| `localFile` | 可读取的普通本地文件，上传期间不可被外部修改 |
| `newDirectory` | 独立的新测试目录，不能是 `/`；示例不会替你证明整棵目录的归属 |
| `downloadDestination` | 尚不存在、宿主有权限且可独占写入的本地目标 |

SwiftPM 的 target 依赖只需：

```swift
.product(name: "BoneRemoteSyncKit", package: "BoneRemoteSyncKit")
```

## 执行流程与保留内容

```text
连接 → 递归建目录 → 非覆盖上传 uploaded.bin
     → 复制为随机名称 → 移动／重命名
     → 下载至本地 → 删除本次创建的远端副本 → 断开
```

成功后：

- 返回原上传文件的 `RemoteEntry`。
- 保留远端 `uploaded.bin`、测试目录及本地下载结果。
- 只删除成功创建并重命名的远端副本，不删除整个测试目录。

失败时：

- 等待 `disconnect()` 后抛出错误。
- 不盲目删除资源或自动回滚；上传、复制或移动可能已在远端完成。
- 重新查询实际状态，再决定清理或重试。目录已存在且名称冲突时，也不能假定其中内容属于本次调用。

## 关键限制

- 上传、移动、复制要求父目录已存在；示例先调用递归 `makeDirectory`。
- 非覆盖上传发送 `If-None-Match: *`。覆盖已有普通文件需要强 ETag，并发送 `If-Match`；不覆盖目录。
- MOVE/COPY 使用 `Overwrite: F`；目录 COPY 使用 `Depth: infinity`。
- 上传使用私有磁盘快照，需要约一个源文件大小的临时空间；无通用断点上传。
- 写请求不自动重试。207 不当作整项成功，错误可能表示部分完成。
- LOCK/UNLOCK、PROPPATCH、ACL 和其他 WebDAV 扩展能力不在本示例范围内。

## 真实 NAS 验收清单

**当前尚未完成真实 NAS 写入验收。** localhost fixture 只能证明受控协议场景，不能替代以下检查：

1. 使用已授权的专用目录及最小权限账号连接 HTTPS 服务。
2. 递归建目录，确认重复创建幂等、文件同名冲突。
3. 上传空文件、中文／空格／`#?%` 文件名和二进制文件，下载后逐字节或 SHA-256 比对。
4. 验证非覆盖冲突、强 ETag 条件覆盖及并发版本变化，不误替换已有文件或目录。
5. 核对文件及非空目录 COPY/MOVE 后的内容；目标已存在时确认不覆盖。
6. 仅在自建资源上验证 DELETE，确认客户端拒绝根删除。
7. 验证只读账号、方法禁用、锁资源、取消和网络中断；失败后检查远端真实状态。
8. 仅清理确定属于本次验收的资源，不以错误返回推断资源没有创建。
