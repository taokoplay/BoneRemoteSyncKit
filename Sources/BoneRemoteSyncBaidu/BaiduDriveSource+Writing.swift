import Foundation
import BoneRemoteSyncCore

extension BaiduDriveSource: RemoteCopyingSource {
    /// Uploads a private snapshot using Baidu's bounded 4 MiB block protocol.
    /// Baidu derives file type from the filename; contentType is validated but cannot be persisted.
    /// Writes are never replayed automatically. An interrupted write may need remote reconciliation.
    public func upload(from localURL: URL, to path: String, options: RemoteUploadOptions) async throws -> RemoteEntry {
        guard options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "Baidu conditional upload")
        }
        try Self.validateUploadContentType(options.contentType)
        let target = try writablePath(path)
        let remote = try BDLocation.remote(target, configuration: configuration)
        let ctx = try context()
        try beginMutation()
        defer { activeMutation = false }

        let snapshot = try await BDUploadSnapshot.create(from: localURL, maximumBytes: configuration.maxUploadBytes)
        try check(ctx)
        options.progress?(0)
        let (parentPath, _) = splitWritePath(target)
        try await requireWriteDirectory(parentPath, context: ctx)
        if let existing = try await existingWriteItem(target, context: ctx) {
            guard options.overwrite, !existing.entry.isDirectory else { throw RemoteSyncError.conflict(path: target) }
        }
        try check(ctx)
        let rtype = options.overwrite ? "3" : "0"
        let blocks = try BDJSON.array(snapshot.blockMD5s.map(BDJSON.string)).encoded()
        let precreated = try await api("file", method: "precreate", form: [
            "path": remote, "size": String(snapshot.size), "isdir": "0", "autoinit": "1",
            "rtype": rtype, "block_list": blocks
        ], context: ctx)
        try check(ctx)
        guard precreated["path"]?.string == remote, let returnType = precreated["return_type"]?.int else {
            throw BaiduDriveError.invalidResponse
        }
        guard returnType == 1 else {
            throw RemoteSyncError.unsupported(operation: "Baidu precreate returned an unsupported completion state; reconcile the target")
        }
        guard let uploadID = precreated["uploadid"]?.string, !uploadID.isEmpty, uploadID.utf8.count <= 4096,
              !uploadID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BaiduDriveError.invalidResponse
        }
        let requested = try Self.uploadParts(precreated["block_list"], count: snapshot.blockMD5s.count)
        let located = try await sendJSON(endpoints.locateUpload, parameters: [
            "method": "locateupload", "appid": "250528", "path": remote,
            "uploadid": uploadID, "upload_version": "2.0"
        ], context: ctx)
        try check(ctx)
        let uploadURL = try uploadServer(located)
        var confirmed = snapshot.blockMD5s
        var acknowledged: Int64 = 0
        for part in requested {
            try check(ctx)
            let chunk = try snapshot.chunk(part: part)
            let boundary = "bone-baidu-" + UUID().uuidString
            let payload = Self.multipartChunk(chunk, boundary: boundary)
            let response = try await sendJSON(uploadURL, parameters: [
                "method": "upload", "type": "tmpfile", "path": remote,
                "uploadid": uploadID, "partseq": String(part)
            ], body: payload, contentType: "multipart/form-data; boundary=\(boundary)", context: ctx, requireCode: false)
            try check(ctx)
            guard let md5 = response["md5"]?.string?.lowercased(), md5 == snapshot.blockMD5s[part] else {
                throw RemoteSyncError.integrityMismatch(path: target)
            }
            confirmed[part] = md5
            acknowledged += Int64(chunk.count)
            // Full size is reserved for an acknowledged create, including skipped/deduplicated blocks.
            if acknowledged < snapshot.size { options.progress?(acknowledged) }
        }
        try check(ctx)
        let created = try await api("file", method: "create", form: [
            "path": remote, "size": String(snapshot.size), "isdir": "0", "uploadid": uploadID,
            "rtype": rtype, "block_list": try BDJSON.array(confirmed.map(BDJSON.string)).encoded()
        ], context: ctx)
        try check(ctx)
        let result = try metadata(created, context: ctx)
        guard result.remotePath == remote, result.entry.path == target, !result.entry.isDirectory,
              result.entry.size == snapshot.size,
              result.entry.id == BDLocation.entryID(result.fsid, binding: ctx.binding) else {
            throw BaiduDriveError.invalidResponse
        }
        options.progress?(snapshot.size)
        return result.entry
    }

    /// Recursive and idempotent below an already-existing configured app root.
    public func makeDirectory(path: String) async throws {
        let target = try writablePath(path)
        let ctx = try context()
        try beginMutation()
        defer { activeMutation = false }
        try await requireWriteDirectory("/", context: ctx)
        var current = ""
        for component in target.dropFirst().split(separator: "/") {
            current += "/" + component
            if let existing = try await existingWriteItem(current, context: ctx) {
                guard existing.entry.isDirectory else { throw RemoteSyncError.conflict(path: current) }
                continue
            }
            let remote = try BDLocation.remote(current, configuration: configuration)
            do {
                try check(ctx)
                let response = try await api("file", method: "create", form: [
                    "path": remote, "isdir": "1", "rtype": "0"
                ], context: ctx)
                try check(ctx)
                let result = try metadata(response, context: ctx)
                guard result.entry.isDirectory, result.remotePath == remote, result.entry.path == current else {
                    throw BaiduDriveError.invalidResponse
                }
            } catch let error as RemoteSyncError {
                guard case .conflict = error else { throw error }
                // Only a confirmed conflict may be resolved by observing a concurrent creator.
                try await requireWriteDirectory(current, context: ctx)
            }
        }
    }

    public func remove(path: String) async throws {
        let target = try writablePath(path)
        let ctx = try context()
        try beginMutation()
        defer { activeMutation = false }
        let value = try await checkedWriteItem(target, context: ctx)
        try await fileManager(operation: "delete", source: value.remotePath,
                              list: .array([.string(value.remotePath)]), context: ctx)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await relocate(operation: "move", source: sourcePath, destination: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try await relocate(operation: "copy", source: sourcePath, destination: destinationPath)
    }

    private func relocate(operation: String, source sourcePath: String, destination destinationPath: String) async throws {
        let source = try writablePath(sourcePath)
        let destination = try writablePath(destinationPath)
        guard source != destination else { throw RemoteSyncError.conflict(path: destination) }
        let ctx = try context()
        try beginMutation()
        defer { activeMutation = false }
        let value = try await checkedWriteItem(source, context: ctx)
        guard !value.entry.isDirectory || !destination.hasPrefix(source + "/") else {
            throw RemoteSyncError.conflict(path: destination)
        }
        let (parent, name) = splitWritePath(destination)
        try await requireWriteDirectory(parent, context: ctx)
        guard try await existingWriteItem(destination, context: ctx) == nil else {
            throw RemoteSyncError.conflict(path: destination)
        }
        let remoteParent = try BDLocation.remote(parent, configuration: configuration)
        try await fileManager(operation: operation, source: value.remotePath, list: .array([.object([
            "path": .string(value.remotePath), "dest": .string(remoteParent), "newname": .string(name)
        ])]), context: ctx)
    }

    private func fileManager(operation: String, source: String, list: BDJSON, context ctx: BDContext) async throws {
        try check(ctx)
        var form = ["async": "0", "filelist": try list.encoded()]
        if operation != "delete" { form["ondup"] = "fail" }
        let response: BDJSON
        do {
            response = try await api("file", method: "filemanager", parameters: ["opera": operation], form: form, context: ctx)
        } catch BaiduDriveError.api(code: 111) {
            throw RemoteSyncError.conflict(path: "Baidu mutation")
        }
        try check(ctx)
        if let task = response["taskid"] {
            let text: String
            switch task {
            case .number(let value), .string(let value): text = value
            default: throw BaiduDriveError.invalidResponse
            }
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let taskID = UInt64(text) else {
                throw BaiduDriveError.invalidResponse
            }
            if taskID != 0 { throw BaiduDriveError.asynchronousResult }
        }
        guard response["errno"]?.int == 0,
              let info = response["info"]?.array, info.count == 1, info[0]["path"]?.string == source,
              let code = info[0]["errno"]?.int else { throw BaiduDriveError.invalidResponse }
        if code == 111 { throw RemoteSyncError.conflict(path: "Baidu mutation") }
        if code != 0 { throw BDAPI.error(code) }
        _ = try BDAPI.checked(info[0])
    }

    private func beginMutation() throws {
        guard !activeMutation else { throw RemoteSyncError.conflict(path: "Baidu mutation") }
        activeMutation = true
    }

    private func writablePath(_ raw: String) throws -> String {
        let path = try BDLocation.path(raw)
        guard path != "/" else { throw RemoteSyncError.unsupported(operation: "Baidu app root mutation") }
        // Validate the combined path as well as its source-relative spelling.
        _ = try BDLocation.path(BDLocation.remote(path, configuration: configuration))
        return path
    }

    private func splitWritePath(_ path: String) -> (String, String) {
        let components = path.dropFirst().split(separator: "/")
        return (components.count == 1 ? "/" : "/" + components.dropLast().joined(separator: "/"), String(components.last!))
    }

    private func checkedWriteItem(_ path: String, context ctx: BDContext) async throws -> BDItem {
        let value = try await item(path: path, context: ctx)
        try check(ctx)
        guard value.remotePath == (try BDLocation.remote(path, configuration: configuration)), value.entry.path == path else {
            throw BaiduDriveError.invalidResponse
        }
        return value
    }

    private func existingWriteItem(_ path: String, context ctx: BDContext) async throws -> BDItem? {
        do { return try await checkedWriteItem(path, context: ctx) }
        catch let error as RemoteSyncError {
            try check(ctx)
            if case .notFound = error { return nil }
            throw error
        }
    }

    private func requireWriteDirectory(_ path: String, context ctx: BDContext) async throws {
        guard try await checkedWriteItem(path, context: ctx).entry.isDirectory else {
            throw RemoteSyncError.conflict(path: path)
        }
    }

    private static func uploadParts(_ raw: BDJSON?, count: Int) throws -> [Int] {
        guard count > 0 else { throw BaiduDriveError.invalidResponse }
        guard let raw else { return [0] }
        guard let values = raw.array else { throw BaiduDriveError.invalidResponse }
        if values.isEmpty { return [0] }
        var seen = Set<Int>()
        for value in values {
            guard case .number(let text) = value, let part = Int(text), part >= 0, part < count,
                  seen.insert(part).inserted else { throw BaiduDriveError.invalidResponse }
        }
        return seen.sorted()
    }

    private func uploadServer(_ response: BDJSON) throws -> URL {
        guard let servers = response["servers"]?.array else { throw BaiduDriveError.invalidResponse }
        for server in servers {
            guard let text = server["server"]?.string, let url = URL(string: text),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.query == nil, components.fragment == nil,
                  components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
                  let trusted = try? BDLocation.serviceURL(url, endpoints: endpoints) else { continue }
            return trusted.appendingPathComponent("rest/2.0/pcs/superfile2")
        }
        throw BaiduDriveError.invalidResponse
    }

    private static func multipartChunk(_ data: Data, boundary: String) -> Data {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        let footer = "\r\n--\(boundary)--\r\n"
        var result = Data()
        result.reserveCapacity(header.utf8.count + data.count + footer.utf8.count)
        result.append(contentsOf: header.utf8)
        result.append(data)
        result.append(contentsOf: footer.utf8)
        return result
    }

    private static func validateUploadContentType(_ value: String?) throws {
        guard let value else { return }
        let token = #"[!#$%&'*+.^_`|~0-9A-Za-z-]+"#
        let quoted = #""(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*""#
        let pattern = "^" + token + "/" + token + "(?: *; *" + token + "=(?:" + token + "|" + quoted + "))*$"
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value >= 127 }),
              value.range(of: pattern, options: .regularExpression) != nil else {
            throw RemoteSyncError.unsupported(operation: "Baidu upload Content-Type is malformed")
        }
    }
}
