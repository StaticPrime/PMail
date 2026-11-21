import Foundation

/// Turns wall-clock readings into moments and back for one time zone: a system time zone, or the offsets an
/// iCalendar file's VTIMEZONE spells out for a zone the system doesn't know.
struct ICalendarZone: Sendable {
    private enum Source: Sendable {
        case system(TimeZone)
        case custom(VTimeZoneRules)
    }

    private let source: Source

    init(_ timeZone: TimeZone) {
        source = .system(timeZone)
    }

    init(_ rules: VTimeZoneRules) {
        source = .custom(rules)
    }

    static let utc = ICalendarZone(TimeZone.gmt)

    /// The system time zone, when the zone is one.
    var systemTimeZone: TimeZone? {
        if case let .system(timeZone) = source { timeZone } else { nil }
    }

    /// Seconds east of UTC at a moment, given in seconds since 1970.
    func offset(atInstant instant: Int64) -> Int {
        switch source {
        case let .system(timeZone): timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant)))
        case let .custom(rules): rules.offset(atInstant: instant)
        }
    }

    /// The moment a wall-clock reading names, in seconds since 1970. A reading that happens twice (when clocks go
    /// back) means the first time; one that never happens (when clocks go forward) is read with the offset from
    /// before the change, as RFC 5545 says.
    func instant(from wall: WallClockTime) -> Int64 {
        let before = offset(atInstant: wall.seconds - 86_400)
        let after = offset(atInstant: wall.seconds + 86_400)
        var best: Int64?
        for candidate in [before, after] {
            let instant = wall.seconds - Int64(candidate)
            if offset(atInstant: instant) == candidate, best.map({ instant < $0 }) ?? true { best = instant }
        }
        return best ?? wall.seconds - Int64(before)
    }

    func wall(fromInstant instant: Int64) -> WallClockTime {
        WallClockTime(seconds: instant + Int64(offset(atInstant: instant)))
    }

    func date(from wall: WallClockTime) -> Date {
        Date(timeIntervalSince1970: TimeInterval(instant(from: wall)))
    }

    func wall(from date: Date) -> WallClockTime {
        wall(fromInstant: Self.seconds(of: date))
    }

    /// Whole seconds since 1970, rounded down.
    static func seconds(of date: Date) -> Int64 {
        let interval = date.timeIntervalSince1970.rounded(.down)
        guard interval.isFinite, abs(interval) < 1e15 else { return 0 }
        return Int64(interval)
    }
}

/// The offsets a VTIMEZONE spells out: its STANDARD and DAYLIGHT parts, each with when it first starts and the
/// rule or dates that repeat it.
struct VTimeZoneRules: Sendable, Hashable {
    struct Observance: Sendable, Hashable {
        /// When it first takes effect, as a wall-clock reading in the offset before it.
        var start: WallClockTime
        var offsetFrom: Int
        var offsetTo: Int
        var rule: ICalendarRecurrenceRule?
        var dates: [WallClockTime]
    }

    var observances: [Observance]

    init?(_ component: ICalendarComponent) {
        var observances: [Observance] = []
        for part in component.components where part.name == "STANDARD" || part.name == "DAYLIGHT" {
            guard let start = part.property("DTSTART").flatMap(ICalendarDateTime.init),
                  let offsetTo = part.property("TZOFFSETTO").flatMap({ Self.offset($0.value) }) else { continue }
            let offsetFrom = part.property("TZOFFSETFROM").flatMap { Self.offset($0.value) } ?? offsetTo
            let rule = part.property("RRULE").flatMap { ICalendarRecurrenceRule($0.value) }
            let dates = part.properties("RDATE").flatMap(ICalendarPeriod.values).map(\.start.wall)
            observances.append(Observance(start: start.wall, offsetFrom: offsetFrom, offsetTo: offsetTo, rule: rule, dates: dates))
        }
        guard !observances.isEmpty else { return nil }
        self.observances = observances
    }

