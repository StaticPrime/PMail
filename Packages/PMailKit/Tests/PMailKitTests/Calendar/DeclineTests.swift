import Foundation
import Testing
@testable import PMailKit

/// Declining meetings during out of office and focus time where the calendar doesn't do it itself: PMail keeps the
/// declining on this Mac and shows it on the event, and answers carry their message in the emailed answer.
struct DeclineTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-declines-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func declinesACalendarDoesntKeepAreKeptOnTheMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = DeclineBook(file: folder.appendingPathComponent(DeclineBook.fileName))
        let wrapper = CalendarWithTasks(calendars: LocalCalendarService(folder: folder.appendingPathComponent("cal"), ownerEmail: "me@example.com"),
                                        tasks: nil, types: EventTypeBook(file: folder.appendingPathComponent("types.json")), declines: book)
        let start = ICS.moment("2026-11-30 00:00")
        let away = CalendarEvent(calendarID: LocalCalendarService.calendarID, title: "Away", start: start, end: start.addingTimeInterval(2 * 86_400),
                                 isAllDay: true, type: .outOfOffice, declinesInvitations: true, declineMessage: "Back Wednesday",
                                 declinesExisting: true)
        let saved = try await wrapper.create(away, addingConference: false)
        #expect(saved.type == .outOfOffice && saved.isTypeLocal && saved.declinesInvitations && saved.declinesExisting
                && saved.declineMessage == "Back Wednesday")
        let before = await book.hasUpcoming(now: ICS.moment("2026-11-22 00:00"))
        let after = await book.hasUpcoming(now: ICS.moment("2026-12-03 00:00"))
        #expect(before && !after, "an upcoming time declines meetings until it's over")

        // Read again, from the calendar and the Mac.
        let again = try await wrapper.loadEvents(in: [LocalCalendarService.calendarID], from: ICS.moment("2026-11-29 00:00"),
                                                 to: ICS.moment("2026-12-03 00:00"))
        #expect(again.first?.declinesInvitations == true && again.first?.declineMessage == "Back Wednesday" && again.first?.declinesExisting == true)

        // No longer declining, or deleted, it's forgotten.
        var changed = saved
        changed.declinesInvitations = false
        _ = try await wrapper.update(changed, scope: .thisEvent, addingConference: false)
        #expect(await book.entry(for: saved) == nil)
        let declining = try await wrapper.update(saved, scope: .thisEvent, addingConference: false)
        #expect(await book.entry(for: declining) != nil)
        try await wrapper.delete(declining, scope: .thisEvent)
        #expect(await book.entry(for: declining) == nil)
    }

    @Test func emailedAnswersCarryTheirMessage() throws {
        let invitation = ICS.calendar("""
        METHOD:REPLY
        BEGIN:VEVENT
        UID:sync@example.com
        DTSTART:20261124T150000Z
        DTEND:20261124T160000Z
        SUMMARY:Sync
        COMMENT:Old
        ATTENDEE;PARTSTAT=DECLINED:mailto:me@example.com
        END:VEVENT
        """)
        let text = InvitationText.withComment(invitation, comment: " I have another event at this time; sorry. ")
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains(#"COMMENT:I have another event at this time\; sorry."#) && !unfolded.contains("COMMENT:Old"))
        #expect(InvitationText.withComment(invitation, comment: "  ") == invitation, "no message, no change")
    }
}
