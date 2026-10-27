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
