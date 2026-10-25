import Foundation
import BoneRemoteSyncCore

/// Graph simple upload limit. Larger files need an upload session, which v1 does not implement.
let oneDriveSimpleUploadLimit: Int64 = 250 * 1024 * 1024

extension OneDriveSource: RemoteWritableSource {
    /// Upload a regular local file. Overwrite is expressed through Graph's conflictBehavior,
    /// so a non-overwrite upload fails at the service instead of racing a local check.
    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions) async throws -> RemoteEntry {
        do {
            let ctx = try context()
            let target = RemotePath.normalize(path)
            guard target != "/" else { throw RemoteSyncError.unsupported(operation: "OneDrive 不能用文件覆盖根目录") }
            let (parentPath, name) = try split(target)
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? Int64, size >= 0 else {
                throw RemoteSyncError.unsupported(operation: "OneDrive 仅上传普通文件")
            }
            guard size <= oneDriveSimpleUploadLimit else {
                throw RemoteSyncError.unsupported(operation: "OneDrive v1 单文件上传上限 250MiB，未实现分片上传")
            }
            let parent = try await item(path: parentPath, context: ctx)
            guard parent.folder != nil else { throw RemoteSyncError.conflict(path: parentPath) }
            let address = ODLocation.upload(parent: parent.id, name: name, drive: ctx.drive, base: endpoints.graph)
            var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: options.overwrite ? "replace" : "fail")]
            let response = try await graph(
                parts.url!,
                generation: ctx.generation,
                client: ctx.client,
                path: target,
                method: "PUT",
                body: .file(localURL),
                uploadProgress: options.progress
            )
            let value = try decode(ODItem.self, response.data)
            try check(ctx.generation)
            try value.validate(drive: ctx.drive, path: target)
            guard value.file != nil, value.name == name else { throw RemoteSyncError.unsupported(operation: "OneDrive 上传结果不是普通文件") }
            return value.entry(drive: ctx.drive, path: target)
        } catch { throw ODHTTPClient.mapped(error) }
    }

    /// Recursive and idempotent: an existing directory is success, an existing file is a conflict.
    public func makeDirectory(path: String) async throws {
        do {
            let ctx = try context()
            let target = RemotePath.normalize(path)
            guard target != "/" else { return }
            var current = ""
            for component in target.dropFirst().split(separator: "/") {
                current += "/" + component
                if try await directoryExists(current, context: ctx) { continue }
                let (parentPath, name) = try split(current)
                let parent = try await item(path: parentPath, context: ctx)
                guard parent.folder != nil else { throw RemoteSyncError.conflict(path: parentPath) }
                let payload = try JSONSerialization.data(withJSONObject: [
                    "name": name,
                    "folder": [:],
                    "@microsoft.graph.conflictBehavior": "fail"
                ])
                do {
                    let response = try await graph(
                        ODLocation.children(parent: parent.id, drive: ctx.drive, base: endpoints.graph),
                        generation: ctx.generation,
                        client: ctx.client,
                        path: current,
                        method: "POST",
                        json: payload
                    )
                    let value = try decode(ODItem.self, response.data)
                    try check(ctx.generation)
                    try value.validate(drive: ctx.drive, path: current)
                    guard value.folder != nil else { throw RemoteSyncError.conflict(path: current) }
                } catch let error as RemoteSyncError {
                    // A concurrent creator may have won the race; only then is conflict benign.
                    if case .conflict = error, try await directoryExists(current, context: ctx) { continue }
                    throw error
                }
            }
        } catch { throw ODHTTPClient.mapped(error) }
    }

    /// Deletes a file or a folder subtree. The drive root is never deletable.
    public func remove(path: String) async throws {
        do {
            let ctx = try context()
            let target = RemotePath.normalize(path)
            guard target != "/" else { throw RemoteSyncError.unsupported(operation: "OneDrive 不能删除主盘根目录") }
            let value = try await item(path: target, context: ctx)
            _ = try await graph(
                ODLocation.item(value.id, drive: ctx.drive, base: endpoints.graph),
                generation: ctx.generation,
                client: ctx.client,
                path: target,
                method: "DELETE"
            )
            try check(ctx.generation)
        } catch { throw ODHTTPClient.mapped(error) }
    }

    /// Move or rename. The destination must not exist; the destination parent must be a folder.
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        do {
            let ctx = try context()
            let source = RemotePath.normalize(sourcePath)
            let destination = RemotePath.normalize(destinationPath)
            guard source != "/", destination != "/" else {
                throw RemoteSyncError.unsupported(operation: "OneDrive 不能移动主盘根目录")
            }
            let value = try await item(path: source, context: ctx)
            let (parentPath, name) = try split(destination)
            let parent = try await item(path: parentPath, context: ctx)
            guard parent.folder != nil else { throw RemoteSyncError.conflict(path: parentPath) }
            do {
                _ = try await item(path: destination, context: ctx)
                throw RemoteSyncError.conflict(path: destination)
            } catch let error as RemoteSyncError {
                guard case .notFound = error else { throw error }
            }
            let payload = try JSONSerialization.data(withJSONObject: ["name": name, "parentReference": ["id": parent.id]])
            let response = try await graph(
                ODLocation.item(value.id, drive: ctx.drive, base: endpoints.graph),
                generation: ctx.generation,
                client: ctx.client,
                path: destination,
                method: "PATCH",
                json: payload
            )
            let updated = try decode(ODItem.self, response.data)
            try check(ctx.generation)
            try updated.validate(drive: ctx.drive, path: destination)
            guard updated.id == value.id, updated.name == name else {
                throw RemoteSyncError.unsupported(operation: "OneDrive 移动结果与请求不一致")
            }
        } catch { throw ODHTTPClient.mapped(error) }
    }

    private func directoryExists(_ path: String, context: ODContext) async throws -> Bool {
        do {
            let value = try await item(path: path, context: context)
            guard value.folder != nil else { throw RemoteSyncError.conflict(path: path) }
            return true
        } catch let error as RemoteSyncError {
            if case .notFound = error { return false }
            throw error
        }
    }

    private func split(_ path: String) throws -> (parent: String, name: String) {
        let parts = path.dropFirst().split(separator: "/")
        guard let last = parts.last, !last.isEmpty else { throw RemoteSyncError.unsupported(operation: "OneDrive 路径") }
        let parent = parts.count == 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
        return (parent, String(last))
    }
}
