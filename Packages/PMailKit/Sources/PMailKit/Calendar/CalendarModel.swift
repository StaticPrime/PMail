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
    /// A calendar the account follows (another person's, or one from a web address) and can stop following; nil for
    /// any other.
    public var canUnsubscribe: Bool?

    public init(id: String, name: String, colorHex: String = "#1A73E8", isPrimary: Bool = false, isReadOnly: Bool = false,
                nativeConference: Conference.Kind? = nil, isOther: Bool = false, canUnsubscribe: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isPrimary = isPrimary
        self.isReadOnly = isReadOnly
        self.nativeConference = nativeConference
        self.isOther = isOther
        self.canUnsubscribe = canUnsubscribe ? true : nil
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

/// Who can see an event's details: whatever the calendar's sharing says, everyone who can see the calendar, or only
/// the people who can change it (others see the time as busy).
public enum EventVisibility: String, Codable, Sendable, Hashable, CaseIterable {
    case `default`
    case `public`
    case `private`

    public var name: String {
        switch self {
        case .default: "Default visibility"
        case .public: "Public"
        case .private: "Private"
        }
    }
}

/// What guests may do with an event besides coming to it.
public enum GuestPermission: String, Sendable, Hashable, CaseIterable {
    /// Change the event.
    case modify
    /// Invite other people.
    case inviteOthers
    /// See who else is invited.
    case seeGuestList

    public var name: String {
        switch self {
        case .modify: "Modify event"
        case .inviteOthers: "Invite others"
        case .seeGuestList: "See guest list"
        }
    }
}

/// What an account's calendars keep for an event beyond the basics, so the window offers only that.
public struct CalendarFeatures: Sendable, Hashable {
    /// The most notifications an event can have.
    public var maximumReminders: Int
    /// The visibilities an event can be given (none: the calendar has no such setting).
    public var visibilities: [EventVisibility]
    /// The guest permissions the calendar keeps.
    public var guestPermissions: [GuestPermission]
    /// Whether other people's busy times can be looked up (`CalendarService.freeBusy`).
    public var looksUpBusyTimes: Bool

    public init(maximumReminders: Int, visibilities: [EventVisibility], guestPermissions: [GuestPermission], looksUpBusyTimes: Bool) {
        self.maximumReminders = maximumReminders
        self.visibilities = visibilities
        self.guestPermissions = guestPermissions
        self.looksUpBusyTimes = looksUpBusyTimes
    }

    /// Google calendars: five notifications, all three visibilities and guest permissions, and free/busy lookups.
    public static let google = CalendarFeatures(maximumReminders: 5, visibilities: EventVisibility.allCases,
                                                guestPermissions: GuestPermission.allCases, looksUpBusyTimes: true)
    /// Microsoft calendars: one notification, normal or private, whether guests see each other, and free/busy lookups
    /// (for work and school accounts).
    public static let microsoft = CalendarFeatures(maximumReminders: 1, visibilities: [.default, .private],
                                                   guestPermissions: [.seeGuestList], looksUpBusyTimes: true)
    /// CalDAV servers that keep an event's CLASS: several notifications and the three visibilities.
    public static let calDAV = CalendarFeatures(maximumReminders: 5, visibilities: EventVisibility.allCases, guestPermissions: [],
                                                looksUpBusyTimes: false)
    /// iCloud calendars and calendars kept on the Mac: several notifications, nothing more.
    public static let basic = CalendarFeatures(maximumReminders: 5, visibilities: [], guestPermissions: [], looksUpBusyTimes: false)
}

/// When someone is busy, from their calendar, or why that isn't known.
public struct FreeBusy: Sendable, Hashable {
    /// The busy stretches, in order.
    public var busy: [DateInterval]
    /// Why their busy times aren't known (their calendar isn't shared, say); nil when they are.
    public var problem: String?

    public init(busy: [DateInterval] = [], problem: String? = nil) {
        self.busy = busy
        self.problem = problem
    }

    public static func unknown(_ problem: String) -> FreeBusy { FreeBusy(problem: problem) }
}

/// What kind of item is on the calendar.
public enum EventType: String, Codable, Sendable, Hashable, CaseIterable {
    case event
    /// Something to do by a day, ticked off when done (in the account's task list).
    case task
    /// Time away: new invitations can be declined.
    case outOfOffice
    /// Time kept for work without meetings.
    case focusTime

    public var name: String {
        switch self {
        case .event: "Event"
        case .task: "Task"
        case .outOfOffice: "Out of office"
        case .focusTime: "Focus time"
        }
    }

    /// The title a new one starts with, if it isn't given one.
    public var defaultTitle: String {
        switch self {
        case .event: ""
        case .task: ""
        case .outOfOffice: "Out of office"
        case .focusTime: "Focus time"
        }
    }
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
    /// The description with its formatting (bold, italic, underline, links, lists) as simple HTML, when it has any
    /// (`EventDescription`); `notes` is always its plain text.
    public var notesHTML: String?
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
    /// What kind of item it is.
    public var type: EventType
    /// For a task: whether it's done.
    public var isCompleted: Bool
    /// Whether `type` is PMail's own, kept on this Mac because the calendar can't hold it.
    public var isTypeLocal: Bool
    /// For out of office and focus time where the calendar can (a Google Workspace calendar): whether invitations for
    /// that time are declined, and the message they're declined with.
    public var declinesInvitations: Bool
    public var declineMessage: String?
    /// Who can see its details.
    public var visibility: EventVisibility
    /// What its guests may do, where the calendar keeps it: change it, invite others, see the guest list.
    public var guestsCanModify: Bool
    public var guestsCanInviteOthers: Bool
    public var guestsCanSeeOtherGuests: Bool

    public init(id: String = UUID().uuidString, calendarID: String, title: String = "", start: Date, end: Date,
                isAllDay: Bool = false, timeZone: String? = nil, location: String? = nil, notes: String? = nil,
                attendees: [Attendee] = [], organizer: MailAddress? = nil, conference: Conference? = nil, colorHex: String? = nil,
                recurrence: [String] = [], seriesID: String? = nil, occurrenceDate: Date? = nil, status: Status = .confirmed,
                myResponse: AttendeeResponse? = nil, availability: EventAvailability = .busy, reminderMinutes: [Int] = [],
                webLink: URL? = nil, uid: String? = nil, resourceHref: String? = nil, etag: String? = nil, type: EventType = .event,
                isCompleted: Bool = false, isTypeLocal: Bool = false, declinesInvitations: Bool = false, declineMessage: String? = nil,
                visibility: EventVisibility = .default, guestsCanModify: Bool = false, guestsCanInviteOthers: Bool = true,
                guestsCanSeeOtherGuests: Bool = true, notesHTML: String? = nil) {
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
        self.type = type
        self.isCompleted = isCompleted
        self.isTypeLocal = isTypeLocal
        self.declinesInvitations = declinesInvitations
        self.declineMessage = declineMessage
        self.visibility = visibility
        self.guestsCanModify = guestsCanModify
        self.guestsCanInviteOthers = guestsCanInviteOthers
        self.guestsCanSeeOtherGuests = guestsCanSeeOtherGuests
        self.notesHTML = notesHTML
    }

    /// Whether this is one occurrence of a repeating event.
    public var isRecurring: Bool { seriesID != nil || !recurrence.isEmpty }

    /// Whether it's a task (in one of the account's task lists) rather than an event.
    public var isTask: Bool { TaskLists.listID(from: calendarID) != nil }
}

extension CalendarEvent {
    /// Events saved before there were kinds of event read as events (and before visibility and guest permissions, with
    /// the usual ones).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), calendarID: try c.decode(String.self, forKey: .calendarID),
                  title: try c.decode(String.self, forKey: .title), start: try c.decode(Date.self, forKey: .start),
                  end: try c.decode(Date.self, forKey: .end), isAllDay: try c.decode(Bool.self, forKey: .isAllDay),
                  timeZone: try c.decodeIfPresent(String.self, forKey: .timeZone), location: try c.decodeIfPresent(String.self, forKey: .location),
                  notes: try c.decodeIfPresent(String.self, forKey: .notes), attendees: try c.decode([Attendee].self, forKey: .attendees),
                  organizer: try c.decodeIfPresent(MailAddress.self, forKey: .organizer),
                  conference: try c.decodeIfPresent(Conference.self, forKey: .conference),
                  colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex), recurrence: try c.decode([String].self, forKey: .recurrence),
                  seriesID: try c.decodeIfPresent(String.self, forKey: .seriesID),
                  occurrenceDate: try c.decodeIfPresent(Date.self, forKey: .occurrenceDate), status: try c.decode(Status.self, forKey: .status),
                  myResponse: try c.decodeIfPresent(AttendeeResponse.self, forKey: .myResponse),
                  availability: try c.decode(EventAvailability.self, forKey: .availability),
                  reminderMinutes: try c.decode([Int].self, forKey: .reminderMinutes), webLink: try c.decodeIfPresent(URL.self, forKey: .webLink),
                  uid: try c.decodeIfPresent(String.self, forKey: .uid), resourceHref: try c.decodeIfPresent(String.self, forKey: .resourceHref),
                  etag: try c.decodeIfPresent(String.self, forKey: .etag),
                  type: try c.decodeIfPresent(EventType.self, forKey: .type) ?? .event,
                  isCompleted: try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false,
                  isTypeLocal: try c.decodeIfPresent(Bool.self, forKey: .isTypeLocal) ?? false,
                  declinesInvitations: try c.decodeIfPresent(Bool.self, forKey: .declinesInvitations) ?? false,
                  declineMessage: try c.decodeIfPresent(String.self, forKey: .declineMessage),
                  visibility: try c.decodeIfPresent(EventVisibility.self, forKey: .visibility) ?? .default,
                  guestsCanModify: try c.decodeIfPresent(Bool.self, forKey: .guestsCanModify) ?? false,
                  guestsCanInviteOthers: try c.decodeIfPresent(Bool.self, forKey: .guestsCanInviteOthers) ?? true,
                  guestsCanSeeOtherGuests: try c.decodeIfPresent(Bool.self, forKey: .guestsCanSeeOtherGuests) ?? true,
                  notesHTML: try c.decodeIfPresent(String.self, forKey: .notesHTML))
    }
}

