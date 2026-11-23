import Foundation
import Testing
@testable import PMailKit

@Suite struct CalDAVTests {
    static let standup = ICS.calendar("""
    BEGIN:VEVENT
    UID:standup
    DTSTAMP:20261001T000000Z
    DTSTART;TZID=America/New_York:20261102T090000
    DTEND;TZID=America/New_York:20261102T093000
    RRULE:FREQ=WEEKLY;COUNT=4
    SUMMARY:Standup
    X-EXAMPLE-TAG:keep me
    END:VEVENT
    """)

    static let lunch = ICS.calendar("""
    BEGIN:VEVENT
    UID:lunch
    DTSTAMP:20261001T000000Z
    DTSTART:20261110T170000Z
    DTEND:20261110T180000Z
    SUMMARY:Lunch
    ORGANIZER;CN=Jamie:mailto:jamie@example.com
    ATTENDEE;CN=Jamie;PARTSTAT=ACCEPTED:mailto:jamie@example.com
    ATTENDEE;CN=Pug;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@icloud.com
    X-EXAMPLE-TAG:also kept
    END:VEVENT
    """)

    /// A server laid out the way iCloud's is: a principal on one host, the calendars on another.
    static func iCloudLikeServer() -> StubTransport {
        let transport = StubTransport()
        transport.on("PROPFIND", "/") { _ in
            DAVStub.multistatus(DAVStub.response("/",
                "<d:current-user-principal><d:href>/123456/principal/</d:href></d:current-user-principal>"))
        }
        transport.on("PROPFIND", "/123456/principal") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/principal/",
                "<c:calendar-home-set><d:href>https://p56-caldav.example.com:443/123456/calendars/</d:href></c:calendar-home-set>"))
        }
        let write = "<d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>"
            + "</d:current-user-privilege-set>"
        let readOnly = "<d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>"
        let events = "<c:supported-calendar-component-set><c:comp name=\"VEVENT\"/></c:supported-calendar-component-set>"
        transport.on("PROPFIND", "/123456/calendars") { _ in
            DAVStub.multistatus(
                DAVStub.response("/123456/calendars/", "<d:resourcetype><d:collection/></d:resourcetype>"),
                DAVStub.response("/123456/calendars/home/", """
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Home</d:displayname>\
                <ical:calendar-color>#1BADF8FF</ical:calendar-color><ical:calendar-order>2</ical:calendar-order>\(events)\(write)
                """),
                DAVStub.response("/123456/calendars/work/", """
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Work</d:displayname>\
                <ical:calendar-color>#FF2968</ical:calendar-color><ical:calendar-order>1</ical:calendar-order>\(events)\(write)
                """),
                DAVStub.response("/123456/calendars/tasks/", """
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Reminders</d:displayname>\
                <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>\(write)
                """),
                DAVStub.response("/123456/calendars/family/", """
                <d:resourcetype><d:collection/><c:calendar/><cs:shared/></d:resourcetype><d:displayname>Family</d:displayname>\
                <ical:calendar-color>#63DA38FF</ical:calendar-color>\(events)\(readOnly)
                """),
                DAVStub.response("/123456/calendars/inbox/", "<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>")
            )
        }
        transport.on("REPORT", "/123456/calendars/work") { _ in
            DAVStub.multistatus(
                DAVStub.response("/123456/calendars/work/standup.ics", DAVStub.calendarData(standup, etag: "\"s1\"")),
                DAVStub.response("/123456/calendars/work/lunch.ics", DAVStub.calendarData(lunch, etag: "\"l1\""))
            )
        }
        transport.on("REPORT", "/123456/calendars/home") { _ in DAVStub.multistatus() }
        return transport
    }

    static func service(_ transport: StubTransport) throws -> CalDAVCalendarService {
        CalDAVCalendarService(serverURL: try #require(URL(string: "https://caldav.example.com/")), credential: DAVStub.password,
                              ownerEmail: "pug@me.com", transport: transport, timeZone: ICS.timeZone("America/New_York"))
    }

    private func november(_ service: CalDAVCalendarService) async throws -> [CalendarEvent] {
        try await service.loadEvents(in: ["/123456/calendars/work/", "/123456/calendars/home/"], from: ICS.moment("2026-11-01 00:00"),
                                     to: ICS.moment("2026-12-01 00:00"))
    }

    @Test func discoveryFollowsTheHomeSetToAnotherHost() async throws {
        let transport = Self.iCloudLikeServer()
        let calendars = try await Self.service(transport).loadCalendars()
        #expect(calendars.map(\.id) == ["/123456/calendars/work/", "/123456/calendars/home/", "/123456/calendars/family/"])
        #expect(calendars.map(\.name) == ["Work", "Home", "Family"])
        #expect(calendars.map(\.colorHex) == ["#FF2968", "#1BADF8", "#63DA38"])
        #expect(calendars.map(\.isPrimary) == [true, false, false])
        #expect(calendars.map(\.isReadOnly) == [false, false, true])
        #expect(calendars.map(\.isOther) == [false, false, true])
        #expect(calendars.allSatisfy { $0.nativeConference == nil })
        let listing = try #require(transport.sent("PROPFIND", "/123456/calendars").first)
        #expect(listing.url?.host == "p56-caldav.example.com" && DAVStub.header(listing, "Depth") == "1")
        #expect(transport.sent("PROPFIND", "/123456/principal").first?.url?.host == "caldav.example.com")
    }

    @Test func wellKnownAddressIsTriedWhenTheServerNamesNoPrincipal() async throws {
        let transport = StubTransport()
        transport.on("PROPFIND", "/") { _ in .status(404) }
        transport.on("PROPFIND", "/.well-known/caldav") { _ in
            StubTransport.Response(status: 301, body: Data(), headers: ["Location": "/dav/principals/pug/"])
        }
        transport.on("PROPFIND", "/dav/principals/pug") { _ in
            DAVStub.multistatus(DAVStub.response("/dav/principals/pug/", """
            <d:current-user-principal><d:href>/dav/principals/pug/</d:href></d:current-user-principal>\
            <c:calendar-home-set><d:href>/dav/calendars/pug/</d:href></c:calendar-home-set>
            """))
        }
        transport.on("PROPFIND", "/dav/calendars/pug") { _ in
            DAVStub.multistatus(DAVStub.response("/dav/calendars/pug/personal/",
                "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Personal</d:displayname>"))
        }
        let calendars = try await Self.service(transport).loadCalendars()
        #expect(calendars.map(\.id) == ["/dav/calendars/pug/personal/"])
        #expect(calendars.first?.isPrimary == true && calendars.first?.isReadOnly == false)
    }

    @Test func refusedSignInIsReported() async throws {
        let transport = StubTransport()
        transport.on("PROPFIND", "/") { _ in .status(401) }
        await #expect(throws: PMailError.authenticationFailed("")) { _ = try await Self.service(transport).loadCalendars() }
    }

    @Test func eventsLoadExpandedWithTheirResources() async throws {
        let transport = Self.iCloudLikeServer()
        let events = try await november(try Self.service(transport))
        try #require(events.count == 5)
        #expect(events.map(\.title) == ["Standup", "Standup", "Lunch", "Standup", "Standup"])
        #expect(events.map { ICS.wall($0.start, "America/New_York") } == ["2026-11-02 09:00", "2026-11-09 09:00", "2026-11-10 12:00",
                                                                         "2026-11-16 09:00", "2026-11-23 09:00"])
        let lunch = try #require(events.first { $0.title == "Lunch" })
        #expect(lunch.id == "/123456/calendars/work/lunch.ics" && lunch.resourceHref == "/123456/calendars/work/lunch.ics")
        #expect(lunch.etag == "\"l1\"" && lunch.calendarID == "/123456/calendars/work/" && lunch.uid == "lunch")
        #expect(lunch.myResponse == .needsAction && lunch.organizer?.email == "jamie@example.com")
        let standup = events[1]
        #expect(standup.id == "/123456/calendars/work/standup.ics|20261109T140000Z" && standup.seriesID == "standup")
        #expect(standup.recurrence == ["RRULE:FREQ=WEEKLY;COUNT=4"] && standup.etag == "\"s1\"")

        let report = try #require(transport.sent("REPORT", "/123456/calendars/work").first)
        #expect(report.url?.host == "p56-caldav.example.com" && DAVStub.header(report, "Depth") == "1")
        #expect(report.bodyText.contains("<c:calendar-query") && report.bodyText.contains("<c:comp-filter name=\"VEVENT\">"))
        #expect(report.bodyText.contains("<c:time-range start=\"20261101T000000Z\" end=\"20261201T000000Z\"/>"))
    }

    @Test func createdEventsAreSavedWithoutOverwriting() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/work") { _ in DAVStub.saved(etag: "\"n1\"") }
        let service = try Self.service(transport)
        let link = try #require(URL(string: "https://facetime.apple.com/join#v=1&p=abc&k=def"))
        let event = CalendarEvent(calendarID: "/123456/calendars/work/", title: "Planning", start: ICS.moment("2026-11-12 15:00"),
                                  end: ICS.moment("2026-11-12 16:00"), conference: Conference(kind: .faceTime, joinURL: link),
                                  uid: "new-event-1")
        let saved = try await service.create(event, addingConference: true)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/new-event-1.ics").first)
        #expect(put.url?.host == "p56-caldav.example.com")
        #expect(DAVStub.header(put, "If-None-Match") == "*" && DAVStub.header(put, "If-Match") == nil)
        #expect(DAVStub.header(put, "Content-Type") == "text/calendar; charset=utf-8")
        #expect(put.bodyText.contains("UID:new-event-1\r\n") && put.bodyText.contains("SUMMARY:Planning\r\n"))
        #expect(put.bodyText.contains("DTSTART:20261112T150000Z\r\n"))
        #expect(put.bodyText.contains("URL:https://facetime.apple.com/join#v=1&p=abc&k=def"))
        #expect(saved.resourceHref == "/123456/calendars/work/new-event-1.ics" && saved.etag == "\"n1\"")
        #expect(saved.id == "/123456/calendars/work/new-event-1.ics" && saved.conference?.kind == .faceTime)

        // A server that doesn't send the ETag back is asked for it.
        transport.on("PUT", "/123456/calendars/work") { _ in DAVStub.saved(etag: nil) }
        transport.on("PROPFIND", "/123456/calendars/work/quiet.ics") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/calendars/work/quiet.ics", "<d:getetag>\"q1\"</d:getetag>"))
        }
        var quiet = event
        quiet.uid = "quiet"
        #expect(try await service.create(quiet, addingConference: false).etag == "\"q1\"")
    }

    @Test func updatesCheckTheVersionAndKeepUnknownProperties() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/work/lunch.ics") { _ in DAVStub.saved(etag: "\"l2\"", status: 204) }
        let service = try Self.service(transport)
        var lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        lunch.title = "Lunch at the dog park"
        let saved = try await service.update(lunch, scope: .allEvents, addingConference: false)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/lunch.ics").last)
        #expect(DAVStub.header(put, "If-Match") == "\"l1\"" && DAVStub.header(put, "If-None-Match") == nil)
        #expect(put.bodyText.contains("SUMMARY:Lunch at the dog park\r\n") && put.bodyText.contains("X-EXAMPLE-TAG:also kept\r\n"))
        #expect(put.bodyText.contains("ORGANIZER;CN=Jamie:mailto:jamie@example.com"))
        #expect(transport.sent("GET", "/").isEmpty, "the data from the listing is reused")
        #expect(saved.title == "Lunch at the dog park" && saved.etag == "\"l2\"" && saved.id == lunch.id)

        // Someone else changed it first.
        transport.on("PUT", "/123456/calendars/work/lunch.ics") { _ in .status(412) }
        await #expect(throws: PMailError.conflict) { _ = try await service.update(saved, scope: .allEvents, addingConference: false) }
    }

    @Test func givingAnEventAnotherCalendarMovesIt() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/home") { _ in DAVStub.saved(etag: "\"h1\"") }
        transport.on("DELETE", "/123456/calendars/work") { _ in .status(204) }
        let service = try Self.service(transport)
        var lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        lunch.calendarID = "/123456/calendars/home/"
        let moved = try await service.update(lunch, scope: .allEvents, addingConference: false)
        let put = try #require(transport.sent("PUT", "/123456/calendars/home/lunch.ics").first)
        #expect(DAVStub.header(put, "If-None-Match") == "*" && put.bodyText.contains("X-EXAMPLE-TAG:also kept"))
        let delete = try #require(transport.sent("DELETE", "/123456/calendars/work/lunch.ics").first)
        #expect(DAVStub.header(delete, "If-Match") == "\"l1\"")
        #expect(moved.calendarID == "/123456/calendars/home/" && moved.resourceHref == "/123456/calendars/home/lunch.ics")
        #expect(moved.etag == "\"h1\"" && moved.id == "/123456/calendars/home/lunch.ics")
    }

    @Test func deletingOneOccurrenceAddsAnException() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/work/standup.ics") { _ in DAVStub.saved(etag: "\"s2\"", status: 204) }
        transport.on("DELETE", "/123456/calendars/work") { _ in .status(204) }
        let service = try Self.service(transport)
        let events = try await november(service)
        let second = try #require(events.first { ICS.wall($0.start, "America/New_York") == "2026-11-09 09:00" })
        try await service.delete(second, scope: .thisEvent)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/standup.ics").first)
        #expect(DAVStub.header(put, "If-Match") == "\"s1\"")
        #expect(put.bodyText.contains("EXDATE;TZID=America/New_York:20261109T090000\r\n"))
        #expect(put.bodyText.contains("X-EXAMPLE-TAG:keep me\r\n") && put.bodyText.contains("RRULE:FREQ=WEEKLY;COUNT=4\r\n"))
        #expect(transport.sent("DELETE", "/").isEmpty)

        let lunch = try #require(events.first { $0.title == "Lunch" })
        try await service.delete(lunch, scope: .allEvents)
        let delete = try #require(transport.sent("DELETE", "/123456/calendars/work/lunch.ics").first)
        #expect(DAVStub.header(delete, "If-Match") == "\"l1\"")
    }

    @Test func changingOneOccurrenceSavesAnOverride() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/work/standup.ics") { _ in DAVStub.saved(etag: "\"s2\"", status: 204) }
        let service = try Self.service(transport)
        var third = try #require(try await november(service).first { ICS.wall($0.start, "America/New_York") == "2026-11-16 09:00" })
        third.location = "Kitchen"
        let saved = try await service.update(third, scope: .thisEvent, addingConference: false)
        let body = try #require(transport.sent("PUT", "/123456/calendars/work/standup.ics").first).bodyText
        #expect(body.contains("RECURRENCE-ID;TZID=America/New_York:20261116T090000\r\n") && body.contains("LOCATION:Kitchen\r\n"))
        #expect(saved.location == "Kitchen" && saved.id == third.id && saved.etag == "\"s2\"")
    }

    @Test func answeringUsesTheNewestVersion() async throws {
        let transport = Self.iCloudLikeServer()
        transport.on("GET", "/123456/calendars/work/lunch.ics") { _ in
            StubTransport.Response(status: 200, body: Data(Self.lunch.utf8), headers: ["ETag": "\"l7\"", "Content-Type": "text/calendar"])
        }
        transport.on("PUT", "/123456/calendars/work/lunch.ics") { _ in DAVStub.saved(etag: "\"l8\"", status: 204) }
        let service = try Self.service(transport)
        let lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        try await service.respond(to: lunch, with: .accepted)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/lunch.ics").first)
        #expect(DAVStub.header(put, "If-Match") == "\"l7\"")
        #expect(put.bodyText.contains("ATTENDEE;CN=Pug;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:pug@icloud.com"))
        #expect(put.bodyText.contains("ATTENDEE;CN=Jamie;PARTSTAT=ACCEPTED:mailto:jamie@example.com"))
    }

    @Test func readOnlyCalendarsRefuseChanges() async throws {
        let transport = Self.iCloudLikeServer()
        let service = try Self.service(transport)
        let event = CalendarEvent(calendarID: "/123456/calendars/family/", title: "Nope", start: ICS.moment("2026-11-12 15:00"),
                                  end: ICS.moment("2026-11-12 16:00"))
        await #expect(throws: PMailError.self) { _ = try await service.create(event, addingConference: false) }
        #expect(transport.sent("PUT", "/").isEmpty)
    }

    // MARK: Invitations that come by email

    static func invitation(uid: String, guest: String = "pug@icloud.com", sequence: Int = 0, method: String = "REQUEST") -> String {
        ICS.calendar("""
        METHOD:\(method)
        BEGIN:VEVENT
        UID:\(uid)
        SEQUENCE:\(sequence)
        DTSTAMP:20261121T120000Z
        DTSTART:20261124T150000Z
        DTEND:20261124T160000Z
        SUMMARY:Garden party
        LOCATION:Olivia's garden
        ORGANIZER;CN=Olivia Chen:mailto:olivia@gmail.example
        ATTENDEE;CN=Olivia Chen;PARTSTAT=ACCEPTED:mailto:olivia@gmail.example
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(guest)
        END:VEVENT
        """)
    }

    /// An invitation emailed to the owner goes on their main calendar, waiting for an answer, marked so the server
    /// doesn't answer too; PMail then has the answer to email. One for someone else, or one the server took in itself,
    /// is left alone, and a cancellation takes PMail's copy off.
    @Test func invitationsThatComeByEmailAreTakenIn() async throws {
        let transport = Self.iCloudLikeServer()
        var stored: String?
        let lock = NSLock()
        // Searching by UID finds what's been saved (PMail's copy), or the server's own copy of "theirs".
        transport.on("REPORT", "/123456/calendars/work") { request in
            let body = request.bodyText
            if body.contains("theirs@example.com") {
                return DAVStub.multistatus(DAVStub.response("/123456/calendars/work/theirs.ics",
                                                            DAVStub.calendarData(Self.invitation(uid: "theirs@example.com"), etag: "\"t1\"")))
            }
            guard body.contains("party@example.com"), let text = lock.withLock({ stored }) else { return DAVStub.multistatus() }
            return DAVStub.multistatus(DAVStub.response("/123456/calendars/work/party%40example.com.ics", DAVStub.calendarData(text, etag: "\"p1\"")))
        }
        transport.on("PUT", "/123456/calendars/work/") { request in
            lock.withLock { stored = request.bodyText }
            return DAVStub.saved(etag: "\"p1\"")
        }
        transport.on("GET", "/123456/calendars/work/party") { _ in
            StubTransport.Response(status: 200, body: Data((lock.withLock { stored } ?? "").utf8), headers: ["ETag": "\"p2\""])
        }
        transport.on("DELETE", "/123456/calendars/work/") { _ in .status(204) }
        let service = try Self.service(transport)
        #expect(service.takesInEmailedInvitations && !service.emailsInvitations)

        let party = try #require(Invitation.read(Data(Self.invitation(uid: "party@example.com").utf8), ownerEmail: "pug@me.com"))
        try await service.receive(party)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/").first)
        #expect(DAVStub.header(put, "If-None-Match") == "*", "a new resource, on the main calendar")
        #expect(put.bodyText.contains("ORGANIZER;CN=Olivia Chen;SCHEDULE-AGENT=CLIENT:mailto:olivia@gmail.example"))
        #expect(!put.bodyText.contains("METHOD:"))

        // On the calendar, waiting for an answer; once answered, the answer to email has no server parameters.
        let event = CalendarEvent(calendarID: "/123456/calendars/work/", start: ICS.moment("2026-11-24 15:00"), end: ICS.moment("2026-11-24 16:00"),
                                  myResponse: .needsAction, uid: "party@example.com", resourceHref: "/123456/calendars/work/party%40example.com.ics")
        try await service.respond(to: event, with: .accepted)
        let reply = try #require(try await service.invitationText(for: event, method: .reply, attendees: nil))
        #expect(reply.contains("METHOD:REPLY") && reply.contains("PARTSTAT=ACCEPTED") && !reply.contains("SCHEDULE-AGENT"))
        #expect(try await service.invitationText(for: event, method: .request, attendees: nil) == nil, "the server sends the organizer's own")

        // Not for the owner, or already the server's: nothing's saved.
        let saves = transport.sent("PUT", "/123456/calendars/").count
        try await service.receive(try #require(Invitation.read(Data(Self.invitation(uid: "other@example.com", guest: "sam@example.com").utf8), ownerEmail: "pug@me.com")))
        try await service.receive(try #require(Invitation.read(Data(Self.invitation(uid: "theirs@example.com", sequence: 3).utf8), ownerEmail: "pug@me.com")))
        #expect(transport.sent("PUT", "/123456/calendars/").count == saves)

        // A cancellation takes PMail's copy off.
        try await service.receive(try #require(Invitation.read(Data(Self.invitation(uid: "party@example.com", sequence: 1, method: "CANCEL").utf8),
                                                               ownerEmail: "pug@me.com")))
        #expect(transport.sent("DELETE", "/123456/calendars/work/party").count == 1)
    }
}
