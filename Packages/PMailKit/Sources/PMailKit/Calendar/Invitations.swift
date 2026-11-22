import Foundation

/// A calendar invitation carried by email (iTIP over iMIP, RFC 5546 and RFC 6047): what it asks (REQUEST, CANCEL or
/// REPLY), the event it's about, and its iCalendar text.
public struct Invitation: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        /// An invitation, or a change to one.
        case request = "REQUEST"
        /// The event is called off (for everyone, or for the guests it names).
        case cancel = "CANCEL"
        /// A guest's answer.
        case reply = "REPLY"
        case other
    }

    public var method: Method
    /// The event as a calendar shows it (the first time, for a repeating one), with the account's own answer.
    public var event: CalendarEvent
    public var uid: String
    public var sequence: Int
    public var organizer: MailAddress?
    /// In a REPLY: the guest who answered, with their answer.
    public var replier: Attendee?
    /// The iCalendar text as it came.
    public var text: String

    /// Whether a file is an invitation's: a text/calendar or application/ics part, or a .ics file.
    public static func isCalendarFile(mimeType: String, filename: String) -> Bool {
        let type = mimeType.lowercased()
        return type.hasPrefix("text/calendar") || type.hasPrefix("application/ics") || filename.lowercased().hasSuffix(".ics")
    }

    /// Reads an invitation from an iCalendar file. `ownerEmail` is the account's address, for its own answer.
    public static func read(_ data: Data, ownerEmail: String, timeZone: TimeZone = .current) -> Invitation? {
        let text = String(decoding: data, as: UTF8.self)
        guard let calendar = ICalendarComponent.parse(text).first(where: { $0.name == "VCALENDAR" }) else { return nil }
        let events = calendar.components.filter { $0.name == "VEVENT" }
        guard let main = events.first(where: { $0.property("RECURRENCE-ID") == nil }) ?? events.first,
              let uid = main.property("UID")?.value.trimmingCharacters(in: .whitespaces), !uid.isEmpty,
              let event = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: timeZone)
                .firstEvent(calendarID: "", href: nil, etag: nil) else { return nil }
        let methodText = calendar.property("METHOD")?.value.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let method = Method(rawValue: methodText) ?? .other
        let organizer = main.property("ORGANIZER").flatMap(ICalendarEventProperties.address(of:))
        let replier = method == .reply
            ? main.properties("ATTENDEE").first.flatMap { ICalendarEventProperties.attendee(from: $0, organizer: organizer) } : nil
        let sequence = main.property("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        return Invitation(method: method, event: event, uid: uid, sequence: sequence, organizer: organizer, replier: replier, text: text)
    }
}

/// The iCalendar text of the invitations PMail sends by email for a calendar with no server to send them: the
/// organizer's REQUEST and CANCEL, and a guest's REPLY.
public enum InvitationText {
    /// An invitation for the event an iCalendar document holds (the organizer's copy), to every guest it names.
    public static func request(from document: String, now: Date = Date()) -> String? {
        guard var calendar = vcalendar(document) else { return nil }
        calendar.components = calendar.components.compactMap { component in
            guard component.name == "VEVENT" else { return component }
            var event = withoutAlarms(component)
            event.setProperty(ICalendarLine("DTSTAMP", value: utc(now)))
            return event
        }
        return withMethod(.request, calendar).serialized
    }

