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
}
