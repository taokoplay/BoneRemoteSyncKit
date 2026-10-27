import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

private final class CatalogLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RemoteLogEvent] = []
    func append(_ event: RemoteLogEvent) { lock.withLock { events.append(event) } }
    var snapshot: [RemoteLogEvent] { lock.withLock { events } }
    var logger: RemoteLogger { .init { [self] in append($0) } }
}

@Suite struct CatalogLoggingTests {
    @Test func classifiesCatalogAndCredentialErrors() {
        let cases: [(any Error, RemoteLogCode, Int32?)] = [
            (RemoteCatalogError.invalidConfiguration, .invalidConfiguration, nil),
            (RemoteCatalogError.invalidPath, .invalidPath, nil),
            (RemoteCatalogError.unsupportedSchema, .unsupportedSchema, nil),
            (RemoteCatalogError.database(6922), .database, 6922),
            (RemoteCatalogError.closed, .closed, nil), (RemoteCatalogError.notFound, .notFound, nil),
            (RemoteCatalogError.staleRevision, .staleRevision, nil), (RemoteCatalogError.invalidPageToken, .invalidPageToken, nil),
            (RemoteCatalogError.busy, .busy, nil), (RemoteCatalogError.needsAuthorization, .authorization, nil),
            (RemoteCatalogError.incompleteListing, .incomplete, nil), (RemoteCatalogError.identityChanged, .identityChanged, nil),
            (RemoteCatalogError.budgetExceeded, .budget, nil), (RemoteCatalogError.interrupted, .interrupted, nil),
            (RemoteCredentialStoreError.unavailable(-25293), .credentialUnavailable, -25293),
            (RemoteCredentialStoreError.missing, .credentialMissing, nil),
            (RemoteCredentialStoreError.alreadyExists, .credentialExists, nil),
            (RemoteCredentialStoreError.invalidRecord, .credentialInvalid, nil),
            (RemoteCredentialStoreError.revoked, .credentialRevoked, nil)
        ]
        let capture = CatalogLogCapture()
        for (error, _, _) in cases { capture.logger.record(error, component: .catalog, operation: .saveSource) }
        #expect(capture.snapshot.map(\.code) == cases.map(\.1))
        #expect(capture.snapshot.map(\.numericCode) == cases.map(\.2))
    }

