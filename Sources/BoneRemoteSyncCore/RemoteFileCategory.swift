import Foundation

/// 用于文件列表展示的类型提示，不解码内容、检查文件头或验证真实格式。
public enum RemoteFileCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case directory, image, audio, video, document, archive, unknown
}

extension RemoteEntry {
    /// 目录优先；合法具体 MIME 优先于扩展名（未知具体 MIME 返回 unknown）。
    /// 只有 MIME 缺失、无效或通用二进制类型时，才按常见扩展名回退。
    /// 此属性无文件/网络 I/O，不会触发下载，也不作为持久化字段编码。
    public var fileCategory: RemoteFileCategory {
        if isDirectory { return .directory }
        if let mime = Self.normalizedMIME(contentType),
           !["application/octet-stream", "binary/octet-stream", "application/binary"].contains(mime) {
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("text/") { return .document }
            if Self.documentMIMEs.contains(mime) { return .document }
            if Self.archiveMIMEs.contains(mime) { return .archive }
            return .unknown
        }
        // A lone dotfile such as .jpg is a name, not an extension; no path/URL parsing.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .unknown }
        let ext = name[name.index(after: dot)...].lowercased()
        return Self.extensionCategories[ext] ?? .unknown
    }

    private static func normalizedMIME(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 1024,
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        let value = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(token.contains) }) else { return nil }
        return value
    }

    private static let documentMIMEs: Set<String> = [
        "application/pdf", "application/rtf", "application/msword", "application/json", "application/ld+json",
        "application/xml", "application/epub+zip", "application/vnd.apple.pages", "application/vnd.apple.numbers",
        "application/vnd.apple.keynote", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation"
    ]
    private static let archiveMIMEs: Set<String> = [
        "application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
        "application/x-tar", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar-compressed",
        "application/x-bzip2", "application/x-xz"
    ]
    private static let extensionCategories: [String: RemoteFileCategory] = {
        let groups: [(RemoteFileCategory, String)] = [
            (.image, "jpg jpeg png gif webp heic heif avif tif tiff bmp svg ico dng raw cr2 cr3 nef arw"),
            (.audio, "mp3 m4a aac wav flac aiff aif alac opus oga wma"),
            (.video, "mp4 m4v mov mkv webm avi mpg mpeg wmv flv 3gp ogv"),
            (.document, "pdf txt md markdown rtf doc docx xls xlsx ppt pptx csv tsv json xml html htm epub pages numbers key odt ods odp"),
            (.archive, "zip tar gz tgz bz2 tbz2 xz txz 7z rar")
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { category, extensions in
            extensions.split(separator: " ").map { (String($0), category) }
        })
    }()
}