/// Task lists shown as calendars of tasks beside an account's calendars: a list's calendar ID is "tasks:" and its own ID.
public enum TaskLists {
    public static let prefix = "tasks:"
    /// The color tasks show in.
    public static let colorHex = "#3F51B5"

    public static func calendarID(for listID: String) -> String { prefix + listID }

    public static func listID(from calendarID: String) -> String? {
        calendarID.hasPrefix(prefix) ? String(calendarID.dropFirst(prefix.count)) : nil
    }
}

extension CalendarInfo {
    /// Whether it's one of the account's task lists rather than a calendar.
    public var isTaskList: Bool { TaskLists.listID(from: id) != nil }
}

/// One of an account's task lists.
public struct TaskList: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Where new tasks go.
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// One account's tasks, however they're kept (Google Tasks, Microsoft To Do, or on this Mac). Tasks come and go as
/// `CalendarEvent`s of type `.task`, in their list's calendar (`TaskLists.calendarID(for:)`), all day on the day
/// they're due.
public protocol TaskService: AnyObject, Sendable {
    func loadTaskLists() async throws -> [TaskList]

    /// The tasks in some lists (by the lists' own IDs) due on a day in `start..<end`, done or not.
    func loadTasks(in listIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent]

    func create(_ task: CalendarEvent) async throws -> CalendarEvent
    func update(_ task: CalendarEvent) async throws -> CalendarEvent
    func delete(_ task: CalendarEvent) async throws
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

