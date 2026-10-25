import Foundation
import Testing
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVParserTests {
    @Test func readsOnlySuccessfulDAVPropertiesAndPreservesETag() throws {
        let xml = """
        <?xml version="1.0"?><x:multistatus xmlns:x="DAV:" xmlns:evil="urn:other">
        <x:response><x:href>/dav/a%20b.txt</x:href>
        <x:propstat><x:prop><x:getetag>bad</x:getetag><x:getcontentlength>999</x:getcontentlength></x:prop><x:status>HTTP/1.1 404 Not Found</x:status></x:propstat>
        <x:propstat><x:prop><x:resourcetype/><x:getcontentlength>12</x:getcontentlength><x:getetag>&quot;v1&amp;2&quot;</x:getetag><x:getlastmodified>Tue, 20 Oct 2026 01:00:00 GMT</x:getlastmodified><x:getcontenttype>text/plain</x:getcontenttype><evil:getcontentlength>999</evil:getcontentlength></x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat>
        </x:response>
        <x:response><x:href>/dav/folder/</x:href><x:propstat><x:prop><x:resourcetype><x:collection/></x:resourcetype></x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response>
        </x:multistatus>
        """
        let responses = try DAVMultiStatusParser.parse(Data(xml.utf8))
        #expect(responses.count == 2)
        #expect(responses[0].href == "/dav/a%20b.txt")
        #expect(responses[0].size == 12)
        #expect(responses[0].etag == "\"v1&2\"")
        #expect(responses[0].modifiedAt == Date(timeIntervalSince1970: 1792458000))
        #expect(responses[0].contentType == "text/plain")
        #expect(!responses[0].isDirectory)
        #expect(responses[1].isDirectory)
    }

    @Test(arguments: ["<html>not DAV</html>", "<d:multistatus xmlns:d='DAV:'><d:response>", "<!DOCTYPE d [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><multistatus xmlns='DAV:'/>"])
    func rejectsMalformedNonDAVAndDTD(xml: String) {
        #expect(throws: (any Error).self) { try DAVMultiStatusParser.parse(Data(xml.utf8)) }
    }

    @Test func acceptsCDATAForHrefsAndProperties() throws {
        let xml = """
        <multistatus xmlns="DAV:"><response><href><![CDATA[/dav/a%20b.txt]]></href><propstat><prop><resourcetype/><getcontentlength><![CDATA[12]]></getcontentlength><getetag><![CDATA["v1"]]></getetag></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        let item = try #require(DAVMultiStatusParser.parse(Data(xml.utf8)).first)
        #expect(item.href == "/dav/a%20b.txt")
        #expect(item.size == 12)
        #expect(item.etag == "\"v1\"")
    }

    @Test func failedResponseIsNotInventedAsZeroByteFile() throws {
        let xml = """
        <multistatus xmlns="DAV:"><response><href>/dav/missing</href><status>HTTP/1.1 404 Not Found</status></response></multistatus>
        """
        let responses = try DAVMultiStatusParser.parse(Data(xml.utf8))
        #expect(responses.first?.status == 404)
        #expect(responses.first?.hasProperties == false)
    }
}
