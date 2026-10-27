import Foundation
import Testing
import BoneRemoteSyncCore

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RemoteLogEvent] = []
    func append(_ event: RemoteLogEvent) { lock.withLock { events.append(event) } }
    var snapshot: [RemoteLogEvent] { lock.withLock { events } }
}

@Suite struct RemoteLoggingTests {
    @Test func mapsEverySyncErrorWithoutRetainingDescriptions() throws {
        let marker = "SECRET-password-token-https://private.invalid/private-file"
        let cases: [(RemoteSyncError, RemoteLogCode)] = [
            (.notConnected, .notConnected), (.authenticationFailed(reason: marker), .authentication),
            (.notFound(path: marker), .notFound), (.permissionDenied(path: marker), .permission),
            (.unsupported(operation: marker), .unsupported), (.rateLimited(retryAfter: .infinity), .rateLimited),
            (.network(marker), .network), (.conflict(path: marker), .conflict),
            (.integrityMismatch(path: marker), .integrity), (.cancelled, .cancelled), (.underlying(marker), .unknown)
        ]
        let capture = LogCapture(); let logger = RemoteLogger { capture.append($0) }
        let correlation = UUID(); let start = Date()
        for (error, _) in cases { logger.record(error, component: .webDAV, operation: .download, correlationID: correlation) }
        #expect(capture.snapshot.map(\.code) == cases.map(\.1))
        #expect(capture.snapshot.allSatisfy { $0.schemaVersion == 1 && $0.correlationID == correlation && $0.timestamp >= start })
        let data = try JSONEncoder().encode(capture.snapshot)
        #expect(!String(decoding: data, as: UTF8.self).contains(marker))
        #expect(try JSONDecoder().decode([RemoteLogEvent].self, from: data) == capture.snapshot)
    }

    @Test func unknownNSErrorDoesNotExposeUserInfoOrDomain() throws {
        let capture = LogCapture(); let logger = RemoteLogger { capture.append($0) }
        logger.record(NSError(domain: "SECRET-domain", code: 123, userInfo: [NSLocalizedDescriptionKey: "SECRET-message", NSFilePathErrorKey: "/SECRET-path"]), component: .local, operation: .list)
        let event = try #require(capture.snapshot.first)
        #expect(event.code == .unknown && event.numericCode == nil)
        #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("SECRET"))
    }

    @Test func cancellationSeverityFilteringAndThrowingSink() {
        let capture = LogCapture(); let logger = RemoteLogger { capture.append($0) }
        logger.record(CancellationError(), component: .core, operation: .walk)
        #expect(capture.snapshot.first?.level == .info)
        let errors = RemoteLogger(minimumLevel: .error) { capture.append($0) }
        errors.record(CancellationError(), component: .core, operation: .walk)
        errors.record(RemoteSyncError.notFound(path: "/private"), component: .local, operation: .stat)
        #expect(capture.snapshot.count == 1)
        errors.record(RemoteSyncError.network("secret"), component: .oneDrive, operation: .connect)
        #expect(capture.snapshot.count == 2)
        // A Sendable synchronized capture proves one failed delivery is not recursively logged or retried.
        let failing = LogCapture()
        let broken = RemoteLogger { event in failing.append(event); throw CancellationError() }
        broken.record(RemoteSyncError.network("secret"), component: .oneDrive, operation: .connect)
        #expect(failing.snapshot.count == 1)
        RemoteLogger.disabled.record(RemoteSyncError.network("secret"), component: .core, operation: .connect)
    }

    @Test func sharedLoggerCanDeliverFromConcurrentTasks() async {
        let capture = LogCapture(); let logger = RemoteLogger { capture.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { logger.record(RemoteSyncError.cancelled, component: .core, operation: .download) }
            }
        }
        #expect(capture.snapshot.count == 100)
    }
}
