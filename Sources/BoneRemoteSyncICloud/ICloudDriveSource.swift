import Foundation
import Darwin
import UniformTypeIdentifiers
import BoneRemoteSyncCore

/// Coordinated iCloud Drive file access, not a CloudKit or automatic sync engine.
/// The host owns entitlements, account UI and exclusive local download destinations.
public actor ICloudDriveSource: RemoteCopyingSource {
    public nonisolated let kind: RemoteSourceKind = .iCloud
    public nonisolated let capabilities = RemoteCapabilities(
        list: true, stat: true, download: true, rangedDownload: true,
        upload: true, resumableUpload: false, makeDirectory: true, remove: true,
        move: true, copy: true, changeFeed: false, contentHash: false,
        maxConcurrentTransfers: 1
    )
    public let configuration: ICloudDriveConfiguration
    private let injectedContainerURL: URL?
    private let environment: ICloudDriveEnvironment
    private let queue = DispatchQueue(label: "BoneRemoteSyncICloud.files", qos: .utility)
    private var rootURL: URL?
    private var identity: ICloudAccountIdentity?
    private var generation = UUID()
    private var operations: [UUID: ICloudCancellation] = [:]

    public init(configuration: ICloudDriveConfiguration = .standard) {
        self.configuration = configuration
        injectedContainerURL = nil
        environment = .system
    }

    /// Deterministic filesystem/ubiquitous-metadata seam, never a real iCloud entitlement test.
    init(configuration: ICloudDriveConfiguration, rootURL: URL, environment: ICloudDriveEnvironment = .system) {
        self.configuration = configuration
        injectedContainerURL = rootURL.standardizedFileURL
        self.environment = environment
    }

    /// Injectable system-account/container seam for deterministic availability tests.
    init(configuration: ICloudDriveConfiguration, environment: ICloudDriveEnvironment) {
        self.configuration = configuration
        injectedContainerURL = nil
        self.environment = environment
    }

    /// Local container/item snapshot only. Does not connect, create a directory, or prove cloud freshness.
    public func status(path: String? = nil) async -> ICloudDriveStatus {
        let injected = injectedContainerURL
        let configuration = configuration
        let environment = environment
        return (try? await perform { cancellation in
            let account = injected == nil && environment.identityToken() != nil
            let availability = try Self.statusAvailability(configuration: configuration, injected: injected,
                environment: environment, account: account, cancellation: cancellation)
            guard let root = availability.rootURL else { return availability }
            let item = try? Self.resolve(path ?? "/", root: root)
            let state = item.flatMap { try? environment.itemState($0) }
            return Self.itemStatus(state, availability: availability)
        }) ?? ICloudDriveStatus(availability: .unavailable, unavailableReason: .unknown)
    }

    /// Queries local metadata once per input, preserving order and duplicates. No connection required.
    /// Item failures are independent; root unavailability is a successful unavailable snapshot.
    /// Cancellation, disconnect/reconnect or an observed account change discards the entire batch.
    /// Cancellation prevents result publication but cannot interrupt a synchronous Foundation call already running.
    /// Does not request downloads, create directories, or provide an atomic/cross-device snapshot.
    public func statuses(paths: [String]) async throws -> [ICloudDriveStatusResult] {
        guard !Task.isCancelled else { throw RemoteSyncError.cancelled }
        guard !paths.isEmpty else { return [] }
        let configuration = configuration
        let injected = injectedContainerURL
        let environment = environment
        let batch: ICloudStatusBatch = try await perform { cancellation in
            let identity = ICloudStatusIdentity(injected: injected != nil, currentToken: environment.identityToken)
            let availability = try Self.statusAvailability(configuration: configuration, injected: injected,
                environment: environment, account: identity.hasAccount, cancellation: cancellation)
            var results: [ICloudDriveStatusResult] = []
            for path in paths {
                try cancellation.check()
                try identity.check()
                let normalized = RemotePath.normalize(path)
                let result: Result<ICloudDriveStatus, any Error>
                do {
                    if let root = availability.rootURL {
                        let url = try Self.resolve(path, root: root)
                        let status = try Self.read(url, path: normalized, metadataOnly: true) { item in
                            try cancellation.check()
                            try Self.validate(item, root: root, path: normalized)
                            // Verify existence even with an injected metadata reader. Never open content.
                            _ = try item.resourceValues(forKeys: [.isDirectoryKey])
                            let state = try environment.itemState(item)
                            if state.hasUnresolvedConflicts {
                                throw ICloudDriveError.unresolvedConflict(path: normalized)
                            }
                            return Self.itemStatus(state, availability: availability)
                        }
                        result = .success(status)
                    } else {
                        result = .success(availability)
                    }
                } catch { result = .failure(Self.map(error, path: normalized)) }
                try cancellation.check()
                try identity.check()
                results.append(ICloudDriveStatusResult(path: normalized, result: result))
            }
            try cancellation.check()
            try identity.check()
            return ICloudStatusBatch(results: results, identity: identity)
        }
        // An account change during the queue -> actor hop must not publish old snapshots.
        guard !Task.isCancelled else { throw RemoteSyncError.cancelled }
        try batch.identity.check()
        return batch.results
    }

    public func connect(_ credential: RemoteCredential) async throws {
        guard case .anonymous = credential else {
            throw RemoteSyncError.authenticationFailed(reason: "iCloud Drive 凭据由系统账号管理")
        }
        invalidate()
        let injected = injectedContainerURL
        let configuration = configuration
        let environment = environment
        let connection: ICloudConnection = try await perform { cancellation in
            let identity: ICloudAccountIdentity?
            if injected == nil {
                identity = try ICloudAccountIdentity(currentToken: environment.identityToken)
            } else {
                identity = nil
            }
            if let identity { try identity.check() }
            guard let container = injected ?? environment.containerURL(configuration.containerIdentifier) else {
                if let identifier = configuration.containerIdentifier,
                   environment.containerURL(nil) != nil {
                    throw ICloudDriveError.containerNotFound(identifier: identifier)
                }
                throw ICloudDriveError.driveUnavailable
            }
            let root = try Self.containerRoot(container, configuration: configuration)
            try Self.requireDirectory(root, path: configuration.directoryPath)
            try cancellation.check()
            try identity?.check()
            return ICloudConnection(root: root, identity: identity)
        }
        rootURL = connection.root
        identity = connection.identity
    }

    public func disconnect() async { invalidate() }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        let root = try connectedRoot()
        try request.validate()
        guard request.cursor == nil else { throw RemoteSyncError.unsupported(operation: "iCloud Drive 不支持游标分页") }
        let normalized = RemotePath.normalize(path)
        let environment = environment
        return try await performConnected { cancellation in
            let directory = try Self.resolve(path, root: root)
            return try Self.read(directory, path: normalized, metadataOnly: true) { url in
                try Self.validate(url, root: root, path: normalized)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    throw RemoteSyncError.notFound(path: normalized)
                }
                guard isDirectory.boolValue else { throw RemoteSyncError.unsupported(operation: "列出非目录条目") }
                let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                var entries: [RemoteEntry] = []
                var seen: Set<String> = []
                var coverage: RemoteListingCoverage = .complete
                for child in urls {
                    try cancellation.check()
                    let name = child.lastPathComponent
                    // Legacy hidden .icloud placeholders cannot be safely represented as ordinary files.
                    if name.hasPrefix("."), name.hasSuffix(".icloud") { coverage = .partial; continue }
                    guard request.includeHidden || !name.hasPrefix(".") else { continue }
                    guard !name.contains("\\"), !name.utf8.contains(0) else {
                        throw RemoteSyncError.unsupported(operation: "iCloud 文件名无法表示为来源路径")
                    }
                    let childPath = RemotePath.join(normalized, name)
                    guard RemotePath.parent(of: childPath) == normalized, seen.insert(childPath).inserted else {
                        throw RemoteSyncError.unsupported(operation: "iCloud 目录包含冲突路径")
                    }
                    do {
                        try Self.validate(child, root: root, path: childPath)
                        entries.append(try Self.entry(child, path: childPath, environment: environment))
                    } catch { coverage = .partial }
                }
                try cancellation.check()
                entries.sort {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return RemoteListPage(coverage: coverage, entries: entries)
            }
        }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let root = try connectedRoot()
        let environment = environment
        return try await performConnected { _ in
            let url = try Self.resolve(path, root: root)
            return try Self.read(url, path: path, metadataOnly: true) {
                try Self.validate($0, root: root, path: path)
                return try Self.entry($0, path: path, environment: environment)
            }
        }
    }

    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载目录") }
        let path = entry.path ?? "/" + entry.id
        let root = try connectedRoot()
        let session = generation
        try await prepareForDownload(path: path, root: root, options: options)
        guard session == generation else { throw RemoteSyncError.cancelled }
        let environment = environment
        return try await performConnected { cancellation in
            let url = try Self.resolve(path, root: root)
            return try Self.read(url, path: path) { coordinated in
                try Self.validate(coordinated, root: root, path: path)
                let current = try Self.entry(coordinated, path: path, environment: environment)
                if let expected = options.expectedETag, expected != current.etag { throw RemoteSyncError.conflict(path: path) }
                let transfer = try ICloudFileTransfer(source: coordinated.resolvingSymlinksInPath(), destination: destination,
                                                     checkCancellation: { try cancellation.check() })
                try transfer.transfer(options: options)
                return current
            }
        }
    }

    @discardableResult
    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions = .init()) async throws -> RemoteEntry {
        let root = try connectedRoot()
        guard options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "iCloud Drive 不支持条件上传")
        }
        let environment = environment
        return try await performConnected { cancellation in
            guard localURL.isFileURL, localURL.host == nil || localURL.host == "localhost", !localURL.path.utf8.contains(0) else {
                throw RemoteSyncError.unsupported(operation: "上传非本地文件")
            }
            let destination = try Self.resolve(path, root: root)
            guard RemotePath.normalize(path) != "/" else { throw RemoteSyncError.conflict(path: "/") }
            return try Self.write(destination, path: path) { target in
                try Self.validate(target, root: root, path: path)
                try Self.checkConflicts(target, path: path, environment: environment)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path) {
                    guard options.overwrite, attrs[.type] as? FileAttributeType == .typeRegular else {
                        throw RemoteSyncError.conflict(path: path)
                    }
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = target.deletingLastPathComponent().appendingPathComponent(".bone-icloud-upload-\(UUID()).part")
                defer { try? FileManager.default.removeItem(at: staging) }
                let transfer = try ICloudFileTransfer(source: localURL, destination: URL(fileURLWithPath: target.path, isDirectory: false), staging: staging,
                                                     checkCancellation: {
                    try cancellation.check()
                    try Self.validate(target, root: root, path: path)
                    try Self.checkConflicts(target, path: path, environment: environment)
                })
                try transfer.transfer(options: .init(overwrite: options.overwrite, progress: options.progress))
                // Local commit is final; this is not an acknowledgement of an iCloud upload.
                return try Self.entry(target, path: path, environment: environment)
            }
        }
    }

    public func makeDirectory(path: String) async throws {
        let root = try connectedRoot()
        guard RemotePath.normalize(path) != "/" else { return }
        let environment = environment
        try await performConnected { cancellation in
            let url = try Self.resolve(path, root: root)
            try Self.write(url, path: path) { target in
                try cancellation.check()
                try Self.validate(target, root: root, path: path)
                try Self.checkConflicts(target, path: path, environment: environment)
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) {
                    guard directory.boolValue else { throw RemoteSyncError.conflict(path: path) }
                } else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
            }
        }
    }

    public func remove(path: String) async throws {
        let root = try connectedRoot()
        guard RemotePath.normalize(path) != "/" else { throw RemoteSyncError.unsupported(operation: "iCloud Drive 不能删除来源根目录") }
        let environment = environment
        try await performConnected { cancellation in
            let url = try Self.resolve(path, root: root)
            try Self.validateMutation(url, root: root, path: path)
            try Self.write(url, path: path, options: .forDeleting) { target in
                try cancellation.check()
                try Self.validateMutation(target, root: root, path: path)
                try Self.checkConflicts(target, path: path, environment: environment)
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let root = try connectedRoot()
        guard RemotePath.normalize(sourcePath) != "/", RemotePath.normalize(destinationPath) != "/" else {
            throw RemoteSyncError.unsupported(operation: "iCloud Drive 不能移动来源根目录")
        }
        let environment = environment
        try await performConnected { cancellation in
            let source = try Self.resolve(sourcePath, root: root)
            let destination = try Self.resolve(destinationPath, root: root)
            try Self.rejectSymlink(source, path: sourcePath)
            try Self.validateMutation(source, root: root, path: sourcePath)
            try Self.validateMutation(destination, root: root, path: destinationPath)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            try Self.coordinate(path: sourcePath) { result, error in
                coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
                    result = Result {
                        try cancellation.check()
                        try Self.rejectSymlink(from, path: sourcePath)
                        try Self.validateMutation(from, root: root, path: sourcePath)
                        try Self.validateMutation(to, root: root, path: destinationPath)
                        try Self.checkConflicts(from, path: sourcePath, environment: environment)
                        guard !FileManager.default.fileExists(atPath: to.path) else { throw RemoteSyncError.conflict(path: destinationPath) }
                        let origin = try Self.canonical(from, path: sourcePath).path
                        let target = try Self.canonical(to, path: destinationPath).path
                        guard !target.hasPrefix(origin + "/") else { throw RemoteSyncError.conflict(path: destinationPath) }
                        coordinator.item(at: from, willMoveTo: to)
                        try FileManager.default.moveItem(at: from, to: to)
                        coordinator.item(at: from, didMoveTo: to)
                    }
                }
            }
        }
    }

    /// File copy hydrates the source first. Recursive directory copy is deliberately unsupported.
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let root = try connectedRoot()
        guard RemotePath.normalize(sourcePath) != "/", RemotePath.normalize(destinationPath) != "/" else {
            throw RemoteSyncError.unsupported(operation: "iCloud Drive 不能复制来源根目录")
        }
        let session = generation
        try await prepareForDownload(path: sourcePath, root: root, options: .init())
        guard session == generation else { throw RemoteSyncError.cancelled }
        let environment = environment
        try await performConnected { cancellation in
            let source = try Self.resolve(sourcePath, root: root)
            let destination = try Self.resolve(destinationPath, root: root)
            try Self.rejectSymlink(source, path: sourcePath)
            try Self.validateMutation(source, root: root, path: sourcePath)
            try Self.validateMutation(destination, root: root, path: destinationPath)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            try Self.coordinate(path: sourcePath) { result, error in
                coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
                    result = Result {
                        try cancellation.check()
                        try Self.rejectSymlink(from, path: sourcePath)
                        try Self.validateMutation(from, root: root, path: sourcePath)
                        try Self.validateMutation(to, root: root, path: destinationPath)
                        try Self.checkConflicts(from, path: sourcePath, environment: environment)
                        guard !FileManager.default.fileExists(atPath: to.path) else { throw RemoteSyncError.conflict(path: destinationPath) }
                        try FileManager.default.copyItem(at: from, to: to)
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle and off-executor work

    private func invalidate() {
        operations.values.forEach { $0.cancel() }
        generation = UUID()
        rootURL = nil
        identity = nil
    }

    private func connectedRoot() throws -> URL {
        guard let rootURL else { throw RemoteSyncError.notConnected }
        do { try identity?.check() }
        catch { invalidate(); throw error }
        return rootURL
    }

    private func performConnected<T: Sendable>(_ body: @escaping @Sendable (ICloudCancellation) throws -> T) async throws -> T {
        let root = try connectedRoot()
        let directoryPath = configuration.directoryPath
        let identity = identity
        return try await perform { cancellation in
            cancellation.identity = identity
            try cancellation.check()
            try Self.requireDirectory(root, path: directoryPath)
            return try body(cancellation)
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (ICloudCancellation) throws -> T) async throws -> T {
        let cancellation = ICloudCancellation()
        let id = UUID(), session = generation
        operations[id] = cancellation
        defer { operations[id] = nil }
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        continuation.resume(returning: try body(cancellation))
                    } catch { continuation.resume(throwing: Self.map(error)) }
                }
            }
        } onCancel: { cancellation.cancel() }
        guard session == generation else { throw RemoteSyncError.cancelled }
        return result
    }

    private func prepareForDownload(path: String, root: URL, options: RemoteDownloadOptions) async throws {
        let session = generation
        let environment = environment
        let timeout = configuration.downloadTimeout
        let interval = configuration.pollInterval
        let start = ProcessInfo.processInfo.systemUptime
        var requested = false
        var lastProgress: RemoteDownloadProgress?

        func report(_ progress: RemoteDownloadProgress) {
            guard progress != lastProgress else { return }
            lastProgress = progress
            options.phaseProgress?(progress)
        }

        while true {
            guard session == generation else { throw RemoteSyncError.cancelled }
            let didRequest = requested
            let snapshot: ICloudPreparationSnapshot = try await performConnected { cancellation in
                let url = try Self.resolve(path, root: root)
                return try Self.read(url, path: path, metadataOnly: true) { item in
                    try cancellation.check()
                    try Self.validate(item, root: root, path: path)
                    let entry = try Self.entry(item, path: path, environment: environment)
                    guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载或复制目录") }
                    let state = try environment.itemState(item)
                    try cancellation.check()
                    if !state.isUbiquitous {
                        return ICloudPreparationSnapshot(ready: true, state: nil)
                    }
                    if state.downloadState == .current {
                        return ICloudPreparationSnapshot(ready: true, state: .ready)
                    }
                    if !didRequest { try environment.startDownloading(item) }
                    try cancellation.check()
                    let preparation: RemoteDownloadPreparationState = switch state.downloadState {
                    case .notDownloaded: .notStarted
                    case .downloading, .downloaded: .inProgress
                    default: .unknown
                    }
                    return ICloudPreparationSnapshot(ready: false, state: preparation)
                }
            }

            guard session == generation, !Task.isCancelled else { throw RemoteSyncError.cancelled }
            // Recheck identity after the queue/actor hop, before publishing a snapshot.
            _ = try connectedRoot()
            if snapshot.ready {
                if let state = snapshot.state {
                    report(RemoteDownloadProgress(phase: .preparing, preparationState: state, fractionCompleted: 1))
                }
                return
            }
            report(RemoteDownloadProgress(phase: .preparing, preparationState: snapshot.state))
            requested = true
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { throw ICloudDriveError.downloadTimedOut(path: path) }
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(interval, remaining)) * 1_000_000_000)) }
            catch { throw RemoteSyncError.cancelled }
        }
    }

    // MARK: - Paths, metadata and coordination (queue only)

    private static func statusAvailability(
        configuration: ICloudDriveConfiguration, injected: URL?, environment: ICloudDriveEnvironment,
        account: Bool, cancellation: ICloudCancellation
    ) throws -> ICloudDriveStatus {
        guard account || injected != nil else {
            return ICloudDriveStatus(availability: .unavailable, unavailableReason: .notSignedIn)
        }
        guard let container = injected ?? environment.containerURL(configuration.containerIdentifier) else {
            let reason: ICloudDriveAvailabilityReason = if configuration.containerIdentifier != nil,
                environment.containerURL(nil) != nil { .containerNotFound } else { .driveUnavailable }
            return ICloudDriveStatus(availability: .unavailable, unavailableReason: reason,
                                     accountIdentifierAvailable: account)
        }
        guard let root = try? containerRoot(container, configuration: configuration) else {
            return ICloudDriveStatus(availability: .unavailable, unavailableReason: .unknown,
                                     containerURL: container, accountIdentifierAvailable: account)
        }
        try cancellation.check()
        do { try requireDirectory(root, path: configuration.directoryPath) }
        catch {
            let reason: ICloudDriveAvailabilityReason
            if case ICloudDriveError.directoryNotFound = error { reason = .directoryNotFound }
            else { reason = .unknown }
            return ICloudDriveStatus(availability: .unavailable, unavailableReason: reason,
                                     containerURL: container, accountIdentifierAvailable: account)
        }
        return ICloudDriveStatus(availability: .available, containerURL: container, rootURL: root,
                                 accountIdentifierAvailable: account)
    }

    private static func itemStatus(_ state: ICloudItemState?, availability: ICloudDriveStatus) -> ICloudDriveStatus {
        ICloudDriveStatus(availability: availability.availability, unavailableReason: availability.unavailableReason,
            containerURL: availability.containerURL, rootURL: availability.rootURL,
            accountIdentifierAvailable: availability.accountIdentifierAvailable,
            isUbiquitous: state?.isUbiquitous ?? false, downloadState: state?.downloadState, percentDownloaded: nil)
    }

    /// Unlike fileExists, preserve permission/IO failures instead of guessing a missing directory.
    private static func requireDirectory(_ url: URL, path: String) throws {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: throw ICloudDriveError.directoryNotFound(path: path)
            case EACCES, EPERM: throw RemoteSyncError.permissionDenied(path: path)
            default: throw RemoteSyncError.underlying("iCloud 配置目录查询失败（\(code)）")
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ICloudDriveError.directoryNotFound(path: path)
        }
    }

    private static func containerRoot(_ container: URL, configuration: ICloudDriveConfiguration) throws -> URL {
        let relative = RemotePath.relative(configuration.directoryPath)
        let root = relative.isEmpty ? container : container.appendingPathComponent(relative, isDirectory: true)
        try validate(root, root: container, path: configuration.directoryPath)
        return root.standardizedFileURL
    }

    private static func resolve(_ path: String, root: URL) throws -> URL {
        guard !path.utf8.contains(0) else { throw RemoteSyncError.permissionDenied(path: RemotePath.normalize(path)) }
        let relative = RemotePath.relative(path)
        let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
        try validate(url, root: root, path: path)
        return url
    }

    private static func validate(_ url: URL, root: URL, path: String) throws {
        let base = try canonical(root, path: path).path
        let candidate = try canonical(url, path: path).path
        guard candidate == base || candidate.hasPrefix(base == "/" ? "/" : base + "/") else {
            throw RemoteSyncError.permissionDenied(path: RemotePath.normalize(path))
        }
    }

    private static func rejectSymlink(_ url: URL, path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw RemoteSyncError.unsupported(operation: "iCloud Drive 不支持移动或复制符号链接：\(path)")
        }
    }

    private static func validateMutation(_ url: URL, root: URL, path: String) throws {
        try validate(url, root: root, path: path)
        guard try canonical(url, path: path).path != canonical(root, path: path).path else {
            throw RemoteSyncError.permissionDenied(path: RemotePath.normalize(path))
        }
    }

    /// realpath the nearest existing ancestor; Foundation does not resolve symlink parents
    /// reliably when the final component does not exist yet.
    private static func canonical(_ url: URL, path: String) throws -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while (try? FileManager.default.attributesOfItem(atPath: ancestor.path)) == nil, ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard let resolved = realpath(ancestor.path, nil) else {
            throw RemoteSyncError.permissionDenied(path: RemotePath.normalize(path))
        }
        defer { free(resolved) }
        var result = URL(fileURLWithPath: String(cString: resolved))
        for component in suffix { result.appendPathComponent(component) }
        return result
    }

    private static func checkConflicts(_ url: URL, path: String, environment: ICloudDriveEnvironment) throws {
        if FileManager.default.fileExists(atPath: url.path), try environment.itemState(url).hasUnresolvedConflicts {
            throw ICloudDriveError.unresolvedConflict(path: path)
        }
    }

    private static func entry(_ url: URL, path: String, environment: ICloudDriveEnvironment) throws -> RemoteEntry {
        try checkConflicts(url, path: path, environment: environment)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey])
        let directory = values.isDirectory ?? false
        let size = directory ? nil : values.fileSize.map(Int64.init)
        let modified = values.contentModificationDate
        let etag: String? = if let size, let modified { "\(size)-\(Int64(modified.timeIntervalSince1970 * 1000))" } else { nil }
        return RemoteEntry(id: RemotePath.relative(path), path: RemotePath.normalize(path), name: url.lastPathComponent,
            type: directory ? .directory : .file, size: size, modifiedAt: modified, etag: etag,
            contentType: values.contentType?.preferredMIMEType, createdAt: values.creationDate)
    }

    private static func read<T>(_ url: URL, path: String, metadataOnly: Bool = false, _ body: (URL) throws -> T) throws -> T {
        try coordinate(path: path) { result, error in
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: metadataOnly ? [.withoutChanges, .immediatelyAvailableMetadataOnly] : [], error: &error) { coordinated in
                result = Result { try body(coordinated) }
            }
        }
    }

    private static func write<T>(_ url: URL, path: String, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> T) throws -> T {
        try coordinate(path: path) { result, error in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &error) { coordinated in
                result = Result { try body(coordinated) }
            }
        }
    }

    private static func coordinate<T>(path: String = "/", _ action: (inout Result<T, Error>?, inout NSError?) -> Void) throws -> T {
        var result: Result<T, Error>?, error: NSError?
        action(&result, &error)
        if let error { throw map(error, path: path) }
        guard let result else { throw ICloudDriveError.coordinationFailed(path: path) }
        do { return try result.get() } catch { throw map(error, path: path) }
    }

    private static func map(_ error: Error, path: String = "/") -> Error {
        if error is RemoteSyncError || error is ICloudDriveError { return error }
        if error is CancellationError { return RemoteSyncError.cancelled }
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return RemoteSyncError.underlying(ns.localizedDescription) }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return RemoteSyncError.notFound(path: path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return RemoteSyncError.permissionDenied(path: path)
        case NSFileWriteFileExistsError: return RemoteSyncError.conflict(path: path)
        default: return RemoteSyncError.underlying(ns.localizedDescription)
        }
    }
}

