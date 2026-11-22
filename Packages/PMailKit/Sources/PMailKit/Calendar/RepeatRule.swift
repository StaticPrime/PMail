import Foundation

/// How an event repeats, as the editor offers it: every so many days, weeks (on some weekdays), months (on the first
/// time's day of the month, or on its first, second… or last weekday of the month) or years; with no end, until a
/// day, or a number of times. Reads and writes RRULE lines. A rule it can't show (hourly, or on several days of the
/// month, say) reads as nil, and the event keeps its own rule.
public struct RepeatRule: Hashable, Sendable {
    public enum Frequency: String, Sendable, Hashable, CaseIterable {
        case daily, weekly, monthly, yearly

        /// The unit, as "Repeat every 2 weeks" says it.
        public func unit(plural: Bool) -> String {
            switch self {
            case .daily: plural ? "days" : "day"
            case .weekly: plural ? "weeks" : "week"
            case .monthly: plural ? "months" : "month"
            case .yearly: plural ? "years" : "year"
            }
        }
    }

    /// A weekday of the month: the fourth Sunday, the last Friday.
    public struct WeekdayOfMonth: Hashable, Sendable {
        /// 1 to 4, or -1 for the last.
        public var ordinal: Int
        /// 1 is Sunday, as in `Calendar`.
        public var weekday: Int

        public init(ordinal: Int, weekday: Int) {
            self.ordinal = ordinal
            self.weekday = weekday
        }
    }

    public enum End: Hashable, Sendable {
        case never
        /// The last day it can happen on (midnight at its start).
        case on(Date)
        /// How many times it happens, the first included.
        case after(Int)
    }

    public var frequency: Frequency
    /// Every how many days, weeks, months or years.
    public var interval: Int
    /// For a weekly rule, the weekdays it happens on (1 is Sunday); empty means the first time's weekday.
    public var weekdays: Set<Int>
    /// For a monthly rule, the weekday of the month it happens on; nil means the first time's day of the month.
    public var weekdayOfMonth: WeekdayOfMonth?
    public var end: End

    public init(frequency: Frequency, interval: Int = 1, weekdays: Set<Int> = [], weekdayOfMonth: WeekdayOfMonth? = nil, end: End = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.weekdayOfMonth = weekdayOfMonth
        self.end = end
    }

    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static let workdays: Set<Int> = [2, 3, 4, 5, 6]

    // MARK: Reading

    /// The rule in an event's recurrence lines (its one RRULE, with no RDATE or EXRULE PMail can't show), for an event
    /// that first happens at `start`. EXDATE lines (occurrences deleted one at a time) don't change the rule.
    public init?(lines: [String], start: Date, calendar: Calendar = .current) {
        let entries = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let rules = entries.filter { $0.uppercased().hasPrefix("RRULE:") || $0.uppercased().hasPrefix("FREQ=") }
        let others = entries.filter { !$0.uppercased().hasPrefix("RRULE:") && !$0.uppercased().hasPrefix("FREQ=") && !$0.uppercased().hasPrefix("EXDATE") }
        guard rules.count == 1, others.isEmpty else { return nil }
        self.init(rrule: rules[0], start: start, calendar: calendar)
    }

