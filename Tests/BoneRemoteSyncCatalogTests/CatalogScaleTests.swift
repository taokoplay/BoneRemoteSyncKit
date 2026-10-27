import Foundation
import Darwin
import Testing
@testable import BoneRemoteSyncCatalog

@Suite struct CatalogScaleTests {
    // Supplemental scale verification, not a latency SLA or a benchmark of a real provider.
    @Test func hundredThousandEntriesUseParentIndexAndVersionedPages() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        let started = Date()
        try await seed(store, root: root, path: "/", entries: (0..<100).map { catalogEntry(String(format: "/d%03d", $0), directory: true) })
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        for d in 0..<100 {
            let path = String(format: "/d%03d", d)
            let ticket = try await store.beginDirectory(run: run, path: path)
            for page in 0..<5 {
                try await store.stage((page * 200..<(page + 1) * 200).map { catalogEntry(path + String(format: "/f%04d.txt", $0)) }, ticket: ticket)
            }
            #expect(try await store.publish(ticket: ticket, permit: .init()) == 1000)
        }
        try await store.finishRun(run, state: "success")
        var token: String?; var total = 0
        repeat {
            let page = try await store.listCached(rootID: root.id, directory: "/d050", query: .init(limit: 137, pageToken: token))
            total += page.entries.count; token = page.nextPageToken
        } while token != nil
        #expect(total == 1000)
        let (count, plan) = try await store.perform { db in
            let count = try db.scalar("SELECT count(*) FROM catalog_entries")
            let statement = try db.statement("EXPLAIN QUERY PLAN SELECT payload FROM catalog_entries WHERE root=? AND parent=? AND parent_epoch=? ORDER BY directory DESC,name COLLATE BINARY,path COLLATE BINARY LIMIT 100", [.uuid(root.id), .text("/d050"), .text("epoch")])
            var details = ""
            while try statement.step() { details += statement.text(3) }
            return (count, details)
        }
        #expect(count == 100100 && plan.contains("entries_parent_order"))
        let wal = (try? FileManager.default.attributesOfItem(atPath: fixture.url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("CATALOG_SCALE entries=100100 seconds=\(Date().timeIntervalSince(started)) peakRSSBytes=\(usage.ru_maxrss) walBytes=\(wal)")
        try await store.close()
    }
}
