import Foundation

/// The dates and sizes PMail shows, worded the way the lists and pages show them.
public struct MailFormatting: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var now: @Sendable () -> Date

    public init(calendar: Calendar = .current, locale: Locale = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.calendar = calendar
        self.locale = locale
        self.now = now
    }

    private func formatter(_ template: String) -> DateFormatter {
        FormatterCache.shared.formatter(template: template, calendar: calendar, locale: locale)
    }

    /// A message list's date: the time for today, "Nov 3" for this year, "11/3/24" for earlier years.
    public func listDate(_ date: Date) -> String {
        let today = now()
        if calendar.isDate(date, inSameDayAs: today) { return formatter("jmm").string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: today) { return formatter("MMMd").string(from: date) }
        return formatter("yyMd").string(from: date)
    }

    /// A time to come, for snoozes and scheduled messages: "Today, 6:00 PM", "Tomorrow, 8:00 AM", "Sat, 8:00 AM" within
    /// a week, else "Dec 3, 8:00 AM" (with the year when it isn't this year).
    public func laterDate(_ date: Date) -> String {
        let today = now()
        let time = formatter("jmm").string(from: date)
        if calendar.isDate(date, inSameDayAs: today) { return "Today, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow, \(time)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)).day ?? 99
        if days > 0, days < 7 { return "\(formatter("EEE").string(from: date)), \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        return "\(formatter(sameYear ? "MMMd" : "yMMMd").string(from: date)), \(time)"
    }

    /// A message's full date, with how long ago: "Nov 21, 2026, 10:42 AM (2 hours ago)".
    public func messageDate(_ date: Date) -> String {
        let full = formatter("yMMMdjmm").string(from: date)
        let seconds = now().timeIntervalSince(date)
        guard seconds >= 0, seconds < 7 * 86_400 else { return full }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.calendar = calendar
        relative.unitsStyle = .full
        let ago = seconds < 60 ? "just now" : relative.localizedString(for: date, relativeTo: now())
        return "\(full) (\(ago))"
    }

    /// A file size: "12 KB", "3.4 MB".
    public func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// An event's time range for its block and details: "10:00 – 11:00 AM", "10:30 AM – 1:00 PM",
    /// "Saturday, November 21", and across days "Nov 21, 10:00 PM – Nov 22, 1:00 AM".
    public func eventTime(start: Date, end: Date, isAllDay: Bool, includeDate: Bool = false) -> String {
        if isAllDay {
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            let day = formatter("EEEEMMMMd")
            if calendar.isDate(start, inSameDayAs: lastDay) || lastDay < start { return day.string(from: start) }
            return "\(formatter("MMMd").string(from: start)) – \(formatter("MMMd").string(from: lastDay))"
        }
        let time = formatter("jmm")
        if !calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) {
            let dayTime = formatter("MMMdjmm")
            return "\(dayTime.string(from: start)) – \(dayTime.string(from: end))"
        }
        let range = "\(time.string(from: start)) – \(time.string(from: end))"
        return includeDate ? "\(formatter("EEEEMMMMd").string(from: start)) · \(range)" : range
    }

    /// A short time for an event chip in the month view: "10am", "1:30pm" (or "10:00" in 24-hour locales).
    public func shortTime(_ date: Date) -> String {
        let text = formatter("jmm").string(from: date)
        guard let range = text.range(of: "AM") ?? text.range(of: "PM") else { return text }
        let suffix = text[range].lowercased()
        let time = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{202F}\u{00A0}")))
        return (time.hasSuffix(":00") ? String(time.dropLast(3)) : time) + suffix
    }
}

/// Date formatters are slow to make, so each template, calendar and locale gets one, kept for reuse.
final class FormatterCache: @unchecked Sendable {
    static let shared = FormatterCache()
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.firstWeekday)|\(locale.identifier)"
        return lock.withLock {
            if let formatter = formatters[key] { return formatter }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters[key] = formatter
            return formatter
        }
    }
}

/// The days a calendar view shows.
public struct CalendarGrid: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// The first day of the week holding `date`, by the calendar's first weekday.
    public func startOfWeek(_ date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let back = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    public func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    /// `count` days from `start`.
    public func days(from start: Date, count: Int) -> [Date] {
        (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: start)) }
    }

    /// The seven days of the week holding `date`.
    public func week(of date: Date) -> [Date] { days(from: startOfWeek(date), count: 7) }

    /// The weeks a month view shows: whole weeks from the one holding the 1st to the one holding the last day
    /// (five or six rows, or four in a February that fits exactly).
    public func monthWeeks(of date: Date) -> [[Date]] {
        let first = startOfMonth(date)
        guard let range = calendar.range(of: .day, in: .month, for: first),
              let last = calendar.date(byAdding: .day, value: range.count - 1, to: first) else { return [] }
        var weeks: [[Date]] = []
        var weekStart = startOfWeek(first)
        while weekStart <= last {
            weeks.append(days(from: weekStart, count: 7))
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        return weeks
    }

    /// Whether two dates are in the same month.
    public func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, equalTo: b, toGranularity: .month)
    }
}

/// Where each timed event goes in a day column when events overlap: side by side, each in its own column.
public enum EventLayout {
    public struct Placement: Sendable, Hashable {
        /// The event's column, from 0.
        public var column: Int
        /// How many columns its group of overlapping events needs.
        public var columns: Int
        /// How many columns it can stretch over to the right, where nothing is in the way.
        public var span: Int

        public init(column: Int, columns: Int, span: Int) {
            self.column = column
            self.columns = columns
            self.span = span
        }
    }

    /// Places events (`id`, `start`, `end`) that share a day. Events that overlap, directly or through others, form a
    /// group; each takes the first column free at its start.
    public static func layout(_ events: [(id: String, start: Date, end: Date)], minimumLength: TimeInterval = 15 * 60) -> [String: Placement] {
        let sorted = events.sorted { $0.start != $1.start ? $0.start < $1.start : ($0.end - $0.start) > ($1.end - $1.start) }
        var placements: [String: Placement] = [:]
        var group: [(id: String, start: Date, end: Date, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast

        func finishGroup() {
            let columns = max(columnEnds.count, 1)
            for member in group {
                // Stretch right over columns with nothing overlapping this event.
                var span = 1
                var next = member.column + 1
                while next < columns, !group.contains(where: { $0.column == next && $0.start < member.end && member.start < $0.end }) {
                    span += 1
                    next += 1
                }
                placements[member.id] = Placement(column: member.column, columns: columns, span: span)
            }
            group.removeAll()
            columnEnds.removeAll()
        }

        for event in sorted {
            let end = max(event.end, event.start.addingTimeInterval(minimumLength))
            if event.start >= groupEnd, !group.isEmpty { finishGroup() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = end
                group.append((event.id, event.start, end, free))
            } else {
                columnEnds.append(end)
                group.append((event.id, event.start, end, columnEnds.count - 1))
            }
            groupEnd = max(groupEnd, end)
        }
        if !group.isEmpty { finishGroup() }
        return placements
    }
}

private extension Date {
    static func - (lhs: Date, rhs: Date) -> TimeInterval { lhs.timeIntervalSince(rhs) }
}
