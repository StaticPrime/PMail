import Foundation
import Testing
@testable import PMailKit

/// How events repeat, as the editor offers it: the usual choices, custom rules, RRULE lines and occurrences.
struct RepeatRuleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func wall(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    @Test func theUsualChoicesForADay() {
        let sunday = at(2026, 11, 22)
        let presets = RepeatRule.presets(for: sunday, calendar: calendar)
        #expect(presets.map { $0.summary(start: sunday, calendar: calendar) }
                == ["Daily", "Weekly on Sunday", "Monthly on the fourth Sunday", "Annually on November 22", "Every weekday"])
        #expect(presets.map { $0.rrule(start: sunday, isAllDay: false, calendar: calendar) }
                == ["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY;BYDAY=SU", "RRULE:FREQ=MONTHLY;BYDAY=4SU", "RRULE:FREQ=YEARLY",
                    "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
        #expect(RepeatRule.weekdayOfMonth(of: at(2026, 11, 29), calendar: calendar) == .init(ordinal: -1, weekday: 1), "the fifth is the last")
        #expect(RepeatRule.weekdayOfMonth(of: at(2026, 11, 1), calendar: calendar) == .init(ordinal: 1, weekday: 1))
    }

    @Test func customRulesAndTheirEnds() {
        let monday = at(2026, 11, 23)
        var rule = RepeatRule(frequency: .weekly, interval: 2, weekdays: [2, 4], end: .after(13))
        #expect(rule.rrule(start: monday, isAllDay: false, calendar: calendar) == "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=13")
        #expect(rule.summary(start: monday, calendar: calendar) == "Every 2 weeks on Monday, Wednesday, 13 times")
        rule.end = .on(at(2027, 2, 21, 0, 0))
        #expect(rule.rrule(start: monday, isAllDay: false, calendar: calendar).hasSuffix(";UNTIL=20270222T045959Z"), "the end of that day, in UTC")
        #expect(rule.rrule(start: monday, isAllDay: true, calendar: calendar).hasSuffix(";UNTIL=20270221"), "a date for an all-day event")
        #expect(rule.summary(start: monday, calendar: calendar) == "Every 2 weeks on Monday, Wednesday, until Feb 21, 2027")
        let monthly = RepeatRule(frequency: .monthly, interval: 3)
        #expect(monthly.summary(start: monday, calendar: calendar) == "Every 3 months on day 23")
        #expect(RepeatRule(frequency: .daily, end: .after(1)).summary(start: monday, calendar: calendar) == "Daily, once")
    }

    @Test func readingRules() throws {
        let monday = at(2026, 11, 23)
        #expect(RepeatRule(rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=13", start: monday, calendar: calendar)
                == RepeatRule(frequency: .weekly, interval: 2, weekdays: [2, 4], end: .after(13)))
        let lastFriday = try #require(RepeatRule(rrule: "FREQ=MONTHLY;BYDAY=-1FR", start: at(2026, 11, 27), calendar: calendar))
        #expect(lastFriday.summary(start: at(2026, 11, 27), calendar: calendar) == "Monthly on the last Friday")
        #expect(RepeatRule(rrule: "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", start: monday, calendar: calendar)?.summary(start: monday, calendar: calendar)
                == "Every weekday", "a daily rule on weekdays")
        #expect(RepeatRule(rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=23", start: monday, calendar: calendar) == RepeatRule(frequency: .monthly))
        #expect(RepeatRule(rrule: "RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=23", start: monday, calendar: calendar) == RepeatRule(frequency: .yearly))
        #expect(RepeatRule(rrule: "RRULE:FREQ=WEEKLY;UNTIL=20270221", start: monday, calendar: calendar)?.end == .on(at(2027, 2, 21, 0, 0)))
        #expect(RepeatRule(rrule: "RRULE:FREQ=WEEKLY;UNTIL=20270222T045959Z", start: monday, calendar: calendar)?.end == .on(at(2027, 2, 21, 0, 0)),
                "an UNTIL in UTC is the day it falls on here")
        // Rules the editor can't show.
        #expect(RepeatRule(rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15", start: monday, calendar: calendar) == nil)
        #expect(RepeatRule(rrule: "RRULE:FREQ=HOURLY", start: monday, calendar: calendar) == nil)
        #expect(RepeatRule(rrule: "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=2", start: monday, calendar: calendar) == nil)
        #expect(RepeatRule(rrule: "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", start: monday, calendar: calendar) == nil)
        // An event's lines: occurrences deleted one at a time don't matter; extra dates and second rules do.
        #expect(RepeatRule(lines: ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE:20261130T173000Z"], start: monday, calendar: calendar) != nil)
        #expect(RepeatRule(lines: ["RRULE:FREQ=WEEKLY;BYDAY=MO", "RDATE:20261201T173000Z"], start: monday, calendar: calendar) == nil)
        #expect(RepeatRule(lines: ["RRULE:FREQ=WEEKLY", "RRULE:FREQ=DAILY"], start: monday, calendar: calendar) == nil)
        #expect(RepeatRule(lines: [], start: monday, calendar: calendar) == nil)
    }

    @Test func occurrences() {
        let range = DateInterval(start: at(2026, 11, 1, 0, 0), end: at(2027, 1, 1, 0, 0))
        let monday = at(2026, 11, 23, 9, 0)
        let fortnightly = RepeatRule(frequency: .weekly, interval: 2, weekdays: [2, 4])
        #expect(fortnightly.starts(from: monday, in: range, calendar: calendar).map(wall)
                == ["2026-11-23 09:00", "2026-11-25 09:00", "2026-12-07 09:00", "2026-12-09 09:00", "2026-12-21 09:00", "2026-12-23 09:00"])
        var counted = fortnightly
        counted.end = .after(3)
        #expect(counted.starts(from: monday, in: range, calendar: calendar).map(wall) == ["2026-11-23 09:00", "2026-11-25 09:00", "2026-12-07 09:00"])
        let weekly = RepeatRule(frequency: .weekly, end: .on(at(2026, 12, 6, 0, 0)))
        #expect(weekly.starts(from: monday, in: range, calendar: calendar).map(wall) == ["2026-11-23 09:00", "2026-11-30 09:00"], "until a day")
        let lastFriday = RepeatRule(frequency: .monthly, weekdayOfMonth: .init(ordinal: -1, weekday: 6))
        #expect(lastFriday.starts(from: at(2026, 11, 27, 9, 0), in: DateInterval(start: range.start, end: at(2027, 2, 1, 0, 0)), calendar: calendar)
                .map(wall) == ["2026-11-27 09:00", "2026-12-25 09:00", "2027-01-29 09:00"])
        let thirtyFirst = RepeatRule(frequency: .monthly)
        #expect(thirtyFirst.starts(from: at(2027, 1, 31, 9, 0), in: DateInterval(start: at(2027, 1, 1, 0, 0), end: at(2027, 5, 1, 0, 0)), calendar: calendar)
                .map(wall) == ["2027-01-31 09:00", "2027-03-31 09:00"], "months without the day are skipped")
        let leapDay = RepeatRule(frequency: .yearly)
        #expect(leapDay.starts(from: at(2028, 2, 29, 9, 0), in: DateInterval(start: at(2028, 1, 1, 0, 0), end: at(2033, 1, 1, 0, 0)), calendar: calendar)
                .map(wall) == ["2028-02-29 09:00", "2032-02-29 09:00"])
        let daily = RepeatRule(frequency: .daily)
        let acrossTheChange = daily.starts(from: at(2027, 3, 12, 9, 0), in: DateInterval(start: at(2027, 3, 12, 0, 0), end: at(2027, 3, 16, 0, 0)),
                                           calendar: calendar)
        #expect(acrossTheChange.map(wall) == ["2027-03-12 09:00", "2027-03-13 09:00", "2027-03-14 09:00", "2027-03-15 09:00"],
                "the same time of day when the clocks change")
        #expect(daily.starts(from: monday, in: DateInterval(start: at(2026, 11, 25, 0, 0), end: at(2026, 11, 27, 0, 0)), calendar: calendar)
                .map(wall) == ["2026-11-25 09:00", "2026-11-26 09:00"], "only the ones in the range")
    }
}
