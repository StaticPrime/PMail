import Foundation

/// A calendar's settings, as its settings pane shows them: its name, description, time zone and color, who owns it,
/// the notifications new events get, and the email notices its provider sends about it.
public struct CalendarSettings: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// The time zone's identifier ("America/New_York"), where the calendar has one.
    public var timeZone: String?
    /// "#RRGGBB".
    public var colorHex: String
    /// Who owns it, as the provider says ("You" for the account's own), where it says.
    public var owner: String?
    /// The notifications new timed events get, in minutes before they start.
    public var eventReminders: [Int]
    /// The notifications new all-day events get.
    public var allDayReminders: [AllDayReminder]
    /// The email notices the provider sends about changes to the calendar, where it sends any (nil where it doesn't).
    public var emailNotices: Set<EmailNotice>?

    public init(name: String, description: String = "", timeZone: String? = nil, colorHex: String, owner: String? = nil,
                eventReminders: [Int] = [10], allDayReminders: [AllDayReminder] = [], emailNotices: Set<EmailNotice>? = nil) {
        self.name = name
        self.description = description
        self.timeZone = timeZone
        self.colorHex = colorHex
        self.owner = owner
        self.eventReminders = eventReminders
        self.allDayReminders = allDayReminders
        self.emailNotices = emailNotices
    }
}

/// A notification for an all-day event: so many days before, at a time of day.
public struct AllDayReminder: Codable, Sendable, Hashable {
    public var daysBefore: Int
    /// Minutes after midnight.
    public var minuteOfDay: Int

    public init(daysBefore: Int, minuteOfDay: Int) {
        self.daysBefore = daysBefore
        self.minuteOfDay = minuteOfDay
    }

    /// How long before the all-day event starts (its midnight) this is, in minutes; negative for a time on the day.
    public var minutesBefore: Int { daysBefore * 1_440 - minuteOfDay }
}

/// Email notices a provider sends about a calendar.
public enum EmailNotice: String, Codable, Sendable, CaseIterable, Hashable {
    case newEvents = "eventCreation"
    case changedEvents = "eventChange"
    case canceledEvents = "eventCancellation"
    case responses = "eventResponse"
    case dailyAgenda = "agenda"

    public var title: String {
        switch self {
        case .newEvents: "New events"
        case .changedEvents: "Changed events"
        case .canceledEvents: "Canceled events"
        case .responses: "Event responses"
        case .dailyAgenda: "Daily agenda"
        }
    }

    public var detail: String {
        switch self {
        case .newEvents: "An event is added to this calendar"
        case .changedEvents: "An event on this calendar is changed"
        case .canceledEvents: "An event on this calendar is canceled"
        case .responses: "Guests respond to an event on this calendar"
        case .dailyAgenda: "A daily email with the agenda for this calendar"
        }
    }
}

/// What a calendar's provider keeps of its settings (the rest PMail keeps on this Mac, or only shows).
public struct CalendarSettingsSupport: Sendable, Hashable {
    public var name = false
    public var description = false
    public var timeZone = false
    public var color = false
    /// The notifications new timed events get.
    public var eventReminders = false
    public var emailNotices = false

    public init(name: Bool = false, description: Bool = false, timeZone: Bool = false, color: Bool = false, eventReminders: Bool = false,
                emailNotices: Bool = false) {
        self.name = name
        self.description = description
        self.timeZone = timeZone
        self.color = color
        self.eventReminders = eventReminders
        self.emailNotices = emailNotices
    }
}
