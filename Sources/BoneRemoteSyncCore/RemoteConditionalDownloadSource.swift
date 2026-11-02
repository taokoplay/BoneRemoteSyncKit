import Foundation

/// Optional atomic conditional-read contract. A kind or ETag's appearance alone
/// does not establish this capability. Conformers must reject unsupported values
/// and enforce the exact condition before publishing downloaded content.
/// 可选的强条件下载协议；来源必须在发布内容前严格验证版本条件。
public protocol RemoteConditionalDownloadSource: RemoteSource {
    /// Returns a value accepted by the conditional download, or nil when this
    /// entry lacks a sufficiently strong validator. Must perform no I/O.
    func conditionalDownloadVersion(for entry: RemoteEntry) -> String?
    /// 按指定强版本执行条件下载；版本不匹配时不得安装目标文件。
    func download(_ entry: RemoteEntry, to destination: URL,
                  requiringVersion: String, options: RemoteDownloadOptions) async throws -> RemoteEntry
}
