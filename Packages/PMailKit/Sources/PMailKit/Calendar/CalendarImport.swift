import Foundation

/// Events read from a file to add to a calendar: iCalendar (.ics), vCalendar (.vcs) or CSV (.csv), as calendar apps
/// export them. They come without guests or an organizer, so importing them never sends anyone an invitation; a
/// repeating event keeps how it repeats.
public enum CalendarImport {
    public struct Result: Sendable {
        public var events: [CalendarEvent]
        /// Rows or entries that couldn't be read as events.
        public var skipped: Int
    }

    /// The file types read.
    public static let fileExtensions = ["ics", "ical", "ifb", "vcs", "csv"]

    /// The events in a file, by its extension (or what it looks like inside).
    public static func events(from data: Data, fileExtension: String, timeZone: TimeZone = .current) throws -> Result {
        let text = String(decoding: data, as: UTF8.self)
        let kind = fileExtension.lowercased()
        if kind == "csv" || (!["ics", "ical", "ifb", "vcs"].contains(kind) && !text.contains("BEGIN:VCALENDAR")) {
            return try csv(text, timeZone: timeZone)
        }
        return calendar(text, timeZone: timeZone)
    }

    // MARK: iCalendar and vCalendar

    static func calendar(_ text: String, timeZone: TimeZone) -> Result {
        var events: [CalendarEvent] = []
        var skipped = 0
        for calendar in ICalendarComponent.parse(decodedQuotedPrintable(text)) where calendar.name == "VCALENDAR" {
            let zones = calendar.components.filter { $0.name == "VTIMEZONE" }
            // Each event or series on its own (the times one changed are left out: they're of the series).
            for event in calendar.components where event.name == "VEVENT" && event.property("RECURRENCE-ID") == nil {
                var single = event
                // vCalendar's own repeat rules aren't iCalendar's; such an event comes in once.
                if let rule = single.property("RRULE"), !rule.value.uppercased().contains("FREQ=") { single.removeProperties("RRULE") }
                single.removeProperties("ATTENDEE")
                single.removeProperties("ORGANIZER")
                var alone = calendar
                alone.components = zones + [single]
                guard var read = ICalendarReader(calendar: alone, ownerEmail: nil, localTimeZone: timeZone).firstEvent(calendarID: "", href: nil, etag: nil)
                else {
                    skipped += 1
                    continue
                }
                read.id = UUID().uuidString
                read.uid = nil
                read.resourceHref = nil
                read.etag = nil
                read.seriesID = nil
                read.occurrenceDate = nil
                read.attendees = []
                read.organizer = nil
                read.myResponse = nil
                if read.title.trimmingCharacters(in: .whitespaces).isEmpty { read.title = "Untitled event" }
                events.append(read)
            }
        }
        return Result(events: events, skipped: skipped)
    }

    /// vCalendar files may write values in quoted-printable (ENCODING=QUOTED-PRINTABLE); they're decoded, and the
    /// parameter dropped, so the reader sees plain text.
    static func decodedQuotedPrintable(_ text: String) -> String {
        guard text.uppercased().contains("QUOTED-PRINTABLE") else { return text }
        var output: [String] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            guard line.uppercased().contains("ENCODING=QUOTED-PRINTABLE"), let colon = line.firstIndex(of: ":") else {
                output.append(line)
                continue
            }
            // Soft line breaks (a trailing "=") continue the value on the next line.
            var value = String(line[line.index(after: colon)...])
            while value.hasSuffix("="), let next = lines.popFirst() {
                value = String(value.dropLast()) + next
            }
            let decoded = String(decoding: TransferEncoding.decodeQuotedPrintable(Data(value.utf8)), as: UTF8.self)
            let name = line[..<colon].replacingOccurrences(of: ";ENCODING=QUOTED-PRINTABLE", with: "", options: .caseInsensitive)
            output.append(name + ":" + decoded.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n"))
        }
        return output.joined(separator: "\r\n")
    }

    // MARK: CSV

