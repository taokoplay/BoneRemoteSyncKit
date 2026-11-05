/// 脱敏的协议错误；不携带原始 URL、响应正文或凭据。
public enum OPDSError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidURL
    case disallowedOrigin
    case invalidDocument
    case resourceLimit
    case invalidReference
    case invalidCursor
    case unsupportedAcquisition
    case unsupportedSearch
    case unexpectedContentType
    case redirectLimit
}
