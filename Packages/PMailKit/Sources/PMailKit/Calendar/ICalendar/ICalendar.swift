import Foundation

/// Reading and writing iCalendar files (RFC 5545), for invitations that arrive by mail and for sharing events.
public enum ICalendar {
    /// The events in an iCalendar file that overlap `start..<end`, with repeating events expanded into their
    /// occurrences. `ownerEmail` fills in each event's `myResponse` from the matching guest.
    public static func events(in data: Data, calendarID: String, from start: Date, to end: Date, ownerEmail: String? = nil,
                              timeZone: TimeZone = .current) -> [CalendarEvent] {
        ICalendarComponent.parse(data).filter { $0.name == "VCALENDAR" }.flatMap { calendar in
            ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: timeZone)
                .events(calendarID: calendarID, href: nil, etag: nil, from: start, to: end)
        }
    }

    public static func events(in text: String, calendarID: String, from start: Date, to end: Date, ownerEmail: String? = nil,
                              timeZone: TimeZone = .current) -> [CalendarEvent] {
        events(in: Data(text.utf8), calendarID: calendarID, from: start, to: end, ownerEmail: ownerEmail, timeZone: timeZone)
    }

    /// A whole iCalendar file for one event, as PMail would save it to a calendar server.
    public static func document(for event: CalendarEvent, ownerEmail: String? = nil, timeZone: TimeZone = .current) -> String {
        let uid = event.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        return ICalendarWriter(ownerEmail: ownerEmail, localTimeZone: timeZone).newCalendar(for: event, uid: uid).serialized
    }

    /// One iCalendar file holding a calendar's events, for exporting it: each repeating series once, as a rule with its
    /// moved and changed times and without its deleted ones, each other event as it is, and each time zone they use once.
    /// A time is judged deleted only up to `end` (the end of the events asked for) and the last event given, so a
    /// provider that stopped listing early doesn't make the times after it look deleted.
    public static func exportDocument(for events: [CalendarEvent], ownerEmail: String? = nil, timeZone: TimeZone = .current,
                                      through end: Date? = nil) -> String {
        let writer = ICalendarWriter(ownerEmail: ownerEmail, localTimeZone: timeZone)
        let latest = events.map(\.start).max().map { $0.addingTimeInterval(86_400) }
        let limit = [end, latest].compactMap { $0 }.min()
        var groups: [String: [CalendarEvent]] = [:]
        var order: [String] = []
        for event in events.sorted(by: { $0.start < $1.start }) {
            let key = event.seriesID ?? event.uid.flatMap { $0.isEmpty ? nil : $0 } ?? event.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }
        var zones: [String: ICalendarComponent] = [:]
        var parts: [ICalendarComponent] = []
        func add(_ calendar: ICalendarComponent) {
            for component in calendar.components {
                if component.name == "VTIMEZONE" {
                    if let id = component.property("TZID")?.value, zones[id] == nil { zones[id] = component }
                } else {
                    parts.append(component)
                }
            }
        }
        for key in order {
            let group = groups[key] ?? []
            let uid = group.first?.uid.flatMap { $0.isEmpty ? nil : $0 } ?? key
            if group.contains(where: \.isRecurring),
               let series = writer.exportedSeries(group, uid: uid, through: limit ?? group.map(\.end).max() ?? Date()) {
                add(series)
                continue
            }
            // Events on their own, and the times of a series that doesn't fit a rule, each with a UID of its own.
            for (index, event) in group.enumerated() {
                var single = event
                if group.count > 1 { single.recurrence = [] }
                add(writer.newCalendar(for: single, uid: group.count > 1 ? "\(uid)-\(index + 1)" : uid))
            }
        }
        var calendar = writer.newCalendar(for: CalendarEvent(calendarID: "", start: Date(), end: Date()), uid: "export")
        calendar.components = zones.keys.sorted().compactMap { zones[$0] } + parts
        return calendar.serialized
    }
}
