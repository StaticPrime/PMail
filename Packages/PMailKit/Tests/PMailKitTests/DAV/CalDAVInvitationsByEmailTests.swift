import Foundation
import Testing
@testable import PMailKit

/// A meeting saved to a CalDAV calendar whose server doesn't send its invitations (iCloud, for meetings saved from
/// PMail): the guests it noted no invitation for become PMail's to invite by email, and their emailed answers go on
/// their lines. A server that does send them keeps doing so.
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

    // MARK: iCloud, which sends its own

    private func iCloud(_ transport: StubTransport) throws -> CalDAVCalendarService {
        CalDAVCalendarService(serverURL: try #require(URL(string: "https://caldav.example.com/")), credential: DAVStub.password,
                              ownerEmail: "pug@me.com", transport: transport, timeZone: ICS.timeZone("America/New_York"), providerInvites: true)
    }

    @Test func iCloudSendsEveryInvitationItself() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        let service = try iCloud(transport)
        let saved = try await service.create(Self.meeting(), addingConference: false)
        #expect(server.saves == 1 && !server.text.contains("SCHEDULE-AGENT"), "saved once, every guest left to iCloud")
        #expect(saved.attendees.allSatisfy { !$0.invitedByEmail })
        #expect(try await service.invitationText(for: saved, method: .request, attendees: nil) == nil, "PMail never emails one")
        #expect(try await service.invitationText(for: saved, method: .cancel, attendees: nil) == nil)
        #expect(transport.sent("GET", "/123456/calendars/work/").count == 1, "read back once, only to note how iCloud kept it")
    }

    @Test func guestsAnEarlierPMailTookOverGoBackToICloud() async throws {
        let server = Server(schedules: false)
        let transport = serve(server)
        // Taken over by the build that emailed iCloud's invitations itself.
        _ = try await CalDAVTests.service(transport).create(Self.meeting(), addingConference: false)
        #expect(server.text.contains("SCHEDULE-AGENT=CLIENT"))
        let service = try iCloud(transport)
        var meeting = try #require(try await service.loadEvents(in: ["/123456/calendars/work/"], from: ICS.moment("2026-11-24 00:00"),
                                                                 to: ICS.moment("2026-11-27 00:00")).first)
        meeting.title = "Planning (moved room)"
        _ = try await service.update(meeting, scope: .thisEvent, addingConference: false)
        #expect(!server.text.contains("SCHEDULE-AGENT"), "iCloud invites them again")
        // A guest's emailed answer is iCloud's to take in.
        let saves = server.saves
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
        #expect(server.saves == saves)
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
