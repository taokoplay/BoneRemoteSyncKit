import Foundation
import BoneRemoteSyncKit

/// Call only from an entitled host, with an existing container-relative directory.
/// This read-only example does not create remote items or install a background schedule.
public func inspectICloudDirectory(
    containerIdentifier: String?,
    directoryPath: String = "/"
) async throws -> [RemoteEntry] {
    let source = ICloudDriveSource(configuration: try ICloudDriveConfiguration(
        containerIdentifier: containerIdentifier, directoryPath: directoryPath
    ))
    do {
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        guard page.coverage == .complete else {
            throw RemoteSyncError.unsupported(operation: "iCloud 目录列表不完整")
        }
        await source.disconnect()
        return page.entries
    } catch {
        await source.disconnect()
        throw error
    }
}

/// Explicitly creates the backup directory. Call only after the host authorizes initialization.
/// The returned source is connected and must be disconnected by the host when no longer needed.
public func connectICloudBackupDirectory(containerIdentifier: String) async throws -> ICloudDriveSource {
    let bootstrap = ICloudDriveSource(configuration: try .init(containerIdentifier: containerIdentifier))
    do {
        try await bootstrap.connect(.anonymous)
        try await bootstrap.makeDirectory(path: "/Documents/Backup")
        await bootstrap.disconnect()
    } catch {
        await bootstrap.disconnect()
        throw error
    }
    let source = ICloudDriveSource(configuration: try .init(
        containerIdentifier: containerIdentifier, directoryPath: "/Documents/Backup",
        downloadTimeout: 120, pollInterval: 0.25
    ))
    try await source.connect(.anonymous)
    return source
}

/// Displays zip candidates; the host must parse its own naming scheme before treating them as backups.
/// Partial results must never drive retention deletion.
public func listICloudBackups(source: ICloudDriveSource) async throws -> [RemoteEntry] {
    let page = try await source.list(path: "/")
    guard page.coverage == .complete else {
        throw RemoteSyncError.unsupported(operation: "备份列表不完整，禁止据此清理")
    }
    // This is only a display filter, not a backup-name parser or deletion policy.
    return page.entries.filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".zip") }
}

/// Queries local iCloud preparation states for a backup list without hydration.
/// This R3 helper is available in the current work tree and is not in v0.3.0.
/// Missing entries remain item failures; the host can display "unavailable" per row.
/// This is not an atomic snapshot and does not replace the complete-list safety check.
public func statusICloudBackups(source: ICloudDriveSource, entries: [RemoteEntry]) async throws -> [ICloudDriveStatusResult] {
    let paths = try entries.map { entry -> String in
        guard entry.type == .file, let path = entry.path, path == RemotePath.normalize(path),
              RemotePath.parent(of: path) == "/" else {
            throw RemoteSyncError.unsupported(operation: "只查询宿主选定的根层备份文件")
        }
        return path
    }
    return try await source.statuses(paths: paths)
}

/// The callback runs synchronously on SDK executors, not necessarily MainActor.
/// Host UI should use a task identity to discard stale updates and switch executors itself.
public func downloadICloudBackup(
    source: ICloudDriveSource,
    entry: RemoteEntry,
    to destination: URL,
    phaseProgress: @escaping @Sendable (RemoteDownloadProgress) -> Void
) async throws {
    _ = try await source.download(entry, to: destination, options: .init(
        overwrite: false, phaseProgress: phaseProgress
    ))
    // Only successful return certifies the complete file has been installed.
    // Zip validation, unpacking and restoring application data remain host responsibilities.
}

/// Uploads one host-named zip without replacing an existing backup.
public func saveICloudBackup(source: ICloudDriveSource, zipURL: URL, backupName: String) async throws -> RemoteEntry {
    guard backupName == RemotePath.name(of: backupName), !backupName.isEmpty,
          !backupName.contains("/"), !backupName.contains("\\"), !backupName.utf8.contains(0),
          backupName.lowercased().hasSuffix(".zip") else {
        throw RemoteSyncError.unsupported(operation: "备份名称必须为单个 zip 文件名")
    }
    return try await source.upload(from: zipURL, to: "/" + backupName, options: .init(overwrite: false))
}

/// The host selects obsolete backups after a successful upload, based on its own naming/retention policy.
/// Stops on the first error; earlier deletions remain committed. This is not a batch transaction.
public func removeHostSelectedOldBackups(source: ICloudDriveSource, entries: [RemoteEntry]) async throws {
    // Validate the complete input before deleting anything; do not accept arbitrary directory paths.
    let paths = try entries.map { entry -> String in
        guard entry.type == .file, let path = entry.path, path == RemotePath.normalize(path),
              RemotePath.parent(of: path) == "/", RemotePath.name(of: path) == entry.name,
              entry.name.lowercased().hasSuffix(".zip") else {
            throw RemoteSyncError.unsupported(operation: "只清理宿主选定的根层备份文件")
        }
        return path
    }
    for path in Set(paths).sorted() { try await source.remove(path: path) }
}
