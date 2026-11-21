import Foundation
import Testing
@testable import PMailKit

@Suite struct WebClientTests {
    private func url(_ path: String) throws -> URL {
        try #require(URL(string: "https://api.example.com" + path))
    }

    @Test func sendsTheBearerTokenAndReadsJSON() async throws {
        let transport = StubTransport()
        transport.on("GET", "/thing") { _ in .json(#"{"name": "Waffles", "count": 3}"#) }
        let json = try await WebClient.test(transport).get(url("/thing"))
        #expect(json["name"].string == "Waffles")
        #expect(json["count"].int == 3)
        let request = try #require(transport.requests.first)
        #expect(request.authorization == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func aTurnedDownTokenIsReplacedAndTriedOnce() async throws {
        let transport = StubTransport()
        let tokens = WebTestTokens()
        transport.on("GET", "/thing") { _ in
            transport.sent("GET", "/thing").count == 1 ? .json(#"""
            {"error": {"code": 401, "message": "Invalid Credentials"}}
            """#, status: 401)
                : .json(#"{"ok": true}"#)
        }
        let json = try await WebClient.test(transport, tokens: tokens).get(url("/thing"))
        #expect(json["ok"].bool == true)
        #expect(tokens.invalidations == 1)
        #expect(transport.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func aSecondTurnDownFailsTheSignIn() async throws {
        let transport = StubTransport()
        let tokens = WebTestTokens()
        transport.on("GET", "/thing") { _ in .json(#"{"error": {"code": 401, "message": "Invalid Credentials"}}"#, status: 401) }
        let client = WebClient.test(transport, tokens: tokens)
        await #expect(throws: PMailError.authenticationFailed("Invalid Credentials")) { try await client.get(url("/thing")) }
        #expect(transport.requests.count == 2)
        #expect(tokens.invalidations == 1)
    }

    @Test func busyAnswersWaitAsAskedAndTryAgain() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in
            switch transport.sent("GET", "/thing").count {
            case 1: StubTransport.Response(status: 429, body: Data(), headers: ["Retry-After": "2"])
            case 2: .status(503)
            default: .json(#"{"ok": true}"#)
            }
        }
        let json = try await WebClient.test(transport, pauses: pauses).get(url("/thing"))
        #expect(json["ok"].bool == true)
        #expect(transport.requests.count == 3)
        #expect(pauses.waits == [2, 2])  // As asked, then the default second wait.
    }

    @Test func busyAnswersGiveUpAfterTwoRetriesAndWaitsAreCapped() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in
            StubTransport.Response(status: 429, body: Data(#"{"error": {"message": "Rate limit exceeded"}}"#.utf8),
                                   headers: ["Retry-After": "120"])
        }
        let client = WebClient.test(transport, pauses: pauses)
        await #expect(throws: PMailError.http(status: 429, message: "Rate limit exceeded")) { try await client.get(url("/thing")) }
        #expect(transport.requests.count == 3)
        #expect(pauses.waits == [5, 5])
    }

    @Test func errorAnswersBecomePMailErrors() async throws {
        let transport = StubTransport()
        transport.on("GET", "/missing") { _ in .json(#"{"error": {"code": 404, "message": "Not Found"}}"#, status: 404) }
        transport.on("GET", "/gone") { _ in .status(410) }
        transport.on("GET", "/stale") { _ in .status(412) }
        transport.on("GET", "/bad") { _ in
            .json(#"{"error": {"code": 400, "message": "Invalid label: Label_99", "status": "INVALID_ARGUMENT"}}"#, status: 400)
        }
        transport.on("GET", "/denied") { _ in
            .json(#"""
            {"error": {"code": "ErrorAccessDenied", "message": "Access is denied. Check credentials and try again."}}
            """#, status: 403)
        }
        transport.on("GET", "/broken") { _ in .text("<html>Bad Gateway</html>", status: 502, contentType: "text/html") }
        transport.on("GET", "/garbled") { _ in .text("{not json") }
        let client = WebClient.test(transport)
        await #expect(throws: PMailError.notFound) { try await client.get(url("/missing")) }
        await #expect(throws: PMailError.notFound) { try await client.get(url("/gone")) }
        await #expect(throws: PMailError.conflict) { try await client.get(url("/stale")) }
        await #expect(throws: PMailError.http(status: 400, message: "Invalid label: Label_99")) { try await client.get(url("/bad")) }
        await #expect(throws: PMailError.http(status: 403, message: "Access is denied. Check credentials and try again.")) {
            try await client.get(url("/denied"))
        }
        await #expect(throws: PMailError.http(status: 502, message: "")) { try await client.get(url("/broken")) }
        await #expect(throws: PMailError.protocolError("the answer wasn’t valid JSON")) { try await client.get(url("/garbled")) }
    }

    @Test func retryAfterReadsSecondsAndDates() {
        let now = WebFixtures.date("2026-10-21T07:27:57Z")
        #expect(WebClient.retryDelay("Wed, 21 Oct 2026 07:28:00 GMT", attempt: 1, cap: 5, now: now) == 3)
        #expect(WebClient.retryDelay("2", attempt: 1, cap: 5) == 2)
        #expect(WebClient.retryDelay("120", attempt: 1, cap: 5) == 5)
        #expect(WebClient.retryDelay(nil, attempt: 2, cap: 5) == 2)
        #expect(WebClient.retryDelay("-4", attempt: 1, cap: 5) == 0)
    }

    @Test func fanOutKeepsOrderAndAtMostTheLimitRunning() async throws {
        let gauge = Gauge()
        let results = try await WebClient.concurrentMap(Array(1...20), limit: 3) { number -> Int in
            await gauge.enter()
            try await Task.sleep(nanoseconds: 2_000_000)
            await gauge.leave()
            return number * 10
        }
        #expect(results == (1...20).map { $0 * 10 })
        let peak = await gauge.peak
        #expect(peak <= 3 && peak >= 2)
    }

    @Test func graphBatchesTwentyAtATimeAndRetriesThrottledRequests() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("POST", "/v1.0/$batch") { request in
            let isFirst = transport.sent("POST", "/v1.0/$batch").count == 1
            let answers = request.bodyJSONValue["requests"].array.map { item -> String in
                let id = item["id"].string ?? ""
                if isFirst && id == "3" {
                    return #"""
                    {"id": "3", "status": 429, "headers": {"Retry-After": "3"},
                     "body": {"error": {"code": "ApplicationThrottled", "message": "Too many requests"}}}
                    """#
                }
                return #"{"id": "\#(id)", "status": 200, "headers": {}, "body": {}}"#
            }
            return .json(#"{"responses": [\#(answers.joined(separator: ","))]}"#)
        }
        let client = WebClient.test(transport, pauses: pauses)
        let requests = (1...25).map { GraphBatchRequest(method: "PATCH", url: "/me/messages/m\($0)", body: ["isRead": true]) }
        try await client.graphBatch(requests)
        let batches = transport.sent("POST", "/v1.0/$batch").map { $0.bodyJSONValue["requests"].array }
        #expect(batches.map(\.count) == [20, 5, 1])
        #expect(batches[0][0] == ["id": "1", "method": "PATCH", "url": "/me/messages/m1", "body": ["isRead": true],
                                  "headers": ["Content-Type": "application/json"]])
        #expect(batches[2][0]["url"].string == "/me/messages/m3")
        #expect(pauses.waits == [3])
    }

    @Test func graphBatchFailuresAreReportedAndMissingItemsSkipped() async throws {
        let transport = StubTransport()
        transport.on("POST", "/v1.0/$batch") { _ in
            .json(#"""
            {"responses": [
                {"id": "1", "status": 204, "body": null},
                {"id": "2", "status": 404, "body": {"error": {"code": "ErrorItemNotFound",
                 "message": "The specified object was not found in the store."}}},
                {"id": "3", "status": 403, "body": {"error": {"code": "ErrorAccessDenied", "message": "Access is denied."}}}
            ]}
            """#)
        }
        let client = WebClient.test(transport)
        let requests = (1...3).map { GraphBatchRequest(method: "DELETE", url: "/me/messages/m\($0)") }
        await #expect(throws: PMailError.http(status: 403, message: "Access is denied.")) { try await client.graphBatch(requests) }
        #expect(transport.requests.count == 1)
    }

    @Test func graphLinksStayOnGraph() {
        #expect(Graph.url(fromLink: "https://graph.microsoft.com/v1.0/me/messages?$skip=50") != nil)
        #expect(Graph.url(fromLink: "https://elsewhere.example.com/v1.0/me/messages") == nil)
        #expect(Graph.url(fromLink: "http://graph.microsoft.com/v1.0/me/messages") == nil)
    }

    @Test func jsonValuesReadSafelyAndWriteSorted() throws {
        let json = try JSONValue.parse(Data(#"""
        {"name": "Waffles", "age": 3, "good": true, "flag": 1, "tags": ["pug", 7], "nested": {"deep": null},
         "big": "1763740800000"}
        """#.utf8))
        #expect(json["name"].string == "Waffles")
        #expect(json["age"].int == 3)
        #expect(json["good"].bool == true)
        #expect(json["flag"].bool == nil)
        #expect(json["flag"].int == 1)
        #expect(json["tags"].strings == ["pug"])
        #expect(json["tags"][5].isNull)
        #expect(json["nested"]["deep"]["deeper"].isNull)
        #expect(json["missing"].array.isEmpty)
        #expect(json["name"]["oops"].isNull)
        #expect(json["big"].int == 1_763_740_800_000)
        let body: JSONValue = ["b": 1, "a": [true, "x/y"], "c": .null, "d": 2.5]
        #expect(String(decoding: body.encoded(), as: UTF8.self) == #"{"a":[true,"x/y"],"b":1,"c":null,"d":2.5}"#)
        #expect(try JSONValue.parse(Data(" \n".utf8)) == .null)
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("{nope".utf8)) }
    }

    @Test func urlsEscapePathsAndQueriesStrictly() throws {
        let calendar = WebURL.segment("en.usa#holiday@group.v.calendar.google.com")
        let url = try WebURL.make("https://example.com/calendars/\(calendar)/events",
                                  query: [("q", "from:a+b@example.com & more"), ("labelIds", "INBOX"), ("labelIds", "CATEGORY_SOCIAL")])
        #expect(url.absoluteString == "https://example.com/calendars/en.usa%23holiday@group.v.calendar.google.com/events"
                + "?q=from:a%2Bb@example.com%20%26%20more&labelIds=INBOX&labelIds=CATEGORY_SOCIAL")
        #expect(WebURL.segment("a/b?c") == "a%2Fb%3Fc")
        #expect(WebURL.path("people/c123") == "people/c123")
    }

    @Test func webDatesReadEveryForm() throws {
        let expected = WebFixtures.date("2026-11-23T15:00:00Z")
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(WebDate.parse("2026-11-23T10:00:00-05:00") == expected)
        #expect(WebDate.parse("2026-11-23T16:00:00+0100") == expected)
        #expect(WebDate.parse("2026-11-23T15:00:00.0000000") == expected)
        #expect(WebDate.parse("2026-11-23T15:00:00.5Z") == expected.addingTimeInterval(0.5))
        #expect(WebDate.parse("2026-11-23T10:00:00", defaultZone: newYork) == expected)
        #expect(WebDate.parse("not a date") == nil)
        #expect(WebDate.parse("2026-13-01T00:00:00Z") == nil)
        #expect(WebDate.parse("2026-11-23T15:00:00Zjunk") == nil)
        #expect(WebDate.localMidnight("2026-11-26") == WebFixtures.localMidnight(2026, 11, 26))
        #expect(WebDate.utcString(expected) == "2026-11-23T15:00:00Z")
        #expect(WebDate.dayString(WebFixtures.localMidnight(2026, 11, 26)) == "2026-11-26")
    }

    @Test func headerAddressesAndMessageIDsParse() {
        let header = #""Rivera, Jamie" <jamie@example.com>, sam@example.com (Sam Lee), "#
            + "=?UTF-8?B?V2FmZmxlcyDwn5C2?= <waffles@example.com>, Team: a@example.com, b@example.com;, <bare@example.com>"
        let addresses = WebAddresses.parse(header)
        #expect(addresses.map(\.email) == ["jamie@example.com", "sam@example.com", "waffles@example.com", "a@example.com", "b@example.com",
                                           "bare@example.com"])
        #expect(addresses.map(\.name) == ["Rivera, Jamie", "Sam Lee", "Waffles 🐶", nil, nil, nil])
        #expect(WebAddresses.parse("undisclosed-recipients:;").isEmpty)
        #expect(WebAddresses.messageIDs("<a@x> <b@y>\r\n <c@z>") == ["<a@x>", "<b@y>", "<c@z>"])
    }

    @Test func rawMessagesKeepBccForTheServices() {
        let from = MailAddress(name: "Jamie Rivera", email: "jamie@example.com")
        let message = OutgoingMessage(from: from, to: [MailAddress(email: "alex@example.com")],
                                      bcc: [MailAddress(name: "Boss", email: "boss@example.com"), MailAddress(email: "hr@example.com")],
                                      subject: "Hi", textBody: "Hello")
        let text = String(decoding: WebMIME.build(message), as: UTF8.self)
        // The services read every recipient from the headers, so the Bcc header goes along (they remove it).
        let bcc = AddressParser.parse(MIMEParser.parse(WebMIME.build(message)).header("Bcc") ?? "")
        #expect(bcc.map(\.email) == ["boss@example.com", "hr@example.com"])
        #expect(text.contains("Subject: Hi"))
        let plain = OutgoingMessage(from: from, to: [MailAddress(email: "alex@example.com")], subject: "Hi")
        #expect(!String(decoding: WebMIME.build(plain), as: UTF8.self).contains("Bcc:"))
    }

    @Test func htmlDescriptionsBecomePlainText() {
        #expect(WebText.looksLikeHTML("<b>Agenda</b><br>Icons"))
        #expect(!WebText.looksLikeHTML("Write to <jamie@example.com> or see <https://example.com>"))
        // Runs of empty blocks become one blank line.
        #expect(WebText.plainText(fromPossibleHTML: "<p>Agenda:</p><p></p><p></p><ul><li>Icons</li></ul>Notes &amp; links")
                == "Agenda:\n\nIcons\nNotes & links")
        #expect(WebText.plainText(fromPossibleHTML: "a < b & c") == "a < b & c")
    }
}

/// Counts how many pieces of work run at once.
private actor Gauge {
    private var running = 0
    private(set) var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() {
        running -= 1
    }
}
