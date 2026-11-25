import Foundation

/// The person's other accounts' calendars, shown beside an account's own so their whole schedule is in one place:
/// read-only there, changed only from their own account. A calendar's ID carries its account's, so calendars (and
/// events) from two accounts never mix, even where their providers give them the same IDs.
public enum OtherAccountCalendars {
    private static let prefix = "account:"

    /// The ID another account's calendar has beside the account showing.
    public static func id(_ calendarID: String, of account: UUID) -> String {
        prefix + account.uuidString + "/" + calendarID
    }

    /// Where a calendar comes from: another account, and the calendar's ID there; nil for the account's own.
    public static func origin(of id: String) -> (account: UUID, calendarID: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let account = UUID(uuidString: String(rest[..<slash])) else { return nil }
        return (account, String(rest[rest.index(after: slash)...]))
    }

    /// The calendars of another account that show: its own (not ones it follows or subscribes to, or its task lists),
    /// read-only, and none of them where new events go.
    public static func calendars(_ calendars: [CalendarInfo], of account: UUID) -> [CalendarInfo] {
        calendars.filter { !$0.isOther && !$0.isTaskList }.map { calendar in
            var shown = calendar
            shown.id = id(calendar.id, of: account)
            shown.isReadOnly = true
            shown.isPrimary = false
            shown.nativeConference = nil
            shown.canUnsubscribe = nil
            return shown
        }
    }

    /// Another account's events on the calendars that show, moved onto those calendars' IDs.
    public static func events(_ events: [CalendarEvent], on calendars: [CalendarInfo], of account: UUID) -> [CalendarEvent] {
        let shown = Set(calendars.map(\.id))
        return events.compactMap { event in
            var moved = event
            moved.calendarID = id(event.calendarID, of: account)
            return shown.contains(moved.calendarID) ? moved : nil
        }
    }

    /// The event as its own account has it (its calendar's ID there), for one from another account.
    public static func original(of event: CalendarEvent) -> CalendarEvent {
        guard let origin = origin(of: event.calendarID) else { return event }
        var original = event
        original.calendarID = origin.calendarID
        return original
    }

    /// Other accounts' events without those already showing: the same meeting (by its iCalendar UID and start) on one
    /// of the account's own calendars, or on an earlier one of the other accounts'.
    public static func withoutRepeats(_ others: [CalendarEvent], besides own: [CalendarEvent]) -> [CalendarEvent] {
        var seen = Set(own.compactMap(sameMeeting))
        return others.filter { event in
            guard let meeting = sameMeeting(event) else { return true }
            return seen.insert(meeting).inserted
        }
    }

    private static func sameMeeting(_ event: CalendarEvent) -> String? {
        guard let uid = event.uid, !uid.isEmpty else { return nil }
        return uid + "\u{1F}" + String(event.start.timeIntervalSince1970)
    }
}
