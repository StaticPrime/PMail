import Foundation

/// One of an account's calendars.
public struct CalendarInfo: Codable, Sendable, Identifiable, Hashable {
    /// The provider's ID for it (a calendar ID, a CalDAV collection's URL path).
    public var id: String
    public var name: String
    /// "#RRGGBB".
    public var colorHex: String
    /// The account's main calendar, where new events go unless the person picks another.
    public var isPrimary: Bool
    /// Events can be read but not added, changed or deleted.
    public var isReadOnly: Bool
    /// The video meeting the calendar can add to an event by itself (Meet on Google calendars, Teams on Microsoft
    /// ones), or nil.
    public var nativeConference: Conference.Kind?
    /// Subscribed or shared calendars, listed under "Other calendars".
    public var isOther: Bool

    public init(id: String, name: String, colorHex: String = "#1A73E8", isPrimary: Bool = false, isReadOnly: Bool = false,
                nativeConference: Conference.Kind? = nil, isOther: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isPrimary = isPrimary
        self.isReadOnly = isReadOnly
        self.nativeConference = nativeConference
        self.isOther = isOther
    }
}

/// A guest's answer to an invitation.
public enum AttendeeResponse: String, Codable, Sendable, Hashable, CaseIterable {
    case needsAction
    case accepted
    case declined
    case tentative
}

/// Someone invited to an event.
public struct Attendee: Codable, Sendable, Hashable {
    public var address: MailAddress
    public var response: AttendeeResponse
    public var isOptional: Bool
    public var isOrganizer: Bool

    public init(address: MailAddress, response: AttendeeResponse = .needsAction, isOptional: Bool = false, isOrganizer: Bool = false) {
        self.address = address
        self.response = response
        self.isOptional = isOptional
        self.isOrganizer = isOrganizer
    }
}

/// A video meeting attached to an event.
public struct Conference: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// A Google Meet meeting.
        case meet
        /// A Microsoft Teams meeting.
        case teams
        /// A FaceTime link.
        case faceTime
        case zoom
        case webex
        case other

        /// The product's name, for "Join with …" buttons.
        public var displayName: String {
            switch self {
            case .meet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .faceTime: "FaceTime"
            case .zoom: "Zoom"
            case .webex: "Webex"
            case .other: "video call"
            }
        }
    }

    public var kind: Kind
    public var joinURL: URL
    /// The meeting's code or ID, as people type it ("abc-defg-hij").
    public var meetingCode: String?
    /// Numbers to dial in by phone, with PINs, as the provider wrote them.
    public var phoneNumbers: [String]

    public init(kind: Kind, joinURL: URL, meetingCode: String? = nil, phoneNumbers: [String] = []) {
        self.kind = kind
        self.joinURL = joinURL
        self.meetingCode = meetingCode
        self.phoneNumbers = phoneNumbers
    }
}

/// Changing or deleting one occurrence of a repeating event, or every occurrence.
public enum RecurrenceScope: String, Codable, Sendable, Hashable {
    case thisEvent
    case allEvents
}

/// How an event shows on the person's free/busy time.
public enum EventAvailability: String, Codable, Sendable, Hashable {
    case busy
    case free
}

/// An event, or one occurrence of a repeating event.
public struct CalendarEvent: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case confirmed
        case tentative
        case cancelled
    }

    /// Unique in the account. For an occurrence of a repeating event, unique to that occurrence.
    public var id: String
    public var calendarID: String
    public var title: String
    /// For all-day events, midnight at the start of the first day, in the current time zone.
    public var start: Date
    /// For all-day events, midnight at the start of the day after the last day (exclusive, as in iCalendar).
    public var end: Date
    public var isAllDay: Bool
    /// The event's own time zone identifier, if it has one.
    public var timeZone: String?
    public var location: String?
    /// The description, as plain text.
    public var notes: String?
    public var attendees: [Attendee]
    public var organizer: MailAddress?
    public var conference: Conference?
    /// The event's own color ("#RRGGBB"), when it differs from its calendar's.
    public var colorHex: String?
    /// RRULE/EXDATE/RDATE lines of a repeating event's series, for showing "Repeats weekly".
    public var recurrence: [String]
    /// For an occurrence of a repeating event, the series' ID.
    public var seriesID: String?
    /// For an occurrence, its original start (iCalendar RECURRENCE-ID).
    public var occurrenceDate: Date?
    public var status: Status
    /// The account owner's own answer, when they're a guest.
    public var myResponse: AttendeeResponse?
    public var availability: EventAvailability
    /// Minutes before the start to remind (pop-up reminders).
    public var reminderMinutes: [Int]
    /// A link the provider gives to the event on its website.
    public var webLink: URL?
    /// iCalendar UID.
    public var uid: String?
    /// The CalDAV resource the event lives in (a URL path), for CalDAV calendars.
    public var resourceHref: String?
    /// For checking nobody else changed it first (an ETag or change key).
    public var etag: String?

    public init(id: String = UUID().uuidString, calendarID: String, title: String = "", start: Date, end: Date,
                isAllDay: Bool = false, timeZone: String? = nil, location: String? = nil, notes: String? = nil,
                attendees: [Attendee] = [], organizer: MailAddress? = nil, conference: Conference? = nil, colorHex: String? = nil,
                recurrence: [String] = [], seriesID: String? = nil, occurrenceDate: Date? = nil, status: Status = .confirmed,
                myResponse: AttendeeResponse? = nil, availability: EventAvailability = .busy, reminderMinutes: [Int] = [],
                webLink: URL? = nil, uid: String? = nil, resourceHref: String? = nil, etag: String? = nil) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.organizer = organizer
        self.conference = conference
        self.colorHex = colorHex
        self.recurrence = recurrence
        self.seriesID = seriesID
        self.occurrenceDate = occurrenceDate
        self.status = status
        self.myResponse = myResponse
        self.availability = availability
        self.reminderMinutes = reminderMinutes
        self.webLink = webLink
        self.uid = uid
        self.resourceHref = resourceHref
        self.etag = etag
    }

    /// Whether this is one occurrence of a repeating event.
    public var isRecurring: Bool { seriesID != nil || !recurrence.isEmpty }
}

/// One account's calendars, however they're reached.
///
/// Implementations are thread-safe and throw `PMailError`. Repeating events come back as separate occurrences.
public protocol CalendarService: AnyObject, Sendable {
    func loadCalendars() async throws -> [CalendarInfo]

    /// Every event and occurrence in the calendars that overlaps `start..<end`.
    func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent]

    /// Adds an event and returns it as saved (with its new ID, and the meeting's link). With `addingConference`,
    /// the calendar's own video meeting (its `nativeConference`) is created and attached; a `conference` already
    /// on the event (a pasted FaceTime link) is saved as it is.
    func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent

    /// Saves changes to an event (one occurrence, or the whole series) and returns it as saved.
    func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent

    func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws

    /// Answers an invitation for the account's owner.
    func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws
}
