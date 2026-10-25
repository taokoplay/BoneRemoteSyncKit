import Foundation
import BoneRemoteSyncCore

/// 重定向全部拒绝；不跨 origin 携带认证，也不悄悄降级到 HTTP。
final class DAVSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private struct Pending {
        let body: DAVBodyState
        let progress: (@Sendable (Int64) -> Void)?
        let completed: @Sendable (Bool) -> Void
    }
    private var bodies: [Int: Pending] = [:]

    func register(_ body: DAVBodyState, for task: URLSessionTask, progress: (@Sendable (Int64) -> Void)? = nil,
                  completed: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { bodies[task.taskIdentifier] = Pending(body: body, progress: progress, completed: completed) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let callback = lock.withLock { bodies[task.taskIdentifier]?.progress }
        callback?(totalBytesSent)
    }

    func cancelAll() {
        let values = lock.withLock { bodies.values.map(\.body) }
        values.forEach { $0.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let body = lock.withLock { bodies[dataTask.taskIdentifier]?.body }
        completionHandler(body?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier]?.body }?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let pending = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) }
        pending?.body.finish(error)
        pending?.completed(error == nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Basic 已由请求头提供；不从系统凭据存储中自动尝试其他用户/密钥。
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}

enum DAVHTTP {
    static func session(timeout: TimeInterval) -> DAVHTTPSession { DAVHTTPSession(timeout: timeout) }

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 24 * 60 * 60)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: DAVSessionDelegate(), delegateQueue: nil)
    }

    static func validateForRetry(_ response: HTTPURLResponse, path: String, allowed: Set<Int>, now: Date = Date()) throws {
        guard !allowed.contains(response.statusCode) else { return }
        throw DAVRequestFailure.http(status: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap { retryAfter($0, now: now) }, path: path)
    }

    static func validate(_ response: HTTPURLResponse, path: String, allowed: Set<Int>) throws {
        if allowed.contains(response.statusCode) { return }
        throw statusError(response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap { retryAfter($0) }, path: path)
    }

    private static func statusError(_ status: Int, retryAfter: TimeInterval?, path: String) -> RemoteSyncError {
        switch status {
        case 300..<400: return RemoteSyncError.unsupported(operation: "WebDAV 重定向；请使用最终地址")
        case 401, 407: return RemoteSyncError.authenticationFailed(reason: nil)
        case 403: return RemoteSyncError.permissionDenied(path: path)
        case 404, 410: return RemoteSyncError.notFound(path: path)
        case 409, 412, 416, 423: return RemoteSyncError.conflict(path: path)
        case 429:
            return RemoteSyncError.rateLimited(retryAfter: retryAfter)
        case 500..<600: return RemoteSyncError.network("WebDAV HTTP \(status)")
        case 408: return RemoteSyncError.network("WebDAV HTTP 408")
        default: return RemoteSyncError.underlying("WebDAV 非预期 HTTP 状态：\(status)")
        }
    }

    /// 只接受 HTTP 非负整数或日期；超过一年视为不可用，避免非有限/越界输入流向调度与 UI。
    static func retryAfter(_ value: String, now: Date = Date()) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let interval: TimeInterval
        if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            guard let seconds = UInt64(value) else { return nil }
            interval = TimeInterval(seconds)
        } else {
            guard let date = DAVHTTPDate.parse(value) else { return nil }
            let delta = date.timeIntervalSince(now)
            guard delta.isFinite else { return nil }
            interval = max(0, delta)
        }
        guard interval.isFinite, interval >= 0, interval <= 31_536_000 else { return nil }
        return interval
    }

    static func mapped(_ error: any Error, localPath: String? = nil) -> RemoteSyncError {
        if let failure = error as? DAVRequestFailure {
            switch failure {
            case .http(let status, let retryAfter, let path): return statusError(status, retryAfter: retryAfter, path: path)
            case .nonRetryable(let underlying): return mapped(underlying, localPath: localPath)
            }
        }
        if error is DAVOperationTimedOut { return .network("WebDAV 操作总时限已到") }
        if let remote = error as? RemoteSyncError { return remote }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let url = error as? URLError {
            if url.code == .userAuthenticationRequired || url.code == .userCancelledAuthentication {
                return .authenticationFailed(reason: nil)
            }
            // 不透传包含 URL、用户名或认证信息的系统错误描述。
            return .network("WebDAV 网络错误（\(url.code.rawValue)）")
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            let path = localPath ?? (ns.userInfo[NSFilePathErrorKey] as? String) ?? "本地文件"
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path: path)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return .permissionDenied(path: path)
            case NSFileWriteFileExistsError: return .conflict(path: path)
            default: break
            }
        }
        return .underlying("WebDAV 操作失败（\(ns.domain):\(ns.code)）")
    }
}
