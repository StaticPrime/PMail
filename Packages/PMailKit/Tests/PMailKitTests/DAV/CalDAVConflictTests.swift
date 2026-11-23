import Foundation
import Testing
@testable import PMailKit

/// Another app on the same iCloud calendar (Calendar on a Mac, taking in the same invitation emails) changing an event
/// while PMail does: PMail makes its answer, or takes the emailed change in, again on the event as it is now, and an
/// answer given for a time the event has since moved away from waits for an answer again, whoever moved it.
struct CalDAVConflictTests {
    /// The calendar's copy of one event, which "another app" can change once, between PMail reading and saving it.
    final class Server: @unchecked Sendable {
        var text: String
        var etag: String
        var otherAppsVersion: (text: String, etag: String)?

        init(_ text: String, etag: String) {
            self.text = text
            self.etag = etag
        }
    }

    private static let path = "/123456/calendars/work/garden.ics"

    /// Garden party as the calendar keeps it: PMail's copy (answered by email), on the 24th, answered No from PMail.
    private static func copy(sequence: Int = 0, day: Int = 24, answer: String = "DECLINED", answeredFor: String? = "20261124T150000Z",
                             answeredByEmail: Bool = true) -> String {
        ICS.calendar("""
        BEGIN:VEVENT
        UID:garden@example.com
        SEQUENCE:\(sequence)
        DTSTAMP:\(sequence == 0 ? "20261120T120000Z" : "20261121T120000Z")
        DTSTART:202611\(day)T150000Z
        DTEND:202611\(day)T160000Z
        SUMMARY:Garden party
        ORGANIZER;CN=Olivia Chen\(answeredByEmail ? ";SCHEDULE-AGENT=CLIENT" : ""):mailto:olivia@gmail.example
        ATTENDEE;CN=Olivia Chen;PARTSTAT=ACCEPTED:mailto:olivia@gmail.example
        ATTENDEE;PARTSTAT=\(answer):mailto:pug@icloud.com
        \(answeredFor.map { "X-PMAIL-ANSWERED:\($0)" } ?? "X-EXAMPLE:none")
        END:VEVENT
        """)
    }

    /// The organizer moving it to the 25th.
    private static let moved = CalDAVTests.invitation(uid: "garden@example.com", sequence: 1)
        .replacingOccurrences(of: "DTSTART:20261124T150000Z", with: "DTSTART:20261125T150000Z")
        .replacingOccurrences(of: "DTEND:20261124T160000Z", with: "DTEND:20261125T160000Z")

    /// The server, which may refuse queries by UID (as iCloud may) or answer queries for a stretch of time with nothing.
    private func serve(_ server: Server, findsByUID: Bool = true, findsByTime: Bool = true) -> StubTransport {
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("REPORT", "/123456/calendars/work") { request in
            let byUID = request.bodyText.contains("prop-filter name=\"UID\"")
            if byUID, !findsByUID { return .status(403) }
            if !byUID, !findsByTime { return DAVStub.multistatus() }
            return DAVStub.multistatus(DAVStub.response(Self.path, DAVStub.calendarData(server.text, etag: server.etag)))
        }
        transport.on("GET", Self.path) { _ in
            StubTransport.Response(status: 200, body: Data(server.text.utf8), headers: ["ETag": server.etag, "Content-Type": "text/calendar"])
        }
        transport.on("PUT", Self.path) { request in
            if let other = server.otherAppsVersion {
                // The other app saves first.
                (server.text, server.etag, server.otherAppsVersion) = (other.text, other.etag, nil)
                return .status(412)
            }
            guard request.value(forHTTPHeaderField: "If-Match") == server.etag else { return .status(412) }
            server.text = request.bodyText
            server.etag = "\"p\(transport.requests.count)\""
            return DAVStub.saved(etag: server.etag, status: 204)
        }
        return transport
    }

