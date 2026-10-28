import Foundation

/// Optional atomic conditional-read contract. A kind or ETag's appearance alone
/// does not establish this capability. Conformers must reject unsupported values
/// and enforce the exact condition before publishing downloaded content.
public protocol RemoteConditionalDownloadSource: RemoteSource {
    /// Returns a value accepted by the conditional download, or nil when this
    /// entry lacks a sufficiently strong validator. Must perform no I/O.
    func conditionalDownloadVersion(for entry: RemoteEntry) -> String?
    func download(_ entry: RemoteEntry, to destination: URL,
                  requiringVersion: String, options: RemoteDownloadOptions) async throws -> RemoteEntry
}
