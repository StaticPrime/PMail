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
        let canceled = try await week(mine)
        #expect(canceled.count == 1 && canceled.first?.status == .cancelled, "a cancellation keeps the event, marked canceled")
    }

    /// Canceling one time of a repeating meeting marks just that time canceled, keeping the series' title.
    @Test func oneCanceledTimeOfARepeatingMeeting() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let series = ICS.calendar("""
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:standup@example.com
        SEQUENCE:0
        DTSTAMP:20261120T120000Z
        DTSTART:20261123T150000Z
        DTEND:20261123T151500Z
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:Standup
        ORGANIZER:mailto:alex@example.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com
        END:VEVENT
        """)
        let oneTime = ICS.calendar("""
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:standup@example.com
        SEQUENCE:1
        DTSTAMP:20261121T120000Z
        RECURRENCE-ID:20261125T150000Z
        ORGANIZER:mailto:alex@example.com
        ATTENDEE:mailto:me@example.com
        STATUS:CANCELLED
        END:VEVENT
        """)
        let mine = calendar(folder)
        try await mine.receive(try #require(Invitation.read(Data(series.utf8), ownerEmail: "me@example.com")))
        try await mine.receive(try #require(Invitation.read(Data(oneTime.utf8), ownerEmail: "me@example.com")))
        let times = try await week(mine)
        #expect(times.count == 5)
        #expect(times.filter { $0.status == .cancelled }.map(\.start) == [ICS.moment("2026-11-25 15:00")])
        #expect(times.allSatisfy { $0.title == "Standup" })
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
        #expect(parsed.summary(id: "m1").isInvitation == true, "the list knows it's an invitation")
    }

    /// An invitation as Google sends one: a time zone with daylight saving rules, times in that zone (or in UTC). It
    /// reads as the time it says, wherever the Mac is.
    @Test func invitationTimesReadAsTheySay() throws {
        let zone = "BEGIN:VTIMEZONE\nTZID:America/New_York\nX-LIC-LOCATION:America/New_York\nBEGIN:DAYLIGHT\nTZOFFSETFROM:-0500\nTZOFFSETTO:-0400\n"
            + "TZNAME:EDT\nDTSTART:19700308T020000\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\nEND:DAYLIGHT\nBEGIN:STANDARD\nTZOFFSETFROM:-0400\n"
            + "TZOFFSETTO:-0500\nTZNAME:EST\nDTSTART:19701101T020000\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\nEND:STANDARD\nEND:VTIMEZONE\n"
        for times in ["DTSTART;TZID=America/New_York:20261123T210000\nDTEND;TZID=America/New_York:20261123T220000",
                      "DTSTART:20261124T020000Z\nDTEND:20261124T030000Z"] {
            let text = ICS.calendar("METHOD:REQUEST\n" + zone + "BEGIN:VEVENT\n" + times + "\nDTSTAMP:20261122T120000Z\nUID:test3@google.com\n"
                + "SEQUENCE:1\nSUMMARY:test3\nORGANIZER;CN=Jason:mailto:jason@gmail.example\n"
                + "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:me@example.com\nEND:VEVENT")
            for mac in ["America/New_York", "UTC", "Asia/Tokyo"] {
                let invitation = try #require(Invitation.read(Data(text.utf8), ownerEmail: "me@example.com", timeZone: ICS.timeZone(mac)))
                #expect(invitation.event.start == WebFixtures.date("2026-11-24T02:00:00Z") && invitation.event.end == WebFixtures.date("2026-11-24T03:00:00Z"),
                        "\(times.prefix(30)) on a Mac in \(mac): \(invitation.event.start)")
            }
        }
    }

    /// One time of a repeating event moved (Tuesday 9 PM to Monday 9 PM), sent on its own: the invitation is for when
    /// it is now, not when it was.
    @Test func aMovedTimeReadsAsItsNewTime() throws {
        let text = ICS.calendar("""
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:weekly@google.com
        RECURRENCE-ID:20261125T020000Z
        DTSTART:20261124T020000Z
        DTEND:20261124T030000Z
        DTSTAMP:20261122T120000Z
        SEQUENCE:1
        SUMMARY:test3
        ORGANIZER:mailto:jason@gmail.example
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com
        END:VEVENT
        """)
        let invitation = try #require(Invitation.read(Data(text.utf8), ownerEmail: "me@example.com", timeZone: ICS.timeZone("America/New_York")))
        #expect(invitation.event.start == WebFixtures.date("2026-11-24T02:00:00Z"), "\(invitation.event.start)")
    }

    /// A newer version that moves the invitation asks again, even when it still carries the answer given before (as
    /// Google's can); one that changes something else keeps the answer; an older one changes nothing.
    @Test func aMovedInvitationAsksAgain() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func version(_ sequence: Int, day: Int, stamp: String, myAnswer: String, notes: String = "Bring snacks") -> Invitation? {
            Invitation.read(Data(ICS.calendar("""
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:test3@google.com
            SEQUENCE:\(sequence)
            DTSTAMP:\(stamp)
            DTSTART:202611\(day)T020000Z
            DTEND:202611\(day)T030000Z
            SUMMARY:test3
            DESCRIPTION:\(notes)
            ORGANIZER:mailto:jason@gmail.example
            ATTENDEE;PARTSTAT=\(myAnswer):mailto:me@example.com
            END:VEVENT
            """).utf8), ownerEmail: "me@example.com")
        }
        let mine = calendar(folder)
        try await mine.receive(try #require(version(0, day: 24, stamp: "20261122T100000Z", myAnswer: "NEEDS-ACTION")))
        let first = try #require(try await week(mine).first)
        try await mine.respond(to: first, with: .declined)

        try await mine.receive(try #require(version(1, day: 25, stamp: "20261122T110000Z", myAnswer: "DECLINED")))
        var current = try #require(try await week(mine).first)
        #expect(current.start == WebFixtures.date("2026-11-25T02:00:00Z") && current.myResponse == .needsAction, "moved, it asks again")

        try await mine.respond(to: current, with: .tentative)
        try await mine.receive(try #require(version(1, day: 25, stamp: "20261122T120000Z", myAnswer: "NEEDS-ACTION", notes: "Bring drinks")))
        current = try #require(try await week(mine).first)
        #expect(current.notes == "Bring drinks" && current.myResponse == .tentative, "another change keeps the answer")

        try await mine.receive(try #require(version(0, day: 24, stamp: "20261122T100000Z", myAnswer: "NEEDS-ACTION")))
        #expect(try await week(mine).first?.start == WebFixtures.date("2026-11-25T02:00:00Z"), "an older one changes nothing")
    }
}
