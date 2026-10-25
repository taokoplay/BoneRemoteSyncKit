# 构建与验证状态

[返回项目首页](../README.md)

本页区分实现、受控测试、平台编译与真实服务验收。状态截至 **2026-10-25（GMT+8）**；测试数量与工具链描述对应当时记录，不是对后续任意版本的保证。

## 本地验证命令

```bash
swift build
swift test
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

## 当前验证摘要

| 检查 | 结果 | 证明范围 |
| --- | --- | --- |
| 全包测试 | 224 项复测通过 | 34 XCTest；106 WebDAV、43 OneDrive、39 Core/Local、2 统一入口 Swift Testing |
| Release 构建 | 通过 | 当前工具链的生产配置编译 |
| 单产品消费端 | 2 项通过 | 只依赖 `BoneRemoteSyncKit`，无分模块 import，也能使用来源、Core 类型及协议扩展 |
| 接入示例 | 两份示例编译通过 | WebDAV 与 OneDrive 宿主片段的类型和依赖正确，不代表完成外部登录 |
| 最低平台目标 | 五模块及两示例编译通过 | arm64 macOS 12，以及 iOS 15 / tvOS 15 / visionOS 1 的 Simulator SDK 目标 |

统一入口阶段使用 **Swift 6.4 / Xcode 27.1、Swift 6 语言模式**。未用 Swift 6.0 编译器重测；最低平台编译不等于模拟器、旧系统或真机运行验收。

一次并发全包执行中，已有 WebDAV 重试测试的短截止时间触发 3 个失败测试、4 个 issue。未修改或放宽断言；单独运行该套件的 5 项测试及随后全包复测均通过。此记录保留测试时序敏感性的事实，不能用最终绿灯隐去首次失败。

## 真实服务验收

| 范围 | 已完成 | 尚未完成 |
| --- | --- | --- |
| 本地目录 | 临时目录中的功能与安全测试 | 所有磁盘类型、外部并发攻击、断电持久性等穷尽验证 |
| WebDAV 真实飞牛 | 有限只读：账号可见非隐藏树、3 个小样本下载、条件续传 | 写入、真实 NAS 故障恢复、大文件公网性能、其他厂商与移动端运行 |
| WebDAV 写入 | localhost：PUT、MKCOL、DELETE、MOVE、COPY；覆盖竞争、取消、重连、错误映射等 | 真实 NAS 写权限、ETag 与方法兼容性 |
| WebDAV managed 恢复 | localhost 故障注入、独立进程取消／SIGKILL 后恢复、ready／rename 窗口 | 真实网络、硬件断电、移动设备运行 |
| OneDrive Personal | localhost：OAuth 请求合同、分页、文件读写、生命周期与安全边界 | 真实 Microsoft 应用／账号、CDN、刷新轮换与授权撤销验收 |

真实服务验收清单见 [WebDAV 示例](../Examples/WebDAVReadWrite/README.md)和 [OneDrive 示例](../Examples/OneDriveReadOnly/README.md)。只在明确授权的专用测试目录中写入；失败后先核实远端状态，不依据错误返回推断“没有创建”。

## 历史验证与性能记录

- 历史只读与下载恢复验证使用 Swift 6.2 / Xcode 26.0。
- WebDAV 写能力阶段全包 222 项通过；统一入口增加 2 项公共 API 测试后，全包复测为 224 项。
- 曾使用 localhost 合成服务和独立 Release runner 比较优化前后的目录解析、下载及遍历；场景包含 32 MiB payload、2,000 项元数据及 30 目录／30 文件的内容或请求数核对。
- 历史原始日志、进程故障探针及性能 runner 保存在开发会话工作台，**未随本仓库分发**。本仓库不存在可直接执行的 `benchmarks/webdav-performance/run.py`，因此不将该路径作为公开复跑命令，也不据此给出公网吞吐承诺。

若需要发布性能数字，应先把测量工具、固定样本、工具链与复现步骤纳入仓库，再重新测量。

## 未实现与后续方向

以下是候选方向，不是已发布能力、承诺日期或既定开发顺序：

1. 完成 WebDAV 与 OneDrive 的真实服务读写及异常验收。
2. OneDrive Upload Session：大文件分片、会话过期与恢复。
3. iCloud Drive 文件协调及云端占位文件处理；SMB 或其他来源按产品需求选择。
4. 独立同步层：快照、差异、可预览计划、执行与状态存储，再考虑双向冲突策略。

当前没有自动同步、后台传输、变更流、通用上传续传或统一跨来源事务。尚未实现的来源不得通过空实现或能力声明伪装为可用。