    /// Reads a UTC offset ("-0500", "+0530", "+053000") as seconds east of UTC.
    static func offset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let signCharacter = trimmed.first, signCharacter == "+" || signCharacter == "-" else { return nil }
        let digits = trimmed.dropFirst().filter { $0 != ":" }
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let seconds = digits.count == 6 ? Int(digits.suffix(2)) ?? 0 : 0
        let total = hours * 3600 + minutes * 60 + seconds
        return signCharacter == "-" ? -total : total
    }

    /// Seconds east of UTC at a moment: the offset of the observance that most recently took effect.
    func offset(atInstant instant: Int64) -> Int {
        var best: (onset: Int64, offset: Int)?
        for observance in observances {
            var latest: Int64?
            func consider(_ wall: WallClockTime) {
                let onset = wall.seconds - Int64(observance.offsetFrom)
                if onset <= instant, latest.map({ onset > $0 }) ?? true { latest = onset }
            }
            consider(observance.start)
            observance.dates.forEach(consider)
            if let rule = observance.rule {
                let target = WallClockTime(seconds: instant + Int64(observance.offsetFrom))
                let iterator = ICalendarRecurrenceIterator(rule: rule, start: observance.start, isDate: false)
                let untilCheck = Self.untilCheck(rule.until, offsetFrom: observance.offsetFrom)
                iterator.forEach(skippingTo: target.adding(days: -400), through: target.adding(days: 1), isPastUntil: untilCheck) { wall in
                    guard wall.seconds - Int64(observance.offsetFrom) <= instant else { return false }
                    consider(wall)
                    return true
                }
            }
            if let latest, best.map({ latest > $0.onset }) ?? true { best = (latest, observance.offsetTo) }
        }
        if let best { return best.offset }
        // Before the zone's first change: the offset in force before the earliest one.
        return observances.min { $0.start < $1.start }?.offsetFrom ?? 0
    }

    private static func untilCheck(_ until: ICalendarDateTime?, offsetFrom: Int) -> (WallClockTime) -> Bool {
        guard let until else { return { _ in false } }
        switch until.form {
        case .utc: return { $0.seconds - Int64(offsetFrom) > until.wall.seconds }
        case .date: return { $0.dayNumber > until.wall.dayNumber }
        case .floating, .zoned: return { $0 > until.wall }
        }
    }
}

/// Finds the time zone for each date-time in a calendar file: the system's zone for IANA names and common Windows
/// names, the file's own VTIMEZONE for names the system doesn't know, and the local zone for floating times and
/// all-day dates.
struct ICalendarZoneResolver: Sendable {
    let localTimeZone: TimeZone
    let local: ICalendarZone
    /// The system zone for each TZID the file uses, looked up once.
    private let system: [String: TimeZone]
    private let custom: [String: VTimeZoneRules]

    init(calendar: ICalendarComponent?, localTimeZone: TimeZone) {
        self.localTimeZone = localTimeZone
        local = ICalendarZone(localTimeZone)
        var system: [String: TimeZone] = [:]
        var unknown = Set<String>()
        func collect(_ component: ICalendarComponent) {
            for property in component.properties {
                guard let tzid = property.parameter("TZID"), system[tzid] == nil, !unknown.contains(tzid) else { continue }
                if let timeZone = Self.systemTimeZone(named: tzid) { system[tzid] = timeZone } else { unknown.insert(tzid) }
            }
            component.components.forEach(collect)
        }
        if let calendar { collect(calendar) }
        var custom: [String: VTimeZoneRules] = [:]
        for component in calendar?.components ?? [] where component.name == "VTIMEZONE" {
            guard let tzid = component.property("TZID")?.text.trimmingCharacters(in: .whitespaces), !tzid.isEmpty,
                  Self.systemTimeZone(named: tzid) == nil, let rules = VTimeZoneRules(component) else { continue }
            custom[tzid] = rules
        }
        self.system = system
        self.custom = custom
    }

    /// The zone a value's wall-clock reading is in.
    func zone(for form: ICalendarDateTime.Form) -> ICalendarZone {
        switch form {
        case .utc: return .utc
        case .date, .floating: return local
        case let .zoned(tzid):
            if let timeZone = system[tzid] ?? Self.systemTimeZone(named: tzid) { return ICalendarZone(timeZone) }
            if let rules = custom[tzid.trimmingCharacters(in: .whitespaces)] { return ICalendarZone(rules) }
            // A TZID with nothing to explain it: read it as local time rather than lose the event.
            return local
        }
    }

    /// The system time zone's identifier for a TZID, or nil when the system doesn't know the zone.
    func systemTimeZoneIdentifier(for tzid: String) -> String? {
        (system[tzid] ?? Self.systemTimeZone(named: tzid))?.identifier
    }

    /// The moment a value names, in seconds since 1970 (midnight local time for a date).
    func instant(_ value: ICalendarDateTime) -> Int64 {
        zone(for: value.form).instant(from: value.wall)
    }

    func date(_ value: ICalendarDateTime) -> Date {
        Date(timeIntervalSince1970: TimeInterval(instant(value)))
    }