    @Test func databaseOpenLogsRejectionsWithoutChangingFilesOrErrors() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let capture = CatalogLogCapture()
        #expect(throws: RemoteCatalogError.invalidConfiguration) {
            try SQLiteRemoteCatalogStore(databaseURL: URL(string: "https://secret.invalid/token")!, logger: capture.logger)
        }
        try fixture.sql("CREATE TABLE marker(value TEXT); PRAGMA user_version=999;")
        let before = try Data(contentsOf: fixture.url)
        #expect(throws: RemoteCatalogError.unsupportedSchema) {
            try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        }
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(capture.snapshot.map(\.code) == [.invalidConfiguration, .unsupportedSchema])
        #expect(capture.snapshot.allSatisfy { $0.operation == .databaseOpen && $0.component == .sqlite })
        let serialized = String(decoding: try JSONEncoder().encode(capture.snapshot), as: UTF8.self)
        #expect(!serialized.contains("secret.invalid") && !serialized.contains(fixture.directory.path))
        let broken = RemoteLogger { _ in throw CancellationError() }
        #expect(throws: RemoteCatalogError.unsupportedSchema) {
            try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: broken)
        }
    }

    @Test func ownerConflictAndCloseFailureAreLoggedOnlyOnce() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let capture = CatalogLogCapture()
        let store = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        #expect(capture.snapshot.isEmpty)
        #expect(throws: RemoteCatalogError.busy) { try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger) }
        try await store.close()
        await #expect(throws: RemoteCatalogError.closed) { try await store.close() }
        #expect(capture.snapshot.map(\.code) == [.busy, .closed])
        #expect(capture.snapshot.map(\.operation) == [.databaseOpen, .databaseClose])
    }

    @Test func reopeningReportsRecoveryAfterCommitOnlyOnce() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        _ = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        try await store.close()
        let capture = CatalogLogCapture()
        let reopened = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        let event = try #require(capture.snapshot.first)
        #expect(event.code == .interrupted && event.operation == .databaseRecovery && event.occurrenceCount == 1)
        #expect(try await reopened.status(rootID: root.id).latestRun?.state == "interrupted")
        try await reopened.close()
        let again = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        #expect(capture.snapshot.count == 1)
        try await again.close()
    }

    @Test func highLevelOperationsLogFailuresButDoNotChangeResults() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let capture = CatalogLogCapture()
        let store = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        let root = try await fixture.selected(store)
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets))
        await #expect(throws: RemoteCatalogError.invalidConfiguration) {
            try await catalog.saveSource(displayName: "SECRET", configuration: .local(accessReference: ""))
        }
        await #expect(throws: RemoteCatalogError.invalidPath) { try await catalog.selectRoot(sourceID: root.sourceID, path: "SECRET-relative") }
        await #expect(throws: RemoteCatalogError.notFound) { try await catalog.listCached(rootID: UUID(), directory: "/SECRET") }
        await #expect(throws: RemoteCatalogError.notFound) { try await catalog.refresh(rootID: UUID()) }
        let report = try await catalog.refresh(rootID: root.id) // No resolver: failure is a report, not a throw.
        #expect(report.state == .failed)
        #expect(capture.snapshot.map(\.operation) == [.saveSource, .selectRoot, .listCached, .refresh, .refresh])
        #expect(capture.snapshot.last?.code == .authorization && capture.snapshot.last?.correlationID == report.refreshID)
        _ = try await catalog.listCached(rootID: root.id, directory: "/")
        #expect(capture.snapshot.count == 5)
        #expect(!String(decoding: try JSONEncoder().encode(capture.snapshot), as: UTF8.self).contains("SECRET"))
        try await store.close()
    }

    @Test func corruptDatabaseLogsNumericCodeWithoutErasingIt() throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let bytes = Data("not-a-database-SECRET".utf8); try bytes.write(to: fixture.url)
        let capture = CatalogLogCapture()
        #expect(throws: RemoteCatalogError.self) { try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger) }
        let event = try #require(capture.snapshot.first)
        #expect(capture.snapshot.count == 1 && event.code == .database && event.numericCode != nil)
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test func throwingSinkDoesNotBreakSuccessfulPublicationOrReplaceFailure() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let upstream = fixture.directory.appendingPathComponent("upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: upstream.appendingPathComponent("private-name.txt"))
        let capture = CatalogLogCapture()
        let logger = RemoteLogger { event in capture.append(event); throw CancellationError() }
        let store = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: logger)
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets, localResolver: GatedResolver(upstream)))
        let profile = try await catalog.saveSource(displayName: "Private", configuration: .local(accessReference: "private-reference"))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/")
        #expect(try await catalog.refresh(rootID: root.id).state == .success)
        #expect(try await catalog.listCached(rootID: root.id, directory: "/").entries.count == 1)
        #expect(capture.snapshot.isEmpty)
        await #expect(throws: RemoteCatalogError.invalidPath) { try await catalog.selectRoot(sourceID: profile.id, path: "relative") }
        #expect(capture.snapshot.count == 1 && capture.snapshot.first?.code == .invalidPath)
        try await store.close()
    }

    @Test func reportCancellationIsInfoAndSuccessIsSilent() {
        let capture = CatalogLogCapture()
        capture.logger.recordRefreshReport(.init(refreshID: UUID(), state: .success, startedAt: Date(), finishedAt: Date(),
            publishedDirectories: 1, publishedEntries: 0, failures: []))
        #expect(capture.snapshot.isEmpty)
        capture.logger.recordRefreshReport(.init(refreshID: UUID(), state: .cancelled, startedAt: Date(), finishedAt: Date(),
            publishedDirectories: 0, publishedEntries: 0, failures: [.init(path: "/private", reason: .cancelled)]))
        #expect(capture.snapshot.count == 1 && capture.snapshot.first?.level == .info)
    }

    @Test func failedFinishStillLogsReportAndOriginalStorageFailure() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let capture = CatalogLogCapture()
        let store = try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger)
        let root = try await fixture.selected(store)
        try await store.perform { db in
            try db.script("CREATE TRIGGER fail_finish BEFORE UPDATE ON refresh_runs BEGIN SELECT RAISE(ABORT, 'SECRET-finish'); END;")
        }
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets))
        await #expect(throws: RemoteCatalogError.self) { try await catalog.refresh(rootID: root.id) }
        #expect(capture.snapshot.map(\.code) == [.authorization, .database])
        #expect(Set(capture.snapshot.compactMap(\.correlationID)).count == 1)
        #expect(try await store.status(rootID: root.id).latestRun?.state == "running")
        try await store.close()
    }

    @Test func recoveryFailureHasOwnOperationAndPreservesOriginalError() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        _ = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        try await store.perform { db in
            try db.script("CREATE TRIGGER fail_recovery BEFORE UPDATE ON refresh_runs BEGIN SELECT RAISE(ABORT, 'SECRET-recovery'); END;")
        }
        try await store.close()
        let capture = CatalogLogCapture()
        #expect(throws: RemoteCatalogError.self) { try SQLiteRemoteCatalogStore(databaseURL: fixture.url, logger: capture.logger) }
        let event = try #require(capture.snapshot.first)
        #expect(capture.snapshot.count == 1 && event.operation == .databaseRecovery && event.code == .database)
        #expect(event.numericCode != nil)
        #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("SECRET"))
        try fixture.sql("DROP TRIGGER fail_recovery;")
        let reopened = try fixture.store()
        #expect(try await reopened.status(rootID: root.id).latestRun?.state == "interrupted")
        try await reopened.close()
    }

    @Test func reportPreservesKnownSourceErrorCategories() {
        let errors: [(RemoteSyncError, RemoteLogCode)] = [
            (.notConnected, .notConnected), (.authenticationFailed(reason: "SECRET"), .authorization),
            (.notFound(path: "SECRET"), .notFound), (.permissionDenied(path: "SECRET"), .permission),
            (.unsupported(operation: "SECRET"), .unsupported), (.rateLimited(retryAfter: 10), .rateLimited),
            (.network("SECRET"), .network), (.conflict(path: "SECRET"), .conflict),
            (.integrityMismatch(path: "SECRET"), .integrity), (.cancelled, .cancelled), (.underlying("SECRET"), .unknown)
        ]
        let capture = CatalogLogCapture()
        for (error, _) in errors {
            capture.logger.recordRefreshReport(.init(refreshID: UUID(), state: .failed, startedAt: Date(), finishedAt: Date(),
                publishedDirectories: 0, publishedEntries: 0, failures: [.init(path: "/SECRET", reason: .map(error))]))
        }
        #expect(capture.snapshot.map(\.code) == errors.map(\.1))
    }

    @Test func reportFailuresAreBoundedAggregatesWithoutPaths() throws {
        let capture = CatalogLogCapture(); let id = UUID()
        let failures = (0..<1000).map { RemoteCatalogDirectoryFailure(path: "/SECRET-\($0)", reason: .permission) }
            + [.init(path: "/SECRET-last", reason: .deadline)]
        capture.logger.recordRefreshReport(.init(refreshID: id, state: .partial, startedAt: Date(), finishedAt: Date(),
            publishedDirectories: 1, publishedEntries: 1, failures: failures))
        #expect(capture.snapshot.count == 2)
        #expect(capture.snapshot.first?.code == .permission && capture.snapshot.first?.occurrenceCount == 1000)
        #expect(capture.snapshot.last?.code == .deadline)
        #expect(capture.snapshot.allSatisfy { $0.correlationID == id && $0.component == .catalog })
        #expect(!String(decoding: try JSONEncoder().encode(capture.snapshot), as: UTF8.self).contains("SECRET"))
    }
}
