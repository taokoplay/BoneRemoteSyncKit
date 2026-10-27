import Foundation
import BoneRemoteSyncCore

/// iCloud Drive-specific diagnostics that are useful to a host UI without exposing
/// Foundation's platform-dependent error objects as part of the public contract.
public enum ICloudDriveError: Error, Sendable, Equatable {
    case unavailable
    case containerNotFound(identifier: String)
    case invalidContainer
    case accountChanged
    case downloadTimedOut(path: String)
    case coordinationFailed(path: String)
    case unresolvedConflict(path: String)
}

extension ICloudDriveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unavailable: return "iCloud Drive 当前不可用"
        case .containerNotFound: return "iCloud 容器不存在或未配置"
        case .invalidContainer: return "iCloud 容器路径无效"
        case .accountChanged: return "iCloud 账号已变化"
        case .downloadTimedOut(let path): return "iCloud 文件下载超时：\(path)"
        case .coordinationFailed(let path): return "iCloud 文件协调失败：\(path)"
        case .unresolvedConflict(let path): return "iCloud 文件存在未解决冲突：\(path)"
        }
    }
}

extension ICloudDriveError {
    /// Maps iCloud-specific failures into the shared source error vocabulary.
    public var remoteSyncError: RemoteSyncError {
        switch self {
        case .unavailable, .containerNotFound, .accountChanged:
            return .network(description)
        case .invalidContainer:
            return .unsupported(operation: description)
        case .downloadTimedOut:
            return .network(description)
        case .coordinationFailed(let path):
            return .conflict(path: path)
        case .unresolvedConflict(let path):
            return .conflict(path: path)
        }
    }
}
