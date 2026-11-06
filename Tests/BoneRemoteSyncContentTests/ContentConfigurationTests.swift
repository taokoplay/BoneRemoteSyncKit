import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncContent

@Suite struct ContentConfigurationTests {
    @Test func validatesConfigurationAndDecodedValues() throws {
        let config = try ContentServerConfiguration(baseURL: URL(string: "https://BOOKS.example/mount")!)
        #expect(config.baseURL.absoluteString == "https://books.example/mount/")
        #expect(try JSONDecoder().decode(ContentServerConfiguration.self, from: JSONEncoder().encode(config)) == config)
        for value in ["http://books.example", "https://user:secret@books.example", "https://books.example/a/../b", "https://books.example/%2f", "https://books.example/?token=secret"] {
            #expect(throws: ContentServerError.invalidConfiguration) {
                try ContentServerConfiguration(baseURL: URL(string: value)!)
            }
        }
        let encoded = try JSONEncoder().encode(config)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["maxConcurrentRequests"] = 0
        #expect(throws: ContentServerError.invalidConfiguration) {
            try JSONDecoder().decode(ContentServerConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: ContentServerError.invalidConfiguration) { try ContentServerConfiguration(baseURL: config.baseURL, timeout: .nan) }
        #expect(throws: ContentServerError.invalidConfiguration) { try ContentServerConfiguration(baseURL: config.baseURL, requestInterval: -.infinity) }
    }

    @Test func preservesMountAndRejectsHostileLinks() throws {
        let client = try ContentHTTPClient(configuration: .init(baseURL: URL(string: "https://books.example/mount/")!), authorization: .bearer("fixture-secret"))
        #expect(try client.url(path: ["api", "标题"], query: [.init(name: "q", value: "a&b")]).absoluteString == "https://books.example/mount/api/%E6%A0%87%E9%A2%98?q=a%26b")
        for value in ["api/items/1", "/api/items/1", "/mount/api/items/1"] {
            #expect(try client.serviceURL(value).path == "/mount/api/items/1")
        }
        for value in ["//evil.test/api", "https://evil.test/api", "https://books.example/outside", "https://books.example:444/mount/api", "http://books.example/mount/api", "../api", "/api/%2e%2e/x", "/api/%252e%252e/x", "/api/a%2fb", "/api/a\\b", "/api/a#fragment"] {
            #expect(throws: ContentServerError.invalidReference) { try client.serviceURL(value) }
        }
        let stream = try client.streamRequest(path: ["api", "items", "1"])
        #expect(stream.headers["Authorization"] == "Bearer fixture-secret")
        #expect(stream.urlRequest().httpShouldHandleCookies == false)
        #expect(!String(reflecting: stream).contains("fixture-secret"))
        #expect(throws: ContentServerError.invalidReference) { try client.url(path: [".."] ) }
    }

    @Test func credentialsAndFilenamesAreBounded() throws {
        let config = try ContentServerConfiguration(baseURL: URL(string: "https://books.example")!)
        #expect(throws: (any Error).self) { try ContentHTTPClient(configuration: config, authorization: .bearer("secret\r\nheader")) }
        #expect(throws: (any Error).self) { try ContentHTTPClient(configuration: config, authorization: .basic(username: "user:other", password: "password")) }
        let name = ContentValidation.filename(String(repeating: "中文👩🏽‍💻", count: 100))
        #expect(!name.isEmpty && name.utf8.count <= 180)
        #expect(ContentValidation.filename("../a:b\\c") == ".._a_b_c")
        #expect(ContentValidation.filename("..") == "download")
    }

    @Test func referencesRejectForgeryAndExpireOnReset() throws {
        var registry = ContentResourceRegistry()
        let binding = RemoteSourceBinding(kind: .komga, identity: "session-fixture")
        let reference = try registry.register(url: URL(string: "https://books.example/file")!, name: "Book.epub", size: 42, binding: binding, limit: 1)
        let entry = try registry.stat(path: reference.displayLocator)
        #expect(try registry.resource(entry: entry).entry.size == 42)
        let forged = RemoteEntry(id: entry.id, path: entry.path, name: entry.name, type: .file, size: 43)
        #expect(throws: ContentServerError.invalidReference) { try registry.resource(entry: forged) }
        #expect(throws: ContentServerError.resourceLimit) {
            try registry.register(url: URL(string: "https://books.example/other")!, name: "Other", binding: binding, limit: 1)
        }
        registry.removeAll()
        #expect(throws: ContentServerError.invalidReference) { try registry.stat(path: reference.displayLocator) }
    }
}
