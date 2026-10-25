import Foundation
import BoneRemoteSyncCore

/// Request body for Graph writes. File bodies avoid loading the whole upload into memory.
enum ODUploadBody: Sendable {
    case data(Data)
    case file(URL)
}

struct ODHTTPResponse: Sendable {
    let response: HTTPURLResponse
    let data: Data
    let transferredBytes: Int64?
    init(response: HTTPURLResponse, data: Data, transferredBytes: Int64? = nil) {
        self.response = response; self.data = data; self.transferredBytes = transferredBytes
    }
}

/// Ephemeral requests have no ambient credentials, cookie jar or automatic redirects.
/// Each operation owns a serial delegate queue. invalidate cancels and wakes all waiters.
final class ODHTTPClient: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var active: [UUID: ODHTTPState] = [:]
    let timeout: TimeInterval
    init(timeout: TimeInterval) { self.timeout = timeout }
    deinit { cancel() }
    func send(
        _ request: URLRequest,
        limit: Int = 8 * 1024 * 1024,
        sink: ODDownloadSink? = nil,
        body: ODUploadBody? = nil,
        uploadProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ODHTTPResponse {
        let id = UUID()
        let state = ODHTTPState(limit: limit, sink: sink, uploadProgress: uploadProgress)
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            active[id] = state
            state.start(request, timeout: timeout, body: body)
        }
        defer { _ = lock.withLock { active.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler { try await state.result() } onCancel: { state.cancel() }
    }
    func cancel() {
        let states = lock.withLock { closed = true; let values = Array(active.values); active.removeAll(); return values }
        states.forEach { $0.cancel() }
    }
    static func validate(_ response: HTTPURLResponse, path: String) throws {
        switch response.statusCode {
        case 200, 201, 202, 204: return
        case 401: throw RemoteSyncError.authenticationFailed(reason: "OneDrive 授权无效")
        case 403: throw RemoteSyncError.permissionDenied(path: path)
        case 404: throw RemoteSyncError.notFound(path: path)
        case 409, 412: throw RemoteSyncError.conflict(path: path)
        case 429: throw RemoteSyncError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599: throw RemoteSyncError.network("OneDrive HTTP \(response.statusCode)")
        default: throw RemoteSyncError.unsupported(operation: "OneDrive HTTP \(response.statusCode)")
        }
    }
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value), seconds <= 31_536_000 { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = max(0, date.timeIntervalSinceNow)
        return seconds.isFinite && seconds <= 31_536_000 ? seconds : nil
    }
    static func mapped(_ error: Error) -> RemoteSyncError {
        if let error = error as? RemoteSyncError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let error = error as? URLError { return .network("OneDrive 传输失败（\(error.errorCode)）") }
        return .underlying("OneDrive 操作失败") // Never include URLs, response bodies or credentials.
    }
}
