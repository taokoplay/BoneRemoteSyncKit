import Foundation
import BoneRemoteSyncCore

/// Structured iCloud Drive failures exposed to hosts that need source-specific recovery.
///
/// The shared `RemoteSyncError` projection remains available for hosts that only need the
/// common source vocabulary. iCloud-aware hosts should catch this type first.
public enum ICloudDriveError: Error, Sendable, Equatable {
    /// No Apple account identity is available to the process.
    case accountNotSignedIn
    /// An account exists, but Foundation cannot resolve the configured ubiquitous service.
    /// This includes iCloud Drive being disabled and unavailable container/entitlement state;
    /// Foundation does not expose a more reliable public distinction for these cases.
    case driveUnavailable
    /// The named container could not be resolved while the default container was accessible.
    /// Does not prove the container is absent from the developer account.
    case containerNotFound(identifier: String)
    case directoryNotFound(path: String)
    case invalidContainer
    case accountChanged
    case downloadTimedOut(path: String)
    case coordinationFailed(path: String)
    case unresolvedConflict(path: String)
}

extension ICloudDriveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .accountNotSignedIn:
            return "系统未向当前进程提供 iCloud 账号身份"
        case .driveUnavailable:
            return "iCloud Drive 当前未启用或容器不可用"
        case .containerNotFound(let identifier):
            return "iCloud 指定容器不可访问：\(identifier)"
        case .directoryNotFound(let path):
            return "iCloud 配置目录不存在：\(path)"
        case .invalidContainer:
            return "iCloud 容器路径无效"
        case .accountChanged:
            return "iCloud 账号已变化"
        case .downloadTimedOut(let path):
            return "iCloud 文件下载超时：\(path)"
        case .coordinationFailed(let path):
            return "iCloud 文件协调失败：\(path)"
        case .unresolvedConflict(let path):
            return "iCloud 文件存在未解决冲突：\(path)"
        }
    }
}

extension ICloudDriveError {
    /// Maps iCloud-specific failures into the shared source error vocabulary.
    public var remoteSyncError: RemoteSyncError {
        switch self {
        case .accountNotSignedIn:
            return .authenticationFailed(reason: description)
        case .driveUnavailable, .containerNotFound, .accountChanged, .downloadTimedOut:
            return .network(description)
        case .directoryNotFound(let path):
            return .notFound(path: path)
        case .invalidContainer:
            return .unsupported(operation: description)
        case .coordinationFailed(let path), .unresolvedConflict(let path):
            return .conflict(path: path)
        }
    }
}