    /// A CSV file with a header row, as calendar apps export them: Subject, Start Date, Start Time, End Date, End Time,
    /// All Day Event, Description, Location (other columns are ignored, and the names can vary a little).
    static func csv(_ text: String, timeZone: TimeZone) throws -> Result {
        let rows = parseCSV(text)
        guard let header = rows.first else { return Result(events: [], skipped: 0) }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ choices: [String]) -> Int? { names.firstIndex { choices.contains($0) } }
        guard let titleColumn = column(["subject", "title", "summary", "name", "event", "event name"]),
              let startColumn = column(["start date", "startdate", "start", "date", "start date/time", "start time and date"]) else {
            throw PMailError.notSupported("This CSV file has no Subject and Start Date columns, so PMail can’t tell which events are in it.")
        }
        let startTime = column(["start time", "starttime"])
        let endDate = column(["end date", "enddate", "end", "end date/time"])
        let endTime = column(["end time", "endtime"])
        let allDay = column(["all day event", "all day", "allday", "all-day", "all-day event"])
        let notes = column(["description", "notes", "details", "body"])
        let place = column(["location", "place", "where"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var events: [CalendarEvent] = []
        var skipped = 0
        for row in rows.dropFirst() where !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let title = value(titleColumn)
            guard !title.isEmpty, let startDay = date(value(startColumn), calendar: calendar) else {
                skipped += 1
                continue
            }
            let wholeDay = ["true", "yes", "y", "1"].contains(value(allDay).lowercased())
                || (value(startTime).isEmpty && startDay.time == nil)
            let start: Date
            var end: Date
            if wholeDay {
                start = calendar.startOfDay(for: startDay.date)
                let lastDay = date(value(endDate), calendar: calendar).map { calendar.startOfDay(for: $0.date) } ?? start
                end = calendar.date(byAdding: .day, value: 1, to: max(lastDay, start)) ?? start.addingTimeInterval(86_400)
            } else {
                guard let begins = combine(startDay, time: value(startTime), calendar: calendar) else {
                    skipped += 1
                    continue
                }
                start = begins
                let endDay = date(value(endDate), calendar: calendar) ?? startDay
                end = combine(endDay, time: value(endTime), calendar: calendar) ?? start.addingTimeInterval(3_600)
                if end <= start { end = start.addingTimeInterval(3_600) }
            }
            let description = value(notes)
            let location = value(place)
            events.append(CalendarEvent(calendarID: "", title: title, start: start, end: end, isAllDay: wholeDay,
                                        location: location.isEmpty ? nil : location, notes: description.isEmpty ? nil : description))
        }
        return Result(events: events, skipped: skipped)
    }

    /// A day, and the time of day when the cell has one too ("2026-11-24 15:00").
    static func date(_ text: String, calendar: Calendar) -> (date: Date, time: DateComponents?)? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "M/d/yyyy h:mm a",
                       "M/d/yyyy HH:mm", "M/d/yyyy h:mm:ss a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return (date, calendar.dateComponents([.hour, .minute], from: date))
            }
        }
        for format in ["yyyy-MM-dd", "M/d/yyyy", "M/d/yy", "d.M.yyyy", "MMM d, yyyy", "d MMM yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, nil) }
        }
        return nil
    }

    /// A day at a time of day ("3:00 PM", "15:00"), or the day's own time when the cell had one.
    static func combine(_ day: (date: Date, time: DateComponents?), time text: String, calendar: Calendar) -> Date? {
        if text.isEmpty { return day.time == nil ? nil : day.date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["h:mm a", "h:mm:ss a", "h:mma", "h a", "ha", "HH:mm", "HH:mm:ss", "H:mm"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text.uppercased()) {
                let parts = calendar.dateComponents([.hour, .minute, .second], from: parsed)
                return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0,
                                     of: calendar.startOfDay(for: day.date))
            }
        }
        return nil
    }

    /// Rows of cells, with quoted cells that hold commas, quotes ("") and line breaks.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var characters = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")[...]
        if characters.first == "\u{FEFF}" { characters = characters.dropFirst() }
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" {
                        cell.append("\"")
                        characters = characters.dropFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(cell)
                cell = ""
            } else if character == "\n" {
                row.append(cell)
                rows.append(row)
                row = []
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        return rows
    }
}
