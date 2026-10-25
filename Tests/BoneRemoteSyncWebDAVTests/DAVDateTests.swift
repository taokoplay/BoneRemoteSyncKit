import Foundation
import Testing
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVDateTests {
    private static let dates = [
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    ]
    private static let expectedDate = Date(timeIntervalSince1970: 784111777)

    @Test(arguments: dates)
    func acceptsAllThreeHTTPDateFormats(value: String) {
        #expect(DAVHTTPDate.parse(value) == Self.expectedDate)
    }

    @Test(arguments: ["", "not a date", "Sun, 32 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994"])
    func rejectsInvalidHTTPDates(value: String) throws {
        #expect(DAVHTTPDate.parse(value) == nil)
        let responses = try DAVMultiStatusParser.parse(Self.xml(dates: [value]))
        #expect(responses.count == 1)
        #expect(responses[0].modifiedAt == nil)
    }

    // A regression to per-property construction must fail this test even if every date remains correct.
    @Test func reusesOneFormatterSetForAllPropertiesInOneXMLParse() throws {
        var constructed: [DateFormatter] = []
        let values = (0..<120).map { Self.dates[$0 % Self.dates.count] }
        let responses = try DAVMultiStatusParser.parse(Self.xml(dates: values), makeDateFormatter: {
            let formatter = DateFormatter()
            constructed.append(formatter)
            return formatter
        })
        #expect(responses.count == 120)
        #expect(responses.allSatisfy { $0.modifiedAt == Self.expectedDate })
        #expect(constructed.count == 3)
    }

    // Retain all real formatters until the workers finish so ObjectIdentifier reuse cannot hide sharing.
    @Test func concurrentXMLParsersOwnDisjointFormatterSets() async throws {
        let registry = FormatterRegistry()
        let xml = Self.xml(dates: Self.dates)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<12 {
                group.addTask {
                    let responses = try DAVMultiStatusParser.parse(xml, makeDateFormatter: {
                        registry.makeFormatter(worker: worker)
                    })
                    #expect(responses.count == 3)
                    #expect(responses.allSatisfy { $0.modifiedAt == Self.expectedDate })
                }
            }
            try await group.waitForAll()
        }
        let groups = registry.identifiers()
        #expect(groups.count == 12)
        #expect(groups.values.allSatisfy { $0.count == 3 })
        #expect(Set(groups.values.flatMap { $0 }).count == 36)
    }

    private static func xml(dates: [String]) -> Data {
        let responses = dates.enumerated().map { index, date in
            """
            <d:response><d:href>/dav/file-\(index)</d:href><d:propstat><d:prop><d:resourcetype/><d:getlastmodified>\(date)</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            """
        }.joined()
        return Data("<d:multistatus xmlns:d=\"DAV:\">\(responses)</d:multistatus>".utf8)
    }
}

private final class FormatterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [Int: [DateFormatter]] = [:]

    func makeFormatter(worker: Int) -> DateFormatter {
        let formatter = DateFormatter()
        lock.lock()
        defer { lock.unlock() }
        formatters[worker, default: []].append(formatter)
        return formatter
    }

    func identifiers() -> [Int: [ObjectIdentifier]] {
        lock.lock()
        defer { lock.unlock() }
        return formatters.mapValues { $0.map(ObjectIdentifier.init) }
    }
}
