#if os(macOS)
import Foundation
import Testing
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVResponseStreamTests {
    @Test func largeCallbackIsSplitAndBackpressuredWithoutRejectingValidBody() async throws {
        let state = DAVBodyState()
        let payload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
        let finished = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    state.receive(payload)
                    state.finish(nil)
                    continuation.resume()
                }
            }
        }
        var count = 0
        while let chunk = try await state.next() {
            #expect(chunk.count <= 64 * 1024)
            #expect(chunk == Data(repeating: 0xA5, count: chunk.count))
            count += chunk.count
            if count % (256 * 1024) == 0 { await Task.yield() }
        }
        await finished.value
        #expect(count == payload.count)
        #expect(state.bufferedBytes == 0)
        #expect(state.peakBufferedBytes <= 256 * 1024)
    }

    @Test func poolDisconnectWakesBackpressuredProducer() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let pool = DAVHTTP.session(timeout: 10)
        defer { pool.invalidateAndCancel() }
        let stream = try await DAVHTTP.stream(session: pool, request: URLRequest(url: server.baseURL.appendingPathComponent("big.bin")))
        defer { stream.cancel() }
        // Callback boundaries need not align with capacity, so a blocked producer can be below 256KiB.
        for _ in 0..<100_000 {
            if stream.bufferedBytes >= 128 * 1024 { break }
            await Task.yield()
        }
        #expect(stream.bufferedBytes >= 128 * 1024)
        pool.invalidateAndCancel()
        await #expect(throws: (any Error).self) { try await stream.next() }
        #expect(stream.bufferedBytes == 0)
    }

    @Test func downloadProgressWorkDoesNotOccupySourceActor() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let release = DispatchSemaphore(value: 0)
        let timeouts = DAVProgress()
        let (events, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            try await source.download(path: "/big.bin", to: server.file("actor-free.bin"), options: .init(progress: { count in
                if count == 0 {
                    continuation.yield(1)
                    if release.wait(timeout: .now() + 5) == .timedOut { timeouts.record(1) }
                }
            }))
        }
        defer { release.signal(); task.cancel(); continuation.finish() }
        for await _ in events { break }
        // The progress callback is stalled before reading the body, but list can still use the actor/session pool.
        let page = try await source.list(path: "/")
        #expect(!page.entries.isEmpty)
        #expect(timeouts.snapshot().isEmpty)
        task.cancel()
        release.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        await source.disconnect()
    }

    @Test func poolReusesIdleSessionAndRejectsAcquireAfterClosing() throws {
        let pool = DAVHTTP.session(timeout: 10)
        let first = try pool.acquire()
        pool.release(first, reusable: true)
        let next = try pool.acquire()
        #expect(first === next)
        pool.release(next, reusable: true)
        pool.invalidateAndCancel()
        #expect(throws: (any Error).self) { try pool.acquire() }
    }

    @Test func largeDownloadDeliversAllBytesWithoutPerByteIteration() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file("big.bin")
        _ = try await source.download(path: "/big.bin", to: target)
        let input = try FileHandle(forReadingFrom: target)
        defer { try? input.close() }
        let pattern = Data((0...255).map(UInt8.init))
        let expected = (0..<256).reduce(into: Data()) { data, _ in data.append(pattern) }
        var count = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            #expect(chunk == expected)
            count += chunk.count
        }
        #expect(count == 32 * 1024 * 1024)
        await source.disconnect()
    }

    @Test func requestAfterPoolDisconnectThrowsWithoutCreatingAnInvalidatedTask() async throws {
        let pool = DAVHTTP.session(timeout: 10)
        pool.invalidateAndCancel()
        await #expect(throws: CancellationError.self) {
            try await DAVHTTP.stream(session: pool, request: URLRequest(url: URL(string: "http://127.0.0.1:1/never")!))
        }
    }

    @Test func alreadyCancelledRequestDoesNotReachTheServer() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let pool = DAVHTTP.session(timeout: 10)
        defer { pool.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DAVHTTP.stream(session: pool, request: URLRequest(url: server.baseURL.appendingPathComponent("hello.txt")))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try server.requests().isEmpty)
    }

    @Test func queuedChunksDrainInOrderAndCancellationResolvesHeaderWaiter() async throws {
        let state = DAVBodyState()
        for value in 0..<24 { state.receive(Data(repeating: UInt8(value), count: 8192)) }
        #expect(state.bufferedBytes == 24 * 8192)
        state.finish(nil)
        for value in 0..<24 { #expect(try await state.next() == Data(repeating: UInt8(value), count: 8192)) }
        #expect(try await state.next() == nil)
        #expect(state.bufferedBytes == 0)
        let waiting = DAVBodyState()
        let task = Task { try await waiting.headers() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        waiting.finish(nil) // completion after cancel must not resume the waiter twice.
    }

    @Test func slowBufferedStreamDoesNotBlockAnotherRequestOnSameSession() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let session = DAVHTTP.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        let slow = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("large.bin")))
        defer { slow.cancel() }
        // Read nothing from the large response. Its task must not block the delegate queue.
        let fast = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("hello.txt")))
        defer { fast.cancel() }
        var data = Data()
        while let chunk = try await fast.next() { data.append(chunk) }
        #expect(String(data: data, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        #expect(slow.peakBufferedBytes <= 256 * 1024)
    }

    @Test func chunksPreserveOrderAndBoundBufferedBytesUnderSlowConsumer() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let session = DAVHTTP.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        let stream = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("large.bin")))
        defer { stream.cancel() }
        #expect(stream.response.statusCode == 200)
        var count = 0
        var chunkCount = 0
        while let chunk = try await stream.next() {
            let expected = Data((0..<chunk.count).map { UInt8((count + $0) % 256) })
            #expect(chunk == expected)
            count += chunk.count
            chunkCount += 1
            if chunkCount % 8 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        #expect(count == 3_145_728)
        #expect(chunkCount < count / 100)
        #expect(stream.peakBufferedBytes <= 256 * 1024)
    }

    @Test func cancellingWaitingConsumerFinishesRatherThanHanging() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let session = DAVHTTP.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        let stream = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("slow.bin")))
        let task = Task {
            while let _ = try await stream.next() { try Task.checkCancellation() }
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        stream.cancel()
        #expect(stream.bufferedBytes == 0)
    }

    @Test func streamExposesRedirectWithoutFollowingItAndPropagatesTruncation() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let session = DAVHTTP.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        let redirect = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("redirect.txt")))
        #expect(redirect.response.statusCode == 302)
        redirect.cancel()
        let truncated = try await DAVHTTP.stream(session: session, request: URLRequest(url: server.baseURL.appendingPathComponent("truncated.txt")))
        defer { truncated.cancel() }
        await #expect(throws: (any Error).self) { while let _ = try await truncated.next() {} }
        #expect(try server.requests().allSatisfy { !($0["path"] as! String).hasPrefix("/dav/redirect/") })
    }
}
#endif
