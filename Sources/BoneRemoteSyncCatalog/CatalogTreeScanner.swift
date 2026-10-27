import Foundation

struct CatalogTreeScanner: Sendable {
    let scanner: CatalogDirectoryScanner
    func scan() async -> RemoteCatalogRefreshReport {
        let started = Date()
        return await withTaskCancellationHandler {
            await withTaskGroup(of: CatalogScannedDirectory.self) { group in
                var queue: [(String, Int)] = [(scanner.run.path, 0)]
                var cursor = 0; var active = 0
                var directories = 0; var entries = 0
                var failures: [RemoteCatalogDirectoryFailure] = []
                func schedule() {
                    while !Task.isCancelled && active < scanner.options.concurrency && cursor < queue.count {
                        let (path, depth) = queue[cursor]; cursor += 1; active += 1
                        group.addTask { await scanner.scan(path: path, depth: depth) }
                    }
                }
                schedule()
                while let result = await group.next() {
                    active -= 1
                    if let count = result.published {
                        directories += 1; entries += count
                        if !Task.isCancelled {
                            queue.append(contentsOf: result.children.map { ($0, result.depth + 1) })
                        }
                    } else if let failure = result.failure {
                        failures.append(.init(path: result.path, reason: failure))
                    }
                    if Task.isCancelled { group.cancelAll() }
                    if cursor > 1024 { queue.removeFirst(cursor); cursor = 0 }
                    schedule()
                }
                if Task.isCancelled && !failures.contains(where: { $0.reason == .cancelled }) {
                    failures.append(.init(path: scanner.run.path, reason: .cancelled))
                }
                let state: RemoteCatalogRefreshState = Task.isCancelled ? .cancelled :
                    (failures.isEmpty ? .success : (directories == 0 ? .failed : .partial))
                return .init(refreshID: scanner.run.id, state: state, startedAt: started, finishedAt: Date(),
                    publishedDirectories: directories, publishedEntries: entries,
                    failures: failures.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
            }
        } onCancel: { scanner.permit.cancel() }
    }
}
