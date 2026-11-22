import Foundation
import Testing
@testable import PMailKit

/// Invitations by email for a calendar with no server to send them: the organizer's invitations and cancellations,
/// a guest's answers, taking in what arrives, and the calendar part that carries them in a message.
struct InvitationTests {
    private static let me = MailAddress(name: "Jamie Rivera", email: "me@example.com")
    private static let alex = MailAddress(name: "Alex Kim", email: "alex@example.com")
    private static let sam = MailAddress(name: "Sam Rivera", email: "sam@example.com")

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-invitations-\(UUID().uuidString)", isDirectory: true)
    }

    private func calendar(_ folder: URL, owner: String = "me@example.com") -> LocalCalendarService {
        LocalCalendarService(folder: folder, ownerEmail: owner, timeZone: ICS.timeZone("UTC"))
    }

    private func week(_ service: LocalCalendarService) async throws -> [CalendarEvent] {
        try await service.loadEvents(in: [LocalCalendarService.calendarID], from: ICS.moment("2026-11-22 00:00"), to: ICS.moment("2026-11-29 00:00"))
    }

    private func meeting(guests: [MailAddress]) -> CalendarEvent {
        CalendarEvent(calendarID: LocalCalendarService.calendarID, title: "Roadmap", start: ICS.moment("2026-11-24 15:00"),
                      end: ICS.moment("2026-11-24 16:00"), location: "Room 4", attendees: guests.map { Attendee(address: $0) })
    }

    /// The content lines with a name, unfolded.
    private func lines(_ text: String?, _ name: String) -> [String] {
        (text ?? "").replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
            .components(separatedBy: "\r\n").filter { $0.hasPrefix(name + ":") || $0.hasPrefix(name + ";") }
    }

    @Test func theOrganizerInvitesAndCallsOff() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = calendar(folder)
        #expect(service.emailsInvitations)
        let saved = try await service.create(meeting(guests: [Self.alex, Self.sam]), addingConference: false)

        let request = try await service.invitationText(for: saved, method: .request, attendees: nil)
        #expect(lines(request, "METHOD") == ["METHOD:REQUEST"])
        #expect(lines(request, "ORGANIZER").first?.hasSuffix("mailto:me@example.com") == true, "the owner organizes it")
        #expect(lines(request, "ATTENDEE").count == 2 && request?.contains("BEGIN:VALARM") == false)
        let invite = try #require(Invitation.read(Data((request ?? "").utf8), ownerEmail: "alex@example.com", timeZone: ICS.timeZone("UTC")))
        #expect(invite.method == .request && invite.event.title == "Roadmap" && invite.event.myResponse == .needsAction && invite.organizer?.email == "me@example.com")

        // Sam is taken off: the cancellation is for Sam alone, and replaces what they had.
        var changed = saved
        changed.attendees = [Attendee(address: Self.alex)]
        let updated = try await service.update(changed, scope: .allEvents, addingConference: false)
        let samsCancellation = try await service.invitationText(for: updated, method: .cancel, attendees: [Self.sam])
        #expect(lines(samsCancellation, "METHOD") == ["METHOD:CANCEL"] && lines(samsCancellation, "STATUS") == ["STATUS:CANCELLED"])
        #expect(lines(samsCancellation, "ATTENDEE").count == 1 && lines(samsCancellation, "ATTENDEE").first?.contains("sam@example.com") == true)
        let cancelled = try #require(Invitation.read(Data((samsCancellation ?? "").utf8), ownerEmail: "sam@example.com"))
        #expect(cancelled.method == .cancel && cancelled.sequence > invite.sequence)

        // Deleting it: everyone still invited hears, asked for before the event goes.
        let everyone = try await service.invitationText(for: updated, method: .cancel, attendees: nil)
        #expect(lines(everyone, "ATTENDEE").contains { $0.contains("alex@example.com") } && !lines(everyone, "ATTENDEE").contains { $0.contains("sam@") })
        try await service.delete(updated, scope: .allEvents)
        #expect(try await week(service).isEmpty)
    }

    @Test func aGuestTakesInAnInvitationAndAnswers() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let organizer = calendar(temporaryFolder(), owner: "alex@example.com")
        let made = try await organizer.create(meeting(guests: [Self.me, Self.sam]), addingConference: false)
        let request = try #require(try await organizer.invitationText(for: made, method: .request, attendees: nil))
        let invitation = try #require(Invitation.read(Data(request.utf8), ownerEmail: "me@example.com"))

        let mine = calendar(folder)
        try await mine.receive(invitation)
        let waiting = try #require(try await week(mine).first)
        #expect(waiting.title == "Roadmap" && waiting.myResponse == .needsAction && waiting.organizer?.email == "alex@example.com")

        try await mine.respond(to: waiting, with: .accepted)
        let reply = try await mine.invitationText(for: waiting, method: .reply, attendees: nil)
        #expect(lines(reply, "METHOD") == ["METHOD:REPLY"])
        #expect(lines(reply, "ATTENDEE").count == 1 && lines(reply, "ATTENDEE").first?.contains("PARTSTAT=ACCEPTED") == true)
        #expect(lines(reply, "ATTENDEE").first?.contains("me@example.com") == true && lines(reply, "UID") == lines(request, "UID"))
        #expect(reply?.contains("LOCATION") == false, "only what identifies the event")

        // Sent again unchanged, the answer stays; a real change asks again; a cancellation takes it off.
        try await mine.receive(invitation)
        #expect(try await week(mine).first?.myResponse == .accepted)
        var moved = made
        moved.start = ICS.moment("2026-11-25 15:00")
        moved.end = ICS.moment("2026-11-25 16:00")
        let movedEvent = try await organizer.update(moved, scope: .allEvents, addingConference: false)
        let change = try #require(Invitation.read(Data((try await organizer.invitationText(for: movedEvent, method: .request, attendees: nil) ?? "").utf8),
                                                  ownerEmail: "me@example.com"))
        try await mine.receive(change)
        let asked = try await week(mine)
        #expect(asked.first?.start == ICS.moment("2026-11-25 15:00") && asked.first?.myResponse == .needsAction)
        try await mine.receive(invitation)
        #expect(try await week(mine).first?.start == ICS.moment("2026-11-25 15:00"), "an older version changes nothing")
        let cancellation = try #require(Invitation.read(Data((try await organizer.invitationText(for: movedEvent, method: .cancel, attendees: nil) ?? "").utf8),
                                                        ownerEmail: "me@example.com"))
        try await mine.receive(cancellation)
        #expect(try await week(mine).isEmpty)
    }

    @Test func theOrganizerTakesInAnswers() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = calendar(folder)
        let made = try await mine.create(meeting(guests: [Self.alex, Self.sam]), addingConference: false)
        let request = try #require(try await mine.invitationText(for: made, method: .request, attendees: nil))
        let replyText = try #require(InvitationText.reply(to: request, from: Self.alex, response: .tentative))
        let reply = try #require(Invitation.read(Data(replyText.utf8), ownerEmail: "me@example.com"))
        #expect(reply.method == .reply && reply.replier?.address.email == "alex@example.com" && reply.replier?.response == .tentative)
        try await mine.receive(reply)
        let answers = try await week(mine).first?.attendees.map { "\($0.address.email)=\($0.response)" }
        #expect(answers?.contains("alex@example.com=tentative") == true && answers?.contains("sam@example.com=needsAction") == true)
    }

    @Test func aMessageCarriesTheInvitation() throws {
        let text = ICS.calendar("METHOD:REQUEST\nBEGIN:VEVENT\nUID:abc@example.com\nDTSTAMP:20261121T120000Z\nDTSTART:20261124T150000Z\n"
            + "DTEND:20261124T160000Z\nSUMMARY:Roadmap\nORGANIZER:mailto:me@example.com\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:alex@example.com\nEND:VEVENT")
        let message = OutgoingMessage(from: Self.me, to: [Self.alex], subject: "Invitation: Roadmap", textBody: "You're invited.",
                                      calendar: OutgoingCalendar(method: "REQUEST", text: text))
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        #expect(raw.contains("Content-Type: multipart/alternative") && raw.contains("Content-Type: text/calendar; charset=utf-8; method=REQUEST"))
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        let file = try #require(parsed.attachments.first { Invitation.isCalendarFile(mimeType: $0.mimeType, filename: $0.filename) })
        let invitation = try #require(Invitation.read(file.data ?? Data(), ownerEmail: "alex@example.com"))
        #expect(invitation.uid == "abc@example.com" && invitation.method == .request && invitation.event.title == "Roadmap")
    }
}
