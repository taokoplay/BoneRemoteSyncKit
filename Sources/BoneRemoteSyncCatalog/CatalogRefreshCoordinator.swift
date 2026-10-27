import Foundation

/// A monotonic timeout cancels network work and permanently closes the publication permit.
/// The caller still awaits resource cleanup; cancellation cannot forcibly terminate an uncooperative host resolver.
struct CatalogRefreshCoordinator: Sendable {
    let store: SQLiteRemoteCatalogStore
    let sessions: RemoteCatalogSessionFactory
    let run: CatalogRun
    let options: RemoteCatalogRefreshOptions

    private enum Event: Sendable { case report(RemoteCatalogRefreshReport), deadline, timerCancelled }
    func runRefresh() async -> RemoteCatalogRefreshReport {
        let started = Date()
        let permit = CatalogCommitPermit(timeout: options.timeout)
        return await withTaskCancellationHandler {
            await withTaskGroup(of: Event.self) { group in
                group.addTask {
                    let session: CatalogSession
                    do {
                        try Task.checkCancellation()
                        let profile = try await store.profile(id: run.root.sourceID)
                        guard profile.bindingID == run.root.bindingID, profile.configurationRevision == run.configurationRevision else {
                            throw RemoteCatalogError.staleRevision
                        }
                        session = try await sessions.open(profile: profile)
                    } catch {
                        return .report(.init(refreshID: run.id, state: Task.isCancelled ? .cancelled : .failed,
                            startedAt: started, finishedAt: Date(), publishedDirectories: 0, publishedEntries: 0,
                            failures: [.init(path: run.path, reason: .map(error))]))
                    }
                    let scanner = CatalogDirectoryScanner(store: store, source: session.source, run: run, options: options, budget: .init(options), permit: permit)
                    let report = await CatalogTreeScanner(scanner: scanner).scan()
                    await session.close()
                    return .report(report)
                }
                group.addTask {
                    do { try await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000)); return .deadline }
                    catch { return .timerCancelled }
                }
                var expired = false
                var report: RemoteCatalogRefreshReport?
                while let event = await group.next() {
                    switch event {
                    case .deadline: expired = true; permit.cancel(); group.cancelAll()
                    case .report(let result): report = result; group.cancelAll()
                    case .timerCancelled: break
                    }
                }
                // Both children always return an Event; the work child always supplies a report.
                let result = report!
                let cancelled = Task.isCancelled
                expired = expired || (permit.isExpired && result.state != .success)
                let terminal: RemoteCatalogFailureReason? = cancelled ? .cancelled : (expired ? .deadline : nil)
                var failures = result.failures
                if let terminal {
                    failures = failures.filter { $0.reason != .cancelled }
                    failures.append(.init(path: run.path, reason: terminal))
                }
                return .init(refreshID: run.id,
                    state: cancelled ? .cancelled : (expired ? (result.publishedDirectories == 0 ? .failed : .partial) : result.state),
                    startedAt: started, finishedAt: Date(), publishedDirectories: result.publishedDirectories,
                    publishedEntries: result.publishedEntries, failures: failures)
            }
        } onCancel: { permit.cancel() }
    }
}
