import Foundation
import Testing
@testable import PMailKit

/// A meeting saved to a CalDAV calendar whose server doesn't send its invitations: the guests it noted no invitation
/// for become PMail's to invite by email, and their emailed answers go on their lines. A server that does send them
/// keeps doing so. iCloud sends them when the Apple Account's email is an iCloud address; otherwise PMail invites every
/// guest by email from the account's address.
struct CalDAVInvitationsByEmailTests {
    /// The calendar's one resource; a server that schedules notes the invitations it sent on its copy.
    final class Server: @unchecked Sendable {
        var text = ""
        var etag = "\"e0\""
        let schedules: Bool
        var saves = 0

        init(schedules: Bool) { self.schedules = schedules }
    }

    private func serve(_ server: Server) -> StubTransport {
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/work/") { request in
            server.saves += 1
            var text = request.bodyText.replacingOccurrences(of: "\r\n ", with: "")
            if server.schedules {
                text = text.replacingOccurrences(of: "RSVP=TRUE:mailto:zoe@example.com", with: "RSVP=TRUE;SCHEDULE-STATUS=1.2:mailto:zoe@example.com")
            }
            (server.text, server.etag) = (text, "\"e\(server.saves)\"")
            return DAVStub.saved(etag: server.schedules ? nil : server.etag, status: 201)
        }
        transport.on("GET", "/123456/calendars/work/") { request in
            StubTransport.Response(status: 200, body: Data(server.text.utf8), headers: ["ETag": server.etag, "Content-Type": "text/calendar"])
        }
        transport.on("PROPFIND", "/123456/calendars/work/") { _ in DAVStub.multistatus(DAVStub.response("/x", "<d:getetag>\(server.etag)</d:getetag>")) }
        transport.on("REPORT", "/123456/calendars/work") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/calendars/work/meeting.ics", DAVStub.calendarData(server.text, etag: server.etag)))
        }
        return transport
    }

    private static func meeting() -> CalendarEvent {
        let me = MailAddress(name: "Pug", email: "pug@me.com")
        let start = ICS.moment("2026-11-25 15:00")
        return CalendarEvent(calendarID: "/123456/calendars/work/", title: "Planning", start: start, end: start.addingTimeInterval(3_600),
                             attendees: [Attendee(address: me, response: .accepted, isOrganizer: true),
                                         Attendee(address: MailAddress(name: "Zoe", email: "zoe@example.com"))],
                             organizer: me, uid: "planning@example.com")
    }

    @Test func guestsTheServerDoesntInviteArePMails() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        let service = try CalDAVTests.service(transport)
        let saved = try await service.create(Self.meeting(), addingConference: false)
        #expect(server.saves == 2, "saved, then the guest taken over")
        #expect(server.text.contains("SCHEDULE-AGENT=CLIENT") && server.text.components(separatedBy: "SCHEDULE-AGENT=CLIENT").count == 2,
                "only the guest, not the organizer")
        #expect(saved.attendees.first { $0.address.email == "zoe@example.com" }?.invitedByEmail == true)
        #expect(saved.attendees.first { $0.address.email == "pug@me.com" }?.invitedByEmail == false)
        // The invitation PMail emails, without the server's own parameters.
        let invitation = try #require(try await service.invitationText(for: saved, method: .request, attendees: nil)).replacingOccurrences(of: "\r\n ", with: "")
        #expect(invitation.contains("METHOD:REQUEST") && invitation.contains("mailto:zoe@example.com") && !invitation.contains("SCHEDULE-AGENT"))
        let cancellation = try #require(try await service.invitationText(for: saved, method: .cancel, attendees: nil))
        #expect(cancellation.contains("METHOD:CANCEL") && cancellation.contains("STATUS:CANCELLED"))
    }

    @Test func aServerThatInvitesKeepsDoingIt() async throws {
        let server = Server(schedules: true)
        let saved = try await CalDAVTests.service(serve(server)).create(Self.meeting(), addingConference: false)
        #expect(server.saves == 1 && !server.text.contains("SCHEDULE-AGENT"), "left to the server, which sent it")
        #expect(saved.attendees.allSatisfy { !$0.invitedByEmail })
    }

    // MARK: iCloud

    /// iCloud, whose principal names the Apple Account's addresses: its email (marked preferred) and the account's.
    private func iCloud(_ transport: StubTransport, appleAccount: String?) throws -> CalDAVCalendarService {
        if let appleAccount {
            transport.on("PROPFIND", "/123456/principal") { _ in
                DAVStub.multistatus(DAVStub.response("/123456/principal/", """
                <c:calendar-home-set><d:href>https://p56-caldav.example.com:443/123456/calendars/</d:href></c:calendar-home-set>\
                <c:calendar-user-address-set><d:href>/123456/principal/</d:href><d:href preferred="1">mailto:\(appleAccount)</d:href>\
                <d:href>mailto:pug@me.com</d:href></c:calendar-user-address-set>
                """))
            }
        }
        return CalDAVCalendarService(serverURL: try #require(URL(string: "https://caldav.example.com/")), credential: DAVStub.password,
                                     ownerEmail: "pug@me.com", transport: transport, timeZone: ICS.timeZone("America/New_York"), iCloud: true)
    }

    private static let zoeSaysYes = ICS.calendar("""
    METHOD:REPLY
    BEGIN:VEVENT
    UID:planning@example.com
    DTSTAMP:20261123T120000Z
    DTSTART:20261125T150000Z
    DTEND:20261125T160000Z
    ORGANIZER:mailto:pug@me.com
    ATTENDEE;PARTSTAT=ACCEPTED:mailto:zoe@example.com
    END:VEVENT
    """)

    @Test func iCloudSendsTheInvitationsWhenTheAppleAccountsEmailIsAnICloudAddress() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        let service = try iCloud(transport, appleAccount: "pug@icloud.com")
        let saved = try await service.create(Self.meeting(), addingConference: false)
        #expect(server.saves == 1 && !server.text.contains("SCHEDULE-AGENT"), "saved once, every guest left to iCloud")
        #expect(server.text.contains("ORGANIZER;CN=Pug:mailto:pug@me.com"), "the owner as written, for iCloud to name its own way")
        #expect(saved.attendees.allSatisfy { !$0.invitedByEmail }, "so the app emails no one")
        #expect(transport.sent("GET", "/123456/calendars/work/").count == 1, "read back once, only to note how iCloud kept it")
    }

    @Test func guestsAnEarlierPMailTookOverGoBackToICloud() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        // Taken over by the build that emailed iCloud's invitations itself.
        _ = try await CalDAVTests.service(transport).create(Self.meeting(), addingConference: false)
        #expect(server.text.contains("SCHEDULE-AGENT=CLIENT"))
        let service = try iCloud(transport, appleAccount: "pug@icloud.com")
        var meeting = try #require(try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-24 00:00"),
                                                                 to: ICS.moment("2026-11-27 00:00")).first)
        meeting.title = "Planning (moved room)"
        _ = try await service.update(meeting, scope: .thisEvent, addingConference: false)
        #expect(!server.text.contains("SCHEDULE-AGENT"), "iCloud invites them again")
        // A guest's emailed answer is iCloud's to take in.
        let saves = server.saves
        try await service.receive(try #require(Invitation.read(Data(Self.zoeSaysYes.utf8), ownerEmail: "pug@me.com")))
        #expect(server.saves == saves)
    }

    @Test func pmailEmailsTheInvitationsWhenTheAppleAccountsEmailIsElsewhere() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        let service = try iCloud(transport, appleAccount: "pug@proton.example")
        let saved = try await service.create(Self.meeting(), addingConference: false)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/").first).bodyText.replacingOccurrences(of: "\r\n ", with: "")
        #expect(server.saves == 1 && put.contains("SCHEDULE-AGENT=CLIENT:mailto:zoe@example.com"), "the guest is PMail's before iCloud sees the meeting")
        #expect(put.components(separatedBy: "SCHEDULE-AGENT=CLIENT").count == 2, "only the guest")
        #expect(put.contains("ORGANIZER;CN=Pug;EMAIL=pug@me.com:/123456/principal/"), "iCloud's copy names the address the invitations come from")
        #expect(transport.sent("GET", "/123456/calendars/work/").isEmpty, "nothing to check after saving")
        #expect(saved.organizer?.email == "pug@me.com" && saved.attendees.first { $0.address.email == "zoe@example.com" }?.invitedByEmail == true)

        // What PMail emails names the owner by the account's address, which guests answer.
        let invitation = try #require(try await service.invitationText(for: saved, method: .request, attendees: nil)).replacingOccurrences(of: "\r\n ", with: "")
        #expect(invitation.contains("METHOD:REQUEST") && invitation.contains("ORGANIZER;CN=Pug:mailto:pug@me.com") && invitation.contains("mailto:zoe@example.com"))
        #expect(!invitation.contains("principal") && !invitation.contains("EMAIL=") && !invitation.contains("SCHEDULE-"), "\(invitation)")
        let cancellation = try #require(try await service.invitationText(for: saved, method: .cancel, attendees: nil)).replacingOccurrences(of: "\r\n ", with: "")
        #expect(cancellation.contains("METHOD:CANCEL") && cancellation.contains("ORGANIZER;CN=Pug:mailto:pug@me.com"))

        // Zoe's emailed answer goes on her line.
        try await service.receive(try #require(Invitation.read(Data(Self.zoeSaysYes.utf8), ownerEmail: "pug@me.com")))
        #expect(server.saves == 2)
        #expect(server.text.range(of: "PARTSTAT=ACCEPTED[^\\r\\n]*mailto:zoe@example.com", options: .regularExpression) != nil, "Zoe said yes")
    }

    @Test func guestsICloudInvitedBecomePMailsWhenTheAppleAccountsEmailIsElsewhere() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        server.text = ICS.calendar("""
        BEGIN:VEVENT
        UID:planning@example.com
        DTSTAMP:20261123T120000Z
        DTSTART:20261125T150000Z
        DTEND:20261125T160000Z
        SUMMARY:Planning
        ORGANIZER;CN=Pug;EMAIL=pug@proton.example:/123456/principal/
        ATTENDEE;CN=Pug;EMAIL=pug@proton.example;PARTSTAT=ACCEPTED;ROLE=CHAIR:/123456/principal/
        ATTENDEE;CN=Zoe;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;SCHEDULE-STATUS=1.1:mailto:zoe@example.com
        END:VEVENT
        """)
        let service = try iCloud(transport, appleAccount: "pug@proton.example")
        var meeting = try #require(try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-24 00:00"),
                                                                 to: ICS.moment("2026-11-27 00:00")).first)
        #expect(meeting.organizer?.email == "pug@me.com" && meeting.attendees.allSatisfy { !$0.invitedByEmail }, "iCloud invited Zoe, as the other address")
        meeting.title = "Planning (moved room)"
        let saved = try await service.update(meeting, scope: .thisEvent, addingConference: false)
        #expect(server.text.contains("SCHEDULE-AGENT=CLIENT:mailto:zoe@example.com") && !server.text.contains("SCHEDULE-STATUS"), "Zoe is PMail's from now on")
        #expect(server.text.contains("ORGANIZER;CN=Pug;EMAIL=pug@me.com:/123456/principal/"))
        #expect(saved.attendees.first { $0.address.email == "zoe@example.com" }?.invitedByEmail == true, "so the app emails her the change")
    }

    @Test func pmailEmailsThemWhenICloudNamesNoAddress() async throws {
        let server = Server(schedules: false)
        let saved = try await iCloud(serve(server), appleAccount: nil).create(Self.meeting(), addingConference: false)
        #expect(server.saves == 1 && server.text.contains("SCHEDULE-AGENT=CLIENT:mailto:zoe@example.com"))
        #expect(saved.attendees.first { $0.address.email == "zoe@example.com" }?.invitedByEmail == true)
    }

    @Test func theAddressICloudMarksPreferredIsTheOneItSendsAs() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        transport.on("PROPFIND", "/123456/principal") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/principal/", """
            <c:calendar-home-set><d:href>https://p56-caldav.example.com:443/123456/calendars/</d:href></c:calendar-home-set>\
            <c:calendar-user-address-set><d:href>mailto:pug@proton.example</d:href><d:href preferred="1">mailto:pug@icloud.com</d:href>\
            </c:calendar-user-address-set>
            """))
        }
        _ = try await iCloud(transport, appleAccount: nil).create(Self.meeting(), addingConference: false)
        #expect(!server.text.contains("SCHEDULE-AGENT"), "iCloud sends them, as the iCloud address")
    }

    @Test func aGuestsEmailedAnswerGoesOnTheirLine() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        let service = try CalDAVTests.service(transport)
        _ = try await service.create(Self.meeting(), addingConference: false)
        let reply = ICS.calendar("""
        METHOD:REPLY
        BEGIN:VEVENT
        UID:planning@example.com
        DTSTAMP:20261123T120000Z
        DTSTART:20261125T150000Z
        DTEND:20261125T160000Z
        ORGANIZER:mailto:pug@me.com
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:zoe@example.com
        END:VEVENT
        """)
        try await service.receive(try #require(Invitation.read(Data(reply.utf8), ownerEmail: "pug@me.com")))
        let unfolded = server.text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(server.saves == 3 && unfolded.contains("PARTSTAT=ACCEPTED") && unfolded.contains("mailto:zoe@example.com"))
        #expect(unfolded.range(of: "PARTSTAT=ACCEPTED[^\\r\\n]*mailto:zoe@example.com", options: .regularExpression) != nil, "Zoe said yes")

        // One the server invited takes in her answer itself.
        let invited = Server(schedules: true)
        let other = try CalDAVTests.service(serve(invited))
        _ = try await other.create(Self.meeting(), addingConference: false)
        try await other.receive(try #require(Invitation.read(Data(reply.utf8), ownerEmail: "pug@me.com")))
        #expect(invited.saves == 1, "left to the server")
    }
}
