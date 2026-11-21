import Foundation
import Testing
@testable import PMailKit

@Suite struct RecurrenceTests {
    /// A repeating event starting at `start` (a DTSTART line's value and parameters), lasting an hour.
    private func series(_ start: String, _ rule: String, extra: String = "") -> String {
        ICS.calendar("""
        BEGIN:VEVENT
        UID:series
        DTSTART\(start)
        DURATION:PT1H
        RRULE:\(rule)
        \(extra)
        END:VEVENT
        """)
    }

    @Test func dailyWithCount() {
        let text = series(":20261121T090000Z", "FREQ=DAILY;COUNT=5")
        #expect(ICS.starts(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00") == [
            "2026-11-21 09:00", "2026-11-22 09:00", "2026-11-23 09:00", "2026-11-24 09:00", "2026-11-25 09:00",
        ])
    }

    @Test func everyOtherWeekOnTuesdaysAndThursdays() {
        let text = series(":20261103T170000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=6")
        #expect(ICS.starts(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00") == [
            "2026-11-03 17:00", "2026-11-05 17:00", "2026-11-17 17:00", "2026-11-19 17:00", "2026-12-01 17:00", "2026-12-03 17:00",
        ])
    }

    @Test func lastFridayOfTheMonth() {
        let text = series(";TZID=Europe/London:20261030T160000", "FREQ=MONTHLY;BYDAY=-1FR")
        #expect(ICS.starts(text, from: "2026-10-01 00:00", to: "2027-03-01 00:00", zone: "Europe/London") == [
            "2026-10-30 16:00", "2026-11-27 16:00", "2026-12-25 16:00", "2027-01-29 16:00", "2027-02-26 16:00",
        ])
    }

    @Test func monthlyOnTheThirtyFirstSkipsShortMonths() {
        let text = series(":20260131T120000Z", "FREQ=MONTHLY;BYMONTHDAY=31;COUNT=5")
        #expect(ICS.starts(text, from: "2026-01-01 00:00", to: "2027-01-01 00:00") == [
            "2026-01-31 12:00", "2026-03-31 12:00", "2026-05-31 12:00", "2026-07-31 12:00", "2026-08-31 12:00",
        ])
        // The last day of every month, by counting from the end.
        let last = series(":20260131T120000Z", "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3")
        #expect(ICS.starts(last, from: "2026-01-01 00:00", to: "2027-01-01 00:00") == [
            "2026-01-31 12:00", "2026-02-28 12:00", "2026-03-31 12:00",
        ])
    }

    @Test func yearlyRules() {
        let birthday = ICS.calendar("""
        BEGIN:VEVENT
        UID:birthday
        DTSTART;VALUE=DATE:19900517
        RRULE:FREQ=YEARLY
        SUMMARY:Waffles' birthday
        END:VEVENT
        """)
        let events = ICS.events(birthday, from: "2026-01-01 00:00", to: "2029-01-01 00:00", zone: "America/Chicago")
        #expect(events.map { ICS.wall($0.start, "America/Chicago") } == ["2026-05-17 00:00", "2027-05-17 00:00", "2028-05-17 00:00"])
        #expect(events.allSatisfy { $0.isAllDay })
        #expect(events.first?.id == "birthday|20260517")

        let thanksgiving = series(";VALUE=DATE:20261126", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH")
        #expect(ICS.starts(thanksgiving, from: "2026-01-01 00:00", to: "2030-01-01 00:00") == [
            "2026-11-26 00:00", "2027-11-25 00:00", "2028-11-23 00:00", "2029-11-22 00:00",
        ])
    }

    @Test func untilIsInclusive() {
        let text = series(":20261105T090000Z", "FREQ=DAILY;UNTIL=20261108T090000Z")
        #expect(ICS.starts(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00") == [
            "2026-11-05 09:00", "2026-11-06 09:00", "2026-11-07 09:00", "2026-11-08 09:00",
        ])
        let dateUntil = series(";VALUE=DATE:20261105", "FREQ=DAILY;UNTIL=20261107")
        #expect(ICS.starts(dateUntil, from: "2026-11-01 00:00", to: "2027-01-01 00:00").count == 3)
    }

    @Test func occurrencesKeepTheirWallClockTimeAcrossDaylightSaving() {
        let text = series(";TZID=America/New_York:20261019T090000", "FREQ=WEEKLY;COUNT=4")
        let events = ICS.events(text, from: "2026-10-01 00:00", to: "2026-12-01 00:00")
        #expect(events.map { ICS.wall($0.start, "America/New_York") } == [
            "2026-10-19 09:00", "2026-10-26 09:00", "2026-11-02 09:00", "2026-11-09 09:00",
        ])
        #expect(events.map { ICS.wall($0.start) } == ["2026-10-19 13:00", "2026-10-26 13:00", "2026-11-02 14:00", "2026-11-09 14:00"])
        #expect(events.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        #expect(events.map(\.id) == ["series|20261019T130000Z", "series|20261026T130000Z", "series|20261102T140000Z",
                                     "series|20261109T140000Z"])
    }

    @Test func onlyOccurrencesOverlappingTheWindowCome() {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:late
        DTSTART:20261101T230000Z
        DTEND:20261102T010000Z
        RRULE:FREQ=DAILY
        END:VEVENT
        """)
        // The one that started the evening before still overlaps midnight.
        #expect(ICS.starts(text, from: "2026-11-10 00:00", to: "2026-11-12 00:00") == [
            "2026-11-09 23:00", "2026-11-10 23:00", "2026-11-11 23:00",
        ])
        #expect(ICS.starts(text, from: "2026-11-10 02:00", to: "2026-11-10 22:00").isEmpty)
    }

    @Test func lastWorkdayOfTheMonthWithSetPosition() {
        let text = series(":20261130T150000Z", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=4")
        #expect(ICS.starts(text, from: "2026-11-01 00:00", to: "2027-06-01 00:00") == [
            "2026-11-30 15:00", "2026-12-31 15:00", "2027-01-29 15:00", "2027-02-26 15:00",
        ])
    }

    @Test func weekStartChangesWhichWeeksCount() {
        // RFC 5545's own example: the result depends on WKST.
        let monday = series(";TZID=America/New_York:19970805T090000", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO")
        #expect(ICS.starts(monday, from: "1997-08-01 00:00", to: "1997-10-01 00:00", zone: "America/New_York") == [
            "1997-08-05 09:00", "1997-08-10 09:00", "1997-08-19 09:00", "1997-08-24 09:00",
        ])
        let sunday = series(";TZID=America/New_York:19970805T090000", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU")
        #expect(ICS.starts(sunday, from: "1997-08-01 00:00", to: "1997-10-01 00:00", zone: "America/New_York") == [
            "1997-08-05 09:00", "1997-08-17 09:00", "1997-08-19 09:00", "1997-08-31 09:00",
        ])
    }

    @Test func extraDatesAndExceptionsCombine() {
        let text = series(":20261102T090000Z", "FREQ=WEEKLY;COUNT=3", extra: """
        RDATE:20261104T120000Z,20261105T120000Z
        EXDATE:20261109T090000Z
        """)
        #expect(ICS.starts(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00") == [
            "2026-11-02 09:00", "2026-11-04 12:00", "2026-11-05 12:00", "2026-11-16 09:00",
        ])
    }

    @Test func oldDailySeriesStillShowsQuickly() {
        let text = series(":20100101T080000Z", "FREQ=DAILY")
        #expect(ICS.starts(text, from: "2026-11-21 00:00", to: "2026-11-23 00:00") == ["2026-11-21 08:00", "2026-11-22 08:00"])
    }

    @Test func runawayRulesAreCapped() {
        let text = series(":20000101T080000Z", "FREQ=DAILY")
        #expect(ICS.events(text, from: "2000-01-01 00:00", to: "2050-01-01 00:00").count == ICalendarReader.maximumOccurrences)
        // A rule that can never match ends instead of searching forever.
        let never = series(":20260101T080000Z", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")
        #expect(ICS.starts(never, from: "2026-01-01 00:00", to: "2100-01-01 00:00") == ["2026-01-01 08:00"])
    }

    @Test func iteratorWalksRulesInOrder() throws {
        let rule = try #require(ICalendarRecurrenceRule("FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU;COUNT=4"))
        #expect(rule.frequency == .monthly && rule.interval == 2 && rule.count == 4)
        #expect(rule.byDay == [ICalendarRecurrenceRule.Weekday(weekday: 2, ordinal: 2)])
        let iterator = ICalendarRecurrenceIterator(rule: rule, start: WallClockTime(year: 2026, month: 1, day: 13, hour: 10), isDate: false)
        var starts: [String] = []
        iterator.forEach(through: WallClockTime(year: 2030, month: 1, day: 1), isPastUntil: { _ in false }) { wall in
            starts.append(wall.dateTimeText)
            return true
        }
        #expect(starts == ["20260113T100000", "20260310T100000", "20260512T100000", "20260714T100000"])
        #expect(ICalendarRecurrenceRule("INTERVAL=2") == nil)
    }
}
