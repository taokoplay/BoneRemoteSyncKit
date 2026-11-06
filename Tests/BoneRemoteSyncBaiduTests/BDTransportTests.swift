import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncBaidu

@Suite struct BDTransportTests {
    private let service = URL(string: "https://d.pcs.baidu.com/file?access_token=fixture-original")!

    @Test func requestsDiscardAmbientAndCallerCredentials() throws {
        var original = URLRequest(url: service)
        original.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
        original.setValue("fixture-cookie", forHTTPHeaderField: "Cookie")
        original.setValue(service.absoluteString, forHTTPHeaderField: "Referer")
        original.setValue("fixture-proxy", forHTTPHeaderField: "Proxy-Authorization")
        original.setValue("other.example", forHTTPHeaderField: "Host")
        original.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        original.setValue("bytes=1-", forHTTPHeaderField: "Range")
        original.setValue("multipart/form-data; boundary=fixture", forHTTPHeaderField: "Content-Type")
        let payload = Data("part".utf8)
        let request = try BDHTTPClient.preparedRequest(original, url: service, method: "POST", body: payload,
                                                       timeout: 30, download: false)
        for name in ["Authorization", "Cookie", "Referer", "Proxy-Authorization", "Host", "Range"] {
            #expect(request.value(forHTTPHeaderField: name) == nil)
        }
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixture")
        #expect(request.httpBody == payload && !request.httpShouldHandleCookies)
    }

