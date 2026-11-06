import Foundation
import BoneRemoteSyncCore

extension BaiduDriveSource: RemoteIDAddressableSource {
    public func stat(path: String) async throws -> RemoteEntry { try await item(path: path, context: context()).entry }
    public func stat(id: String) async throws -> RemoteEntry { try await item(id: id, context: context()).entry }
    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        let ctx = try context()
        return try await page(path: BDLocation.path(path), parentID: nil, request: request, context: ctx)
    }
    public func list(parentID: String, request: RemoteListRequest) async throws -> RemoteListPage {
        let ctx = try context()
        try request.validate()
        let parent = try await item(id: parentID, context: ctx)
        guard parent.entry.isDirectory, let path = parent.entry.path else { throw RemoteSyncError.unsupported(operation: "百度列表父项不是目录") }
        return try await page(path: path, parentID: parentID, request: request, context: ctx)
    }
    private func page(path: String, parentID: String?, request: RemoteListRequest, context ctx: BDContext) async throws -> RemoteListPage {
        try request.validate()
        let previous: BDCursor?
        if let cursor = request.cursor {
            guard let saved = cursors[cursor], saved.path == path, saved.parentID == parentID,
                  saved.requestLimit == request.limit, saved.includeHidden == request.includeHidden else { throw BaiduDriveError.invalidCursor }
            previous = saved; cursors[cursor] = nil // single consumer; failed pages restart from page one
            cursorOrder.removeAll { $0 == cursor }
        } else { previous = nil }
        let limit = min(request.limit ?? 1000, 1000), offset = previous?.offset ?? 0
        let result = try await api("file", method: "list", parameters: [
            "dir": BDLocation.remote(path, configuration: configuration), "start": String(offset), "limit": String(limit),
            "order": "name", "desc": "0", "folder": "0", "web": "0"
        ], context: ctx)
        let data: BDJSON
        if let nested = result["data"] { data = try BDAPI.checked(nested, requireCode: false) } else { data = result }
        guard let list = data["list"]?.array, list.count <= limit else { throw BaiduDriveError.invalidResponse }
        var ids = previous?.seenIDs ?? [], paths = previous?.seenPaths ?? []
        var entries: [RemoteEntry] = [], coverage = RemoteListingCoverage.complete
        for raw in list {
            let item = try metadata(raw, context: ctx)
            guard let child = item.entry.path, RemotePath.parent(of: child) == path,
                  ids.insert(item.entry.id).inserted, paths.insert(child).inserted else { throw BaiduDriveError.invalidResponse }
            if raw["unlist"]?.int ?? 0 != 0 { coverage = .partial }
            if request.includeHidden || !item.entry.name.hasPrefix(".") { entries.append(item.entry) }
        }
        guard ids.count <= 100_000, offset <= 100_000 - list.count else { throw BaiduDriveError.responseTooLarge }
        try check(ctx)
        var next: String?
        // API has no snapshot/has_more guarantee. A full page needs another request, including an empty final page.
        if list.count == limit {
            // Abandoned listings must not permanently prevent new directory reads.
            while cursors.count >= cursorCapacity, let oldest = cursorOrder.first {
                cursors[oldest] = nil; cursorOrder.removeFirst()
            }
            let cursor = UUID().uuidString
            cursors[cursor] = .init(path: path, parentID: parentID, requestLimit: request.limit, includeHidden: request.includeHidden,
                                   offset: offset + list.count, seenIDs: ids, seenPaths: paths)
            cursorOrder.append(cursor); next = cursor
        }
        return .init(coverage: coverage, entries: entries, nextCursor: next)
    }

    func item(path: String, context ctx: BDContext) async throws -> BDItem {
        let local = try BDLocation.path(path), remote = try BDLocation.remote(local, configuration: configuration)
        let result = try await api("file", method: "meta", parameters: ["path": remote, "dlink": "0"], context: ctx)
        let resultItem = try singleItem(result, context: ctx)
        guard resultItem.remotePath == remote else { throw BaiduDriveError.invalidResponse }
        return resultItem
    }
    func item(id: String, dlink: Bool = false, context ctx: BDContext) async throws -> BDItem {
        let fsid = try BDLocation.fsid(id, binding: ctx.binding)
        let result = try await api("multimedia", method: "filemetas", parameters: ["fsids": "[\(fsid)]", "dlink": dlink ? "1" : "0"], context: ctx)
        let resultItem = try singleItem(result, context: ctx)
        guard resultItem.fsid == fsid else { throw BaiduDriveError.invalidResponse }
        return resultItem
    }
    private func singleItem(_ result: BDJSON, context ctx: BDContext) throws -> BDItem {
        let value: BDJSON
        if let data = result["data"] { value = try BDAPI.checked(data, requireCode: false) } else { value = result }
        if let list = (value["list"] ?? value["info"])?.array {
            guard !list.isEmpty else { throw RemoteSyncError.notFound(path: "Baidu resource") }
            guard list.count == 1 else { throw BaiduDriveError.invalidResponse }
            return try metadata(list[0], context: ctx)
        }
        return try metadata(value, context: ctx)
    }
    func metadata(_ raw: BDJSON, context ctx: BDContext) throws -> BDItem {
        _ = try BDAPI.checked(raw, requireCode: false)
        guard let fsid = raw["fs_id"]?.uintString, let remote = raw["path"]?.string,
              let isdir = raw["isdir"]?.int, [0, 1].contains(isdir), raw["isdelete"]?.int ?? 0 == 0 else { throw BaiduDriveError.invalidResponse }
        let local = try BDLocation.local(remote, configuration: configuration)
        let name = local == "/" ? RemotePath.name(of: configuration.rootPath) : RemotePath.name(of: local)
        if let reported = (raw["server_filename"] ?? raw["filename"])?.string, reported != name { throw BaiduDriveError.invalidResponse }
        let size = raw["size"]?.int.map(Int64.init)
        guard isdir == 1 || (size != nil && size! >= 0) else { throw BaiduDriveError.invalidResponse }
        func date(_ value: BDJSON?) -> Date? {
            guard let seconds = value?.int, seconds >= 0, seconds <= 253402300799 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        // API docs describe md5 inconsistently (cloud hash vs actual MD5); never publish it as checksum or ETag.
        let entry = RemoteEntry(id: BDLocation.entryID(fsid, binding: ctx.binding), path: local, name: name,
                                type: isdir == 1 ? .directory : .file, size: isdir == 1 ? nil : size,
                                modifiedAt: date(raw["server_mtime"] ?? raw["mtime"]),
                                createdAt: date(raw["server_ctime"] ?? raw["ctime"]))
        return .init(entry: entry, remotePath: remote, fsid: fsid, dlink: raw["dlink"]?.string, cloudHash: raw["md5"]?.string)
    }
}