    /// Calls the event off for these guests, or for everyone when `attendees` is nil: its main VEVENT, marked
    /// cancelled, with a higher SEQUENCE so it replaces what they had.
    public static func cancel(from document: String, for attendees: [MailAddress]? = nil, now: Date = Date()) -> String? {
        guard var calendar = vcalendar(document),
              var event = calendar.components.first(where: { $0.name == "VEVENT" && $0.property("RECURRENCE-ID") == nil })
                ?? calendar.components.first(where: { $0.name == "VEVENT" }) else { return nil }
        event = withoutAlarms(event)
        let sequence = event.property("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        event.setProperty(ICalendarLine("SEQUENCE", value: String(sequence + 1)))
        event.setProperty(ICalendarLine("STATUS", value: "CANCELLED"))
        event.setProperty(ICalendarLine("DTSTAMP", value: utc(now)))
        if let attendees {
            let organizer = event.property("ORGANIZER").flatMap(ICalendarEventProperties.address(of:))
            var lines = event.properties("ATTENDEE").filter { line in
                guard let address = ICalendarEventProperties.address(of: line) else { return false }
                return attendees.contains { ICalendarEventProperties.isSameMailbox($0.email, address.email) }
            }
            // Guests already taken off the event aren't in it any more, but the cancellation is for them.
            for guest in attendees where !lines.contains(where: { line in
                ICalendarEventProperties.address(of: line).map { ICalendarEventProperties.isSameMailbox($0.email, guest.email) } ?? false
            }) && !(organizer.map { ICalendarEventProperties.isSameMailbox($0.email, guest.email) } ?? false) {
                lines.append(attendeeLine(guest, response: .needsAction))
            }
            event.removeProperties("ATTENDEE")
            event.properties += lines
        }
        calendar.components = calendar.components.filter { $0.name != "VEVENT" } + [event]
        return withMethod(.cancel, calendar).serialized
    }

    /// A guest's answer to an invitation (its iCalendar text, or the copy kept of it): each VEVENT with what
    /// identifies it, and just the guest's own ATTENDEE line with their answer.
    public static func reply(to document: String, from attendee: MailAddress, response: AttendeeResponse, now: Date = Date()) -> String? {
        guard var calendar = vcalendar(document) else { return nil }
        let kept: Set<String> = ["UID", "SEQUENCE", "RECURRENCE-ID", "DTSTART", "DTEND", "DURATION", "RRULE", "SUMMARY", "ORGANIZER"]
        var replied = false
        calendar.components = calendar.components.compactMap { component in
            guard component.name == "VEVENT" else { return component.name == "VTIMEZONE" ? component : nil }
            var event = ICalendarComponent(name: "VEVENT", properties: component.properties.filter { kept.contains($0.name) })
            event.properties.append(ICalendarLine("DTSTAMP", value: utc(now)))
            var line = component.properties("ATTENDEE").first { line in
                ICalendarEventProperties.address(of: line).map { ICalendarEventProperties.isSameMailbox($0.email, attendee.email) } ?? false
            } ?? attendeeLine(attendee, response: response)
            line.setParameter("PARTSTAT", ICalendarEventProperties.partstat(response))
            line.setParameter("RSVP", nil)
            event.properties.append(line)
            replied = true
            return event
        }
        return replied ? withMethod(.reply, calendar).serialized : nil
    }

    /// Sets a guest's answer (by address) on every VEVENT of a calendar. False when they aren't on it.
    static func setAnswer(_ response: AttendeeResponse, of email: String, in calendar: inout ICalendarComponent) -> Bool {
        var found = false
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" {
            for index in calendar.components[event].properties.indices where calendar.components[event].properties[index].name == "ATTENDEE" {
                guard let address = ICalendarEventProperties.address(of: calendar.components[event].properties[index]),
                      ICalendarEventProperties.isSameMailbox(address.email, email) else { continue }
                calendar.components[event].properties[index].setParameter("PARTSTAT", ICalendarEventProperties.partstat(response))
                calendar.components[event].properties[index].setParameter("RSVP", nil)
                found = true
            }
        }
        return found
    }

    static func sequence(of calendar: ICalendarComponent) -> Int {
        let main = calendar.components.first { $0.name == "VEVENT" && $0.property("RECURRENCE-ID") == nil }
            ?? calendar.components.first { $0.name == "VEVENT" }
        return main?.property("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    static func organizer(of calendar: ICalendarComponent) -> MailAddress? {
        calendar.components.first { $0.name == "VEVENT" }?.property("ORGANIZER").flatMap(ICalendarEventProperties.address(of:))
    }

    /// The method's iCalendar line, in place of any the document had.
    static func withMethod(_ method: Invitation.Method, _ calendar: ICalendarComponent) -> ICalendarComponent {
        var calendar = calendar
        calendar.removeProperties("METHOD")
        let position = (calendar.properties.firstIndex { $0.name == "PRODID" }).map { $0 + 1 } ?? calendar.properties.count
        calendar.properties.insert(ICalendarLine("METHOD", value: method.rawValue), at: position)
        return calendar
    }

    static func vcalendar(_ document: String) -> ICalendarComponent? {
        ICalendarComponent.parse(document).first { $0.name == "VCALENDAR" }
    }

    static func withoutAlarms(_ event: ICalendarComponent) -> ICalendarComponent {
        var event = event
        event.components.removeAll { $0.name == "VALARM" }
        return event
    }

    static func attendeeLine(_ address: MailAddress, response: AttendeeResponse) -> ICalendarLine {
        var parameters = [ICalendarParameter("PARTSTAT", ICalendarEventProperties.partstat(response))]
        if let name = address.name, !name.isEmpty { parameters.insert(ICalendarParameter("CN", name), at: 0) }
        return ICalendarLine("ATTENDEE", parameters: parameters, value: "mailto:" + address.email)
    }

    static func utc(_ date: Date) -> String {
        ICalendarDateTime(wall: ICalendarZone.utc.wall(from: date), form: .utc).text
    }
}
