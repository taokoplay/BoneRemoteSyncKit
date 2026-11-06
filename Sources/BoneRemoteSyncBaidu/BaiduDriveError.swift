import Foundation
import BoneRemoteSyncCore

/// 脱敏错误，不携带 token、下载地址或原始响应正文。
public enum BaiduDriveError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidResponse
    case invalidReference
    case invalidCursor
    case responseTooLarge
    /// 即使请求同步，服务端仍返回了异步任务；结果未知，不得自动重放写入。
    case asynchronousResult
    case api(code: Int)
}

enum BDAPI {
    static func error(_ code: Int) -> any Error {
        switch code {
        case -6, 110, 1110, 20016, 20017, 31045: RemoteSyncError.authenticationFailed(reason: "百度网盘授权失效")
        case -3, -9, 31066, 31190: RemoteSyncError.notFound(path: "Baidu resource")
        case -7, 6, 20011, 20013, 20015, 20020, 31024: RemoteSyncError.permissionDenied(path: "Baidu resource")
        case -8, 31061: RemoteSyncError.conflict(path: "Baidu resource")
        case 20012, 31034: RemoteSyncError.rateLimited(retryAfter: nil)
        default: BaiduDriveError.api(code: code)
        }
    }
    static func checked(_ value: BDJSON, requireCode: Bool = true) throws -> BDJSON {
        guard value.object != nil else { throw BaiduDriveError.invalidResponse }
        let codes = [value["errno"], value["error_code"]].compactMap { $0 }
        guard !requireCode || !codes.isEmpty else { throw BaiduDriveError.invalidResponse }
        for raw in codes {
            guard let code = raw.int else { throw BaiduDriveError.invalidResponse }
            if code != 0 { throw error(code) }
        }
        return value
    }
}

/// Typed JSON keeps uint64 fs_id/uk exact across actor boundaries and avoids Double rounding.
indirect enum BDJSON: Codable, Sendable, Equatable {
    case object([String: BDJSON]), array([BDJSON]), string(String), number(String), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Int64.self) { self = .number(String(x)) }
        else if let x = try? c.decode(UInt64.self) { self = .number(String(x)) }
        else if let x = try? c.decode([String: BDJSON].self) { self = .object(x) }
        else if let x = try? c.decode([BDJSON].self) { self = .array(x) }
        else if (try? c.decode(Double.self)) != nil { self = .null } // unused fractional metadata is not an ID
        else { throw BaiduDriveError.invalidResponse }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x):
            if let signed = Int64(x) { try c.encode(signed) }
            else if let unsigned = UInt64(x) { try c.encode(unsigned) }
            else { throw BaiduDriveError.invalidResponse }
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> BDJSON? { object?[key] }
    var object: [String: BDJSON]? { if case .object(let x) = self { x } else { nil } }
    var array: [BDJSON]? { if case .array(let x) = self { x } else { nil } }
    var string: String? { if case .string(let x) = self { x } else { nil } }
    var int: Int? {
        switch self { case .string(let x), .number(let x): Int(x); default: nil }
    }
    var uintString: String? {
        switch self {
        case .string(let x), .number(let x):
            guard !x.isEmpty, x.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(x), n > 0 else { return nil }
            return String(n)
        default: return nil
        }
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
