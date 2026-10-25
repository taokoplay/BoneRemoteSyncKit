import Foundation

/// 路径归一化。
///
/// 所有来源对外统一用 POSIX 风格、以 "/" 开头、结尾不带 "/" 的路径，根为 "/"。
/// 转换（SMB 的 "\"、WebDAV 的编码、云盘的 fileId）全部留在适配器内部，
/// 不允许把差异泄漏到上层。
public enum RemotePath {
    /// 归一化为 "/a/b" 形式；根返回 "/"。
    ///
    /// 会消解 "." 与 ".."，因此不能用来做目录穿越攻击：
    /// "/a/../../etc" 归一化后是 "/etc"，仍在来源根之内。
    public static func normalize(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// 拼接。base 为 "/" 时不会产生 "//"。
    public static func join(_ base: String, _ component: String) -> String {
        normalize(normalize(base) + "/" + component)
    }

    /// 父路径；根没有父路径，返回 nil。
    public static func parent(of path: String) -> String? {
        let normalized = normalize(path)
        guard normalized != "/" else { return nil }
        let components = normalized.split(separator: "/").dropLast()
        return "/" + components.joined(separator: "/")
    }

    /// 最后一段名称；根返回 ""。
    public static func name(of path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? ""
    }

    /// 来源内相对路径（不带前导 "/"），供需要相对定位的适配器使用。
    public static func relative(_ path: String) -> String {
        let normalized = normalize(path)
        return normalized == "/" ? "" : String(normalized.dropFirst())
    }
}
