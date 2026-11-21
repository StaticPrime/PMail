import Foundation
@testable import PMailKit

/// Builds the XML a WebDAV server answers with, for the stub servers in the DAV tests.
enum DAVStub {
    static func multistatus(_ responses: String...) -> StubTransport.Response {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:card="urn:ietf:params:xml:ns:carddav" \
        xmlns:cs="http://calendarserver.org/ns/" xmlns:ical="http://apple.com/ns/ical/">\(responses.joined())</d:multistatus>
        """
        return .text(xml, status: 207, contentType: "application/xml; charset=utf-8")
    }

    /// One resource with properties found.
    static func response(_ href: String, _ properties: String) -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(properties)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func calendarData(_ text: String, etag: String) -> String {
        "<d:getetag>\(escape(etag))</d:getetag><c:calendar-data>\(escape(text))</c:calendar-data>"
    }

    static func addressData(_ text: String, etag: String) -> String {
        "<d:getetag>\(escape(etag))</d:getetag><card:address-data>\(escape(text))</card:address-data>"
    }

    static func saved(etag: String?, status: Int = 201) -> StubTransport.Response {
        StubTransport.Response(status: status, body: Data(), headers: etag.map { ["ETag": $0] } ?? [:])
    }

    static let password = Credential.password(username: "pug@example.com", password: "app-specific-password")

    static func header(_ request: URLRequest?, _ name: String) -> String? {
        request?.value(forHTTPHeaderField: name)
    }
}

/// A token source for testing sign-in refreshes: hands out "token-1", then "token-2" once told the first was turned
/// down.
final class CountingTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 1
    private(set) var invalidations = 0

    func accessToken() async throws -> String {
        lock.withLock { "token-\(generation)" }
    }

    func invalidateAccessToken() async {
        lock.withLock {
            invalidations += 1
            generation += 1
        }
    }
}