    /// When people (by email address) are busy in `start..<end`, as far as the provider can tell: each one's busy
    /// times, or why they aren't known. Calendars that can't look people up say so for everyone.
    func freeBusy(for addresses: [String], from start: Date, to end: Date) async throws -> [String: FreeBusy]

    // Invitations by email, for a calendar with no server to send them (`emailsInvitations`). Providers' calendars
    // send their own invitations, answers and cancellations.

    /// Whether PMail emails this calendar's invitations, answers and cancellations itself.
    var emailsInvitations: Bool { get }

    /// Whether invitations that come by email are taken into this calendar (`receive`): a calendar kept on this Mac,
    /// or a calendar server's (which may not take them in itself). Providers' calendars take theirs in themselves.
    var takesInEmailedInvitations: Bool { get }

    /// The iCalendar text to email about an event: an invitation (REQUEST) to its guests, its cancellation (CANCEL) for
    /// some guests or, when `attendees` is nil, everyone, or the owner's answer (REPLY). Nil when there's nothing to send.
    /// Ask for a cancellation before deleting the event.
    func invitationText(for event: CalendarEvent, method: Invitation.Method, attendees: [MailAddress]?) async throws -> String?

    // Subscriptions: other calendars the account follows, listed under "Other calendars".

    /// Whether another person's calendar can be followed by their address.
    var canSubscribeToPeople: Bool { get }

    /// Follows another person's calendar, by their address, and returns it. Throws when they haven't shared it with the
    /// account (or made it public).
    func subscribe(toCalendarOf email: String) async throws -> CalendarInfo

    /// Stops following a calendar (one whose `canUnsubscribe` is set). Nothing is deleted from the calendar itself.
    func unsubscribe(from calendarID: String) async throws

    /// Takes in an invitation that came by email, when the owner is one of its guests: a REQUEST adds its event,
    /// waiting for an answer (or updates it, whatever changed), a CANCEL marks it canceled, and a REPLY puts a guest's
    /// answer on an event of the owner's. `invitationText(for:method: .reply…)` then gives the answer to email, where PMail sends it.
    func receive(_ invitation: Invitation) async throws
}

extension CalendarService {
    public func freeBusy(for addresses: [String], from start: Date, to end: Date) async throws -> [String: FreeBusy] {
        Dictionary(addresses.map { ($0, FreeBusy.unknown("This account’s calendar can’t look up other people’s busy times.")) },
                   uniquingKeysWith: { first, _ in first })
    }

    public var emailsInvitations: Bool { false }

    public var takesInEmailedInvitations: Bool { false }

    public var canSubscribeToPeople: Bool { false }

    public func subscribe(toCalendarOf email: String) async throws -> CalendarInfo {
        throw PMailError.notSupported("This account can’t follow other people’s calendars.")
    }

    public func unsubscribe(from calendarID: String) async throws {
        throw PMailError.notSupported("This calendar can’t be unsubscribed from here.")
    }

    public func invitationText(for event: CalendarEvent, method: Invitation.Method, attendees: [MailAddress]?) async throws -> String? { nil }

    public func receive(_ invitation: Invitation) async throws {}
}