    @Test func signedRedirectQueriesArePreservedWithoutAddingOriginalToken() throws {
        let target = "https://cdn.baidupcs.com/file?sign=a%2Fb%2Bc&part=1&part=2"
        let redirectResponse = try response(status: 302, headers: ["Location": target])
        #expect(try BDHTTPClient.redirectURL(redirectResponse, from: service, endpoints: .production).absoluteString == target)
        let relative = try response(status: 307, headers: ["Location": "../next?sign=x%2By"])
        #expect(try BDHTTPClient.redirectURL(relative, from: service, endpoints: .production).absoluteString
                == "https://d.pcs.baidu.com/next?sign=x%2By")
        let explicit = "https://cdn.baidupcs.com/file?access_token=fixture-server&sign=abc"
        let explicitResponse = try response(status: 302, headers: ["Location": explicit])
        #expect(try BDHTTPClient.redirectURL(explicitResponse, from: service, endpoints: .production).absoluteString == explicit)
    }

    @Test(arguments: ["https://evil.example/file?access_token=fixture", "https://www.baidu.com/file",
                      "https://baidupcs.com.evil.example/file", "http://d.pcs.baidu.com/file",
                      "https://user:fixture@d.pcs.baidu.com/file", "file:///tmp/file", "https://d.pcs.baidu.com/file\nnext"])
    func redirectsRejectUnsafeLocations(_ location: String) throws {
        let response = try response(status: 302, headers: ["Location": location])
        #expect(throws: BaiduDriveError.self) {
            try BDHTTPClient.redirectURL(response, from: service, endpoints: .production)
        }
    }

    @Test func HTTPSCannotDowngradeEvenIntoFixtureOrigin() throws {
        let endpoints = BDEndpoints(api: URL(string: "http://127.0.0.1:8123/rest/2.0/xpan/")!,
                                    locateUpload: URL(string: "http://127.0.0.1:8123/rest/2.0/pcs/file")!, allowsLoopback: true)
        let response = try response(status: 302, headers: ["Location": "http://127.0.0.1:8123/file"])
        #expect(throws: BaiduDriveError.self) {
            try BDHTTPClient.redirectURL(response, from: service, endpoints: endpoints)
        }
    }

    @Test func metadataHeaderBoundAndDownloadReferenceSizeAreMandatory() throws {
        let limit = BDHTTPState.metadataLimit
        let atLimit = try response(headers: ["Content-Length": String(limit)])
        #expect(try BDHTTPState.validateResponse(atLimit, expectedSize: nil) == Int64(limit))
        let tooLarge = try response(headers: ["Content-Length": String(limit + 1)])
        #expect(throws: BaiduDriveError.responseTooLarge) { try BDHTTPState.validateResponse(tooLarge, expectedSize: nil) }
        let file = try response(headers: ["Content-Length": "3", "Content-Type": "text/html"])
        #expect(try BDHTTPState.validateResponse(file, expectedSize: 3) == 3)
        #expect(throws: RemoteSyncError.integrityMismatch(path: "Baidu resource")) {
            try BDHTTPState.validateResponse(file, expectedSize: 4)
        }
    }

    @Test(arguments: ["-1", "+3", "3, 3", "3.0", "9223372036854775808", "invalid"])
    func invalidContentLengthIsRejected(_ length: String) throws {
        let response = try response(headers: ["Content-Length": length])
        #expect(throws: RemoteSyncError.integrityMismatch(path: "Baidu resource")) {
            try BDHTTPState.validateResponse(response, expectedSize: nil)
        }
    }

    @Test func partialCompressedAndAmbiguousFramingAreRejected() throws {
        for headers in [["Content-Length": "3", "Transfer-Encoding": "chunked"],
                        ["Content-Encoding": "gzip"], ["Content-Range": "bytes 0-2/3"]] {
            let response = try response(headers: headers)
            #expect(throws: RemoteSyncError.integrityMismatch(path: "Baidu resource")) {
                try BDHTTPState.validateResponse(response, expectedSize: 3)
            }
        }
        let partial = try response(status: 206)
        #expect(throws: RemoteSyncError.integrityMismatch(path: "Baidu resource")) {
            try BDHTTPState.validateResponse(partial, expectedSize: 3)
        }
    }

    @Test func onlyCompleteBaiduErrorEnvelopesAreRejectedAsFiles() throws {
        for json in [#"{"errno":-6,"request_id":123}"#, #"{"error_code":-6,"request_id":"id"}"#,
                     #"{"errno":"-6","request_id":"id"}"#, #"{"error_code":"-6","request_id":"id"}"#,
                     #"{"errno":0,"error_code":-6,"request_id":18446744073709551615}"#] {
            #expect(throws: BaiduDriveError.api(code: -6)) {
                try BDHTTPState.validateDownloadEnvelope(Data(json.utf8))
            }
        }
        for document in [#"{"errno":-6}"#, #"{"errno":true,"request_id":123}"#,
                         #"{"errno":0,"request_id":123}"#, #"{"errno":-6,"request_id":false}"#,
                         #"{"errno":-6,"request_id":123"#, "<html><title>Saved document</title></html>"] {
            try BDHTTPState.validateDownloadEnvelope(Data(document.utf8))
        }
    }

    @Test func errorsPreserveTypedFailuresWithoutLeakingRawDescriptions() {
        let raw = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: service,
                                                         NSLocalizedDescriptionKey: "fixture-secret"])
        #expect(BDHTTPClient.mapped(raw) as? RemoteSyncError == .network("Baidu transport failed (-1011)"))
        #expect(BDHTTPClient.mapped(CancellationError()) as? RemoteSyncError == .cancelled)
        #expect(BDHTTPClient.mapped(BaiduDriveError.api(code: -6)) as? BaiduDriveError == .api(code: -6))
        #expect(BDHTTPClient.mapped(RemoteSyncError.notConnected) as? RemoteSyncError == .notConnected)
        #expect(BDHTTPClient.mapped(NSError(domain: "fixture-secret", code: 1)) as? RemoteSyncError
                == .underlying("Baidu operation failed"))
    }

    @Test func stagingOnlyInstallsAfterExplicitCommit() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("file")
        let old = Data("old".utf8), content = Data(repeating: 65, count: 150_000)
        try old.write(to: destination)
        let file = try BDDownloadFile(destination: destination); defer { file.cleanup() }
        try file.validate(overwrite: true)
        try file.open(); try file.write(content); try file.sync()
        #expect(try Data(contentsOf: destination) == old)
        try file.install(overwrite: true, bytes: Int64(content.count))
        file.cleanup()
        #expect(try Data(contentsOf: destination) == content)
        #expect(!FileManager.default.fileExists(atPath: file.staging.path))
    }

    @Test(arguments: [false, true]) func destinationLinksCannotBeOverwritten(_ hardlink: Bool) throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim"), destination = root.appendingPathComponent("file")
        try Data("keep".utf8).write(to: victim)
        if hardlink { try FileManager.default.linkItem(at: victim, to: destination) }
        else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim) }
        let file = try BDDownloadFile(destination: destination)
        #expect(throws: RemoteSyncError.conflict(path: destination.path)) { try file.validate(overwrite: true) }
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }

    @Test func parentAliasesAndEquivalentNamesShareDestinationLock() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let direct = try BDDownloadFile(destination: directory.appendingPathComponent("new/Café.txt"))
        let throughAlias = try BDDownloadFile(destination: alias.appendingPathComponent("new/CAFE\u{301}.TXT"))
        #expect(direct.lockKey == throughAlias.lockKey)
    }

    @Test func replacedStagingIsNeitherInstalledNorRemoved() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("file")
        let file = try BDDownloadFile(destination: destination); defer { file.cleanup() }
        try file.open(); try file.write(Data("new".utf8))
        try FileManager.default.removeItem(at: file.staging)
        try Data("unrelated".utf8).write(to: file.staging)
        #expect(throws: RemoteSyncError.conflict(path: destination.path)) { try file.install(overwrite: false, bytes: 3) }
        file.cleanup()
        #expect(try Data(contentsOf: file.staging) == Data("unrelated".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancelledTaskCannotInstallAndCleanupPreservesOriginal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: destination)
        let file = try BDDownloadFile(destination: destination); defer { file.cleanup() }
        try file.open(); try file.write(Data("new".utf8)); try file.sync()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try file.install(overwrite: true, bytes: 3)
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        file.cleanup()
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.staging.path))
    }

    private func response(status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: service, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func temporaryDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PI_SCRATCH_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("BoneBaiduTransport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