private struct ICloudConnection: Sendable {
    let root: URL
    let identity: ICloudAccountIdentity?
}

private struct ICloudStatusBatch: Sendable {
    let results: [ICloudDriveStatusResult]
    let identity: ICloudStatusIdentity
}

/// Immutable Foundation identity snapshot, including the initially signed-out state.
/// Never serialized or exposed; injected filesystem tests do not claim a real identity.
private final class ICloudStatusIdentity: @unchecked Sendable {
    private let injected: Bool
    private let token: NSObject?
    private let currentToken: @Sendable () -> NSObject?
    var hasAccount: Bool { !injected && token != nil }

    init(injected: Bool, currentToken: @escaping @Sendable () -> NSObject?) {
        self.injected = injected
        self.currentToken = currentToken
        token = injected ? nil : currentToken()
    }

    func check() throws {
        guard !injected else { return }
        let current = currentToken()
        guard token == nil && current == nil || token?.isEqual(current) == true else {
            throw ICloudDriveError.accountChanged
        }
    }
}

private struct ICloudPreparationSnapshot: Sendable, Equatable {
    let ready: Bool
    let state: RemoteDownloadPreparationState?
}

/// The Foundation token is immutable and used only for isEqual; never serialized or exposed.
private final class ICloudAccountIdentity: @unchecked Sendable {
    private let token: NSObject
    private let currentToken: @Sendable () -> NSObject?

