import Foundation
import Testing
@testable import PMailKit

/// Calendars an account follows: another person's (added to a Google account's list, or read through a Microsoft
/// account where they've shared it), and ones from web addresses, kept on the Mac for any account.
struct SubscriptionTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-subscriptions-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func googleAddsSomeonesCalendarToTheList() async throws {
        let transport = StubTransport()
        transport.on("POST", "/calendar/v3/users/me/calendarList") { request in
            guard request.bodyJSONValue["id"] == "alex@acme.example" else {
                return .json(#"{"error": {"code": 404, "message": "Not Found"}}"#, status: 404)
            }
            return .json(##"{"id": "alex@acme.example", "summary": "Alex Kim", "accessRole": "reader", "backgroundColor": "#9fe1e7"}"##)
        }
        transport.on("DELETE", "/calendar/v3/users/me/calendarList/") { _ in .status(204) }
        let calendar = GoogleCalendarService(client: .test(transport))
        #expect(calendar.canSubscribeToPeople)
        let alex = try await calendar.subscribe(toCalendarOf: " alex@acme.example ")
        #expect(alex.id == "alex@acme.example" && alex.name == "Alex Kim" && alex.isOther && alex.isReadOnly && alex.canUnsubscribe == true)
        await #expect {
            try await calendar.subscribe(toCalendarOf: "nobody@acme.example")
        } throws: { error in
            guard case let PMailError.notSupported(reason) = error else { return false }
            return reason.contains("hasn’t shared their calendar")
        }
        try await calendar.unsubscribe(from: "alex@acme.example")
        #expect(transport.sent("DELETE", "/calendar/v3/users/me/calendarList/alex@acme.example").count == 1)
    }

