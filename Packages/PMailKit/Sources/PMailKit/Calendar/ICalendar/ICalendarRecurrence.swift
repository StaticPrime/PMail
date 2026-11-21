import Foundation

/// A repeating event's rule, from an RRULE line (RFC 5545 section 3.3.10): how often it repeats, on which days, and
/// until when.
struct ICalendarRecurrenceRule: Sendable, Hashable {
    enum Frequency: String, Sendable {
        case secondly = "SECONDLY", minutely = "MINUTELY", hourly = "HOURLY"
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    /// A BYDAY entry: a weekday (0 is Sunday) and, for monthly and yearly rules, which one of the month or year it
    /// means (2 for the second, -1 for the last, 0 for every one).
    struct Weekday: Sendable, Hashable {
        var weekday: Int
        var ordinal: Int
    }

    static let weekdayNames = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: ICalendarDateTime?
    var byDay: [Weekday] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var byYearDay: [Int] = []
    var byWeekNo: [Int] = []
    var byHour: [Int] = []
    var byMinute: [Int] = []
    var bySecond: [Int] = []
    var bySetPos: [Int] = []
    /// The day weeks start on (WKST), 0 for Sunday; Monday unless the rule says otherwise.
    var weekStart = 1

    init(frequency: Frequency) {
        self.frequency = frequency
    }

    /// Reads an RRULE value ("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH"). Returns nil without a frequency it knows; parts
    /// it can't read are left out.
    init?(_ text: String) {
        var frequency: Frequency?
        var rule = ICalendarRecurrenceRule(frequency: .daily)
        for part in text.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            func numbers(_ range: ClosedRange<Int>, allowNegative: Bool = true) -> [Int] {
                value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { number in
                    number < 0 ? allowNegative && range.contains(-number) : range.contains(number)
                }
            }
            switch name {
            case "FREQ": frequency = Frequency(rawValue: value.uppercased())
            case "INTERVAL": rule.interval = max(1, min(Int(value) ?? 1, 10_000))
            case "COUNT": rule.count = Int(value).map { max(1, $0) }
            case "UNTIL": rule.until = ICalendarDateTime(text: value)
            case "BYDAY": rule.byDay = value.split(separator: ",").compactMap { Self.weekday(String($0)) }
            case "BYMONTHDAY": rule.byMonthDay = numbers(1...31)
            case "BYMONTH": rule.byMonth = numbers(1...12, allowNegative: false)
            case "BYYEARDAY": rule.byYearDay = numbers(1...366)
            case "BYWEEKNO": rule.byWeekNo = numbers(1...53)
            case "BYHOUR": rule.byHour = numbers(0...23, allowNegative: false)
            case "BYMINUTE": rule.byMinute = numbers(0...59, allowNegative: false)
            case "BYSECOND": rule.bySecond = numbers(0...59, allowNegative: false)
            case "BYSETPOS": rule.bySetPos = numbers(1...366)
            case "WKST": rule.weekStart = Self.weekdayNames.firstIndex(of: value.uppercased()) ?? 1
            default: break
            }
        }
        guard let frequency else { return nil }
        rule.frequency = frequency
        self = rule
    }

    /// Reads a BYDAY entry ("MO", "2TU", "-1FR").
    private static func weekday(_ text: String) -> Weekday? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count >= 2, let weekday = weekdayNames.firstIndex(of: String(trimmed.suffix(2))) else { return nil }
        let prefix = trimmed.dropLast(2)
        guard !prefix.isEmpty else { return Weekday(weekday: weekday, ordinal: 0) }
        guard let ordinal = Int(prefix), ordinal != 0, abs(ordinal) <= 53 else { return nil }
        return Weekday(weekday: weekday, ordinal: ordinal)
    }

    /// Whether the rule runs out by itself (a COUNT or an UNTIL).
    var isFinite: Bool { count != nil || until != nil }
}

/// Walks the starts a recurrence rule gives an event, as wall-clock readings in the event's own time zone, so that
/// "9:00 every Monday" stays at 9:00 across daylight saving changes. It follows the BYxxx rules of RFC 5545 for
/// daily, weekly, monthly and yearly rules; other frequencies give only the first start.
struct ICalendarRecurrenceIterator {
    /// Most periods (days, weeks, months or years) walked in one go, against rules that never match anything.
    static let maximumPeriods = 200_000

    let rule: ICalendarRecurrenceRule
    /// DTSTART, which is always the first start.
    let start: WallClockTime
    let isDate: Bool

