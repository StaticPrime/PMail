import Foundation
import Testing
@testable import PMailKit

/// iCloud names a meeting's organizer by the Apple Account (its principal) and that account's email, whatever address
/// the app wrote. When PMail emails a meeting's invitations (the Apple Account's email isn't an iCloud address), it names
/// the owner the way Apple's apps do, the principal with the account's own address; and it knows the owner again however
/// iCloud names them, listed once.
struct ICloudOrganizerTests {
    private static let identity = CalDAVCalendarService.OwnerIdentity(principalPath: "/123456/principal/", names: ["/123456/principal/"],
                                                                       otherAddresses: ["pug@proton.example"])

    @Test func theOwnerIsNamedByTheAccountsAddressWhenPMailSendsTheInvitations() async throws {
        final class Stored: @unchecked Sendable { var text = "" }
        let stored = Stored()
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("PROPFIND", "/123456/principal") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/principal/", """
            <c:calendar-home-set><d:href>https://p56-caldav.example.com:443/123456/calendars/</d:href></c:calendar-home-set>\
            <c:calendar-user-address-set><d:href>mailto:pug@proton.example</d:href><d:href>mailto:pug@icloud.com</d:href>\
            <d:href>/123456/principal/</d:href></c:calendar-user-address-set>
            """))
        }
        transport.on("PUT", "/123456/calendars/work/") { request in
            stored.text = request.bodyText.replacingOccurrences(of: "\r\n ", with: "")
            return DAVStub.saved(etag: "\"e1\"")
        }
        transport.on("GET", "/123456/calendars/work/") { _ in
            StubTransport.Response(status: 200, body: Data(stored.text.utf8), headers: ["ETag": "\"e1\""])
        }
        let service = CalDAVCalendarService(serverURL: try #require(URL(string: "https://caldav.example.com/")), credential: DAVStub.password,
                                            ownerEmail: "pug@icloud.com", transport: transport, timeZone: ICS.timeZone("America/New_York"),
                                            iCloud: true)
        let me = MailAddress(name: "Pug", email: "pug@icloud.com")
        let start = ICS.moment("2026-11-25 15:00")
        let meeting = CalendarEvent(calendarID: "/123456/calendars/work/", title: "Party", start: start, end: start.addingTimeInterval(3_600),
                                    attendees: [Attendee(address: me, response: .accepted, isOrganizer: true), Attendee(address: MailAddress(email: "zoe@example.com"))],
                                    organizer: me, uid: "party@example.com")
        let saved = try await service.create(meeting, addingConference: false)
        #expect(stored.text.contains("ORGANIZER;CN=Pug;EMAIL=pug@icloud.com:/123456/principal/"), "\(stored.text)")
        #expect(stored.text.range(of: "ATTENDEE;[^\\r\\n]*EMAIL=pug@icloud.com[^\\r\\n]*:/123456/principal/", options: .regularExpression) != nil)
        #expect(stored.text.contains("SCHEDULE-AGENT=CLIENT:mailto:zoe@example.com"), "the guest is PMail's to invite, at her own address")
        #expect(saved.organizer?.email == "pug@icloud.com", "and PMail still knows the meeting as the owner's")
        #expect(saved.attendees.first { $0.address.email == "zoe@example.com" }?.invitedByEmail == true)
    }

    @Test func theOwnerIsKnownHoweverICloudNamesThem() throws {
        var calendar = try #require(InvitationText.vcalendar(ICS.calendar("""
        BEGIN:VEVENT
        UID:party@example.com
        DTSTAMP:20261123T120000Z
        DTSTART:20261128T230000Z
        DTEND:20261129T020000Z
        SUMMARY:Party
        ORGANIZER;CN=Pug;EMAIL=pug@proton.example:/123456/principal/
        ATTENDEE;CN=Pug;EMAIL=pug@proton.example;PARTSTAT=ACCEPTED;ROLE=CHAIR:/123456/principal/
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:pug@proton.example
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;SCHEDULE-STATUS=1.1:mailto:vince@example.com
        END:VEVENT
        """)))
        CalDAVCalendarService.recognizeOwner(in: &calendar, owner: "pug@icloud.com", identity: Self.identity)
        let reader = ICalendarReader(calendar: calendar, ownerEmail: "pug@icloud.com", localTimeZone: ICS.timeZone("UTC"))
        let event = try #require(reader.firstEvent(calendarID: "c", href: nil, etag: nil))
        #expect(event.organizer?.email == "pug@icloud.com", "the organizer is the owner")
        #expect(event.attendees.map(\.address.email) == ["pug@icloud.com", "vince@example.com"], "listed once")
        #expect(event.attendees.first?.response == .accepted)
    }

    @Test func otherPeoplesMeetingsAreLeftAlone() throws {
        var calendar = try #require(InvitationText.vcalendar(ICS.calendar("""
        BEGIN:VEVENT
        UID:theirs@example.com
        DTSTAMP:20261123T120000Z
        DTSTART:20261128T230000Z
        DTEND:20261129T020000Z
        ORGANIZER;CN=Olivia:mailto:olivia@example.com
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:olivia@example.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:pug@proton.example
        END:VEVENT
        """)))
        let before = calendar.serialized
        CalDAVCalendarService.recognizeOwner(in: &calendar, owner: "pug@icloud.com", identity: Self.identity)
        #expect(calendar.serialized.contains("olivia@example.com") && calendar.serialized != before, "only the owner's other address changes")
        let reader = ICalendarReader(calendar: calendar, ownerEmail: "pug@icloud.com", localTimeZone: ICS.timeZone("UTC"))
        #expect(reader.firstEvent(calendarID: "c", href: nil, etag: nil)?.myResponse == .needsAction, "an invitation to the owner's other address is theirs to answer")
    }
}
