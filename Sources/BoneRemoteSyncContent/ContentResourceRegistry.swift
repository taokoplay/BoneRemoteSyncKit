import Foundation
import BoneRemoteSyncCore

package struct ContentResource: Sendable {
    package let entry: RemoteEntry
    package let url: URL
}

/// 会话内的文件描述，不把服务端 URL 或凭据变成长期文件 ID。
package struct ContentResourceRegistry: Sendable {
    private var resources: [String: ContentResource] = [:]
    package init() {}
    package mutating func register(url: URL, name: String, mediaType: String? = nil, size: Int64? = nil,
                                   binding: RemoteSourceBinding, limit: Int) throws -> RemoteFileReference {
        guard resources.count < limit else { throw ContentServerError.resourceLimit }
        guard size.map({ $0 >= 0 }) ?? true else { throw ContentServerError.invalidResponse }
        let id = UUID().uuidString, path = "/resources/" + id
        let entry = RemoteEntry(id: id, path: path, name: ContentValidation.filename(name), type: .file,
                                size: size, contentType: mediaType)
        resources[path] = .init(entry: entry, url: url)
        return .init(source: binding, path: path)
    }
    package func stat(path: String) throws -> RemoteEntry {
        guard let resource = resources[path] else { throw ContentServerError.invalidReference }
        return resource.entry
    }
    package func resource(entry: RemoteEntry) throws -> ContentResource {
        guard let path = entry.path, let resource = resources[path], resource.entry == entry else {
            throw ContentServerError.invalidReference
        }
        return resource
    }
    package mutating func removeAll() { resources.removeAll() }
}
