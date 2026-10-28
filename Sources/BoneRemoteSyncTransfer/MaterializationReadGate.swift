import Foundation

/// Per-materializer admission for download operations (not metadata requests).
/// Queued cancellations remove their waiter; acquired slots are always released.
actor MaterializationReadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active < limit { active += 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
}
