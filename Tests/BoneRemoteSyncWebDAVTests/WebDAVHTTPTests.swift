import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite struct WebDAVHTTPTests {
    @Test(arguments: ["nan", "inf", "-1", "1e300", "1.5", "+7", String(repeating: "9", count: 200), "31536001"])
    func invalidRetryAfterIsNotExposedAsInterval(value: String) throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.com/dav/")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value]))
        do {
            try DAVHTTP.validate(response, path: "/", allowed: [207])
            Issue.record("应抛出限流错误")
        } catch let error as RemoteSyncError {
            guard case .rateLimited(let interval) = error else { Issue.record("应为限流错误"); return }
            #expect(interval == nil)
        }
    }

    @Test func localFileErrorsUseTheActualDownloadDestination() {
        let path = "/tmp/downloads/result.txt"
        let notFound = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(DAVHTTP.mapped(notFound, localPath: path) == .notFound(path: path))
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(DAVHTTP.mapped(denied, localPath: path) == .permissionDenied(path: path))
        let conflict = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        #expect(DAVHTTP.mapped(conflict, localPath: path) == .conflict(path: path))
    }

    @Test func retryAfterSupportsDecimalSecondsAndHTTPDate() throws {
        for value in ["0", "7", "31536000", "Tue, 20 Oct 2026 01:00:00 GMT"] {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://example.com/dav/")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value]))
            do {
                try DAVHTTP.validate(response, path: "/", allowed: [207])
                Issue.record("应抛出限流错误")
            } catch let error as RemoteSyncError {
                guard case .rateLimited(let interval) = error else { Issue.record("应为限流错误"); return }
                let seconds = try #require(interval)
                #expect(seconds.isFinite && seconds >= 0 && seconds <= 31_536_000)
                if let expected = Double(value) { #expect(seconds == expected) }
            }
        }
    }
}
