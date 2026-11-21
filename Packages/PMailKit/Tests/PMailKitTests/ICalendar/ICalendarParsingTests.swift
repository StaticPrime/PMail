import Foundation
import Testing
@testable import PMailKit

@Suite struct ICalendarParsingTests {
    @Test func simpleEventReadsEveryField() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:simple-1@example.com
        DTSTAMP:20261101T120000Z
        DTSTART:20261121T150000Z
        DTEND:20261121T160000Z
        SUMMARY:Coffee with Jamie
        LOCATION:Puggle Café\\, Main St
        DESCRIPTION:Bring the plans\\nand the dog
        STATUS:TENTATIVE
        TRANSP:TRANSPARENT
        COLOR:turquoise
        URL:https://example.com/events/1
        END:VEVENT
        """)
        let events = ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00")
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.id == "simple-1@example.com" && event.uid == "simple-1@example.com")
        #expect(event.title == "Coffee with Jamie")
        #expect(event.location == "Puggle Café, Main St")
        #expect(event.notes == "Bring the plans\nand the dog")
        #expect(ICS.wall(event.start) == "2026-11-21 15:00" && ICS.wall(event.end) == "2026-11-21 16:00")
        #expect(!event.isAllDay && event.seriesID == nil && event.occurrenceDate == nil && event.recurrence.isEmpty)
        #expect(event.status == .tentative && event.availability == .free)
        #expect(event.colorHex == "#40E0D0")
        #expect(event.webLink?.absoluteString == "https://example.com/events/1")
        #expect(event.conference == nil)
    }

    @Test func allDayEventsStartAtLocalMidnightAndEndExclusive() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:trip
        DTSTART;VALUE=DATE:20261125
        DTEND;VALUE=DATE:20261127
        SUMMARY:Trip
        END:VEVENT
        """)
        let event = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00", zone: "Europe/Paris").first)
        #expect(event.isAllDay)
        #expect(ICS.wall(event.start, "Europe/Paris") == "2026-11-25 00:00")
        #expect(ICS.wall(event.end, "Europe/Paris") == "2026-11-27 00:00")
        #expect(event.timeZone == nil)

        // A date with no end lasts the one day.
        let single = ICS.calendar("BEGIN:VEVENT\nUID:d\nDTSTART;VALUE=DATE:20261125\nEND:VEVENT")
        let day = try #require(ICS.events(single, from: "2026-11-01 00:00", to: "2026-12-01 00:00", zone: "Asia/Tokyo").first)
        #expect(ICS.wall(day.end, "Asia/Tokyo") == "2026-11-26 00:00")
    }

    @Test func zonedTimesFollowTheirZoneAcrossDaylightSaving() throws {
        let customZone = """
        BEGIN:VTIMEZONE
        TZID:Custom Eastern
        BEGIN:STANDARD
        DTSTART:19701101T020000
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:19700308T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
        TZOFFSETFROM:-0500
        TZOFFSETTO:-0400
        END:DAYLIGHT
        END:VTIMEZONE
        """
        // Daylight saving time ends in New York on 1 November 2026.
        for tzid in ["America/New_York", "Eastern Standard Time", "/mozilla.org/20050126_1/America/New_York", "Custom Eastern"] {
            let text = ICS.calendar(customZone + """

            BEGIN:VEVENT
            UID:before
            DTSTART;TZID=\(tzid):20261030T090000
            DTEND;TZID=\(tzid):20261030T100000
            END:VEVENT
            BEGIN:VEVENT
            UID:after
            DTSTART;TZID=\(tzid):20261102T090000
            DTEND;TZID=\(tzid):20261102T100000
            END:VEVENT
            """)
            let events = ICS.events(text, from: "2026-10-01 00:00", to: "2026-12-01 00:00")
            #expect(events.map { ICS.wall($0.start) } == ["2026-10-30 13:00", "2026-11-02 14:00"], "TZID \(tzid)")
            #expect(events.map { ICS.wall($0.end) } == ["2026-10-30 14:00", "2026-11-02 15:00"], "TZID \(tzid)")
            if tzid != "Custom Eastern" { #expect(events.first?.timeZone == "America/New_York") }
        }
    }

    @Test func floatingTimesAreLocal() throws {
        let text = ICS.calendar("BEGIN:VEVENT\nUID:f\nDTSTART:20261121T090000\nDTEND:20261121T093000\nEND:VEVENT")
        let event = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00", zone: "Asia/Tokyo").first)
        #expect(ICS.wall(event.start, "Asia/Tokyo") == "2026-11-21 09:00")
        #expect(event.end.timeIntervalSince(event.start) == 1800)
    }

    @Test func durationStandsInForAMissingEnd() throws {
        let text = ICS.calendar("BEGIN:VEVENT\nUID:d\nDTSTART:20261121T150000Z\nDURATION:PT1H30M\nEND:VEVENT")
        let event = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00").first)
        #expect(ICS.wall(event.end) == "2026-11-21 16:30")
    }

    @Test func weeklySeriesHonorsExceptionsAndOverrides() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:weekly
        DTSTART;TZID=Europe/Berlin:20261102T100000
        DTEND;TZID=Europe/Berlin:20261102T110000
        RRULE:FREQ=WEEKLY;COUNT=5
        EXDATE;TZID=Europe/Berlin:20261109T100000
        SUMMARY:Standup
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        RECURRENCE-ID;TZID=Europe/Berlin:20261116T100000
        DTSTART;TZID=Europe/Berlin:20261116T140000
        DTEND;TZID=Europe/Berlin:20261116T150000
        SUMMARY:Standup (moved)
        END:VEVENT
        """)
        let events = ICS.events(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00", zone: "Europe/Berlin", href: "/cal/weekly.ics")
        try #require(events.count == 4)
        #expect(events.map { ICS.wall($0.start, "Europe/Berlin") } == ["2026-11-02 10:00", "2026-11-16 14:00", "2026-11-23 10:00",
                                                                      "2026-11-30 10:00"])
        #expect(events.map(\.title) == ["Standup", "Standup (moved)", "Standup", "Standup"])
        let moved = events[1]
        #expect(moved.id == "/cal/weekly.ics|20261116T090000Z")
        #expect(moved.seriesID == "weekly" && moved.resourceHref == "/cal/weekly.ics")
        #expect(moved.occurrenceDate.map { ICS.wall($0, "Europe/Berlin") } == "2026-11-16 10:00")
        #expect(moved.recurrence == ["RRULE:FREQ=WEEKLY;COUNT=5", "EXDATE;TZID=Europe/Berlin:20261109T100000"])
        #expect(Set(events.map(\.id)).count == 4)
        #expect(events.allSatisfy { $0.isRecurring })
    }

    @Test func overrideMovedIntoTheWindowStillShows() {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:w
        DTSTART:20261102T100000Z
        DTEND:20261102T110000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        END:VEVENT
        BEGIN:VEVENT
        UID:w
        RECURRENCE-ID:20261116T100000Z
        DTSTART:20261104T100000Z
        DTEND:20261104T110000Z
        END:VEVENT
        """)
        #expect(ICS.starts(text, from: "2026-11-03 00:00", to: "2026-11-05 00:00") == ["2026-11-04 10:00"])
        #expect(ICS.starts(text, from: "2026-11-15 00:00", to: "2026-11-17 00:00").isEmpty)
    }

    @Test func foldedLinesUnfoldEvenInsideAMultibyteCharacter() throws {
        // A careless writer folded in the middle of the dog's four UTF-8 bytes.
        let dog = Array("🐶".utf8)
        var data = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:fold\r\nDTSTART:20261121T150000Z\r\nSUMMARY:Pug ".utf8)
        data.append(contentsOf: dog[0..<2])
        data.append(contentsOf: Array("\r\n ".utf8))
        data.append(contentsOf: dog[2..<4])
        data.append(contentsOf: Array(" party\r\nDESCRIPTION:Line one goes on and on\n\tand on\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8))
        let calendar = try #require(ICalendarComponent.parse(data).first)
        let event = try #require(calendar.components.first)
        #expect(event.property("SUMMARY")?.text == "Pug 🐶 party")
        #expect(event.property("DESCRIPTION")?.text == "Line one goes on and onand on")
    }

    @Test func parametersAndEscapesRead() throws {
        let attendee = #"ATTENDEE;CN="Rivera, Jamie: PhD";X-LIST=a,"b;c",d;RSVP=TRUE:mailto:jamie@example.com"#
        let line = try #require(ICalendarLine(parsing: attendee))
        #expect(line.name == "ATTENDEE")
        #expect(line.parameter("CN") == "Rivera, Jamie: PhD")
        #expect(line.parameterValues("X-LIST") == ["a", "b;c", "d"])
        #expect(line.value == "mailto:jamie@example.com")
        let grouped = try #require(ICalendarLine(parsing: "item1.EMAIL;type=INTERNET;type=pref:pug@example.com"))
        #expect(grouped.group == "item1" && grouped.name == "EMAIL" && grouped.parameterValues("TYPE") == ["INTERNET", "pref"])
        let text = try #require(ICalendarLine(parsing: #"SUMMARY:Semi\; comma\, backslash\\ newline\Nend"#))
        #expect(text.text == "Semi; comma, backslash\\ newline\nend")
        #expect(ICalendarLine(parsing: "no colon here") == nil)
        #expect(ICalendarText.split(#"a\;b;c\\;d"#, at: ";") == [#"a\;b"#, #"c\\"#, "d"])
        #expect(ICalendarParameter.decode("Jamie ^'Pug^' ^^ Rivera^nNext") == "Jamie \"Pug\" ^ Rivera\nNext")
    }

    @Test func attendeesOrganizerAndMyResponse() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:meet
        DTSTART:20261121T150000Z
        DTEND:20261121T160000Z
        ORGANIZER;CN="Rivera, Jamie":mailto:jamie@example.com
        ATTENDEE;CN=Jamie Rivera;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:jamie@example.com
        ATTENDEE;CN=Pug Owner;PARTSTAT=TENTATIVE;ROLE=REQ-PARTICIPANT:mailto:Me@Example.com
        ATTENDEE;CN=Sam;PARTSTAT=NEEDS-ACTION;ROLE=OPT-PARTICIPANT;RSVP=TRUE:mailto:sam@example.com
        ATTENDEE;CUTYPE=INDIVIDUAL;PARTSTAT=DECLINED;EMAIL=alex@example.com:urn:uuid:1234
        END:VEVENT
        """)
        let event = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00", owner: "me@example.com").first)
        #expect(event.organizer == MailAddress(name: "Rivera, Jamie", email: "jamie@example.com"))
        #expect(event.attendees.map(\.address.email) == ["jamie@example.com", "Me@Example.com", "sam@example.com", "alex@example.com"])
        #expect(event.attendees.map(\.response) == [.accepted, .tentative, .needsAction, .declined])
        #expect(event.attendees.map(\.isOrganizer) == [true, false, false, false])
        #expect(event.attendees.map(\.isOptional) == [false, false, true, false])
        #expect(event.myResponse == .tentative)
        // The organizer has no answer of their own to give.
        let mine = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00", owner: "jamie@example.com").first)
        #expect(mine.myResponse == nil)
        // iCloud addresses match across me.com, mac.com and icloud.com.
        #expect(ICalendarEventProperties.isSameMailbox("pug@me.com", "PUG@icloud.com"))
    }

    @Test func alarmsBecomeReminderMinutes() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:alarms
        DTSTART:20261121T150000Z
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER:-PT15M
        END:VALARM
        BEGIN:VALARM
        ACTION:AUDIO
        TRIGGER:-P1D
        END:VALARM
        BEGIN:VALARM
        ACTION:EMAIL
        TRIGGER:-PT30M
        END:VALARM
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER;RELATED=END:-PT5M
        END:VALARM
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER;VALUE=DATE-TIME:20261121T140000Z
        END:VALARM
        END:VEVENT
        """)
        let event = try #require(ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00").first)
        #expect(event.reminderMinutes == [15, 1440])
    }

    @Test func meetingLinksAreFoundInURLLocationAndDescription() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20261121T150000Z
        URL:https://facetime.apple.com/join#v=1&p=abc&k=def
        END:VEVENT
        BEGIN:VEVENT
        UID:b
        DTSTART:20261121T160000Z
        DESCRIPTION:Agenda first.\\nJoin: https://example.zoom.us/j/123456789
        END:VEVENT
        """)
        let events = ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00")
        try #require(events.count == 2)
        #expect(events.map { $0.conference?.kind } == [.faceTime, .zoom])
        #expect(events[1].conference?.meetingCode == "123456789")
    }

    @Test func brokenInputNeverCrashes() {
        let samples = [
            "", "BEGIN:VCALENDAR", "END:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:2026\r\n",
            ICS.calendar("BEGIN:VEVENT\nUID:x\nDTSTART:20261340T250000Z\nRRULE:FREQ=SOMETIMES;COUNT=-4\nEND:VEVENT"),
            ICS.calendar("BEGIN:VEVENT\nUID:y\nDTSTART:20261121T090000\nRRULE:FREQ=DAILY;INTERVAL=0;BYMONTHDAY=99;BYSETPOS=-999\nEND:VEVENT"),
            ICS.calendar("BEGIN:VEVENT\nUID:z\nDTSTART;TZID=Nowhere/Special:20261121T090000\nDURATION:P99999999999W\nEND:VEVENT"),
            ICS.calendar("BEGIN:VEVENT\nUID:q\nDTSTART;VALUE=DATE:20261121\nEXDATE:garbage\n"
                         + "RDATE;VALUE=PERIOD:20261122T090000Z/PTXH\nEND:VEVENT"),
        ]
        for sample in samples {
            _ = ICS.events(sample, from: "2026-01-01 00:00", to: "2027-01-01 00:00")
        }
        // The unknown zone falls back to local time rather than losing the event.
        #expect(ICS.events(samples[5], from: "2026-01-01 00:00", to: "2027-01-01 00:00").count == 1)
    }
}