    /// The system time zone a TZID names: an IANA name ("Europe/Paris"), one with a path in front
    /// ("/mozilla.org/20050126_1/America/New_York"), a common Windows name ("W. Europe Standard Time"), or a
    /// display name some programs write ("(UTC-05:00) Eastern Time (US & Canada)").
    static func systemTimeZone(named tzid: String) -> TimeZone? {
        let name = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespaces))
        guard !name.isEmpty else { return nil }
        if let timeZone = TimeZone(identifier: name) { return timeZone }
        let parts = name.split(separator: "/")
        if parts.count > 1 {
            for start in 1..<parts.count {
                if let timeZone = TimeZone(identifier: parts[start...].joined(separator: "/")) { return timeZone }
            }
        }
        if let identifier = windowsNames[name], let timeZone = TimeZone(identifier: identifier) { return timeZone }
        for (fragment, identifier) in displayNameFragments where name.localizedCaseInsensitiveContains(fragment) {
            return TimeZone(identifier: identifier)
        }
        return nil
    }

    /// Windows time zone names, as some programs write them in TZID, with the IANA zone each means.
    static let windowsNames: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "UTC-11": "Etc/GMT+11", "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage", "Pacific Standard Time": "America/Los_Angeles",
        "Pacific Standard Time (Mexico)": "America/Tijuana", "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time": "America/Denver", "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Central Standard Time": "America/Chicago", "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina", "Central America Standard Time": "America/Guatemala",
        "Eastern Standard Time": "America/New_York", "Eastern Standard Time (Mexico)": "America/Cancun",
        "US Eastern Standard Time": "America/Indiana/Indianapolis", "SA Pacific Standard Time": "America/Bogota",
        "Atlantic Standard Time": "America/Halifax", "Venezuela Standard Time": "America/Caracas",
        "SA Western Standard Time": "America/La_Paz", "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns", "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Argentina/Buenos_Aires", "SA Eastern Standard Time": "America/Cayenne",
        "Greenland Standard Time": "America/Godthab", "Montevideo Standard Time": "America/Montevideo",
        "UTC-02": "Etc/GMT+2", "Mid-Atlantic Standard Time": "Etc/GMT+2", "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde", "UTC": "Etc/UTC", "Coordinated Universal Time": "Etc/UTC",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "Morocco Standard Time": "Africa/Casablanca", "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest", "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw", "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest", "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo", "E. Europe Standard Time": "Europe/Chisinau",
        "South Africa Standard Time": "Africa/Johannesburg", "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem", "Jordan Standard Time": "Asia/Amman",
        "Turkey Standard Time": "Europe/Istanbul", "Arabic Standard Time": "Asia/Baghdad",
        "Arab Standard Time": "Asia/Riyadh", "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi", "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai", "Azerbaijan Standard Time": "Asia/Baku",
        "Caucasus Standard Time": "Asia/Yerevan", "Afghanistan Standard Time": "Asia/Kabul",
        "Pakistan Standard Time": "Asia/Karachi", "West Asia Standard Time": "Asia/Tashkent",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg", "India Standard Time": "Asia/Kolkata",
        "Sri Lanka Standard Time": "Asia/Colombo", "Nepal Standard Time": "Asia/Kathmandu",
        "Central Asia Standard Time": "Asia/Almaty", "Bangladesh Standard Time": "Asia/Dhaka",
        "Myanmar Standard Time": "Asia/Yangon", "SE Asia Standard Time": "Asia/Bangkok",
        "North Asia Standard Time": "Asia/Krasnoyarsk", "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk", "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth", "Taipei Standard Time": "Asia/Taipei",
        "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar", "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul", "Yakutsk Standard Time": "Asia/Yakutsk",
        "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby", "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok", "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "New Zealand Standard Time": "Pacific/Auckland", "Fiji Standard Time": "Pacific/Fiji",
        "Tonga Standard Time": "Pacific/Tongatapu", "Samoa Standard Time": "Pacific/Apia",
    ]

    /// Pieces of the display names some programs write in TZID, with the IANA zone each means.
    private static let displayNameFragments: [(String, String)] = [
        ("Eastern Time (US & Canada)", "America/New_York"), ("Central Time (US & Canada)", "America/Chicago"),
        ("Mountain Time (US & Canada)", "America/Denver"), ("Pacific Time (US & Canada)", "America/Los_Angeles"),
        ("Amsterdam, Berlin", "Europe/Berlin"), ("Brussels, Copenhagen", "Europe/Paris"),
        ("Dublin, Edinburgh", "Europe/London"), ("Belgrade, Bratislava", "Europe/Budapest"),
        ("Sarajevo, Skopje", "Europe/Warsaw"), ("Athens, Bucharest", "Europe/Bucharest"),
        ("Helsinki, Kyiv", "Europe/Helsinki"), ("Osaka, Sapporo, Tokyo", "Asia/Tokyo"),
        ("Beijing, Chongqing", "Asia/Shanghai"), ("Chennai, Kolkata", "Asia/Kolkata"),
        ("Canberra, Melbourne, Sydney", "Australia/Sydney"), ("Auckland, Wellington", "Pacific/Auckland"),
    ]

    /// A VTIMEZONE describing a system time zone's rules as they stand in a year, for files that name the zone in a
    /// TZID (RFC 5545 asks for one per TZID). Programs that know the IANA name use their own rules; the rest use these.
    static func vtimezone(for timeZone: TimeZone, year: Int) -> ICalendarComponent {
        var component = ICalendarComponent(name: "VTIMEZONE", properties: [ICalendarLine("TZID", value: timeZone.identifier)])
        let yearStart = Int64(GregorianDays.dayNumber(year: year, month: 1, day: 1)) * 86_400
        let yearEnd = Int64(GregorianDays.dayNumber(year: year + 1, month: 1, day: 1)) * 86_400
        var transitions: [Date] = []
        var cursor = Date(timeIntervalSince1970: TimeInterval(yearStart))
        while transitions.count < 2, let next = timeZone.nextDaylightSavingTimeTransition(after: cursor),
              next.timeIntervalSince1970 < TimeInterval(yearEnd) {
            transitions.append(next)
            cursor = next
        }
        guard !transitions.isEmpty else {
            let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(yearStart)))
            var standard = ICalendarComponent(name: "STANDARD")
            standard.properties = [
                ICalendarLine("DTSTART", value: "19700101T000000"),
                ICalendarLine("TZOFFSETFROM", value: offsetText(offset)),
                ICalendarLine("TZOFFSETTO", value: offsetText(offset)),
            ]
            if let abbreviation = timeZone.abbreviation(for: Date(timeIntervalSince1970: TimeInterval(yearStart))) {
                standard.properties.append(.text("TZNAME", abbreviation))
            }
            component.components = [standard]
            return component
        }
        for transition in transitions {
            let from = timeZone.secondsFromGMT(for: transition.addingTimeInterval(-1))
            let to = timeZone.secondsFromGMT(for: transition)
            let wall = WallClockTime(seconds: ICalendarZone.seconds(of: transition) + Int64(from))
            let (wallYear, month, day) = wall.date
            let weekday = wall.weekday
            let ordinal = day + 7 > GregorianDays.daysInMonth(year: wallYear, month: month) ? -1 : (day - 1) / 7 + 1
            let firstDay = GregorianDays.nthWeekday(weekday, ordinal: ordinal, year: 1970, month: month)
                ?? GregorianDays.dayNumber(year: 1970, month: month, day: 1)
            var observance = ICalendarComponent(name: timeZone.isDaylightSavingTime(for: transition) ? "DAYLIGHT" : "STANDARD")
            let byDay = "\(ordinal)\(ICalendarRecurrenceRule.weekdayNames[weekday])"
            observance.properties = [
                ICalendarLine("DTSTART", value: WallClockTime(dayNumber: firstDay, secondOfDay: wall.secondOfDay).dateTimeText),
                ICalendarLine("RRULE", value: "FREQ=YEARLY;BYMONTH=\(month);BYDAY=\(byDay)"),
                ICalendarLine("TZOFFSETFROM", value: offsetText(from)),
                ICalendarLine("TZOFFSETTO", value: offsetText(to)),
            ]
            if let abbreviation = timeZone.abbreviation(for: transition) { observance.properties.append(.text("TZNAME", abbreviation)) }
            component.components.append(observance)
        }
        return component
    }

    /// "+0530", "-0500".
    static func offsetText(_ seconds: Int) -> String {
        let magnitude = abs(seconds)
        let hours = magnitude / 3600, minutes = magnitude % 3600 / 60, rest = magnitude % 60
        var text = (seconds < 0 ? "-" : "+") + (hours < 10 ? "0" : "") + "\(hours)" + (minutes < 10 ? "0" : "") + "\(minutes)"
        if rest > 0 { text += (rest < 10 ? "0" : "") + "\(rest)" }
        return text
    }
}
