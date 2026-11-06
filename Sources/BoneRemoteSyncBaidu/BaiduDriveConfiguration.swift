import Foundation
import BoneRemoteSyncCore

/// 个人网盘中已获授权的应用目录。SDK 不持有应用 SecretKey。
public struct BaiduDriveConfiguration: Sendable, Codable, Equatable {
    public let appKey: String
    public let rootPath: String
    public let timeout: TimeInterval
    public let maxConcurrentTransfers: Int
    public let maxUploadBytes: Int64

    public init(appKey: String, rootPath: String, timeout: TimeInterval = 60,
                maxConcurrentTransfers: Int = 3, maxUploadBytes: Int64 = 4 * 1024 * 1024 * 1024) throws {
        guard !appKey.isEmpty, appKey.utf8.count <= 256,
              appKey.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }),
              rootPath.hasPrefix("/apps/"), rootPath.split(separator: "/").count >= 2,
              rootPath == RemotePath.normalize(rootPath), rootPath.utf8.count <= 4096,
              !rootPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              timeout.isFinite, timeout > 0, timeout <= 86400,
              (1...8).contains(maxConcurrentTransfers), (1...Int64(4 * 1024 * 1024 * 1024)).contains(maxUploadBytes) else {
            throw BaiduDriveError.invalidConfiguration
        }
        self.appKey = appKey; self.rootPath = rootPath; self.timeout = timeout
        self.maxConcurrentTransfers = maxConcurrentTransfers; self.maxUploadBytes = maxUploadBytes
    }
    private enum CodingKeys: String, CodingKey { case appKey, rootPath, timeout, maxConcurrentTransfers, maxUploadBytes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(appKey: c.decode(String.self, forKey: .appKey), rootPath: c.decode(String.self, forKey: .rootPath),
                      timeout: c.decode(TimeInterval.self, forKey: .timeout), maxConcurrentTransfers: c.decode(Int.self, forKey: .maxConcurrentTransfers),
                      maxUploadBytes: c.decode(Int64.self, forKey: .maxUploadBytes))
    }
}

struct BDEndpoints: Sendable {
    let api: URL
    let locateUpload: URL
    let allowsLoopback: Bool
    static let production = Self(api: URL(string: "https://pan.baidu.com/rest/2.0/xpan/")!,
                                 locateUpload: URL(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!, allowsLoopback: false)
}

/// 经宿主取得的令牌。刷新回调应先安全持久化完整的新令牌再返回，旧refresh_token只能用一次。
public struct BaiduDriveToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date) throws {
        guard BDLocation.validToken(accessToken), refreshToken.map(BDLocation.validToken) ?? true,
              expiresAt.timeIntervalSinceReferenceDate.isFinite else { throw BaiduDriveError.invalidConfiguration }
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
    public var credential: RemoteCredential { .oauth(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt) }
    public var description: String { "BaiduDriveToken(***)" }
    public var debugDescription: String { description }
}

/// Callback must exchange/refresh through a trusted host service; no client secret is bundled.
public typealias BaiduDriveTokenRefresher = @Sendable (BaiduDriveToken) async throws -> BaiduDriveToken
