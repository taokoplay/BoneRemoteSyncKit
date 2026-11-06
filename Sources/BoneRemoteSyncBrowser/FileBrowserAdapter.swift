import Foundation
import BoneRemoteSyncCore

struct FileBrowserAdapter: BrowserAdapter {
    let source: any RemoteSource
    let binding: RemoteSourceBinding
    let rootPath: String
    let bindingValidator: (@Sendable () async throws -> RemoteSourceBinding)?
    var rootCapabilities: RemoteBrowseCapabilities { [.browse] }

    func validateSession() async throws {
        try Task.checkCancellation()
        if let bindingValidator {
            guard try await bindingValidator() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
        }
    }
    func page(_ request: BrowserRequest) async throws -> BrowserResult {
        guard request.query == nil else { throw RemoteBrowserError(code: .unsupported) }
        let list = RemoteListRequest(cursor: request.fileCursor, limit: request.pageSize, includeHidden: request.includeHidden)
        let response: RemoteListPage
        if let parent = request.parent {
            guard case .file(let entry) = parent, entry.isDirectory else { throw RemoteBrowserError(code: .invalidReference) }
            if source.capabilities.idAddressing, let ids = source as? any RemoteIDAddressableSource {
                response = try await ids.list(parentID: entry.id, request: list)
            } else if let path = entry.path { response = try await source.list(path: path, request: list) }
            else { throw RemoteBrowserError(code: .invalidReference) }
        } else { response = try await source.list(path: rootPath, request: list) }
        try await validateSession()
        var next: BrowserContinuation?
        if let cursor = response.nextCursor {
            var value = request.next(); value.fileCursor = cursor
            next = .request(value)
        }
        let total = request.fileCursor == nil && response.nextCursor == nil && response.coverage == .complete ? response.entries.count : nil
        return .init(records: response.entries.map(record), total: total, coverage: response.coverage, next: next)
    }
    func details(_ node: BrowserNode) async throws -> BrowserRecord { record(try await refreshed(node)) }
    func artwork(_ node: BrowserNode) async throws -> Data? { nil }
    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord] {
        let entry = try await refreshed(node)
        guard !entry.isDirectory, source.capabilities.download else { return [] }
        return [.init(key: BrowserMapping.key(entry.id), title: entry.name, filename: entry.name,
                      contentType: entry.contentType, size: entry.size, kind: .originalFile,
                      locator: .file(try reference(entry)))]
    }
    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference {
        guard case .file(let reference) = download.locator, reference.source == binding else { throw RemoteBrowserError(code: .invalidReference) }
        let entry: RemoteEntry
        switch reference.locator {
        case .path(let path): entry = try await source.stat(path: path)
        case .itemID(let id):
            guard let ids = source as? any RemoteIDAddressableSource, source.capabilities.idAddressing else { throw RemoteBrowserError(code: .unsupported) }
            entry = try await ids.stat(id: id)
        }
        try await validateSession()
        guard !entry.isDirectory else { throw RemoteBrowserError(code: .invalidReference) }
        return reference
    }
    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference {
        .file(try reference(await refreshed(node)))
    }
    private func refreshed(_ node: BrowserNode) async throws -> RemoteEntry {
        guard case .file(let old) = node else { throw RemoteBrowserError(code: .invalidReference) }
        let entry: RemoteEntry
        if source.capabilities.idAddressing, let ids = source as? any RemoteIDAddressableSource { entry = try await ids.stat(id: old.id) }
        else if let path = old.path { entry = try await source.stat(path: path) }
        else { throw RemoteBrowserError(code: .invalidReference) }
        try await validateSession()
        guard entry.id == old.id, entry.type == old.type else { throw RemoteBrowserError(code: .invalidReference) }
        return entry
    }
    private func reference(_ entry: RemoteEntry) throws -> RemoteFileReference {
        if source.capabilities.idAddressing, source is any RemoteIDAddressableSource { return .init(source: binding, itemID: entry.id) }
        guard let path = entry.path else { throw RemoteBrowserError(code: .invalidReference) }
        return .init(source: binding, path: path)
    }
    private func record(_ entry: RemoteEntry) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: entry.name)
        metadata.size = entry.size; metadata.contentType = entry.contentType
        metadata.createdAt = entry.createdAt; metadata.modifiedAt = entry.modifiedAt
        let caps: RemoteBrowseCapabilities = entry.isDirectory ? [.browse] : (source.capabilities.download ? [.download] : [])
        return .init(key: BrowserMapping.key(entry.id), kind: entry.isDirectory ? .directory : .file,
                     metadata: metadata, capabilities: caps, node: .file(entry))
    }
}
