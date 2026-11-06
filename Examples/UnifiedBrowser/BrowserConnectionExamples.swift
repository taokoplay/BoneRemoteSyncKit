import Foundation
import BoneRemoteSyncKit

/// 宿主示例，不是 SDK 导出的类型。所有凭据和配置由调用方提供。
/// 成功返回后，宿主保留原 source；结束 Transfer/播放器后 close Browser，再 disconnect source。
public enum BrowserConnectionExamples {
    public static func local(root: URL) async throws -> (source: LocalFileSource, browser: RemoteBrowser) {
        let source = LocalFileSource(root: root)
        return try await openFile(source, credential: .anonymous)
    }

    public static func webDAV(baseURL: URL, credential: RemoteCredential) async throws
        -> (source: WebDAVSource, browser: RemoteBrowser) {
        let source = try WebDAVSource(baseURL: baseURL)
        return try await openFile(source, credential: credential)
    }

    /// 宿主 App 必须提供 iCloud entitlement、容器和目录授权。
    public static func iCloud(configuration: ICloudDriveConfiguration = .standard) async throws
        -> (source: ICloudDriveSource, browser: RemoteBrowser) {
        let source = ICloudDriveSource(configuration: configuration)
        return try await openFile(source, credential: .anonymous)
    }

    /// credential 来自宿主完成 OAuth 后保存的 token.credential。
    /// persistRefreshedToken 应原子写入对应账号的安全凭据存储，不打印令牌。
    public static func oneDrive(
        configuration: OneDriveConfiguration, credential: RemoteCredential,
        persistRefreshedToken: @escaping @Sendable (OneDriveToken) throws -> Void
    ) async throws -> (source: OneDriveSource, browser: RemoteBrowser) {
        let source = OneDriveSource(configuration: configuration, onTokenRefresh: persistRefreshedToken)
        do {
            try await source.connect(credential)
            let binding = try await source.connectedBinding()
            let browser = try RemoteBrowser.files(source, binding: binding,
                validateBinding: { try await source.connectedBinding() })
            return (source, browser)
        } catch { await source.disconnect(); throw error }
    }

    /// rootPath 在 configuration 中限定为已存在且已授权的应用目录。
    public static func baidu(
        configuration: BaiduDriveConfiguration, credential: RemoteCredential,
        expectedUserID: String? = nil, refresh: BaiduDriveTokenRefresher? = nil
    ) async throws -> (source: BaiduDriveSource, browser: RemoteBrowser) {
        let source = BaiduDriveSource(configuration: configuration, refreshToken: refresh)
        do {
            if let expectedUserID { try await source.connect(credential, expectedUserID: expectedUserID) }
            else { try await source.connect(credential) }
            let binding = try await source.connectedBinding()
            let browser = try RemoteBrowser.files(source, binding: binding,
                validateBinding: { try await source.connectedBinding() })
            return (source, browser)
        } catch { await source.disconnect(); throw error }
    }

    public static func opds(configuration: OPDSConfiguration, credential: RemoteCredential = .anonymous) async throws
        -> (source: OPDSSource, browser: RemoteBrowser) {
        let source = OPDSSource(configuration: configuration)
        do {
            try await source.connect(credential)
            return (source, try await RemoteBrowser.opds(source))
        } catch { await source.disconnect(); throw error }
    }

    public static func komga(
        configuration: KomgaConfiguration, credential: RemoteCredential, expectedUserID: String? = nil
    ) async throws -> (source: KomgaSource, browser: RemoteBrowser) {
        try await connectKomgaBrowser(configuration: configuration, credential: credential, expectedUserID: expectedUserID)
    }

    public static func kavita(
        configuration: KavitaConfiguration, credential: RemoteCredential, expectedUserID: Int? = nil
    ) async throws -> (source: KavitaSource, browser: RemoteBrowser) {
        let source = KavitaSource(configuration: configuration)
        do {
            try await source.connect(credential, expectedUserID: expectedUserID)
            return (source, try await RemoteBrowser.kavita(source))
        } catch { await source.disconnect(); throw error }
    }

    public static func audiobookshelf(
        configuration: AudiobookshelfConfiguration, credential: RemoteCredential, expectedUserID: String? = nil
    ) async throws -> (source: AudiobookshelfSource, browser: RemoteBrowser) {
        let source = AudiobookshelfSource(configuration: configuration)
        do {
            try await source.connect(credential, expectedUserID: expectedUserID)
            return (source, try await RemoteBrowser.audiobookshelf(source))
        } catch { await source.disconnect(); throw error }
    }

    /// Local/WebDAV/iCloud 每次示例连接生成新 binding，仅供本次会话和 Transfer 使用。
    /// Catalog 的扫描会话未公开；本示例创建宿主独立管理的来源，不借用其内部连接。
    private static func openFile<Source: RemoteSource>(
        _ source: Source, credential: RemoteCredential
    ) async throws -> (source: Source, browser: RemoteBrowser) {
        do {
            try await source.connect(credential)
            let binding = RemoteSourceBinding(kind: source.kind, identity: UUID().uuidString)
            return (source, try RemoteBrowser.files(source, binding: binding))
        } catch { await source.disconnect(); throw error }
    }
}
