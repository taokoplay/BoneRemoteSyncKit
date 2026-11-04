import Foundation

/// 保存于来源配置中的可组合文件访问权限。
/// 配置与受控会话始终包含 readOnly；集合本身保留标准 OptionSet 运算语义。
public struct RemoteAccessPermission: OptionSet, Sendable, Hashable, Codable, CaseIterable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    /// 必选基础权限：浏览、查询和下载；与其他权限组合时不限制已授予的写操作。
    public static let readOnly = Self(rawValue: 1 << 0)
    /// 编辑已有文件，以及移动或重命名文件、目录。
    public static let edit = Self(rawValue: 1 << 1)
    /// 新增文件、创建目录和复制；受控会话自动包含读取权限。
    public static let create = Self(rawValue: 1 << 2)
    /// 删除文件或目录。
    public static let delete = Self(rawValue: 1 << 3)

    public static let all: Self = [.readOnly, .edit, .create, .delete]

    /// 供多选界面枚举的四个选项；readOnly 应始终勾选并禁止取消。
    public static let allCases: [Self] = [.readOnly, .edit, .create, .delete]

    private enum Name: String, Codable, CaseIterable {
        case readOnly, edit, create, delete

        var permission: RemoteAccessPermission {
            switch self {
            case .readOnly: .readOnly
            case .edit: .edit
            case .create: .create
            case .delete: .delete
            }
        }
    }

    /// 权限统一使用名称数组，不接受角色字符串或其他格式。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try container.decode([Name].self).reduce(into: Self()) { $0.insert($1.permission) }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isSubset(of: .all) else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Unknown access permission bits"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(Name.allCases.filter { contains($0.permission) })
    }
}
