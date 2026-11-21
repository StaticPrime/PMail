import Foundation
@testable import PMailKit

/// Helpers for the iCalendar tests: wrapping fixtures, making moments and reading them back on a wall clock.
enum ICS {
    /// A VCALENDAR around some lines, with CRLF line breaks as servers send them.
    static func calendar(_ body: String) -> String {
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example Corp//Example Calendar//EN"]
            + body.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
            + ["END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The first VCALENDAR in some text.
    static func component(_ text: String) -> ICalendarComponent? {
        ICalendarComponent.parse(text).first { $0.name == "VCALENDAR" }
    }

    static func reader(_ text: String, owner: String? = nil, zone: String = "UTC") -> ICalendarReader? {
        guard let calendar = component(text) else { return nil }
        return ICalendarReader(calendar: calendar, ownerEmail: owner, localTimeZone: timeZone(zone))
    }

    /// Events in a window given as "yyyy-MM-dd HH:mm" in a zone.
    static func events(_ text: String, from start: String, to end: String, zone: String = "UTC", owner: String? = nil,
                       href: String? = nil) -> [CalendarEvent] {
        reader(text, owner: owner, zone: zone)?.events(calendarID: "cal", href: href, etag: nil, from: moment(start, zone),
                                                       to: moment(end, zone)) ?? []
    }

    static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .gmt
    }

    /// A moment from "yyyy-MM-dd HH:mm" on a zone's wall clock.
    static func moment(_ text: String, _ zone: String = "UTC") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone(zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text) ?? .distantPast
    }

    /// A moment as "yyyy-MM-dd HH:mm" on a zone's wall clock.
    static func wall(_ date: Date, _ zone: String = "UTC") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone(zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The starts of a window's events, as wall-clock text in a zone.
    static func starts(_ text: String, from start: String, to end: String, zone: String = "UTC") -> [String] {
        events(text, from: start, to: end, zone: zone).map { wall($0.start, zone) }
    }
}
