import Foundation
import Testing
@testable import PMailKit

@Suite struct WebDAVTests {
    @Test func multistatusReadsNamespacesAndStatuses() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/" \
        xmlns:I="http://apple.com/ns/ical/">
          <response>
            <href>/123456/calendars/home/</href>
            <propstat>
              <prop>
                <displayname>Home &amp; Garden</displayname>
                <resourcetype><collection/><C:calendar/></resourcetype>
                <I:calendar-color>#1BADF8FF</I:calendar-color>
                <CS:getctag>"ctag-1"</CS:getctag>
                <C:supported-calendar-component-set><C:comp name="VEVENT"/><C:comp name="VTODO"/></C:supported-calendar-component-set>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
            <propstat>
              <prop><C:calendar-description/></prop>
              <status>HTTP/1.1 404 Not Found</status>
            </propstat>
          </response>
          <response>
            <href>/123456/calendars/home/event%201.ics</href>
            <propstat><prop><C:calendar-data><![CDATA[BEGIN:VCALENDAR
        END:VCALENDAR]]></C:calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat>
          </response>
          <response>
            <href>/123456/calendars/gone/</href>
            <status>HTTP/1.1 404 Not Found</status>
          </response>
        </multistatus>
        """
        let base = try #require(URL(string: "https://p56-caldav.example.com:443/123456/calendars/"))
        let answer = try DAVMultistatus(parsing: Data(xml.utf8), baseURL: base)
        #expect(answer.responses.count == 3)
        let home = answer.responses[0]
        #expect(home.property(.displayName)?.trimmedText == "Home & Garden")
        #expect(home.property(.resourceType)?.child(DAVNamespace.calDAV, "calendar") != nil)
        #expect(home.property(.calendarColor)?.trimmedText == "#1BADF8FF")
        #expect(home.property(.getCTag)?.trimmedText == "\"ctag-1\"")
        #expect(home.property(.supportedCalendarComponentSet)?.children.compactMap { $0.attributes["name"] } == ["VEVENT", "VTODO"])
        #expect(home.property(DAVProperty(DAVNamespace.calDAV, "calendar-description")) == nil)
        #expect(answer.responses[1].property(.calendarData)?.text == "BEGIN:VCALENDAR\nEND:VCALENDAR")
        let resource = answer.url(for: answer.responses[1].href)?.absoluteString
        #expect(resource == "https://p56-caldav.example.com:443/123456/calendars/home/event%201.ics")
        #expect(answer.responses[2].status == 404 && !answer.responses[2].isAvailable)
        #expect(throws: PMailError.self) { try DAVMultistatus(parsing: Data("<html>nope</html>".utf8), baseURL: base) }
        #expect(try DAVMultistatus(parsing: Data(), baseURL: base).responses.isEmpty)
    }

    @Test func requestsAreSignedAndRedirectsFollowed() async throws {
        let transport = StubTransport()
        transport.on("PROPFIND", "/old") { _ in StubTransport.Response(status: 301, body: Data(), headers: ["Location": "/new/"]) }
        transport.on("PROPFIND", "/new") { _ in DAVStub.multistatus(DAVStub.response("/new/", "<d:displayname>Moved</d:displayname>")) }
        transport.on("PROPFIND", "/loop") { _ in StubTransport.Response(status: 307, body: Data(), headers: ["Location": "/loop/"]) }
        let client = WebDAVClient(credential: DAVStub.password, transport: transport)
        let answer = try await client.propfind(try #require(URL(string: "https://dav.example.com/old/")), depth: 0, properties: [.displayName])
        #expect(answer.responses.first?.property(.displayName)?.trimmedText == "Moved")
        #expect(answer.baseURL.absoluteString == "https://dav.example.com/new/")
        let moved = try #require(transport.sent("PROPFIND", "/new").first)
        #expect(moved.httpBody == transport.sent("PROPFIND", "/old").first?.httpBody)
        #expect(DAVStub.header(moved, "Depth") == "0")
        #expect(DAVStub.header(moved, "Authorization") == "Basic " + Data("pug@example.com:app-specific-password".utf8).base64EncodedString())
        #expect(moved.bodyText.contains("<d:propfind") && moved.bodyText.contains("<d:displayname/>"))

        await #expect(throws: PMailError.self) {
            _ = try await client.propfind(try #require(URL(string: "https://dav.example.com/loop/")), depth: 0, properties: [.displayName])
        }
        #expect(transport.sent("PROPFIND", "/loop").count == WebDAVClient.maximumRedirects + 1)
    }

    @Test func refusedTokensAreRefreshedOnce() async throws {
        let transport = StubTransport()
        transport.on("GET", "/card.vcf") { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer token-2"
                ? StubTransport.Response(status: 200, body: Data("BEGIN:VCARD\r\nEND:VCARD\r\n".utf8), headers: ["ETag": "\"7\""])
                : .status(401)
        }
        let tokens = CountingTokens()
        let client = WebDAVClient(credential: .oauth(username: "pug", tokens: tokens), transport: transport)
        let (_, etag) = try await client.get(try #require(URL(string: "https://dav.example.com/card.vcf")))
        #expect(etag == "\"7\"" && tokens.invalidations == 1)

        let refused = WebDAVClient(credential: DAVStub.password, transport: transport)
        await #expect(throws: PMailError.authenticationFailed("")) {
            _ = try await refused.get(try #require(URL(string: "https://dav.example.com/card.vcf")))
        }
    }

    @Test func httpFailuresBecomeFriendlyErrors() {
        #expect(WebDAVClient.error(status: 401) == .authenticationFailed(""))
        #expect(WebDAVClient.error(status: 404) == .notFound)
        #expect(WebDAVClient.error(status: 412) == .conflict)
        #expect(WebDAVClient.error(status: 503) == .http(status: 503, message: "Service unavailable"))
        #expect(DAVResourceName.name(for: "abc-123", fileExtension: "ics") == "abc-123.ics")
        #expect(DAVResourceName.name(for: "weird/uid@host", fileExtension: "ics") != "weird/uid@host.ics")
        let body = String(decoding: DAVRequestBody.calendarMultiget(["/a&b.ics"]), as: UTF8.self)
        #expect(body.contains("<d:href>/a&amp;b.ics</d:href>") && body.contains("<c:calendar-data/>"))
    }
}