    @Test func anAnswerIsMadeAgainOnTheNewestVersion() async throws {
        let server = Server(Self.copy(answer: "NEEDS-ACTION;RSVP=TRUE", answeredFor: nil), etag: "\"v0\"")
        server.otherAppsVersion = (Self.copy(answer: "NEEDS-ACTION;RSVP=TRUE", answeredFor: nil).replacingOccurrences(
            of: "X-EXAMPLE:none", with: "X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC"), "\"a1\"")
        let transport = serve(server)
        let service = try CalDAVTests.service(transport)
        let party = try #require(try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-22 00:00"),
                                                              to: ICS.moment("2026-11-29 00:00")).first)
        try await service.respond(to: party, with: .declined, comment: nil, scope: .thisEvent)
        let puts = transport.sent("PUT", Self.path)
        #expect(puts.count == 2 && DAVStub.header(puts.last, "If-Match") == "\"a1\"", "made again on the other app's version")
        let saved = server.text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(saved.contains("PARTSTAT=DECLINED") && saved.contains("X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC"), "keeping what it changed")
        #expect(saved.contains("X-PMAIL-ANSWERED:20261124T150000Z"), "the answer notes the time it was given for")
    }

    @Test func aChangeAnotherAppTookInFirstStillAsksAgain() async throws {
        // PMail reads the copy, then Calendar (taking in the same email) saves the move first, keeping the old answer.
        let server = Server(Self.copy(), etag: "\"v0\"")
        server.otherAppsVersion = (Self.copy(sequence: 1, day: 25, answeredFor: nil, answeredByEmail: false), "\"a1\"")
        let transport = serve(server)
        try await CalDAVTests.service(transport).receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        let last = try #require(transport.sent("PUT", Self.path).last)
        #expect(DAVStub.header(last, "If-Match") == "\"a1\"" && DAVStub.header(last, "Schedule-Reply") == "F",
                "made on the other app's copy, without the server answering for the owner")
        let saved = server.text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(saved.contains("DTSTART:20261125T150000Z") && saved.contains("PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com"),
                "moved, and waiting for an answer again")
    }

    @Test func anAnswerTheEventMovedAwayFromWaitsAgain() async throws {
        // Calendar took the move in before PMail looked, and kept the answer given for the 24th (and PMail's note of it).
        let server = Server(Self.copy(sequence: 1, day: 25, answeredFor: "20261124T150000Z", answeredByEmail: false), etag: "\"a1\"")
        let transport = serve(server)
        let service = try CalDAVTests.service(transport)
        try await service.receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        let saved = server.text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(transport.sent("PUT", Self.path).count == 1 && saved.contains("PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com")
                && !saved.contains("X-PMAIL-ANSWERED"), "the answer was for the old time")

        // Answered again for the 25th, the same email changes nothing.
        let answered = Server(Self.copy(sequence: 1, day: 25, answeredFor: "20261125T150000Z", answeredByEmail: false), etag: "\"a2\"")
        let quiet = serve(answered)
        try await CalDAVTests.service(quiet).receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        #expect(quiet.sent("PUT", Self.path).isEmpty)
    }

    @Test func aMoveAnotherAppTookInBeforePMailLookedStillAsksAgain() async throws {
        // PMail is showing the calendar: No, on the 24th (answered elsewhere, so without PMail's note).
        let server = Server(Self.copy(answeredFor: nil), etag: "\"v0\"")
        let transport = serve(server)
        let service = try CalDAVTests.service(transport)
        _ = try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-22 00:00"), to: ICS.moment("2026-11-29 00:00"))
        // Calendar takes the move in first, keeping the answer.
        (server.text, server.etag) = (Self.copy(sequence: 1, day: 25, answeredFor: nil, answeredByEmail: false), "\"a1\"")
        try await service.receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        let saved = server.text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(saved.contains("DTSTART:20261125T150000Z") && saved.contains("PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com"),
                "the answer PMail saw for the 24th waits again")
    }

    // MARK: Finding the copy

    @Test func aServerThatWontFindByUIDStillHasItsCopyUpdated() async throws {
        // Without the search by UID, the copy is found among the events around the invitation's time, and moved, not
        // added a second time.
        let server = Server(Self.copy(), etag: "\"v0\"")
        let transport = serve(server, findsByUID: false)
        try await CalDAVTests.service(transport).receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        let puts = transport.sent("PUT", "/123456/calendars/")
        #expect(puts.count == 1 && puts.first?.url?.path == Self.path && DAVStub.header(puts.first, "If-Match") == "\"v0\"")
        #expect(server.text.contains("DTSTART:20261125T150000Z") && server.text.contains("PARTSTAT=NEEDS-ACTION"))
    }

    @Test func whereACopyIsIsRemembered() async throws {
        // Seen when the calendar loaded, the copy is found where it was, whatever the server answers to queries.
        let server = Server(Self.copy(), etag: "\"v0\"")
        let transport = serve(server, findsByUID: false)
        let service = try CalDAVTests.service(transport)
        _ = try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-22 00:00"), to: ICS.moment("2026-11-29 00:00"))
        transport.on("REPORT", "/123456/calendars/work") { request in
            request.bodyText.contains("prop-filter name=\"UID\"") ? .status(403) : DAVStub.multistatus()
        }
        try await service.receive(try #require(Invitation.read(Data(Self.moved.utf8), ownerEmail: "pug@me.com")))
        #expect(transport.sent("GET", Self.path).count == 1 && transport.sent("PUT", "/123456/calendars/").count == 1)
        #expect(server.text.contains("DTSTART:20261125T150000Z"))
    }

    @Test func aKeptAnswerKeepsItsNote() throws {
        let stored = try #require(InvitationText.vcalendar(Self.copy(answer: "ACCEPTED")))
        var incoming = try #require(InvitationText.vcalendar(CalDAVTests.invitation(uid: "garden@example.com", sequence: 1)
            .replacingOccurrences(of: "LOCATION:Olivia's garden", with: "LOCATION:The park")))
        InvitationText.carryAnswer(of: "pug@icloud.com", from: stored, into: &incoming, answer: .accepted)
        let text = incoming.serialized
        #expect(text.contains("PARTSTAT=ACCEPTED:mailto:pug@icloud.com") && text.contains("X-PMAIL-ANSWERED:20261124T150000Z"),
                "a change that keeps the time keeps the answer, and what it was for")
    }
}