    @Test func microsoftFollowsACalendarSharedWithTheAccount() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(FollowedCalendars.fileName)
        let transport = StubTransport()
        transport.on("GET", "/v1.0/me/calendars") { _ in
            .json(#"{"value": [{"id": "AAMkCal1=", "name": "Calendar", "isDefaultCalendar": true, "canEdit": true, "owner": {"address": "jamie@contoso.example"}}]}"#)
        }
        transport.on("GET", "/v1.0/users/alex@contoso.example/calendar") { request in
            if request.url?.path.hasSuffix("/calendarView") == true {
                return .json(#"""
                {"value": [{"id": "AAMkAlex1=", "subject": "Design sync", "start": {"dateTime": "2026-11-24T15:00:00.0000000", "timeZone": "UTC"},
                            "end": {"dateTime": "2026-11-24T16:00:00.0000000", "timeZone": "UTC"}}]}
                """#)
            }
            return .json(##"{"id": "AAMkAlexCal=", "name": "Calendar", "hexColor": "#8764b8", "owner": {"name": "Alex Kim", "address": "alex@contoso.example"}}"##)
        }
        transport.on("GET", "/v1.0/users/sam@contoso.example/calendar") { _ in
            .json(#"{"error": {"code": "ErrorAccessDenied", "message": "Access is denied."}}"#, status: 403)
        }
        let calendar = MicrosoftCalendarService(client: .test(transport), followedFile: file)
        let alex = try await calendar.subscribe(toCalendarOf: "alex@contoso.example")
        #expect(alex.id == "person:alex@contoso.example" && alex.name == "Alex Kim" && alex.colorHex.lowercased() == "#8764b8" && alex.canUnsubscribe == true)
        await #expect {
            try await calendar.subscribe(toCalendarOf: "sam@contoso.example")
        } throws: { error in
            guard case let PMailError.notSupported(reason) = error else { return false }
            return reason.contains("sign in to this account again")
        }

        // After relaunching, Alex's calendar is still listed, and its events come from Alex's mailbox.
        let again = MicrosoftCalendarService(client: .test(transport), followedFile: file)
        #expect(try await again.loadCalendars().map(\.id) == ["AAMkCal1=", "person:alex@contoso.example"])
        let events = try await again.loadEvents(in: ["person:alex@contoso.example"], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                to: WebFixtures.date("2026-11-29T00:00:00Z"))
        #expect(events.map(\.title) == ["Design sync"] && events.first?.calendarID == "person:alex@contoso.example")
        try await again.unsubscribe(from: "person:alex@contoso.example")
        #expect(try await again.loadCalendars().map(\.id) == ["AAMkCal1="])
        await #expect(throws: PMailError.self) { try await again.unsubscribe(from: "AAMkCal1=") }
    }

    @Test func calendarsFromWebAddressesAreKeptOnTheMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ics = ICS.calendar("""
        X-WR-CALNAME:Riverside Rovers
        BEGIN:VEVENT
        UID:rovers@example.com
        DTSTAMP:20261101T000000Z
        DTSTART:20261107T150000Z
        DTEND:20261107T170000Z
        RRULE:FREQ=WEEKLY;BYDAY=SA;COUNT=4
        SUMMARY:Rovers game
        END:VEVENT
        """)
        let transport = StubTransport()
        transport.on("GET", "/rovers.ics") { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return StubTransport.Response(status: 304, body: Data(), headers: [:]) }
            return StubTransport.Response(status: 200, body: Data(ics.utf8), headers: ["ETag": "\"v1\"", "Content-Type": "text/calendar"])
        }
        transport.on("GET", "/page.html") { _ in .text("<html>Hello</html>") }
        let feeds = CalendarFeeds(folder: folder, transport: transport, timeZone: ICS.timeZone("UTC"))
        #expect(CalendarFeeds.fetchableURL("webcal://teams.example.com/rovers.ics")?.absoluteString == "https://teams.example.com/rovers.ics")
        #expect(CalendarFeeds.fetchableURL("ftp://example.com/x.ics") == nil && CalendarFeeds.fetchableURL("not an address") == nil)

        let start = ICS.moment("2026-11-01 00:00")
        let rovers = try await feeds.subscribe(to: "webcal://teams.example.com/rovers.ics", now: start)
        #expect(rovers.name == "Riverside Rovers" && CalendarFeeds.isFeed(rovers.id) && rovers.isReadOnly && rovers.isOther && rovers.canUnsubscribe == true)
        #expect(transport.sent("GET", "/rovers.ics").first?.url?.scheme == "https")
        let november = try #require(Optional(await feeds.events(in: [rovers.id], from: start, to: ICS.moment("2026-12-01 00:00"), now: start)))
        #expect(november.map(\.title) == Array(repeating: "Rovers game", count: 4) && november.allSatisfy { $0.calendarID == rovers.id })
        #expect(transport.sent("GET", "/rovers.ics").count == 1, "the copy is used while it's fresh")

        // An hour on, it's asked again, only whether it changed; unchanged, the copy stays.
        let later = start.addingTimeInterval(3_700)
        let again = await feeds.events(in: [rovers.id], from: start, to: ICS.moment("2026-12-01 00:00"), now: later)
        #expect(again.count == 4 && transport.sent("GET", "/rovers.ics").last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")

        // Kept between launches, until unsubscribed.
        let reopened = CalendarFeeds(folder: folder, transport: transport, timeZone: ICS.timeZone("UTC"))
        #expect(await reopened.calendars().map(\.name) == ["Riverside Rovers"])
        try await reopened.unsubscribe(rovers.id)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ics") }
        let remaining = await reopened.calendars()
        #expect(remaining.isEmpty && copies.isEmpty)

        await #expect(throws: PMailError.self) { try await feeds.subscribe(to: "https://teams.example.com/page.html") }
    }

    @Test func feedCalendarsCantBeChanged() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = CalendarWithTasks(calendars: LocalCalendarService(folder: folder.appendingPathComponent("cal"), ownerEmail: "me@example.com"),
                                        tasks: nil, types: EventTypeBook(file: folder.appendingPathComponent("types.json")),
                                        feeds: CalendarFeeds(folder: folder.appendingPathComponent("feeds")))
        let event = CalendarEvent(calendarID: "feed:abc", title: "Game", start: Date(), end: Date().addingTimeInterval(3_600))
        await #expect(throws: PMailError.self) { try await wrapper.update(event, scope: .thisEvent, addingConference: false) }
        await #expect(throws: PMailError.self) { try await wrapper.delete(event, scope: .thisEvent) }
    }

    // MARK: Canceled invitations

    /// Google lists canceled events only when asked: an invitation its organizer canceled shows, marked canceled; one
    /// the owner declined, or their own event they deleted, doesn't; and one deleted from PMail stays gone.
    @Test func googleShowsInvitationsTheirOrganizersCanceled() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = "/calendar/v3/calendars/jamie@acme.example/events"
        let transport = StubTransport()
        transport.on("GET", events) { request in
            #expect(request.queryValues(named: "showDeleted") == ["true"])
            func item(_ id: String, me: String, organizerSelf: Bool) -> String {
                #"{"id": "\#(id)", "status": "cancelled", "summary": "\#(id)", "start": {"dateTime": "2026-11-24T15:00:00Z"}, "#
                    + #""end": {"dateTime": "2026-11-24T16:00:00Z"}, "organizer": {"email": "\#(organizerSelf ? "jamie@acme.example" : "alex@acme.example")"}, "#
                    + #""attendees": [{"email": "jamie@acme.example", "self": true, "organizer": \#(organizerSelf), "responseStatus": "\#(me)"}]}"#
            }
            return .json(#"{"items": ["# + [item("theirs", me: "accepted", organizerSelf: false), item("declined", me: "declined", organizerSelf: false),
                                             item("mine", me: "accepted", organizerSelf: true)].joined(separator: ",") + "]}")
        }
        transport.on("DELETE", events) { _ in .json(#"{"error": {"code": 410, "message": "Resource has been deleted"}}"#, status: 410) }
        let file = folder.appendingPathComponent(DismissedEvents.fileName)
        let week = (WebFixtures.date("2026-11-22T00:00:00Z"), WebFixtures.date("2026-11-29T00:00:00Z"))
        let calendar = GoogleCalendarService(client: .test(transport), dismissedFile: file)
        let shown = try await calendar.loadEvents(in: ["jamie@acme.example"], from: week.0, to: week.1)
        #expect(shown.map(\.id) == ["theirs"] && shown.first?.status == .cancelled)
        try await calendar.delete(try #require(shown.first), scope: .thisEvent)
        let after = GoogleCalendarService(client: .test(transport), dismissedFile: file)
        #expect(try await after.loadEvents(in: ["jamie@acme.example"], from: week.0, to: week.1).isEmpty, "deleted from PMail, it stays gone")
    }

    /// Outlook puts "Canceled: " before a canceled meeting's title; PMail marks it canceled instead.
    @Test func microsoftCanceledMeetingsKeepTheirTitle() async throws {
        let transport = StubTransport()
        transport.on("GET", "/v1.0/me/calendars/AAMkCal1=/calendarView") { _ in
            .json(#"""
            {"value": [{"id": "AAMkGone=", "subject": "Canceled: Budget review", "isCancelled": true,
                        "start": {"dateTime": "2026-11-24T15:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-24T16:00:00.0000000", "timeZone": "UTC"}, "responseStatus": {"response": "accepted"}}]}
            """#)
        }
        let events = try await MicrosoftCalendarService(client: .test(transport))
            .loadEvents(in: ["AAMkCal1="], from: WebFixtures.date("2026-11-22T00:00:00Z"), to: WebFixtures.date("2026-11-29T00:00:00Z"))
        #expect(events.map(\.title) == ["Budget review"] && events.first?.status == .cancelled)
    }
}
