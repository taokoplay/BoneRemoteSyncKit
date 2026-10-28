import Foundation
import BoneRemoteSyncCore

/// How long a materialized file remains managed by the transfer layer.
public enum RemoteMaterializationRetention: Sendable, Hashable, Codable {
    /// Keep the file until the lease is released. The file may be removed later.
    case lease
    /// Retain until explicitly evicted within this materializer's lifetime.
    /// This is not a persistent index or cross-process cache recovery.
    case persistent
}

/// Cache reuse policy for a materialization request.
public enum RemoteMaterializationReuse: Sendable, Hashable, Codable {
    /// Reuse only a cache entry whose source reference and observed version match.
    case matchingVersion
    /// Always fetch a fresh copy, while still publishing atomically.
    case refresh
}

public struct RemoteMaterializationOptions: Sendable {
    public var retention: RemoteMaterializationRetention
    public var reuse: RemoteMaterializationReuse
    public var consistency: RemoteReadConsistency
    public var verifySize: Bool
    /// Defaults to the existing sequential path; segment validation is never disabled.
    public var downloadStrategy: RemoteDownloadStrategy
    /// Explicit whole-file checksum. This release supports SHA-256; other algorithms
    /// are rejected before I/O. Provider-reported checksums are not auto-trusted.
    public var expectedChecksum: RemoteContentChecksum?
    public var phaseProgress: (@Sendable (RemoteDownloadProgress) -> Void)?
    /// Includes verification and commit boundaries. Late in-flight callbacks are
    /// observations only; the coordinator's terminal snapshot remains authoritative.
    public var transferProgress: (@Sendable (RemoteTransferProgress) -> Void)?

    public init(
        retention: RemoteMaterializationRetention = .lease,
        reuse: RemoteMaterializationReuse = .matchingVersion,
        consistency: RemoteReadConsistency = .latestObserved,
        verifySize: Bool = true,
        expectedChecksum: RemoteContentChecksum? = nil,
        downloadStrategy: RemoteDownloadStrategy = .sequential,
        phaseProgress: (@Sendable (RemoteDownloadProgress) -> Void)? = nil,
        transferProgress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) {
        self.retention = retention
        self.reuse = reuse
        self.consistency = consistency
        self.verifySize = verifySize
        self.downloadStrategy = downloadStrategy
        self.expectedChecksum = expectedChecksum
        self.phaseProgress = phaseProgress
        self.transferProgress = transferProgress
    }
}

/// A lease over a file owned by the transfer layer.
///
/// The URL is valid until the lease is released. The lease does not expose the
/// source's original URL, credentials, temporary download URL, or staging path.
public struct MaterializedFileLease: Sendable {
    public let url: URL
    public let reference: RemoteFileReference
    public let entry: RemoteEntry
    public let version: RemoteVersion?

    private let releaser: LeaseReleaser?

    init(
        url: URL,
        reference: RemoteFileReference,
        entry: RemoteEntry,
        version: RemoteVersion?,
        releaser: LeaseReleaser?
    ) {
        self.url = url
        self.reference = reference
        self.entry = entry
        self.version = version
        self.releaser = releaser
    }

    /// Releases this consumer's lease, including persistent-cache leases.
    /// Copies share one release token. Releasing more than once is harmless.
    public func release() async {
        await releaser?.release()
    }

    public func withAccess<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async rethrows -> T {
        do {
            let result = try await body(url)
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

actor LeaseReleaser {
    private var completion: Task<Void, Never>?
    private let action: @Sendable () async -> Void

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func release() async {
        if completion == nil {
            let action = self.action
            completion = Task { await action() }
        }
        // Every copy waits for the same cleanup, even during actor reentrancy.
        await completion?.value
    }
}

/// A source adapter used by the generic materializer.
public protocol RemoteFileMaterializing: Sendable {
    func materialize(
        _ reference: RemoteFileReference,
        options: RemoteMaterializationOptions
    ) async throws -> MaterializedFileLease
}
