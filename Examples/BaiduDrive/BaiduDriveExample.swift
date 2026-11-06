import Foundation
import BoneRemoteSyncKit

/// token 由官方授权或宿主后端取得；此示例不包含 SecretKey 或真实账号凭据。
/// rootPath 必须是已存在且已获授权的 /apps/应用名称（或其子目录）。
func readBaiduFile(
    configuration: BaiduDriveConfiguration,
    token: BaiduDriveToken,
    path: String,
    cacheDirectory: URL,
    refresh: BaiduDriveTokenRefresher? = nil,
    consume: @Sendable (URL) async throws -> Void
) async throws {
    let source = BaiduDriveSource(configuration: configuration, refreshToken: refresh)
    do {
        try await source.connect(token.credential)
        let binding = try await source.connectedBinding()
        let entry = try await source.stat(path: path)
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: cacheDirectory)
        let coordinator = RemoteTransferCoordinator(materializer: materializer, maxConcurrentTransfers: 2)
        do {
            let id = await coordinator.submit(.init(reference: .init(source: binding, itemID: entry.id)))
            let lease = try await coordinator.wait(for: id)
            try await lease.withAccess { try await consume($0) }
            await coordinator.shutdown()
            await materializer.shutdown()
        } catch {
            await coordinator.shutdown()
            await materializer.shutdown()
            throw error
        }
        await source.disconnect()
    } catch {
        await source.disconnect()
        throw error
    }
}

/// 用户选定的非空文件上传到既有根目录下；只操作明确传入的目标，不隐式覆盖。
func uploadBaiduFile(source: BaiduDriveSource, localFile: URL, targetPath: String) async throws -> RemoteEntry {
    try await source.upload(from: localFile, to: targetPath, options: .init(overwrite: false))
}

/// 首次连接取得的用户ID保存进Catalog，下次打开会话时会重新核对账号。
func saveBaiduCatalog(catalog: RemoteCatalog, connectedSource: BaiduDriveSource,
                      credential: RemoteCredential) async throws -> RemoteSourceProfile {
    let userID = try await connectedSource.connectedUserID()
    return try await catalog.saveSource(displayName: "百度网盘", configuration: .baidu(configuration: connectedSource.configuration, userID: userID),
                                        credential: credential, permission: .readOnly)
}

/// 返回给宿主的URL应由系统浏览器/ASWebAuthenticationSession展示；回调交回同一oauth实例。
func startBaiduAuthorization(oauth: BaiduDriveOAuth, callbackURL: URL) async throws -> BaiduDriveAuthorization {
    try await oauth.authorize(redirectURI: callbackURL, flow: .implicit)
}
