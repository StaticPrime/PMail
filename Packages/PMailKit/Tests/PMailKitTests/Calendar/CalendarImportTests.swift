import Foundation
import Testing
@testable import PMailKit

/// Importing events from files: iCalendar with its repeats and without its guests, vCalendar with quoted-printable
/// text, and CSV as calendar apps export it.
struct CalendarImportTests {
    private let zone = ICS.timeZone("America/New_York")

    @Test func iCalendarFilesKeepRepeatsAndLoseGuests() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:standup@example.com
        DTSTART;TZID=America/New_York:20261123T093000
        DTEND;TZID=America/New_York:20261123T094500
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
        SUMMARY:Standup
        LOCATION:Room 4
        ORGANIZER:mailto:alex@example.com
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@example.com
        END:VEVENT
        BEGIN:VEVENT
        UID:standup@example.com
        RECURRENCE-ID;TZID=America/New_York:20261125T093000
        DTSTART;TZID=America/New_York:20261125T100000
        DTEND;TZID=America/New_York:20261125T101500
        SUMMARY:Standup (late)
        END:VEVENT
        BEGIN:VEVENT
        UID:trip@example.com
        DTSTART;VALUE=DATE:20261201
        DTEND;VALUE=DATE:20261204
        SUMMARY:Trip
        END:VEVENT
        """)
        let result = try CalendarImport.events(from: Data(text.utf8), fileExtension: "ics", timeZone: zone)
        #expect(result.events.map(\.title) == ["Standup", "Trip"] && result.skipped == 0)
        let standup = try #require(result.events.first)
        #expect(standup.start == WebFixtures.date("2026-11-23T14:30:00Z") && standup.location == "Room 4")
        #expect(standup.recurrence.contains { $0.contains("FREQ=WEEKLY") }, "\(standup.recurrence)")
        #expect(standup.attendees.isEmpty && standup.organizer == nil && standup.uid == nil, "imported without guests, so no one's invited")
        #expect(result.events.last?.isAllDay == true)
    }

    @Test func vCalendarFilesWithQuotedPrintableText() throws {
        let text = """
        BEGIN:VCALENDAR\r
        VERSION:1.0\r
        BEGIN:VEVENT\r
        DTSTART:20261124T150000Z\r
        DTEND:20261124T160000Z\r
        SUMMARY;ENCODING=QUOTED-PRINTABLE:Caf=C3=A9 with Sam\r
        DESCRIPTION;ENCODING=QUOTED-PRINTABLE:Bring the =\r
        plans\r
        RRULE:W1 TU #4\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let result = try CalendarImport.events(from: Data(text.utf8), fileExtension: "vcs", timeZone: zone)
        #expect(result.events.map(\.title) == ["Café with Sam"])
        #expect(result.events.first?.notes == "Bring the plans" && result.events.first?.recurrence.isEmpty == true,
                "vCalendar's own repeat rule is left out")
    }

    @Test func csvFilesAsCalendarAppsExportThem() throws {
        let text = """
        Subject,Start Date,Start Time,End Date,End Time,All Day Event,Description,Location
        "Dentist, check-up",11/24/2026,3:00 PM,11/24/2026,4:00 PM,False,"Bring the ""blue"" form",Bright Smiles
        Thanksgiving,11/26/2026,,,,True,,
        Coffee,2026-11-27,09:30,,,,"Line one
        line two",
        ,11/28/2026,1:00 PM,,,,,
        Broken,someday,,,,,,
        """
        let result = try CalendarImport.events(from: Data(text.utf8), fileExtension: "csv", timeZone: zone)
        #expect(result.events.map(\.title) == ["Dentist, check-up", "Thanksgiving", "Coffee"] && result.skipped == 2)
        let dentist = result.events[0]
        #expect(dentist.start == WebFixtures.date("2026-11-24T20:00:00Z") && dentist.end == WebFixtures.date("2026-11-24T21:00:00Z"))
        #expect(dentist.notes == "Bring the \"blue\" form" && dentist.location == "Bright Smiles" && !dentist.isAllDay)
        #expect(result.events[1].isAllDay && result.events[1].end.timeIntervalSince(result.events[1].start) == 86_400)
        #expect(result.events[2].end.timeIntervalSince(result.events[2].start) == 3_600 && result.events[2].notes == "Line one\nline two",
                "no end time means an hour")
        #expect(throws: PMailError.self) { try CalendarImport.events(from: Data("Name,Phone\nSam,555".utf8), fileExtension: "csv") }
    }
}
