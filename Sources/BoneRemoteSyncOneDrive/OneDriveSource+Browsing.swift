import Foundation
import CryptoKit
import BoneRemoteSyncCore

extension OneDriveSource {
    public func stat(path: String) async throws -> RemoteEntry {
        do {
            let ctx = try context(); let normalized = RemotePath.normalize(path)
            let value = try await item(path: normalized, context: ctx)
            try check(ctx.generation)
            return value.entry(drive: ctx.drive, path: normalized)
        } catch { throw ODHTTPClient.mapped(error) }
    }
    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        do {
            let ctx = try context(); let path = RemotePath.normalize(path)
            try request.validate()
            let url: URL; let resource: URL; var visited: Set<Data>
            if let cursor = request.cursor {
                guard let saved = cursors[cursor], saved.path == path, saved.limit == request.limit, saved.includeHidden == request.includeHidden else {
                    throw RemoteSyncError.unsupported(operation: "OneDrive 游标无效或不属于当前请求")
                }
                url = saved.url; resource = saved.resource; visited = saved.visited
            } else {
                let folder = try await item(path: path, context: ctx)
                guard folder.folder != nil else { throw RemoteSyncError.unsupported(operation: "列出非目录条目") }
                resource = ODLocation.item(folder.id, drive: ctx.drive, base: endpoints.graph).appendingPathComponent("children")
                var parts = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
                if let limit = request.limit { parts.queryItems = [URLQueryItem(name: "$top", value: String(min(limit, 200)))] }
                url = parts.url!; visited = []
            }
            let result = try await graph(url, generation: ctx.generation, client: ctx.client, path: path)
            let page = try decode(ODPage.self, result.data)
            try check(ctx.generation)
            var ids = Set<String>(); var names = Set<String>()
            let entries = try page.value.compactMap { value -> RemoteEntry? in
                let child = path == "/" ? "/" + value.name : path + "/" + value.name
                try value.validate(drive: ctx.drive, path: child)
                guard ids.insert(value.id).inserted, names.insert(value.name).inserted else { throw RemoteSyncError.unsupported(operation: "OneDrive 分页包含重复条目") }
                return request.includeHidden || !value.name.hasPrefix(".") ? value.entry(drive: ctx.drive, path: child) : nil
            }
            // A request may have suspended while another caller consumed the same cursor.
            if let old = request.cursor, cursors[old] == nil { throw RemoteSyncError.unsupported(operation: "OneDrive 游标已消费或淘汰") }
            func fingerprint(_ url: URL) -> Data { Data(SHA256.hash(data: Data(url.absoluteString.utf8))) }
            visited.insert(fingerprint(url))
            var cursor: String?
            if let raw = page.next {
                let next = try ODLocation.next(raw, resource: resource, base: endpoints.graph)
                guard !visited.contains(fingerprint(next)), visited.count <= 10000 else { throw RemoteSyncError.unsupported(operation: "OneDrive 分页循环或页面上限") }
                cursor = UUID().uuidString
                // Advancing replaces the old slot; abandoned listings are FIFO evicted.
                if let old = request.cursor { cursors.removeValue(forKey: old); cursorOrder.removeAll { $0 == old } }
                while cursors.count >= 256, let oldest = cursorOrder.first {
                    cursors.removeValue(forKey: oldest); cursorOrder.removeFirst()
                }
                cursorOrder.append(cursor!)
                cursors[cursor!] = ODCursor(path: path, limit: request.limit, includeHidden: request.includeHidden, url: next, resource: resource, visited: visited)
            }
            // Successful advancement consumes the supplied cursor, bounding active pagination state.
            if let old = request.cursor { cursors.removeValue(forKey: old); cursorOrder.removeAll { $0 == old } }
            return RemoteListPage(coverage: .complete, entries: entries, nextCursor: cursor)
        } catch { throw ODHTTPClient.mapped(error) }
    }
}
