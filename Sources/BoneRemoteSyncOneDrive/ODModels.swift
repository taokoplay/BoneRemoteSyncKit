import Foundation
import BoneRemoteSyncCore

struct ODDrive: Decodable { let id: String; let driveType: String }
struct ODPage: Decodable {
    let value: [ODItem]
    let next: String?
    enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
}
struct ODItem: Decodable {
    struct Empty: Decodable {}
    struct File: Decodable { let mimeType: String? }
    struct Parent: Decodable { let driveId: String?; let id: String? }
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let lastModifiedDateTime: String?
    private struct OptionalDateString: Decodable {
        let value: String?
        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }
    private let createdDateTime: OptionalDateString?
    let file: File?
    let folder: Empty?
    let remoteItem: Empty?
    let package: Empty?
    let deleted: Empty?
    let parentReference: Parent?
    let downloadURL: String?
    enum CodingKeys: String, CodingKey {
        case id, name, size, eTag, lastModifiedDateTime, createdDateTime, file, folder, remoteItem, package, deleted, parentReference
        case downloadURL = "@microsoft.graph.downloadUrl"
    }
    func validate(drive: String, path: String) throws {
        guard !id.isEmpty, id.utf8.count <= 8192, remoteItem == nil, package == nil, deleted == nil,
              (folder != nil) != (file != nil), size.map({ $0 >= 0 }) ?? true,
              parentReference?.driveId == nil || parentReference?.driveId == drive,
              path == "/" || (!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")) else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 不支持的条目或跨盘引用")
        }
    }
    func entry(drive: String, path: String?) -> RemoteEntry {
        let formatter = ISO8601DateFormatter()
        var modified = lastModifiedDateTime.flatMap { formatter.date(from: $0) }
        if modified == nil { formatter.formatOptions.insert(.withFractionalSeconds); modified = lastModifiedDateTime.flatMap { formatter.date(from: $0) } }
        let created = RemoteCreationDate.parse(createdDateTime?.value)
        return RemoteEntry(id: ODLocation.identity(drive: drive, item: id), path: path,
            name: path == "/" ? "" : name, type: folder != nil ? .directory : .file,
            size: folder != nil ? nil : size, modifiedAt: modified, etag: eTag, contentType: file?.mimeType, createdAt: created)
    }
}