    /// Reads an RRULE ("RRULE:FREQ=WEEKLY;BYDAY=MO,WE" or just its value) for an event that first happens at `start`.
    public init?(rrule text: String, start: Date, calendar: Calendar = .current) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.uppercased().hasPrefix("RRULE:") { value = String(value.dropFirst(6)) }
        guard let rule = ICalendarRecurrenceRule(value) else { return nil }
        guard rule.byYearDay.isEmpty, rule.byWeekNo.isEmpty, rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.bySecond.isEmpty,
              rule.bySetPos.isEmpty else { return nil }
        let parts = calendar.dateComponents([.month, .day], from: start)
        let startMonth = parts.month ?? 1
        let startDay = parts.day ?? 1
        var result: RepeatRule
        switch rule.frequency {
        case .daily:
            guard rule.byMonth.isEmpty, rule.byMonthDay.isEmpty else { return nil }
            if rule.byDay.isEmpty {
                result = RepeatRule(frequency: .daily, interval: rule.interval)
            } else {
                // Every weekday, written as a daily rule by some apps.
                guard rule.interval == 1, rule.byDay.allSatisfy({ $0.ordinal == 0 }) else { return nil }
                result = RepeatRule(frequency: .weekly, weekdays: Set(rule.byDay.map { $0.weekday + 1 }))
            }
        case .weekly:
            guard rule.byMonth.isEmpty, rule.byMonthDay.isEmpty, rule.byDay.allSatisfy({ $0.ordinal == 0 }) else { return nil }
            result = RepeatRule(frequency: .weekly, interval: rule.interval, weekdays: Set(rule.byDay.map { $0.weekday + 1 }))
        case .monthly:
            guard rule.byMonth.isEmpty else { return nil }
            if !rule.byDay.isEmpty {
                guard rule.byMonthDay.isEmpty, rule.byDay.count == 1, let entry = rule.byDay.first,
                      (1...4).contains(entry.ordinal) || entry.ordinal == -1 else { return nil }
                result = RepeatRule(frequency: .monthly, interval: rule.interval,
                                    weekdayOfMonth: WeekdayOfMonth(ordinal: entry.ordinal, weekday: entry.weekday + 1))
            } else {
                guard rule.byMonthDay.isEmpty || rule.byMonthDay == [startDay] else { return nil }
                result = RepeatRule(frequency: .monthly, interval: rule.interval)
            }
        case .yearly:
            guard rule.byDay.isEmpty, rule.byMonth.isEmpty || rule.byMonth == [startMonth],
                  rule.byMonthDay.isEmpty || rule.byMonthDay == [startDay] else { return nil }
            result = RepeatRule(frequency: .yearly, interval: rule.interval)
        default:
            return nil
        }
        if let count = rule.count {
            result.end = .after(count)
        } else if let until = rule.until {
            result.end = .on(Self.day(of: until, calendar: calendar))
        }
        self = result
    }

    /// The day an UNTIL falls on, where the Mac is.
    private static func day(of until: ICalendarDateTime, calendar: Calendar) -> Date {
        if until.form == .utc {
            return calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(until.wall.seconds)))
        }
        let date = until.wall.date
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: Writing

    /// The RRULE line for an event that first happens at `start`. An end day is written as a date for an all-day
    /// event, and as the end of that day (in UTC) for a timed one.
    public func rrule(start: Date, isAllDay: Bool, calendar: Calendar = .current) -> String {
        var parts = ["FREQ=" + frequency.rawValue.uppercased()]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        switch frequency {
        case .weekly:
            let days = weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : weekdays.sorted()
            parts.append("BYDAY=" + days.map { Self.weekdayCodes[$0 - 1] }.joined(separator: ","))
        case .monthly:
            if let weekdayOfMonth { parts.append("BYDAY=\(weekdayOfMonth.ordinal)\(Self.weekdayCodes[weekdayOfMonth.weekday - 1])") }
        case .daily, .yearly:
            break
        }
        switch end {
        case .never:
            break
        case let .after(count):
            parts.append("COUNT=\(max(1, count))")
        case let .on(day):
            parts.append("UNTIL=" + Self.untilText(day, isAllDay: isAllDay, calendar: calendar))
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    static func untilText(_ day: Date, isAllDay: Bool, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if isAllDay {
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: day)
        }
        let start = calendar.startOfDay(for: day)
        let last = (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).addingTimeInterval(-1)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: last)
    }

    // MARK: Saying it

    /// The rule in words, for an event that first happens at `start`: "Weekly on Sunday", "Every 2 weeks on Monday,
    /// Wednesday", "Monthly on the fourth Sunday", "Annually on November 22", "Every weekday", "Daily, 13 times".
    public func summary(start: Date, calendar: Calendar = .current) -> String {
        let every = interval > 1 ? "Every \(interval) \(frequency.unit(plural: true))" : nil
        var text: String
        switch frequency {
        case .daily:
            text = every ?? "Daily"
        case .weekly:
            let days = weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : weekdays.sorted()
            if interval == 1, Set(days) == Self.workdays {
                text = "Every weekday"
            } else if days.count == 7 {
                text = (every ?? "Weekly") + " on every day"
            } else {
                let names = days.map { Self.weekdayName($0, calendar: calendar) }.joined(separator: ", ")
                text = (every ?? "Weekly") + " on " + names
            }
        case .monthly:
            text = (every ?? "Monthly") + " on " + monthlyText(start: start, calendar: calendar)
        case .yearly:
            text = (every ?? "Annually") + " on " + Self.monthDayText(start, calendar: calendar)
        }
        switch end {
        case .never:
            break
        case let .after(count):
            text += count == 1 ? ", once" : ", \(count) times"
        case let .on(day):
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale ?? .current
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMdy")
            text += ", until " + formatter.string(from: day)
        }
        return text
    }

    /// "day 22" or "the fourth Sunday".
    public func monthlyText(start: Date, calendar: Calendar = .current) -> String {
        if let weekdayOfMonth { return "the " + Self.ordinalName(weekdayOfMonth.ordinal) + " " + Self.weekdayName(weekdayOfMonth.weekday, calendar: calendar) }
        return "day \(calendar.component(.day, from: start))"
    }

    static func ordinalName(_ ordinal: Int) -> String {
        switch ordinal {
        case 1: "first"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        default: "last"
        }
    }

    static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.standaloneWeekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    static func monthDayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter.string(from: date)
    }

    // MARK: Choices

    /// The weekday of the month a day is: the fourth Sunday for November 22, 2026, and the last one when it's the
    /// fifth.
    public static func weekdayOfMonth(of date: Date, calendar: Calendar = .current) -> WeekdayOfMonth {
        let parts = calendar.dateComponents([.day, .weekday], from: date)
        let ordinal = ((parts.day ?? 1) - 1) / 7 + 1
        return WeekdayOfMonth(ordinal: ordinal > 4 ? -1 : ordinal, weekday: parts.weekday ?? 1)
    }

    /// The usual choices for an event first happening at `start`: daily, weekly on its weekday, monthly on its weekday
    /// of the month, annually on its date, and every weekday.
    public static func presets(for start: Date, calendar: Calendar = .current) -> [RepeatRule] {
        [RepeatRule(frequency: .daily),
         RepeatRule(frequency: .weekly, weekdays: [calendar.component(.weekday, from: start)]),
         RepeatRule(frequency: .monthly, weekdayOfMonth: weekdayOfMonth(of: start, calendar: calendar)),
         RepeatRule(frequency: .yearly),
         RepeatRule(frequency: .weekly, weekdays: workdays)]
    }

    /// The same rule written out for comparing with the presets: a weekly rule's weekdays filled in.
    public func normalized(start: Date, calendar: Calendar = .current) -> RepeatRule {
        var rule = self
        if rule.frequency == .weekly, rule.weekdays.isEmpty { rule.weekdays = [calendar.component(.weekday, from: start)] }
        if rule.frequency != .weekly { rule.weekdays = [] }
        if rule.frequency != .monthly { rule.weekdayOfMonth = nil }
        return rule
    }

    // MARK: Occurrences

    /// The starts of the occurrences that begin in `range`, for an event first happening at `first`, at the same time
    /// of day (wall-clock, across daylight saving changes). Gives up after `limit` occurrences.
    public func starts(from first: Date, in range: DateInterval, calendar: Calendar = .current, limit: Int = 2_000) -> [Date] {
        var result: [Date] = []
        var made = 0
        let lastDay: Date? = if case let .on(day) = end { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) } else { nil }
        let count: Int? = if case let .after(times) = end { times } else { nil }
        let time = calendar.dateComponents([.hour, .minute, .second], from: first)
        func at(_ day: Date) -> Date? {
            calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }
        /// Takes a start; false when the rule has run out or gone past the range.
        func take(_ start: Date) -> Bool {
            if start < first { return true }
            if let lastDay, start >= lastDay { return false }
            if let count, made >= count { return false }
            if start >= range.end { return false }
            made += 1
            if start >= range.start { result.append(start) }
            return made < limit
        }
        let firstDay = calendar.startOfDay(for: first)
        var period = 0
        periods: while period < 100_000 {
            switch frequency {
            case .daily:
                guard let day = calendar.date(byAdding: .day, value: period * interval, to: firstDay), let start = at(day) else { break periods }
                if !take(start) { break periods }
            case .weekly:
                let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7),
                                              to: firstDay) ?? firstDay
                guard let week = calendar.date(byAdding: .weekOfYear, value: period * interval, to: weekStart) else { break periods }
                let days = weekdays.isEmpty ? [calendar.component(.weekday, from: first)] : Array(weekdays)
                let ordered = days.map { ($0 - calendar.firstWeekday + 7) % 7 }.sorted()
                for offset in ordered {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: week), let start = at(day) else { continue }
                    if !take(start) { break periods }
                }
            case .monthly:
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: firstDay)) ?? firstDay
                guard let month = calendar.date(byAdding: .month, value: period * interval, to: monthStart) else { break periods }
                if let day = monthDay(in: month, firstDay: firstDay, calendar: calendar), let start = at(day) {
                    if !take(start) { break periods }
                } else if month >= range.end {
                    break periods
                }
            case .yearly:
                let parts = calendar.dateComponents([.year, .month, .day], from: firstDay)
                let year = (parts.year ?? 1970) + period * interval
                if let day = calendar.date(from: DateComponents(year: year, month: parts.month, day: parts.day)),
                   calendar.component(.day, from: day) == parts.day, let start = at(day) {
                    if !take(start) { break periods }
                } else if let yearStart = calendar.date(from: DateComponents(year: year)), yearStart >= range.end {
                    break periods
                }
            }
            period += 1
        }
        return result
    }

    /// The day of a month the rule falls on, or nil in a month without one (a 31st).
    private func monthDay(in month: Date, firstDay: Date, calendar: Calendar) -> Date? {
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
        if let weekdayOfMonth {
            let matching = days.compactMap { day -> Date? in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: month),
                      calendar.component(.weekday, from: date) == weekdayOfMonth.weekday else { return nil }
                return date
            }
            return weekdayOfMonth.ordinal == -1 ? matching.last : matching[safe: weekdayOfMonth.ordinal - 1]
        }
        let day = calendar.component(.day, from: firstDay)
        guard days.contains(day) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: month)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
