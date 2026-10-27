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

    /// Local container/item snapshot only. Does not connect, create a directory, or prove cloud freshness.
    public func status(path: String? = nil) async -> ICloudDriveStatus {
        let injected = injectedContainerURL
        let configuration = configuration
        let environment = environment
        return (try? await perform { cancellation in
            let account = injected == nil && FileManager.default.ubiquityIdentityToken != nil
            guard let container = injected ?? FileManager.default.url(forUbiquityContainerIdentifier: configuration.containerIdentifier),
                  let root = try? Self.containerRoot(container, configuration: configuration) else {
                return ICloudDriveStatus(availability: .unavailable, accountIdentifierAvailable: account)
            }
            try cancellation.check()
            var directory: ObjCBool = false
            let available = FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
            let item = try? Self.resolve(path ?? "/", root: root)
            let state = item.flatMap { try? environment.itemState($0) }
            return ICloudDriveStatus(availability: available ? .available : .unavailable,
                containerURL: container, rootURL: available ? root : nil,
                accountIdentifierAvailable: account, isUbiquitous: state?.isUbiquitous ?? false,
                downloadState: state?.downloadState, percentDownloaded: nil)
        }) ?? ICloudDriveStatus(availability: .unavailable)
    }

    public func connect(_ credential: RemoteCredential) async throws {
        guard case .anonymous = credential else {
            throw RemoteSyncError.authenticationFailed(reason: "iCloud Drive 凭据由系统账号管理")
        }
        invalidate()
        let injected = injectedContainerURL
        let configuration = configuration
        let connection: ICloudConnection = try await perform { cancellation in
            let identity = injected == nil ? ICloudAccountIdentity() : nil
            if let identity { try identity.check() }
            guard let container = injected ?? FileManager.default.url(forUbiquityContainerIdentifier: configuration.containerIdentifier) else {
                throw ICloudDriveError.unavailable.remoteSyncError
            }
            let root = try Self.containerRoot(container, configuration: configuration)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                throw RemoteSyncError.notFound(path: configuration.directoryPath)
            }
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
        try await prepareForDownload(path: path, root: root)
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
        try await prepareForDownload(path: sourcePath, root: root)
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
        _ = try connectedRoot()
        let identity = identity
        return try await perform { cancellation in
            cancellation.identity = identity
            try cancellation.check()
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

    private func prepareForDownload(path: String, root: URL) async throws {
        let session = generation
        let environment = environment
        let timeout = configuration.downloadTimeout
        let interval = configuration.pollInterval
        let start = ProcessInfo.processInfo.systemUptime
        var requested = false
        while true {
            guard session == generation else { throw RemoteSyncError.cancelled }
            let didRequest = requested
            let ready: Bool = try await performConnected { cancellation in
                let url = try Self.resolve(path, root: root)
                return try Self.read(url, path: path, metadataOnly: true) { item in
                    try cancellation.check()
                    try Self.validate(item, root: root, path: path)
                    let entry = try Self.entry(item, path: path, environment: environment)
                    guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "下载或复制目录") }
                    let state = try environment.itemState(item)
                    if !state.isUbiquitous || state.downloadState == .current { return true }
                    if !didRequest { try environment.startDownloading(item) }
                    return false
                }
            }
            if ready { return }
            requested = true
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { throw ICloudDriveError.downloadTimedOut(path: path).remoteSyncError }
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(interval, remaining)) * 1_000_000_000)) }
            catch { throw RemoteSyncError.cancelled }
        }
    }

    // MARK: - Paths, metadata and coordination (queue only)

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
            throw ICloudDriveError.unresolvedConflict(path: path).remoteSyncError
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
        guard let result else { throw ICloudDriveError.coordinationFailed(path: path).remoteSyncError }
        do { return try result.get() } catch { throw map(error, path: path) }
    }

    private static func map(_ error: Error, path: String = "/") -> RemoteSyncError {
        if let error = error as? RemoteSyncError { return error }
        if let error = error as? ICloudDriveError { return error.remoteSyncError }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return .underlying(ns.localizedDescription) }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path: path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return .permissionDenied(path: path)
        case NSFileWriteFileExistsError: return .conflict(path: path)
        default: return .underlying(ns.localizedDescription)
        }
    }
}

private struct ICloudConnection: Sendable {
    let root: URL
    let identity: ICloudAccountIdentity?
}

/// The Foundation token is immutable and used only for isEqual; never serialized or exposed.
private final class ICloudAccountIdentity: @unchecked Sendable {
    private let token = FileManager.default.ubiquityIdentityToken
    func check() throws {
        guard let token, let current = FileManager.default.ubiquityIdentityToken, token.isEqual(current) else {
            throw ICloudDriveError.accountChanged.remoteSyncError
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
