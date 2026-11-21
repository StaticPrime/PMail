import Foundation
import Testing
@testable import PMailKit

@Suite struct ICalendarWritingTests {
    private let writer = ICalendarWriter(ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("America/New_York"),
                                         now: ICS.moment("2026-11-21 12:00"))

    /// Checks the rules every file PMail writes keeps: CRLF only, no line over 75 octets, folds never inside a
    /// UTF-8 sequence.
    private func expectWellFormed(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let bytes = Array(text.utf8)
        #expect(text.hasSuffix("\r\n"), sourceLocation: sourceLocation)
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            #expect(index > 0 && bytes[index - 1] == 0x0D, "bare line feed", sourceLocation: sourceLocation)
        }
        for line in text.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 75, "line too long: \(line)", sourceLocation: sourceLocation)
        }
        var line: [UInt8] = []
        for byte in bytes {
            if byte == 0x0D || byte == 0x0A {
                #expect(String(bytes: line, encoding: .utf8) != nil, "a fold split a character", sourceLocation: sourceLocation)
                line = []
            } else {
                line.append(byte)
            }
        }
    }

    @Test func newTimedEventIsWrittenInUTC() throws {
        let event = CalendarEvent(calendarID: "cal", title: "Vet visit; bring treats, leash \\ and 🐶",
                                  start: ICS.moment("2026-11-24 15:30"), end: ICS.moment("2026-11-24 16:15"),
                                  location: "Clinic", notes: "Line one\nLine two", reminderMinutes: [10, 60])
        let text = writer.newCalendar(for: event, uid: "new-1").serialized
        expectWellFormed(text)
        #expect(text.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//PuggleSoft//PMail//EN\r\n"))
        #expect(text.contains("\r\nDTSTAMP:20261121T120000Z\r\n"))
        #expect(text.contains("\r\nDTSTART:20261124T153000Z\r\nDTEND:20261124T161500Z\r\n"))
        #expect(text.contains("\r\nSUMMARY:Vet visit\\; bring treats\\, leash \\\\ and 🐶\r\n"))
        #expect(text.contains("\r\nDESCRIPTION:Line one\\nLine two\r\n"))
        #expect(text.contains("TRIGGER:-PT10M") && text.contains("TRIGGER:-PT1H"))
        #expect(!text.contains("VTIMEZONE"))

        // And it reads back as the same event.
        let read = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00").first)
        #expect(read.title == event.title && read.notes == event.notes && read.location == "Clinic")
        #expect(read.start == event.start && read.end == event.end && read.reminderMinutes == [10, 60])
    }

    @Test func newAllDayEventIsWrittenAsDates() throws {
        let start = ICS.moment("2026-12-24 00:00", "America/New_York")
        let event = CalendarEvent(calendarID: "cal", title: "Holiday", start: start, end: start.addingTimeInterval(2 * 86_400), isAllDay: true)
        let text = writer.newCalendar(for: event, uid: "allday").serialized
        #expect(text.contains("\r\nDTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261226\r\n"))
        let read = try #require(ICS.events(text, from: "2026-12-01 00:00", to: "2027-01-01 00:00", zone: "America/New_York").first)
        #expect(read.isAllDay && read.start == start)
    }

    @Test func newRepeatingEventKeepsItsTimeZone() throws {
        let start = ICS.moment("2026-10-19 09:00", "America/New_York")
        let event = CalendarEvent(calendarID: "cal", title: "Walk", start: start, end: start.addingTimeInterval(1800),
                                  timeZone: "America/New_York", recurrence: ["RRULE:FREQ=WEEKLY;COUNT=4"])
        let text = writer.newCalendar(for: event, uid: "walk").serialized
        expectWellFormed(text)
        #expect(text.contains("DTSTART;TZID=America/New_York:20261019T090000"))
        #expect(text.contains("BEGIN:VTIMEZONE\r\nTZID:America/New_York\r\n"))
        #expect(text.contains("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU") && text.contains("RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"))
        let starts = ICS.starts(text, from: "2026-10-01 00:00", to: "2026-12-01 00:00", zone: "America/New_York")
        #expect(starts == ["2026-10-19 09:00", "2026-10-26 09:00", "2026-11-02 09:00", "2026-11-09 09:00"])
    }

    @Test func longLinesFoldWithoutSplittingCharacters() {
        let title = String(repeating: "Pugs 🐶 and café ☕︎ ", count: 12)
        let event = CalendarEvent(calendarID: "cal", title: title, start: ICS.moment("2026-11-24 15:30"), end: ICS.moment("2026-11-24 16:30"))
        let text = writer.newCalendar(for: event, uid: "long").serialized
        expectWellFormed(text)
        let read = ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00").first
        #expect(read?.title == title)
    }

    private let existing = ICS.calendar("""
    X-WR-CALNAME:Home
    BEGIN:VEVENT
    UID:keep-1
    DTSTAMP:20261001T000000Z
    DTSTART;TZID=Europe/Paris:20261124T100000
    DTEND;TZID=Europe/Paris:20261124T110000
    SUMMARY;LANGUAGE=fr:Réunion
    LOCATION:Bureau
    X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-TITLE=Bureau:geo:48.85,2.35
    X-PUGGLE-MOOD;X-LEVEL=11:very happy
    ATTENDEE;CN=Sam;PARTSTAT=NEEDS-ACTION;SCHEDULE-STATUS=1.2:mailto:sam@example.com
    ORGANIZER:mailto:me@example.com
    BEGIN:VALARM
    ACTION:EMAIL
    TRIGGER:-PT1H
    SUMMARY:Mail reminder
    END:VALARM
    BEGIN:X-PUGGLE-EXTRA
    X-DATA:kept as is
    END:X-PUGGLE-EXTRA
    END:VEVENT
    BEGIN:VTODO
    UID:todo-1
    SUMMARY:Not an event
    END:VTODO
    """)

    @Test func rewritingKeepsEverythingItDoesNotUnderstand() throws {
        var calendar = try #require(ICS.component(existing))
        let reader = ICalendarReader(calendar: calendar, ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("Europe/Paris"))
        var event = try #require(reader.events(calendarID: "cal", href: "/cal/keep-1.ics", etag: "\"1\"",
                                               from: ICS.moment("2026-11-01 00:00"), to: ICS.moment("2026-12-01 00:00")).first)
        event.title = "Team meeting"
        event.reminderMinutes = [15]
        _ = try writer.update(&calendar, with: event, scope: .allEvents)
        let text = calendar.serialized
        expectWellFormed(text)
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        for kept in ["X-WR-CALNAME:Home", "X-PUGGLE-MOOD;X-LEVEL=11:very happy", "LOCATION:Bureau",
                     "X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-TITLE=Bureau:geo:48.85,2.35",
                     "ATTENDEE;CN=Sam;PARTSTAT=NEEDS-ACTION;SCHEDULE-STATUS=1.2:mailto:sam@example.com",
                     "DTSTART;TZID=Europe/Paris:20261124T100000", "BEGIN:X-PUGGLE-EXTRA\r\nX-DATA:kept as is\r\nEND:X-PUGGLE-EXTRA",
                     "ACTION:EMAIL", "BEGIN:VTODO\r\nUID:todo-1\r\nSUMMARY:Not an event\r\nEND:VTODO"] {
            #expect(unfolded.contains(kept), "lost \(kept)")
        }
        #expect(text.contains("SUMMARY:Team meeting"))
        #expect(text.contains("TRIGGER:-PT15M"))
        #expect(text.contains("PRODID:-//PuggleSoft//PMail//EN"))
        #expect(text.contains("DTSTAMP:20261121T120000Z"))
        // Unchanged times aren't rewritten, so the zone stays and SEQUENCE doesn't move.
        #expect(!text.contains("SEQUENCE"))
    }

    @Test func changingTheLocationDropsTheStalePinnedPlace() throws {
        var calendar = try #require(ICS.component(existing))
        let reader = ICalendarReader(calendar: calendar, ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("Europe/Paris"))
        var event = try #require(reader.events(calendarID: "cal", href: nil, etag: nil, from: ICS.moment("2026-11-01 00:00"),
                                               to: ICS.moment("2026-12-01 00:00")).first)
        event.location = "Café"
        event.start = event.start.addingTimeInterval(3600)
        event.end = event.end.addingTimeInterval(3600)
        _ = try writer.update(&calendar, with: event, scope: .allEvents)
        let text = calendar.serialized
        #expect(text.contains("LOCATION:Café") && !text.contains("X-APPLE-STRUCTURED-LOCATION"))
        #expect(text.contains("DTSTART;TZID=Europe/Paris:20261124T110000"))
        #expect(text.contains("SEQUENCE:1"))
    }

    @Test func pastedFaceTimeLinkGoesInURLAndDescription() throws {
        let link = try #require(URL(string: "https://facetime.apple.com/join#v=1&p=abc&k=def"))
        let event = CalendarEvent(calendarID: "cal", title: "Catch up", start: ICS.moment("2026-11-24 15:30"),
                                  end: ICS.moment("2026-11-24 16:00"), notes: "Agenda",
                                  conference: Conference(kind: .faceTime, joinURL: link))
        let text = writer.newCalendar(for: event, uid: "ft").serialized
        #expect(text.contains("URL:https://facetime.apple.com/join#v=1&p=abc&k=def"))
        #expect(text.contains("DESCRIPTION:Agenda\\n\\nhttps://facetime.apple.com/join#v=1&p=abc&k=def"))
        let read = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00").first)
        #expect(read.conference?.kind == .faceTime && read.conference?.joinURL == link)
    }

    @Test func guestsGetAnOrganizerAndInvitations() throws {
        let event = CalendarEvent(calendarID: "cal", title: "Lunch", start: ICS.moment("2026-11-24 15:30"), end: ICS.moment("2026-11-24 16:30"),
                                  attendees: [Attendee(address: MailAddress(name: "Rivera, Jamie", email: "jamie@example.com")),
                                              Attendee(address: MailAddress(email: "sam@example.com"), isOptional: true)])
        let text = writer.newCalendar(for: event, uid: "lunch").serialized.replacingOccurrences(of: "\r\n ", with: "")
        #expect(text.contains("ORGANIZER:mailto:me@example.com"))
        #expect(text.contains(#"ATTENDEE;CN="Rivera, Jamie";PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:jamie@example.com"#))
        #expect(text.contains("ATTENDEE;PARTSTAT=NEEDS-ACTION;ROLE=OPT-PARTICIPANT;RSVP=TRUE:mailto:sam@example.com"))
    }

    private let weekly = ICS.calendar("""
    BEGIN:VEVENT
    UID:weekly
    DTSTART;TZID=America/New_York:20261019T090000
    DTEND;TZID=America/New_York:20261019T100000
    RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=6
    SUMMARY:Standup
    LOCATION:Room 1
    X-KEEP:yes
    END:VEVENT
    """)

    private func occurrence(_ calendar: ICalendarComponent, _ wall: String) throws -> CalendarEvent {
        let reader = ICalendarReader(calendar: calendar, ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("America/New_York"))
        let events = reader.events(calendarID: "cal", href: "/cal/weekly.ics", etag: nil, from: ICS.moment("2026-10-01 00:00"),
                                   to: ICS.moment("2027-01-01 00:00"))
        return try #require(events.first { ICS.wall($0.start, "America/New_York") == wall })
    }

    @Test func changingOneOccurrenceAddsAnOverride() throws {
        var calendar = try #require(ICS.component(weekly))
        var event = try occurrence(calendar, "2026-11-02 09:00")
        event.title = "Standup (demo)"
        event.start = event.start.addingTimeInterval(2 * 3600)
        event.end = event.end.addingTimeInterval(2 * 3600)
        let key = try writer.update(&calendar, with: event, scope: .thisEvent)
        let text = calendar.serialized
        #expect(text.contains("RECURRENCE-ID;TZID=America/New_York:20261102T090000"))
        #expect(text.contains("SUMMARY:Standup (demo)"))
        #expect(text.contains("DTSTART;TZID=America/New_York:20261102T110000"))
        let starts = ICS.starts(text, from: "2026-10-01 00:00", to: "2027-01-01 00:00", zone: "America/New_York")
        #expect(starts == ["2026-10-19 09:00", "2026-10-26 09:00", "2026-11-02 11:00", "2026-11-09 09:00", "2026-11-16 09:00",
                           "2026-11-23 09:00"])
        let overrides = calendar.components.filter { $0.property("RECURRENCE-ID") != nil }
        #expect(overrides.count == 1 && overrides.first?.property("X-KEEP")?.value == "yes")
        #expect(overrides.first?.property("RRULE") == nil)
        #expect(key == ICS.moment("2026-11-02 09:00", "America/New_York").timeIntervalSince1970.int64)

        // Changing it again edits the same override.
        var again = try occurrence(calendar, "2026-11-02 11:00")
        again.location = "Room 2"
        _ = try writer.update(&calendar, with: again, scope: .thisEvent)
        #expect(calendar.components.filter { $0.property("RECURRENCE-ID") != nil }.count == 1)
        #expect(try occurrence(calendar, "2026-11-02 11:00").location == "Room 2")
        #expect(try occurrence(calendar, "2026-11-09 09:00").location == "Room 1")
    }

    @Test func movingTheSeriesMovesItsExceptionsToo() throws {
        var calendar = try #require(ICS.component(weekly))
        _ = try writer.deleteOccurrence(of: occurrence(calendar, "2026-10-26 09:00"), from: &calendar)
        var event = try occurrence(calendar, "2026-11-02 09:00")
        event.start = event.start.addingTimeInterval(86_400 + 3600)
        event.end = event.end.addingTimeInterval(86_400 + 3600)
        event.title = "Standup (Tuesdays)"
        _ = try writer.update(&calendar, with: event, scope: .allEvents)
        let text = calendar.serialized
        #expect(text.contains("RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=6"))
        let events = ICS.events(text, from: "2026-10-01 00:00", to: "2027-01-01 00:00", zone: "America/New_York")
        #expect(events.map { ICS.wall($0.start, "America/New_York") } == ["2026-10-20 10:00", "2026-11-03 10:00", "2026-11-10 10:00",
                                                                         "2026-11-17 10:00", "2026-11-24 10:00"])
        #expect(events.allSatisfy { $0.title == "Standup (Tuesdays)" })
    }

    @Test func aNewRuleDropsExceptionsForDatesItNoLongerHas() throws {
        var calendar = try #require(ICS.component(weekly))
        for wall in ["2026-10-26 09:00", "2026-11-02 09:00"] {
            var event = try occurrence(calendar, wall)
            event.title = "Special"
            _ = try writer.update(&calendar, with: event, scope: .thisEvent)
        }
        #expect(calendar.components.filter { $0.property("RECURRENCE-ID") != nil }.count == 2)
        // Every other week from 19 October keeps 2 November and loses 26 October.
        var event = try occurrence(calendar, "2026-10-19 09:00")
        event.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=3"]
        _ = try writer.update(&calendar, with: event, scope: .allEvents)
        let overrides = calendar.components.filter { $0.property("RECURRENCE-ID") != nil }
        #expect(overrides.map { $0.property("RECURRENCE-ID")?.value } == ["20261102T090000"])
        let events = ICS.events(calendar.serialized, from: "2026-10-01 00:00", to: "2027-01-01 00:00", zone: "America/New_York")
        #expect(events.map(\.title) == ["Standup", "Special", "Standup"])
    }

    @Test func deletingOneOccurrenceAddsAnException() throws {
        var calendar = try #require(ICS.component(weekly))
        let isEmpty = try writer.deleteOccurrence(of: occurrence(calendar, "2026-11-09 09:00"), from: &calendar)
        #expect(!isEmpty)
        let text = calendar.serialized
        #expect(text.contains("EXDATE;TZID=America/New_York:20261109T090000"))
        #expect(!ICS.starts(text, from: "2026-10-01 00:00", to: "2027-01-01 00:00", zone: "America/New_York").contains("2026-11-09 09:00"))

        // Deleting every occurrence of a finite series leaves nothing.
        var single = try #require(ICS.component(ICS.calendar("""
        BEGIN:VEVENT
        UID:twice
        DTSTART:20261102T090000Z
        RRULE:FREQ=DAILY;COUNT=2
        END:VEVENT
        """)))
        let reader = ICalendarReader(calendar: single, ownerEmail: nil, localTimeZone: .gmt)
        let both = reader.events(calendarID: "c", href: nil, etag: nil, from: ICS.moment("2026-11-01 00:00"),
                                 to: ICS.moment("2026-12-01 00:00"))
        #expect(try !writer.deleteOccurrence(of: both[0], from: &single))
        #expect(try writer.deleteOccurrence(of: both[1], from: &single))
    }

    @Test func deletingTheFirstOccurrencesKeepsTheRest() throws {
        var calendar = try #require(ICS.component(ICS.calendar("""
        BEGIN:VEVENT
        UID:long
        DTSTART:20261102T090000Z
        RRULE:FREQ=DAILY;UNTIL=20301231T090000Z
        END:VEVENT
        """)))
        for _ in 0..<4 {
            let reader = ICalendarReader(calendar: calendar, ownerEmail: nil, localTimeZone: .gmt)
            let first = try #require(reader.events(calendarID: "c", href: nil, etag: nil, from: ICS.moment("2026-11-01 00:00"),
                                                   to: ICS.moment("2026-12-01 00:00")).first)
            #expect(try !writer.deleteOccurrence(of: first, from: &calendar))
        }
        let starts = ICS.starts(calendar.serialized, from: "2026-11-01 00:00", to: "2026-11-08 00:00")
        #expect(starts == ["2026-11-06 09:00", "2026-11-07 09:00"])
    }

    @Test func answeringSetsTheOwnersParticipation() throws {
        var calendar = try #require(ICS.component(ICS.calendar("""
        BEGIN:VEVENT
        UID:invite
        DTSTART:20261124T150000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        ORGANIZER;CN=Jamie:mailto:jamie@example.com
        ATTENDEE;CN=Me;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:ME@example.com
        SEQUENCE:4
        END:VEVENT
        BEGIN:VEVENT
        UID:invite
        RECURRENCE-ID:20261201T150000Z
        DTSTART:20261201T160000Z
        ATTENDEE;CN=Me;PARTSTAT=NEEDS-ACTION:mailto:me@example.com
        END:VEVENT
        """)))
        let event = try #require(ICalendarReader(calendar: calendar, ownerEmail: "me@example.com", localTimeZone: .gmt)
            .events(calendarID: "c", href: nil, etag: nil, from: ICS.moment("2026-11-01 00:00"), to: ICS.moment("2027-01-01 00:00")).first)
        #expect(event.myResponse == .needsAction)
        try writer.respond(.accepted, to: event, in: &calendar)
        let text = calendar.serialized
        #expect(text.contains("ATTENDEE;CN=Me;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:ME@example.com"))
        #expect(text.contains("ATTENDEE;CN=Me;PARTSTAT=ACCEPTED:mailto:me@example.com"))
        // A guest's answer isn't a change to the event, so SEQUENCE stays.
        #expect(text.contains("SEQUENCE:4"))

        let notInvited = ICalendarWriter(ownerEmail: "stranger@example.com", localTimeZone: .gmt)
        #expect(throws: PMailError.self) { try notInvited.respond(.accepted, to: event, in: &calendar) }
    }
}

private extension TimeInterval {
    var int64: Int64 { Int64(self) }
}