    /// Calls `body` with DTSTART and then each later start in order, until `body` returns false, the rule runs out
    /// (COUNT or UNTIL), the starts pass `limit`, or the safety cap is reached. With `skippingTo`, a rule without a
    /// COUNT jumps ahead to the period that reading falls in instead of walking from DTSTART (so a daily event
    /// started years ago is still quick to show).
    func forEach(skippingTo target: WallClockTime? = nil, through limit: WallClockTime, isPastUntil: (WallClockTime) -> Bool,
                 _ body: (WallClockTime) -> Bool) {
        var produced = 1
        guard body(start) else { return }
        if let count = rule.count, produced >= count { return }
        guard [.daily, .weekly, .monthly, .yearly].contains(rule.frequency) else { return }

        let startDay = start.dayNumber
        let (startYear, startMonth, startDayOfMonth) = start.date
        let interval = max(1, rule.interval)
        let yearlyByWeek = rule.frequency == .yearly && !rule.byWeekNo.isEmpty

        // What a rule leaves out comes from DTSTART ("every year" means on DTSTART's month and day).
        var byMonth = rule.byMonth
        var byMonthDay = rule.byMonthDay
        var plainDays = Set<Int>()
        var numberedDays: [ICalendarRecurrenceRule.Weekday] = []
        for entry in rule.byDay {
            if entry.ordinal == 0 || rule.frequency == .daily || rule.frequency == .weekly || yearlyByWeek {
                plainDays.insert(entry.weekday)
            } else {
                numberedDays.append(entry)
            }
        }
        if rule.byWeekNo.isEmpty && rule.byYearDay.isEmpty && rule.byMonthDay.isEmpty && rule.byDay.isEmpty {
            switch rule.frequency {
            case .yearly:
                if byMonth.isEmpty { byMonth = [startMonth] }
                byMonthDay = [startDayOfMonth]
            case .monthly:
                byMonthDay = [startDayOfMonth]
            case .weekly:
                plainDays = [start.weekday]
            default:
                break
            }
        }
        let monthSet = Set(byMonth)
        let monthDaySet = Set(byMonthDay)
        let yearDaySet = Set(rule.byYearDay)
        let weekNoSet = yearlyByWeek ? Set(rule.byWeekNo) : []
        let times: [Int] = {
            guard !isDate else { return [0] }
            let hours = rule.byHour.isEmpty ? [start.hour] : rule.byHour
            let minutes = rule.byMinute.isEmpty ? [start.minute] : rule.byMinute
            let seconds = rule.bySecond.isEmpty ? [start.second] : rule.bySecond
            let all = hours.flatMap { hour in minutes.flatMap { minute in seconds.map { hour * 3600 + minute * 60 + $0 } } }
            return Array(Set(all)).sorted()
        }()

        func weekStart(of day: Int) -> Int {
            day - (GregorianDays.weekday(day) - rule.weekStart + 7) % 7
        }
        /// The first day of week 1 of a year: the week (starting on WKST) that has at least four days in the year.
        func firstWeekStart(ofYear year: Int) -> Int {
            let januaryFirst = GregorianDays.dayNumber(year: year, month: 1, day: 1)
            let start = weekStart(of: januaryFirst)
            return januaryFirst - start >= 4 ? start + 7 : start
        }
        func floorDivide(_ value: Int, _ divisor: Int) -> Int {
            value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
        }
        let startMonthIndex = startYear * 12 + startMonth - 1
        let startWeek = weekStart(of: startDay)

        /// The days a period covers, and the year it falls in (for a yearly rule, the year it stands for).
        func days(ofPeriod period: Int) -> (range: ClosedRange<Int>, year: Int) {
            switch rule.frequency {
            case .daily:
                let day = startDay + period * interval
                return (day...day, GregorianDays.date(fromDayNumber: day).year)
            case .weekly:
                let first = startWeek + period * interval * 7
                return (first...first + 6, GregorianDays.date(fromDayNumber: first).year)
            case .monthly:
                let monthIndex = startMonthIndex + period * interval
                let year = floorDivide(monthIndex, 12), month = monthIndex - year * 12 + 1
                let first = GregorianDays.dayNumber(year: year, month: month, day: 1)
                return (first...first + GregorianDays.daysInMonth(year: year, month: month) - 1, year)
            default:
                let year = startYear + period * interval
                if yearlyByWeek { return (firstWeekStart(ofYear: year)...firstWeekStart(ofYear: year + 1) - 1, year) }
                let first = GregorianDays.dayNumber(year: year, month: 1, day: 1)
                return (first...first + GregorianDays.daysInYear(year) - 1, year)
            }
        }

        func periodIndex(containing day: Int) -> Int {
            switch rule.frequency {
            case .daily: return floorDivide(day - startDay, interval)
            case .weekly: return floorDivide((weekStart(of: day) - startWeek) / 7, interval)
            case .monthly:
                let (year, month, _) = GregorianDays.date(fromDayNumber: day)
                return floorDivide(year * 12 + month - 1 - startMonthIndex, interval)
            default:
                return floorDivide(GregorianDays.date(fromDayNumber: day).year - startYear, interval)
            }
        }

        var period = 0
        if let target, rule.count == nil { period = max(0, periodIndex(containing: target.dayNumber) - 1) }
        var walked = 0
        while walked < Self.maximumPeriods {
            walked += 1
            let (range, periodYear) = days(ofPeriod: period)
            if range.lowerBound > limit.dayNumber { return }

            // Numbered weekdays ("2TU", "-1FR") pick days within each month, or within the year.
            var numbered = Set<Int>()
            if !numberedDays.isEmpty {
                var spans: [ClosedRange<Int>] = []
                if rule.frequency == .monthly {
                    spans = [range]
                } else if !byMonth.isEmpty {
                    spans = byMonth.sorted().map { month in
                        let first = GregorianDays.dayNumber(year: periodYear, month: month, day: 1)
                        return first...first + GregorianDays.daysInMonth(year: periodYear, month: month) - 1
                    }
                } else {
                    spans = [range]
                }
                for span in spans {
                    for entry in numberedDays {
                        let day: Int
                        if entry.ordinal > 0 {
                            let first = span.lowerBound + (entry.weekday - GregorianDays.weekday(span.lowerBound) + 7) % 7
                            day = first + (entry.ordinal - 1) * 7
                        } else {
                            let last = span.upperBound - (GregorianDays.weekday(span.upperBound) - entry.weekday + 7) % 7
                            day = last + (entry.ordinal + 1) * 7
                        }
                        if span.contains(day) { numbered.insert(day) }
                    }
                }
            }

            // A yearly rule with months only looks at those months' days.
            var dayList: [Int] = []
            if rule.frequency == .yearly && !yearlyByWeek && !byMonth.isEmpty {
                for month in byMonth.sorted() {
                    let first = GregorianDays.dayNumber(year: periodYear, month: month, day: 1)
                    dayList.append(contentsOf: first...first + GregorianDays.daysInMonth(year: periodYear, month: month) - 1)
                }
            } else {
                dayList = Array(range)
            }

            var candidates: [WallClockTime] = []
            let weekOneStart = yearlyByWeek ? firstWeekStart(ofYear: periodYear) : 0
            let weeksInYear = yearlyByWeek ? (firstWeekStart(ofYear: periodYear + 1) - weekOneStart) / 7 : 0
            for day in dayList {
                let (year, month, dayOfMonth) = GregorianDays.date(fromDayNumber: day)
                if !monthSet.isEmpty && !monthSet.contains(month) { continue }
                if !monthDaySet.isEmpty {
                    let length = GregorianDays.daysInMonth(year: year, month: month)
                    if !monthDaySet.contains(dayOfMonth) && !monthDaySet.contains(dayOfMonth - length - 1) { continue }
                }
                if !yearDaySet.isEmpty {
                    let dayOfYear = day - GregorianDays.dayNumber(year: year, month: 1, day: 1) + 1
                    if !yearDaySet.contains(dayOfYear) && !yearDaySet.contains(dayOfYear - GregorianDays.daysInYear(year) - 1) { continue }
                }
                if !weekNoSet.isEmpty {
                    let week = (day - weekOneStart) / 7 + 1
                    if !weekNoSet.contains(week) && !weekNoSet.contains(week - weeksInYear - 1) { continue }
                }
                if !plainDays.isEmpty || !numberedDays.isEmpty {
                    if !plainDays.contains(GregorianDays.weekday(day)) && !numbered.contains(day) { continue }
                }
                for time in times { candidates.append(WallClockTime(dayNumber: day, secondOfDay: time)) }
            }
            if !rule.bySetPos.isEmpty && !candidates.isEmpty {
                var picked = Set<WallClockTime>()
                for position in rule.bySetPos {
                    let index = position > 0 ? position - 1 : candidates.count + position
                    if candidates.indices.contains(index) { picked.insert(candidates[index]) }
                }
                candidates = picked.sorted()
            }
            for candidate in candidates where candidate > start {
                if isPastUntil(candidate) { return }
                produced += 1
                guard body(candidate) else { return }
                if let count = rule.count, produced >= count { return }
            }
            period += 1
        }
    }
}
