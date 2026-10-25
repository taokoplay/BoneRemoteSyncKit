import Foundation
import BoneRemoteSyncKit

/// Upload a caller-owned file into a caller-selected new directory and exercise file operations.
/// Use a fresh, dedicated test path. The caller must explicitly authorize the resulting writes.
/// No real credentials or external endpoint are embedded in this example.
public func webDAVFileManagementExample(
    baseURL: URL,
    credential: RemoteCredential,
    localFile: URL,
    newDirectory: String,
    downloadDestination: URL
) async throws -> RemoteEntry {
    let directory = RemotePath.normalize(newDirectory)
    guard directory != "/" else {
        throw RemoteSyncError.unsupported(operation: "示例需要独立的新目录")
    }
    let source = try WebDAVSource(baseURL: baseURL)
    do {
        try await source.connect(credential)
        try await source.makeDirectory(path: directory)
        let uploaded = try await source.upload(
            from: localFile, to: RemotePath.join(directory, "uploaded.bin"),
            options: .init(overwrite: false)
        )
        let copy = RemotePath.join(directory, "copy-\(UUID().uuidString).bin")
        let renamed = RemotePath.join(directory, "renamed-\(UUID().uuidString).bin")
        try await source.copy(from: uploaded.path!, to: copy)
        try await source.move(from: copy, to: renamed)
        _ = try await source.download(path: renamed, to: downloadDestination, options: .init(overwrite: false))
        // Only this example's successfully created copy is removed; keep the uploaded file.
        try await source.remove(path: renamed)
        await source.disconnect()
        return uploaded
    } catch {
        await source.disconnect()
        // Do not blindly delete remote resources on failure: the last mutation may have committed.
        throw error
    }
}
