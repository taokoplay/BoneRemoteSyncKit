import Foundation
import BoneRemoteSyncCore

/// A single pull consumer. The delegate callback waits when the application queue is full;
/// task.suspend alone cannot bound callbacks that URLSession has already enqueued.
/// The queue is at most 256KiB. URLSession's own buffers and the active callback Data are external.
final class DAVBodyState: @unchecked Sendable {
    private let condition = NSCondition()
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var headerWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var bodyWaiter: CheckedContinuation<Data?, Error>?
    private var terminal: Result<Void, Error>?
    private var queue: [Data] = []
    private var head = 0
    private var size = 0
    private var peak = 0
    private var suspended = false
    private let capacity = 256 * 1024
    private let chunkSize = 64 * 1024

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try operation()
    }
    var bufferedBytes: Int { locked { size } }
    var peakBufferedBytes: Int { locked { peak } }

    func start(_ task: URLSessionDataTask) {
        locked {
            self.task = task
            if terminal != nil { task.cancel() } else { task.resume() }
        }
    }

    func headers() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                locked {
                    if let terminal, case .failure(let error) = terminal { continuation.resume(throwing: error) }
                    else if let response { continuation.resume(returning: response) }
                    else if terminal != nil { continuation.resume(throwing: RemoteSyncError.network("WebDAV 缺少 HTTP 响应")) }
                    else { headerWaiter = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func receive(_ response: URLResponse) -> Bool {
        locked {
            guard terminal == nil, let response = response as? HTTPURLResponse else { return false }
            self.response = response
            headerWaiter?.resume(returning: response)
            headerWaiter = nil
            return true
        }
    }

    func receive(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        var position = 0
        while position < data.count, terminal == nil {
            let count = min(chunkSize, data.count - position)
            while terminal == nil, bodyWaiter == nil, size > capacity - count {
                condition.wait() // releases the lock; next()/cancel()/disconnect can always wake us.
            }
            guard terminal == nil else { return }
            let chunk = data.subdata(in: position..<(position + count))
            position += count
            if let waiter = bodyWaiter {
                bodyWaiter = nil
                waiter.resume(returning: chunk)
            } else {
                queue.append(chunk)
                size += chunk.count
                peak = max(peak, size)
                if size >= capacity, !suspended {
                    suspended = true
                    task?.suspend()
                }
            }
        }
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                locked {
                    if head < queue.count {
                        let data = queue[head]
                        queue[head] = Data()
                        head += 1
                        size -= data.count
                        if head == queue.count { queue.removeAll(keepingCapacity: true); head = 0 }
                        else if head >= 32 { queue.removeFirst(head); head = 0 }
                        if suspended, size <= 64 * 1024 {
                            suspended = false
                            if terminal == nil { task?.resume() }
                        }
                        condition.broadcast()
                        continuation.resume(returning: data)
                    } else if let terminal {
                        switch terminal {
                        case .success: continuation.resume(returning: nil)
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    } else if bodyWaiter != nil {
                        continuation.resume(throwing: RemoteSyncError.unsupported(operation: "WebDAV 数据流只允许单个消费者"))
                    } else { bodyWaiter = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func finish(_ error: (any Error)?) {
        locked {
            finishLocked(error.map { .failure($0) } ?? .success(()), discard: false)
            task = nil
        }
    }

    func cancel() {
        locked {
            queue.removeAll(); head = 0; size = 0
            if terminal == nil { finishLocked(.failure(CancellationError()), discard: true) }
            condition.broadcast()
            task?.cancel()
            task = nil
        }
    }

    private func finishLocked(_ result: Result<Void, Error>, discard: Bool) {
        guard terminal == nil else { return }
        terminal = result
        if discard { queue.removeAll(); head = 0; size = 0 }
        condition.broadcast()
        if let waiter = headerWaiter {
            headerWaiter = nil
            switch result {
            case .failure(let error): waiter.resume(throwing: error)
            case .success: waiter.resume(throwing: RemoteSyncError.network("WebDAV 缺少 HTTP 响应"))
            }
        }
        if let waiter = bodyWaiter {
            bodyWaiter = nil
            switch result {
            case .failure(let error): waiter.resume(throwing: error)
            case .success: waiter.resume(returning: nil)
            }
        }
    }
}

final class DAVResponseStream: Sendable {
    let response: HTTPURLResponse
    private let state: DAVBodyState
    init(response: HTTPURLResponse, state: DAVBodyState) { self.response = response; self.state = state }
    deinit { state.cancel() }
    func next() async throws -> Data? { try await state.next() }
    func cancel() { state.cancel() }
    var bufferedBytes: Int { state.bufferedBytes }
    var peakBufferedBytes: Int { state.peakBufferedBytes }
}

extension DAVHTTP {
    static func stream(session pool: DAVHTTPSession, request: URLRequest, uploadFile: URL? = nil,
                       progress: (@Sendable (Int64) -> Void)? = nil) async throws -> DAVResponseStream {
        try Task.checkCancellation()
        let state = DAVBodyState()
        try pool.start(request: request, state: state, uploadFile: uploadFile, progress: progress)
        do { return DAVResponseStream(response: try await state.headers(), state: state) }
        catch { state.cancel(); throw error }
    }

    /// Wake blocked callbacks immediately, rather than waiting for a queued didComplete delegate call.
    static func invalidate(_ session: URLSession) {
        (session.delegate as? DAVSessionDelegate)?.cancelAll()
        session.invalidateAndCancel()
    }
}
