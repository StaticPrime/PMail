import Foundation

/// Gregorian calendar arithmetic with plain whole numbers, so dates in calendar files never depend on the Mac's
/// settings. Day numbers count days since 1 January 1970; weekdays run from 0 (Sunday) to 6 (Saturday).
enum GregorianDays {
    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(fromDayNumber dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func weekday(_ dayNumber: Int) -> Int {
        ((dayNumber % 7) + 7 + 4) % 7
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func daysInYear(_ year: Int) -> Int {
        isLeapYear(year) ? 366 : 365
    }

    /// The day number of the `ordinal`th `weekday` in a month (2 for the second, -1 for the last), or nil if the
    /// month hasn't that many.
    static func nthWeekday(_ weekday: Int, ordinal: Int, year: Int, month: Int) -> Int? {
        let first = dayNumber(year: year, month: month, day: 1)
        let last = first + daysInMonth(year: year, month: month) - 1
        let day: Int
        if ordinal > 0 {
            day = first + (weekday - self.weekday(first) + 7) % 7 + (ordinal - 1) * 7
        } else {
            day = last - (self.weekday(last) - weekday + 7) % 7 + (ordinal + 1) * 7
        }
        return (first...last).contains(day) ? day : nil
    }
}

/// A reading on a wall clock with no time zone ("9:00 on 21 November 2026"), as iCalendar writes local, floating and
/// all-day times. It's kept as seconds since 1970-01-01 00:00 on the same clock, so arithmetic is plain addition.
struct WallClockTime: Sendable, Hashable, Comparable {
    var seconds: Int64

    init(seconds: Int64) {
        self.seconds = seconds
    }

    init(dayNumber: Int, secondOfDay: Int = 0) {
        seconds = Int64(dayNumber) * 86_400 + Int64(secondOfDay)
    }

    init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.init(dayNumber: GregorianDays.dayNumber(year: year, month: month, day: day),
                  secondOfDay: hour * 3600 + minute * 60 + second)
    }

    var dayNumber: Int {
        let quotient = seconds / 86_400
        return Int(seconds % 86_400 < 0 ? quotient - 1 : quotient)
    }

    var secondOfDay: Int { Int(seconds - Int64(dayNumber) * 86_400) }
    var date: (year: Int, month: Int, day: Int) { GregorianDays.date(fromDayNumber: dayNumber) }
    var hour: Int { secondOfDay / 3600 }
    var minute: Int { secondOfDay % 3600 / 60 }
    var second: Int { secondOfDay % 60 }
    var weekday: Int { GregorianDays.weekday(dayNumber) }

    func adding(seconds: Int64) -> WallClockTime {
        WallClockTime(seconds: self.seconds + seconds)
    }

    func adding(days: Int) -> WallClockTime {
        WallClockTime(seconds: seconds + Int64(days) * 86_400)
    }

    /// "20261121".
    var dateText: String {
        let (year, month, day) = date
        return pad(year, 4) + pad(month, 2) + pad(day, 2)
    }

    /// "20261121T090000".
    var dateTimeText: String {
        dateText + "T" + pad(hour, 2) + pad(minute, 2) + pad(second, 2)
    }

    static func < (lhs: WallClockTime, rhs: WallClockTime) -> Bool {
        lhs.seconds < rhs.seconds
    }

    private func pad(_ number: Int, _ width: Int) -> String {
        let digits = String(abs(number))
        return (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

/// A DATE or DATE-TIME value as an iCalendar file writes it: the wall-clock reading, and how to place it in time.
struct ICalendarDateTime: Sendable, Hashable {
    enum Form: Sendable, Hashable {
        /// A whole day (VALUE=DATE), for all-day events.
        case date
        /// UTC, written with a trailing Z.
        case utc
        /// Local time wherever the reader is.
        case floating
        /// Wall-clock time in the named time zone (TZID).
        case zoned(String)
    }

    var wall: WallClockTime
    var form: Form

    init(wall: WallClockTime, form: Form) {
        self.wall = wall
        self.form = form
    }

    var isDate: Bool { form == .date }

    /// The TZID, for a zoned value.
    var tzid: String? {
        if case let .zoned(tzid) = form { tzid } else { nil }
    }

    /// Reads "20261121", "20261121T090000" or "20261121T140000Z" (dashes and colons are tolerated). A TZID makes a
    /// local time zoned; `isDate` (from VALUE=DATE) keeps only the day.
    init?<S: StringProtocol>(text: S, tzid: String? = nil, isDate forceDate: Bool = false) {
        let compact = text.unicodeScalars.filter { $0 != "-" && $0 != ":" && $0 != " " && $0 != "\t" }
        let characters = Array(String(String.UnicodeScalarView(compact)).utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= characters.count else { return nil }
            var value = 0
            for index in range {
                let byte = characters[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard characters.count >= 8, let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              (1...12).contains(month), year >= 1, day >= 1, day <= GregorianDays.daysInMonth(year: year, month: month) else { return nil }
        if characters.count == 8 || forceDate {
            self.init(wall: WallClockTime(year: year, month: month, day: day), form: .date)
            return
        }
        guard characters[8] == UInt8(ascii: "T") || characters[8] == UInt8(ascii: "t"),
              let hour = number(9..<11), let minute = number(11..<13), hour <= 24, minute <= 59 else { return nil }
        var second = 0
        var rest = 13
        if let seconds = number(13..<15) {
            second = min(seconds, 59)
            rest = 15
        }
        // Skip fractions of a second, which some writers add.
        if rest < characters.count, characters[rest] == UInt8(ascii: ".") {
            rest += 1
            while rest < characters.count, characters[rest] >= 48, characters[rest] <= 57 { rest += 1 }
        }
        let isUTC = rest < characters.count && (characters[rest] == UInt8(ascii: "Z") || characters[rest] == UInt8(ascii: "z"))
        let wall = WallClockTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        if isUTC {
            self.init(wall: wall, form: .utc)
        } else if let tzid = tzid?.trimmingCharacters(in: .whitespaces), !tzid.isEmpty {
            self.init(wall: wall, form: .zoned(tzid))
        } else {
            self.init(wall: wall, form: .floating)
        }
    }

    /// Reads a property's value, minding its VALUE and TZID parameters.
    init?(_ line: ICalendarLine) {
        self.init(text: line.value, tzid: line.parameter("TZID"), isDate: line.parameter("VALUE")?.uppercased() == "DATE")
    }

    /// The value as a file writes it ("20261121", "20261121T140000Z", "20261121T090000").
    var text: String {
        switch form {
        case .date: wall.dateText
        case .utc: wall.dateTimeText + "Z"
        case .floating, .zoned: wall.dateTimeText
        }
    }

    /// A property line carrying this value, with VALUE=DATE or TZID as it needs.
    func line(_ name: String) -> ICalendarLine {
        switch form {
        case .date: ICalendarLine(name, parameters: [ICalendarParameter("VALUE", "DATE")], value: text)
        case let .zoned(tzid): ICalendarLine(name, parameters: [ICalendarParameter("TZID", tzid)], value: text)
        case .utc, .floating: ICalendarLine(name, value: text)
        }
    }
}

/// A DURATION value ("PT1H30M", "-P1D", "P2W"). Days follow the wall clock across daylight saving changes; hours,
/// minutes and seconds are exact, as RFC 5545 says.
struct ICalendarDuration: Sendable, Hashable {
    /// Whole days, with weeks counted as seven.
    var days: Int
    /// Hours, minutes and seconds together.
    var seconds: Int

    init(days: Int = 0, seconds: Int = 0) {
        self.days = days
        self.seconds = seconds
    }

    init?<S: StringProtocol>(_ text: S) {
        var characters = Substring(text.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1
        if characters.first == "-" { sign = -1; characters = characters.dropFirst() }
        else if characters.first == "+" { characters = characters.dropFirst() }
        guard characters.first == "P" else { return nil }
        characters = characters.dropFirst()
        var days = 0, seconds = 0, number = 0, hasNumber = false, inTime = false, sawPart = false
        for character in characters {
            if let digit = character.wholeNumberValue, character.isASCII {
                guard number < 100_000_000 else { return nil }
                number = number * 10 + digit
                hasNumber = true
                continue
            }
            switch character {
            case "T":
                inTime = true
                continue
            case "W" where !inTime && hasNumber: days += number * 7
            case "D" where !inTime && hasNumber: days += number
            case "H" where inTime && hasNumber: seconds += number * 3600
            case "M" where inTime && hasNumber: seconds += number * 60
            case "S" where inTime && hasNumber: seconds += number
            default: return nil
            }
            number = 0
            hasNumber = false
            sawPart = true
        }
        guard sawPart, !hasNumber else { return nil }
        self.init(days: sign * days, seconds: sign * seconds)
    }

    /// Roughly how long it lasts, in seconds, counting a day as 24 hours.
    var approximateSeconds: Int64 { Int64(days) * 86_400 + Int64(seconds) }

    /// The value as a file writes it.
    var text: String {
        let negative = days < 0 || seconds < 0
        let days = abs(days), seconds = abs(seconds)
        var text = negative ? "-P" : "P"
        if seconds == 0, days > 0, days % 7 == 0 { return text + "\(days / 7)W" }
        if days > 0 { text += "\(days)D" }
        if seconds > 0 || days == 0 {
            text += "T"
            if seconds / 3600 > 0 { text += "\(seconds / 3600)H" }
            if seconds % 3600 / 60 > 0 { text += "\(seconds % 3600 / 60)M" }
            if seconds % 60 > 0 || seconds == 0 { text += "\(seconds % 60)S" }
        }
        return text
    }
}

/// One value of an RDATE or EXDATE line: a date or date-time, or for RDATE a PERIOD with its own end.
struct ICalendarPeriod: Sendable, Hashable {
    var start: ICalendarDateTime
    var end: ICalendarDateTime?
    var duration: ICalendarDuration?

    /// Every value on an RDATE or EXDATE line, which may hold several separated by commas.
    static func values(of line: ICalendarLine) -> [ICalendarPeriod] {
        let tzid = line.parameter("TZID")
        let isDate = line.parameter("VALUE")?.uppercased() == "DATE"
        return line.value.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "/", maxSplits: 1)
            guard let first = parts.first, let start = ICalendarDateTime(text: first, tzid: tzid, isDate: isDate) else { return nil }
            var period = ICalendarPeriod(start: start)
            if parts.count == 2 {
                if let end = ICalendarDateTime(text: parts[1], tzid: tzid) {
                    period.end = end
                } else {
                    period.duration = ICalendarDuration(parts[1])
                }
            }
            return period
        }
    }
}
