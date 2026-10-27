import Foundation
import BoneRemoteSyncCore

enum CatalogValidation {
    static func text(_ value: String, max: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= max && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func path(_ path: String) throws {
        guard !path.utf8.contains(0), path.utf8.count <= 16384,
              path == RemotePath.normalize(path), !path.contains("\\") else { throw RemoteCatalogError.invalidPath }
    }
    static func contains(_ path: String, in root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteCatalogError.invalidConfiguration }
    }
}
