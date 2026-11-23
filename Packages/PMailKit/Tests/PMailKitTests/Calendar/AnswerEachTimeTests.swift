import Foundation
import Testing
@testable import PMailKit

/// Answering one time of a repeating invitation, or every time: on a calendar kept on the Mac and on iCloud, in that
/// time's own override (with an emailed answer for just that time); on Google and Outlook, on the series itself.
struct AnswerEachTimeTests {
    private let zone = "America/New_York"

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-answers-\(UUID().uuidString)", isDirectory: true)
    }

    private static func weekly(organizerParameters: String = "") -> String {
        ICS.calendar("""
        BEGIN:VEVENT
        UID:weekly@example.com
        DTSTAMP:20261101T000000Z
        DTSTART;TZID=America/New_York:20261123T103000
        DTEND;TZID=America/New_York:20261123T110000
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Weekly sync
        ORGANIZER;CN=Zoe\(organizerParameters):mailto:zoe@example.com
        ATTENDEE;CN=Zoe;PARTSTAT=ACCEPTED:mailto:zoe@example.com
        ATTENDEE;CN=Pug;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com
        END:VEVENT
        """)
    }

    @Test func aCalendarOnTheMacAnswersEachTime() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let calendar = LocalCalendarService(folder: folder, ownerEmail: "pug@icloud.com")
        let request = Self.weekly().replacingOccurrences(of: "BEGIN:VEVENT", with: "METHOD:REQUEST\r\nBEGIN:VEVENT")
        let invitation = try #require(Invitation.read(Data(request.utf8), ownerEmail: "pug@icloud.com"))
        try await calendar.receive(invitation)
        func times() async throws -> [CalendarEvent] {
            try await calendar.loadEvents(in: [LocalCalendarService.calendarID], from: ICS.moment("2026-11-22 00:00", zone),
                                          to: ICS.moment("2026-12-15 00:00", zone))
        }
        var all = try await times()
        #expect(all.count == 3 && all.allSatisfy { $0.myResponse == .needsAction })

        try await calendar.respond(to: all[1], with: .declined, comment: nil, scope: .thisEvent)
        all = try await times()
        #expect(all.map(\.myResponse) == [.needsAction, .declined, .needsAction], "just that time")
        let reply = try #require(try await calendar.replyText(for: all[1], response: .declined, scope: .thisEvent))
        let unfolded = reply.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("METHOD:REPLY") && unfolded.components(separatedBy: "BEGIN:VEVENT").count == 2, "the answer is for that time alone")
        #expect(unfolded.contains("RECURRENCE-ID;TZID=America/New_York:20261130T103000") && unfolded.contains("PARTSTAT=DECLINED")
                && !unfolded.contains("RRULE:FREQ=WEEKLY"))

        // Every time of it, the one answered alone too.
        try await calendar.respond(to: all[0], with: .accepted, comment: nil, scope: .allEvents)
        all = try await times()
        #expect(all.allSatisfy { $0.myResponse == .accepted })
        let series = try #require(try await calendar.replyText(for: all[0], response: .accepted, scope: .allEvents))
        #expect(series.contains("RRULE:FREQ=WEEKLY") && !series.contains("PARTSTAT=DECLINED"))
    }

    @Test func iCloudAnswersOneTimeInItsOwnOverride() async throws {
        final class Stored: @unchecked Sendable {
            var text: String
            init(_ text: String) { self.text = text }
        }
        // Taken in from an email, so PMail emails its answers.
        let stored = Stored(Self.weekly(organizerParameters: ";SCHEDULE-AGENT=CLIENT"))
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("REPORT", "/123456/calendars/work") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/calendars/work/weekly.ics", DAVStub.calendarData(stored.text, etag: "\"w1\"")))
        }
        transport.on("GET", "/123456/calendars/work/weekly.ics") { _ in
            StubTransport.Response(status: 200, body: Data(stored.text.utf8), headers: ["ETag": "\"w1\"", "Content-Type": "text/calendar"])
        }
        transport.on("PUT", "/123456/calendars/work/weekly.ics") { request in
            stored.text = request.bodyText
            return DAVStub.saved(etag: "\"w2\"", status: 204)
        }
        let service = try CalDAVTests.service(transport)
        let all = try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-22 00:00", zone),
                                               to: ICS.moment("2026-12-15 00:00", zone))
        #expect(all.count == 3)
        try await service.respond(to: all[1], with: .declined, comment: nil, scope: .thisEvent)
        let body = try #require(transport.sent("PUT", "/123456/calendars/work/weekly.ics").first).bodyText.replacingOccurrences(of: "\r\n ", with: "")
        let events = Array(body.components(separatedBy: "BEGIN:VEVENT").dropFirst())
        #expect(events.count == 2, "the series and that time's own override")
        #expect(events.first?.contains("PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com") == true, "the other times still wait")
        #expect(events.last?.contains("RECURRENCE-ID;TZID=America/New_York:20261130T103000") == true
                && events.last?.contains("DTSTART;TZID=America/New_York:20261130T103000") == true)
        #expect(events.last?.contains("PARTSTAT=DECLINED") == true && events.last?.contains("RRULE") == false)

        let reply = try #require(try await service.replyText(for: all[1], response: .declined, scope: .thisEvent))
        #expect(reply.contains("METHOD:REPLY") && reply.components(separatedBy: "BEGIN:VEVENT").count == 2 && reply.contains("RECURRENCE-ID"))
    }

    @Test func googleAnswersEveryTimeOnTheSeries() async throws {
        let events = "/calendar/v3/calendars/jamie@gmail.com/events"
        let transport = StubTransport()
        transport.on("GET", "\(events)/weekly") { _ in
            .json(#"{"id": "weekly", "attendees": [{"email": "jamie@gmail.com", "self": true, "responseStatus": "needsAction"}]}"#)
        }
        transport.on("PATCH", "\(events)/weekly") { _ in .json(#"{"id": "weekly"}"#) }
        let calendar = GoogleCalendarService(client: .test(transport))
        let time = CalendarEvent(id: "weekly_20261123T153000Z", calendarID: "jamie@gmail.com", start: Date(), end: Date(), seriesID: "weekly")
        try await calendar.respond(to: time, with: .accepted, comment: nil, scope: .allEvents)
        try await calendar.respond(to: time, with: .declined, comment: nil, scope: .thisEvent)
        #expect(transport.requests.filter { $0.httpMethod == "PATCH" }.compactMap { $0.url?.path }
                == ["\(events)/weekly", "\(events)/weekly_20261123T153000Z"])
    }

    @Test func outlookAnswersEveryTimeOnTheSeries() async throws {
        let transport = StubTransport()
        transport.on("POST", "/v1.0/me/events/AAMkSeries=/decline") { _ in .status(202) }
        transport.on("POST", "/v1.0/me/events/AAMkOcc1=/accept") { _ in .status(202) }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        let start = Date().addingTimeInterval(2 * 86_400)
        let first = CalendarEvent(id: "AAMkOcc1=", calendarID: "AAMkCal1=", title: "Weekly", start: start, end: start.addingTimeInterval(1_800),
                                  seriesID: "AAMkSeries=", myResponse: .needsAction)
        try await calendar.respond(to: first, with: .accepted, comment: nil, scope: .thisEvent)
        try await calendar.respond(to: first, with: .declined, comment: nil, scope: .allEvents)
        #expect(transport.requests.compactMap { $0.url?.path } == ["/v1.0/me/events/AAMkOcc1=/accept", "/v1.0/me/events/AAMkSeries=/decline"],
                "one time on its own, every time on the series")
    }

    @Test func waitingAnswersShowOnEveryTimeTheyreFor() throws {
        let start = Date()
        let first = CalendarEvent(id: "w|1", calendarID: "c", start: start, end: start, seriesID: "w", myResponse: .needsAction)
        let second = CalendarEvent(id: "w|2", calendarID: "c", start: start, end: start, seriesID: "w", myResponse: .needsAction)
        let other = CalendarEvent(id: "x", calendarID: "c", start: start, end: start, myResponse: .needsAction)
        let all = CalendarChange.applying([.answer(first, response: .accepted, scope: .allEvents)], to: [first, second, other])
        #expect(all.map(\.myResponse) == [.accepted, .accepted, .needsAction])
        let one = CalendarChange.applying([.answer(first, response: .declined, scope: .thisEvent)], to: [first, second])
        #expect(one.map(\.myResponse) == [.declined, .needsAction])
        // A later answer replaces an earlier one, of either kind, and both are kept and read back.
        let queue = CalendarChange.adding(.answer(first, response: .declined, scope: .thisEvent), to: [.respond(first, response: .accepted)])
        #expect(queue == [.answer(first, response: .declined, scope: .thisEvent)])
        let kept = try JSONEncoder().encode(queue + [.respond(second, response: .tentative)])
        #expect(try JSONDecoder().decode([CalendarChange].self, from: kept) == queue + [.respond(second, response: .tentative)])
    }
}