    init(currentToken: @escaping @Sendable () -> NSObject?) throws {
        guard let token = currentToken() else {
            throw ICloudDriveError.accountNotSignedIn
        }
        self.token = token
        self.currentToken = currentToken
    }

    func check() throws {
        guard let current = currentToken() else {
            throw ICloudDriveError.accountChanged
        }
        guard token.isEqual(current) else {
            throw ICloudDriveError.accountChanged
        }
    }
}

/// Bridges Swift task cancellation to synchronous NSFileCoordinator/file I/O on the utility queue.
private final class ICloudCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    // Set and read only on the serial work queue.
    var identity: ICloudAccountIdentity?
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        guard !lock.withLock({ cancelled }) else { throw RemoteSyncError.cancelled }
        try identity?.check()
    }
}

/// Minimal ubiquitous-resource seam; production always reads Foundation metadata on the work queue.
struct ICloudDriveEnvironment: Sendable {
    var identityToken: @Sendable () -> NSObject? = { FileManager.default.ubiquityIdentityToken as? NSObject }
    var containerURL: @Sendable (String?) -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: $0) }
    var itemState: @Sendable (URL) throws -> ICloudItemState
    var startDownloading: @Sendable (URL) throws -> Void
    static let system = Self(itemState: { url in
        // Fresh URL prevents resource-value caching across polling iterations.
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingErrorKey])
        if let error = values.ubiquitousItemDownloadingError { throw error }
        let state: ICloudDriveDownloadState? = if values.ubiquitousItemIsDownloading == true { .downloading }
        else if let status = values.ubiquitousItemDownloadingStatus {
            switch status { case .current: .current; case .downloaded: .downloaded; case .notDownloaded: .notDownloaded; default: .unknown }
        } else { nil }
        return ICloudItemState(isUbiquitous: values.isUbiquitousItem ?? false, downloadState: state,
                               hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false)
    }, startDownloading: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) })
}

struct ICloudItemState: Sendable {
    var isUbiquitous: Bool = false
    var downloadState: ICloudDriveDownloadState?
    var hasUnresolvedConflicts: Bool = false
}
