import Foundation

/// The VEVENTs of one event in a calendar resource: the main one (with the repeat rule, if it repeats), and the
/// overrides that change single occurrences (VEVENTs with the same UID and a RECURRENCE-ID).
struct ICalendarSeries: Sendable {
    var uid: String?
    var master: ICalendarComponent?
    var overrides: [ICalendarComponent]

    /// Whether the main VEVENT has a repeat rule or extra dates.
    var hasRepeats: Bool {
        guard let master else { return false }
        return master.property("RRULE") != nil || master.property("RDATE") != nil
    }

    var isRecurring: Bool { hasRepeats || !overrides.isEmpty }

    /// The series in a VCALENDAR, in the order their first VEVENT appears. VEVENTs without a UID each stand alone.
    static func all(in calendar: ICalendarComponent) -> [ICalendarSeries] {
        var order: [String] = []
        var byKey: [String: ICalendarSeries] = [:]
        for (index, component) in calendar.components.enumerated() where component.name == "VEVENT" {
            let uid = component.uid
            let key = uid ?? "\u{0}\(index)"
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = ICalendarSeries(uid: uid, master: nil, overrides: [])
            }
            if component.property("RECURRENCE-ID") == nil, byKey[key]?.master == nil {
                byKey[key]?.master = component
            } else {
                byKey[key]?.overrides.append(component)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

/// When a VEVENT starts, in which zone, and how long it lasts.
struct ICalendarTiming: Sendable {
    enum Length: Sendable {
        /// Whole days, for all-day events.
        case days(Int)
        /// An exact number of seconds (from DTEND): every occurrence lasts exactly as long.
        case exact(Int64)
        /// A DURATION: days follow the wall clock, the rest is exact.
        case nominal(ICalendarDuration)
    }

    var start: ICalendarDateTime
    var zone: ICalendarZone
    var length: Length

    var isDate: Bool { start.isDate }

    /// When an occurrence starting at a wall-clock reading (and moment) ends.
    func end(startWall: WallClockTime, startInstant: Int64) -> Int64 {
        switch length {
        case let .days(days): zone.instant(from: WallClockTime(dayNumber: startWall.dayNumber + days))
        case let .exact(seconds): startInstant + seconds
        case let .nominal(duration): zone.instant(from: startWall.adding(days: duration.days)) + Int64(duration.seconds)
        }
    }

    /// Roughly how long it lasts, in seconds.
    var approximateSeconds: Int64 {
        switch length {
        case let .days(days): Int64(days) * 86_400
        case let .exact(seconds): seconds
        case let .nominal(duration): duration.approximateSeconds
        }
    }
}

/// Reads the events in a VCALENDAR as PMail's `CalendarEvent`s, with repeating events expanded into their
/// occurrences in the event's own time zone.
struct ICalendarReader {
    /// Most occurrences one repeating event gives in a window, against rules that would run away.
    static let maximumOccurrences = 5000
    /// The last moment the reader looks at when it needs "forever" (the end of year 9999).
    static let endOfTime: Int64 = 253_402_300_799
    /// Properties other calendar programs put meeting links in.
    static let conferenceProperties = ["X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGCONFLINK"]

    /// One occurrence, before it becomes a `CalendarEvent`.
    struct Instance {
        /// The original start (RECURRENCE-ID): a moment for timed events, midnight on the day's wall clock for
        /// all-day ones. Nil for an event that doesn't repeat.
        var key: Int64?
        /// The VEVENT it comes from: the main one, or an override.
        var component: ICalendarComponent
        var start: Int64
        var end: Int64
        var isDate: Bool
    }

    let calendar: ICalendarComponent
    let resolver: ICalendarZoneResolver
    let ownerEmail: String?
    let series: [ICalendarSeries]

    init(calendar: ICalendarComponent, ownerEmail: String?, localTimeZone: TimeZone) {
        self.calendar = calendar
        self.ownerEmail = ownerEmail
        resolver = ICalendarZoneResolver(calendar: calendar, localTimeZone: localTimeZone)
        series = ICalendarSeries.all(in: calendar)
    }

    // MARK: Events in a window

    /// Every event and occurrence that overlaps `start..<end`, sorted by start.
    func events(calendarID: String, href: String?, etag: String?, from start: Date, to end: Date) -> [CalendarEvent] {
        let lower = ICalendarZone.seconds(of: start)
        let window = lower..<max(ICalendarZone.seconds(of: end.addingTimeInterval(0.999)), lower)
        guard !window.isEmpty else { return [] }
        var events: [CalendarEvent] = []
        for (index, series) in series.enumerated() {
            let base = baseID(of: series, index: index, href: href)
            for instance in instances(of: series, in: window) {
                events.append(event(for: instance, in: series, base: base, calendarID: calendarID, href: href, etag: etag))
            }
        }
        return events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The occurrences of a series that overlap a window (in seconds since 1970), at most `limit` of them.
    func instances(of series: ICalendarSeries, in window: Range<Int64>, limit: Int = maximumOccurrences) -> [Instance] {
        func overlaps(_ start: Int64, _ end: Int64) -> Bool {
            start < window.upperBound && (end > window.lowerBound || (end <= start && start >= window.lowerBound))
        }
        func instance(of override: ICalendarComponent, key: Int64?, fallback: ICalendarTiming.Length?) -> Instance? {
            guard let timing = timing(of: override, fallback: fallback) else { return nil }
            let start = timing.zone.instant(from: timing.start.wall)
            let end = timing.end(startWall: timing.start.wall, startInstant: start)
            return overlaps(start, end) ? Instance(key: key, component: override, start: start, end: end, isDate: timing.isDate) : nil
        }

        guard let master = series.master, let timing = timing(of: master) else {
            // Only overrides here (an invitation to one occurrence): each stands on its own.
            return series.overrides.compactMap { override in
                let key = timing(of: override).flatMap { overrideTiming in
                    override.property("RECURRENCE-ID").flatMap(ICalendarDateTime.init).map { instanceKey($0, timing: overrideTiming) }
                }
                return instance(of: override, key: key, fallback: nil)
            }.sorted { $0.start < $1.start }
        }
        let masterStart = timing.zone.instant(from: timing.start.wall)
        guard series.isRecurring else {
            let end = timing.end(startWall: timing.start.wall, startInstant: masterStart)
            guard overlaps(masterStart, end) else { return [] }
            return [Instance(key: nil, component: master, start: masterStart, end: end, isDate: timing.isDate)]
        }

        var overrides: [Int64: ICalendarComponent] = [:]
        for override in series.overrides {
            guard let recurrenceID = override.property("RECURRENCE-ID").flatMap(ICalendarDateTime.init) else { continue }
            overrides[instanceKey(recurrenceID, timing: timing)] = override
        }
        var excluded = Set<Int64>()
        var excludedDays = Set<Int>()
        for period in master.properties("EXDATE").flatMap(ICalendarPeriod.values) {
            if !timing.isDate && period.start.isDate {
                excludedDays.insert(period.start.wall.dayNumber)
            } else {
                excluded.insert(instanceKey(period.start, timing: timing))
            }
        }

        func isExcluded(_ key: Int64, _ wall: WallClockTime) -> Bool {
            excluded.contains(key) || (!timing.isDate && excludedDays.contains(wall.dayNumber))
        }

        // The original starts in and just before the window, by key.
        var starts: [Int64: (start: Int64, end: Int64, wall: WallClockTime)] = [:]
        let span = max(timing.approximateSeconds, 0) + 2 * 86_400
        func add(_ wall: WallClockTime, end: Int64? = nil) {
            let start = timing.zone.instant(from: wall)
            starts[instanceKey(wall: wall, timing: timing)] = (start, end ?? timing.end(startWall: wall, startInstant: start), wall)
        }
        let rules = master.properties("RRULE").compactMap { ICalendarRecurrenceRule($0.value) }
        if rules.isEmpty { add(timing.start.wall) }
        let lookFrom = timing.zone.wall(fromInstant: window.lowerBound - span)
        let lastWall = timing.zone.wall(fromInstant: window.upperBound).adding(days: 2)
        for rule in rules {
            let iterator = ICalendarRecurrenceIterator(rule: rule, start: timing.start.wall, isDate: timing.isDate)
            var kept = 0
            iterator.forEach(skippingTo: lookFrom, through: lastWall, isPastUntil: untilCheck(rule.until, timing: timing)) { wall in
                let start = timing.zone.instant(from: wall)
                guard start < window.upperBound else { return false }
                if start + span >= window.lowerBound {
                    add(wall)
                    if !isExcluded(instanceKey(wall: wall, timing: timing), wall) { kept += 1 }
                }
                // Stop once there are enough to fill the limit, counting only starts no exception removes.
                return kept <= limit * 2
            }
        }
        for period in master.properties("RDATE").flatMap(ICalendarPeriod.values) {
            let wall: WallClockTime
            if timing.isDate {
                wall = WallClockTime(dayNumber: period.start.wall.dayNumber)
            } else if period.start.isDate {
                wall = WallClockTime(dayNumber: period.start.wall.dayNumber, secondOfDay: timing.start.wall.secondOfDay)
            } else {
                wall = timing.zone.wall(fromInstant: resolver.instant(period.start))
            }
            var end: Int64?
            if let periodEnd = period.end {
                end = resolver.instant(periodEnd)
            } else if let duration = period.duration {
                end = timing.zone.instant(from: wall.adding(days: duration.days)) + Int64(duration.seconds)
            }
            add(wall, end: end)
        }

        var result: [Instance] = []
        var handled = Set<Int64>()
        for (key, value) in starts.sorted(by: { ($0.value.start, $0.key) < ($1.value.start, $1.key) }) {
            if isExcluded(key, value.wall) { continue }
            handled.insert(key)
            if let override = overrides[key] {
                if let moved = instance(of: override, key: key, fallback: timing.length) { result.append(moved) }
            } else if overlaps(value.start, value.end) {
                result.append(Instance(key: key, component: master, start: value.start, end: value.end, isDate: timing.isDate))
            }
            if result.count >= limit { return result }
        }
        // Overrides that moved an occurrence into the window from outside it.
        for (key, override) in overrides where !handled.contains(key) && !excluded.contains(key) {
            if let moved = instance(of: override, key: key, fallback: timing.length) { result.append(moved) }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Whether a series' rule and dates (leaving its overrides aside) give an occurrence with this key.
    func generates(_ series: ICalendarSeries, key: Int64) -> Bool {
        guard let master = series.master, let timing = timing(of: master) else { return false }
        let start = timing.isDate ? timing.zone.instant(from: WallClockTime(seconds: key)) : key
        let bare = ICalendarSeries(uid: series.uid, master: master, overrides: [])
        return instances(of: bare, in: (start - 1)..<(start + 1), limit: 10).contains { $0.key == key }
    }

    /// Whether a series still has any occurrence at all (after a deletion, a finite series may have none left).
    func hasInstances(_ series: ICalendarSeries) -> Bool {
        guard let master = series.master, let timing = timing(of: master) else { return !series.overrides.isEmpty }
        let rules = master.properties("RRULE").compactMap { ICalendarRecurrenceRule($0.value) }
        if rules.contains(where: { !$0.isFinite }) { return true }
        let start = timing.zone.instant(from: timing.start.wall) - 2 * 86_400
        return !instances(of: series, in: start..<Self.endOfTime, limit: 1).isEmpty
    }

    // MARK: Single events

    /// The series a `CalendarEvent` belongs to: by its series ID or UID, or the only one there is.
    func series(for event: CalendarEvent) -> ICalendarSeries? {
        if let uid = event.seriesID ?? event.uid, let match = series.first(where: { $0.uid == uid }) { return match }
        return series.count == 1 ? series.first : nil
    }

    /// The original start of the occurrence a `CalendarEvent` stands for: from the end of its ID, which carries the
    /// RECURRENCE-ID, or else from `occurrenceDate`. Nil for an event that doesn't repeat.
    func key(for event: CalendarEvent, in series: ICalendarSeries) -> Int64? {
        guard series.isRecurring, let timing = referenceTiming(of: series) else { return nil }
        if let bar = event.id.lastIndex(of: "|"), let value = ICalendarDateTime(text: event.id[event.id.index(after: bar)...]) {
            return instanceKey(value, timing: timing)
        }
        if let occurrence = event.occurrenceDate {
            let seconds = ICalendarZone.seconds(of: occurrence)
            return timing.isDate ? Int64(resolver.local.wall(fromInstant: seconds).dayNumber) * 86_400 : seconds
        }
        return nil
    }

    /// One event or occurrence as the resource has it now, for handing back after a change.
    func event(in series: ICalendarSeries, key: Int64?, calendarID: String, href: String?, etag: String?) -> CalendarEvent? {
        let index = self.series.firstIndex { $0.uid == series.uid && $0.master == series.master } ?? 0
        let base = baseID(of: series, index: index, href: href)
        guard let instance = instance(in: series, key: key) else { return nil }
        return event(for: instance, in: series, base: base, calendarID: calendarID, href: href, etag: etag)
    }

    /// The first occurrence of each series, for handing back a newly made event.
    func firstEvent(calendarID: String, href: String?, etag: String?) -> CalendarEvent? {
        guard let series = series.first else { return nil }
        let key = series.isRecurring ? series.master.flatMap { timing(of: $0) }.map { instanceKey(wall: $0.start.wall, timing: $0) } : nil
        return event(in: series, key: key, calendarID: calendarID, href: href, etag: etag)
    }

    /// One occurrence by its key (the override's, if it has one), or the event itself when the key is nil.
    func instance(in series: ICalendarSeries, key: Int64?) -> Instance? {
        if let key, let override = series.overrides.first(where: { override in
            guard let timing = referenceTiming(of: series),
                  let value = override.property("RECURRENCE-ID").flatMap(ICalendarDateTime.init) else { return false }
            return instanceKey(value, timing: timing) == key
        }), let timing = timing(of: override, fallback: series.master.flatMap { timing(of: $0) }?.length) {
            let start = timing.zone.instant(from: timing.start.wall)
            return Instance(key: key, component: override, start: start, end: timing.end(startWall: timing.start.wall, startInstant: start),
                            isDate: timing.isDate)
        }
        guard let master = series.master, let timing = timing(of: master) else { return nil }
        guard series.isRecurring, let key else {
            let start = timing.zone.instant(from: timing.start.wall)
            let key = series.isRecurring ? instanceKey(wall: timing.start.wall, timing: timing) : nil
            return Instance(key: key, component: master, start: start, end: timing.end(startWall: timing.start.wall, startInstant: start),
                            isDate: timing.isDate)
        }
        let wall = timing.isDate ? WallClockTime(seconds: key) : timing.zone.wall(fromInstant: key)
        let start = timing.zone.instant(from: wall)
        return Instance(key: key, component: master, start: start, end: timing.end(startWall: wall, startInstant: start),
                        isDate: timing.isDate)
    }

    // MARK: Building events

    private func baseID(of series: ICalendarSeries, index: Int, href: String?) -> String {
        let uid = series.uid ?? "event-\(index)"
        guard let href else { return uid }
        return self.series.count > 1 ? "\(href)#\(uid)" : href
    }

    private func event(for instance: Instance, in series: ICalendarSeries, base: String, calendarID: String, href: String?,
                       etag: String?) -> CalendarEvent {
        var event = fields(of: instance.component, calendarID: calendarID)
        event.start = Date(timeIntervalSince1970: TimeInterval(instance.start))
        event.end = Date(timeIntervalSince1970: TimeInterval(max(instance.end, instance.start)))
        event.isAllDay = instance.isDate
        event.resourceHref = href
        event.etag = etag
        if let key = instance.key {
            let isDate = referenceTiming(of: series)?.isDate ?? instance.isDate
            event.id = base + "|" + Self.recurrenceText(key: key, isDate: isDate)
            event.seriesID = series.uid ?? base
            let original = isDate ? resolver.local.instant(from: WallClockTime(seconds: key)) : key
            event.occurrenceDate = Date(timeIntervalSince1970: TimeInterval(original))
            event.recurrence = series.master.map(Self.recurrenceLines) ?? []
        } else {
            event.id = base
        }
        return event
    }

    /// "20261121T140000Z" for a timed occurrence, "20261121" for an all-day one: the RECURRENCE-ID in UTC.
    static func recurrenceText(key: Int64, isDate: Bool) -> String {
        isDate ? WallClockTime(seconds: key).dateText : WallClockTime(seconds: key).dateTimeText + "Z"
    }

    /// A main VEVENT's RRULE, RDATE and EXDATE lines, as text.
    static func recurrenceLines(of component: ICalendarComponent) -> [String] {
        component.properties.filter { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }.map(\.serialized)
    }

    /// What a VEVENT says about an event, with the start and end it gives itself (an override without an end of its
    /// own borrows its series' length, `fallback`). The ID is left for the caller.
    func fields(of component: ICalendarComponent, calendarID: String, fallback: ICalendarTiming.Length? = nil) -> CalendarEvent {
        let organizer = component.property("ORGANIZER").flatMap(ICalendarEventProperties.address)
        let attendees = component.properties("ATTENDEE").compactMap { ICalendarEventProperties.attendee(from: $0, organizer: organizer) }
        let location = component.property("LOCATION")?.text
        let description = component.property("DESCRIPTION")?.text
        let link = component.property("URL").map { $0.text.trimmingCharacters(in: .whitespaces) }
        let linkTexts = [link] + Self.conferenceProperties.map { component.property($0)?.text } + [location, description]
        let conference = ConferenceDetector.detect(in: linkTexts)
        let webLink = link.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        var myResponse: AttendeeResponse?
        if let owner = ownerEmail, !(organizer.map { ICalendarEventProperties.isSameMailbox($0.email, owner) } ?? false) {
            myResponse = attendees.first { ICalendarEventProperties.isSameMailbox($0.address.email, owner) }?.response
        }
        let timing = timing(of: component, fallback: fallback)
        let start = timing.map { $0.zone.instant(from: $0.start.wall) } ?? 0
        let end = timing.map { $0.end(startWall: $0.start.wall, startInstant: start) } ?? start
        return CalendarEvent(
            id: component.uid ?? "", calendarID: calendarID, title: component.property("SUMMARY")?.text ?? "",
            start: Date(timeIntervalSince1970: TimeInterval(start)), end: Date(timeIntervalSince1970: TimeInterval(max(end, start))),
            isAllDay: timing?.isDate ?? false, timeZone: timing?.start.tzid.flatMap { resolver.systemTimeZoneIdentifier(for: $0) },
            location: location.flatMap { $0.isEmpty ? nil : $0 }, notes: description.flatMap { $0.isEmpty ? nil : $0 },
            attendees: attendees, organizer: organizer, conference: conference,
            colorHex: component.property("COLOR").flatMap { ICalendarColor.hex(from: $0.text) },
            status: ICalendarEventProperties.status(of: component), myResponse: myResponse,
            availability: ICalendarEventProperties.availability(of: component),
            reminderMinutes: ICalendarEventProperties.reminders(of: component), webLink: webLink, uid: component.uid)
    }

    // MARK: Times

    /// When a VEVENT starts and how long it lasts; nil without a readable DTSTART. `fallback` is the length to use
    /// when the VEVENT gives none (an override borrows its series' length).
    func timing(of component: ICalendarComponent, fallback: ICalendarTiming.Length? = nil) -> ICalendarTiming? {
        guard let start = component.property("DTSTART").flatMap(ICalendarDateTime.init) else { return nil }
        let zone = resolver.zone(for: start.form)
        let length: ICalendarTiming.Length
        if let end = component.property("DTEND").flatMap(ICalendarDateTime.init) {
            if start.isDate {
                length = .days(max(1, end.wall.dayNumber - start.wall.dayNumber))
            } else {
                length = .exact(max(0, resolver.instant(end) - zone.instant(from: start.wall)))
            }
        } else if let duration = component.property("DURATION").flatMap({ ICalendarDuration($0.value) }), duration.approximateSeconds >= 0 {
            length = start.isDate ? .days(max(1, duration.days + duration.seconds / 86_400)) : .nominal(duration)
        } else if let fallback {
            length = fallback
        } else {
            length = start.isDate ? .days(1) : .exact(0)
        }
        return ICalendarTiming(start: start, zone: zone, length: length)
    }

    /// The timing that decides how a series' occurrences are keyed: its main VEVENT's, or else its first override's.
    func referenceTiming(of series: ICalendarSeries) -> ICalendarTiming? {
        series.master.flatMap { timing(of: $0) } ?? series.overrides.lazy.compactMap { timing(of: $0) }.first
    }

    /// The key of an occurrence given as a RECURRENCE-ID, EXDATE or RDATE value: its moment for timed events, or
    /// midnight on the wall clock of its day for all-day ones.
    func instanceKey(_ value: ICalendarDateTime, timing: ICalendarTiming) -> Int64 {
        if timing.isDate { return Int64(value.wall.dayNumber) * 86_400 }
        if value.isDate {
            return timing.zone.instant(from: WallClockTime(dayNumber: value.wall.dayNumber, secondOfDay: timing.start.wall.secondOfDay))
        }
        return resolver.instant(value)
    }

    /// The key of an occurrence given as a wall-clock reading in the series' zone.
    func instanceKey(wall: WallClockTime, timing: ICalendarTiming) -> Int64 {
        timing.isDate ? Int64(wall.dayNumber) * 86_400 : timing.zone.instant(from: wall)
    }

    private func untilCheck(_ until: ICalendarDateTime?, timing: ICalendarTiming) -> (WallClockTime) -> Bool {
        guard let until else { return { _ in false } }
        switch until.form {
        case .date:
            let day = until.wall.dayNumber
            return { $0.dayNumber > day }
        case .utc:
            let limit = until.wall.seconds
            let zone = timing.zone
            return { zone.instant(from: $0) > limit }
        case .floating, .zoned:
            if timing.isDate {
                let day = until.wall.dayNumber
                return { $0.dayNumber > day }
            }
            let limit = until.wall
            return { $0 > limit }
        }
    }
}
