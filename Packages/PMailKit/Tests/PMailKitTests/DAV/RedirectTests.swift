import Foundation
import Testing
@testable import PMailKit

/// A calendar server that sends its well-known address elsewhere (`/.well-known/caldav` to `/dav/cal`, as many do):
/// through a real URLSession, the redirect comes back to WebDAV, which follows it with the same request and sign-in.
/// URLSession following it itself leaves the sign-in behind, and the server then refuses it as a wrong password.
struct RedirectTests {
    /// The server, inside URLSession: it redirects the well-known address and answers only requests signed in.
    final class Server: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [(method: String, path: String, signedIn: Bool)] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dav.redirect.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let client else { return }
            let signedIn = request.value(forHTTPHeaderField: "Authorization") != nil
            Self.lock.withLock { Self.seen.append((request.httpMethod ?? "", url.path, signedIn)) }
            if url.path == "/.well-known/caldav" {
                let redirect = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: ["Location": "/dav/cal/"])!
                var next = request
                next.url = URL(string: "https://dav.redirect.test/dav/cal/")
                client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
                client.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
                client.urlProtocolDidFinishLoading(self)
                return
            }
            let status = signedIn ? 207 : 401
            let body = signedIn ? """
            <?xml version="1.0" encoding="UTF-8"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
            <d:response><d:href>/dav/cal/</d:href><d:propstat><d:prop><c:calendar-home-set><d:href>/dav/cal/pug/</d:href>\
            </c:calendar-home-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """ : ""
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func aRedirectedServerGetsTheSignInToo() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Server.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration), followsRedirects: false)

        // The redirect itself comes back.
        var request = URLRequest(url: try #require(URL(string: "https://dav.redirect.test/.well-known/caldav")), method: "PROPFIND")
        request.setValue("Basic cHVnOnB3", forHTTPHeaderField: "Authorization")
        let (_, response) = try await transport.data(for: request)
        #expect(response.statusCode == 301 && response.value(forHTTPHeaderField: "Location") == "/dav/cal/", "not followed by URLSession")

        // WebDAV follows it, signed in, and finds the calendars.
        Server.lock.withLock { Server.seen = [] }
        let client = WebDAVClient(credential: .password(username: "pug", password: "pw"), transport: transport)
        let answer = try await client.propfind(try #require(URL(string: "https://dav.redirect.test/.well-known/caldav")), depth: 0,
                                               properties: [.currentUserPrincipal, .calendarHomeSet])
        #expect(answer.firstURL(of: .calendarHomeSet)?.absoluteString == "https://dav.redirect.test/dav/cal/pug/")
        let seen = Server.lock.withLock { Server.seen }
        #expect(seen.map(\.path) == ["/.well-known/caldav", "/dav/cal"], "\(seen)")
        #expect(seen.allSatisfy { $0.method == "PROPFIND" && $0.signedIn }, "the same request, signed in, at the new address")
    }

    @Test func calendarAndContactsServersLeaveRedirectsToWebDAV() throws {
        // Their transport, as the app makes them, hands redirects back.
        func value(_ subject: Any, at path: [String]) -> Any? {
            var current = subject
            for label in path {
                guard let child = Mirror(reflecting: current).children.first(where: { $0.label == label }) else { return nil }
                current = child.value
            }
            return current
        }
        let server = try #require(URL(string: "https://dav.redirect.test/"))
        let calendar = CalDAVCalendarService(serverURL: server, credential: .password(username: "pug", password: "pw"), ownerEmail: "pug@redirect.test")
        let contacts = CardDAVContactsService(serverURL: server, credential: .password(username: "pug", password: "pw"))
        #expect(value(calendar, at: ["client", "transport", "followsRedirects"]) as? Bool == false)
        #expect(value(contacts, at: ["client", "transport", "followsRedirects"]) as? Bool == false)
    }
}
