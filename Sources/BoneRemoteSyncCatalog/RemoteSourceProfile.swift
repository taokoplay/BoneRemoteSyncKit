import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV
import BoneRemoteSyncOneDrive
import BoneRemoteSyncICloud

/// Catalog 配置、缓存和刷新过程中的错误。
public enum RemoteCatalogError: Error, Sendable, Equatable {
    /// 来源配置不合法，或配置与凭据类型不匹配。
    case invalidConfiguration
    /// 路径不是来源支持的绝对规范路径。
    case invalidPath
    /// 数据库 schema 版本或 application ID 不受支持。
    case unsupportedSchema
    /// SQLite 返回数据库错误码。
    case database(Int32)
    /// Catalog 数据库已经关闭，不能继续操作。
    case closed
    /// 请求的来源、根目录或缓存记录不存在。
    case notFound
    /// 写入方使用的配置版本或选择版本已经过期。
    case staleRevision
    /// 分页令牌无效、过期，或与当前目录请求不匹配。
    case invalidPageToken
    /// 同一来源或根目录已有互斥操作正在执行。
    case busy
    /// 缺少可恢复来源连接所需的授权或凭据。
    case needsAuthorization
    /// 目录结果不完整，不能作为完整目录快照使用。
    case incompleteListing
    /// 来源账号、主盘、绑定或目录身份发生变化。
    case identityChanged
    /// 操作超过条目、深度、时间或其他资源预算。
    case budgetExceeded
    /// 操作被中断，部分临时状态已被清理或保留为中断状态。
    case interrupted
}

/// Catalog 中用于区分具体来源适配器的提供方标识。
public enum RemoteCatalogProvider: String, Sendable, Codable { case local, webDAV, oneDrive, iCloud }

/// 网盘非敏感配置；密码、令牌、bookmark 和运行时连接对象不保存于此。
public enum RemoteSourceConfiguration: Sendable, Codable, Equatable {
    case local(accessReference: String)
    case webDAV(baseURL: URL, timeout: TimeInterval = 60, retry: RemoteCatalogRetryPolicy = .none)
    case oneDrive(clientID: String, redirectURI: URL, driveID: String, timeout: TimeInterval = 60)
    case iCloud(ICloudDriveConfiguration)

    /// 返回配置对应的明确提供方，不根据通用 cloudAPI 猜测品牌。
    public var provider: RemoteCatalogProvider {
        switch self { case .local: .local; case .webDAV: .webDAV; case .oneDrive: .oneDrive; case .iCloud: .iCloud }
    }
    /// 校验来源参数、URL、超时、容器和凭据引用的组合。
    public func validate() throws {
        do {
            switch self {
            case .local(let reference):
                guard CatalogValidation.text(reference, max: 4096) else { throw RemoteCatalogError.invalidConfiguration }
            case .webDAV(let url, let timeout, let retry):
                guard timeout.isFinite, timeout > 0, timeout <= 86400,
                      CatalogValidation.text(url.absoluteString, max: 16384),
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      !url.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
                _ = try WebDAVSource(baseURL: url, timeout: timeout, retryPolicy: retry.adapterPolicy)
            case .oneDrive(let client, let redirect, let drive, let timeout):
                guard CatalogValidation.text(client, max: 4096), CatalogValidation.text(drive, max: 4096),
                      CatalogValidation.text(redirect.absoluteString, max: 16384),
                      !redirect.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
                _ = try OneDriveConfiguration(clientID: client, redirectURI: redirect, timeout: timeout)
            case .iCloud(let configuration):
                _ = try ICloudDriveConfiguration(containerIdentifier: configuration.containerIdentifier,
                    directoryPath: configuration.directoryPath, downloadTimeout: configuration.downloadTimeout,
                    pollInterval: configuration.pollInterval)
            }
        } catch { throw RemoteCatalogError.invalidConfiguration }
    }

    /// Identity-affecting settings, excluding timeouts/retry behavior.
    func sameBinding(as other: Self) -> Bool {
        switch (self, other) {
        case (.local(let a), .local(let b)): return a == b
        case (.webDAV(let a, _, _), .webDAV(let b, _, _)): return a == b
        case (.oneDrive(let a, let b, let c, _), .oneDrive(let x, let y, let z, _)): return a == x && b == y && c == z
        case (.iCloud(let a), .iCloud(let b)): return a == b
        default: return false
        }
    }
}

/// WebDAV 只读请求使用的重试参数；写请求不会自动重试。
public struct RemoteCatalogRetryPolicy: Sendable, Codable, Equatable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let totalTimeout: TimeInterval?
    /// 创建并校验 Catalog 使用的 WebDAV 重试参数。
    public init(maxAttempts: Int = 1, initialDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 8, totalTimeout: TimeInterval? = nil) {
        self.maxAttempts = maxAttempts; self.initialDelay = initialDelay
        self.maxDelay = maxDelay; self.totalTimeout = totalTimeout
    }
    public static let none = Self()
    var adapterPolicy: WebDAVRetryPolicy {
        .init(maxAttempts: maxAttempts, initialDelay: initialDelay, maxDelay: maxDelay, totalTimeout: totalTimeout)
    }
}

/// 已保存的网盘实例配置、来源绑定、凭据引用和文件访问权限。
public struct RemoteSourceProfile: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let bindingID: UUID
    public let configurationRevision: Int64
    public let displayName: String
    public let configuration: RemoteSourceConfiguration
    public let credentialReference: UUID?
    public let permission: RemoteAccessPermission

    private enum CodingKeys: String, CodingKey { case id, bindingID, configurationRevision, displayName, configuration, credentialReference, permission }

    /// 创建并校验网盘配置详情；未显式传入权限时默认允许编辑。
    public init(id: UUID = UUID(), bindingID: UUID = UUID(), configurationRevision: Int64 = 1,
                displayName: String, configuration: RemoteSourceConfiguration, credentialReference: UUID? = nil,
                permission: RemoteAccessPermission = .editor) throws {
        self.id = id; self.bindingID = bindingID; self.configurationRevision = configurationRevision
        self.displayName = displayName; self.configuration = configuration; self.credentialReference = credentialReference
        self.permission = permission
        try validate()
    }
    /// 从持久化数据解码配置详情；旧数据缺失权限字段时按 editor 兼容。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), bindingID: values.decode(UUID.self, forKey: .bindingID),
            configurationRevision: values.decode(Int64.self, forKey: .configurationRevision),
            displayName: values.decode(String.self, forKey: .displayName),
            configuration: values.decode(RemoteSourceConfiguration.self, forKey: .configuration),
            credentialReference: values.decodeIfPresent(UUID.self, forKey: .credentialReference),
            permission: values.decodeIfPresent(RemoteAccessPermission.self, forKey: .permission) ?? .editor)
    }
    /// 校验配置详情、版本、显示名称和凭据引用的组合。
    public func validate() throws {
        try configuration.validate()
        guard configurationRevision > 0, configurationRevision < Int64.max,
              CatalogValidation.text(displayName, max: 1024) else { throw RemoteCatalogError.invalidConfiguration }
        switch configuration {
        case .local: guard credentialReference == nil else { throw RemoteCatalogError.invalidConfiguration }
        case .oneDrive: guard credentialReference != nil else { throw RemoteCatalogError.invalidConfiguration }
        case .webDAV, .iCloud: break
        }
    }
    /// Stable across launches; switching account or endpoint requires a new binding.
    public var sourceNamespace: String { bindingID.uuidString }
}
