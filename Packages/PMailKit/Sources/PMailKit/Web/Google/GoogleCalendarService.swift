import Foundation
import os

/// A Google account's calendars, through Google's calendar API. New events can get a Google Meet meeting of their own.
/// Out of office and focus time are Google's own kinds of event where the calendar takes them (a Workspace account's
/// primary calendar); elsewhere they're saved as ordinary events.
public actor GoogleCalendarService: CalendarService {
    let client: WebClient
    /// Each calendar's default pop-up reminders, from the calendar list, for events that use them.
    private var defaultReminders: [String: [Int]] = [:]
    /// Event colors by `colorId`, fetched once.
    private var eventColors: [String: String]?
    /// Repeating series' RRULE lines, fetched once per series, since occurrences don't carry them.
    private var seriesRecurrence: [EventKey: [String]] = [:]
    /// The events as last loaded or saved, so an update sends only what the person changed.
    private var loaded: [EventKey: CalendarEvent] = [:]
    /// Calendars that turned down out of office or focus time, which aren't asked again.
    private var refusesStatusEvents: Set<String> = []

    static let base = "https://www.googleapis.com/calendar/v3/"
    /// Seconds between looks at a new event while Google is still making its meeting.
    static let conferencePollInterval = 1.0

    struct EventKey: Hashable, Sendable {
        var calendarID: String
        var eventID: String
    }

    /// Canceled invitations deleted from PMail, which Google keeps listing.
    let dismissed: DismissedEvents

    /// `dismissedFile` keeps the canceled invitations deleted from PMail between launches.
    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport(), dismissedFile: URL? = nil) {
        self.init(client: WebClient(tokens: tokens, transport: transport), dismissedFile: dismissedFile)
    }

    init(client: WebClient, dismissedFile: URL? = nil) {
        self.client = client
        dismissed = DismissedEvents(file: dismissedFile)
    }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    static func eventsURL(_ calendarID: String, _ eventID: String? = nil, _ query: [(String, String)] = []) throws -> URL {
        let path = "calendars/\(WebURL.segment(calendarID))/events" + (eventID.map { "/\(WebURL.segment($0))" } ?? "")
        return try url(path, query)
    }

    // MARK: Calendars

    public func loadCalendars() async throws -> [CalendarInfo] {
        let pages = try await client.pages { token in
            try Self.url("users/me/calendarList", [("maxResults", "250")] + (token.map { [("pageToken", $0)] } ?? []))
        }
        var calendars: [CalendarInfo] = []
        var owned = Set<String>()
        for item in pages.flatMap({ $0["items"].array }) {
            guard let calendar = Self.calendar(from: item) else { continue }
            defaultReminders[calendar.id] = Self.popupMinutes(item["defaultReminders"])
            if item["accessRole"].string == "owner" { owned.insert(calendar.id) }
            calendars.append(calendar)
        }
        let ownedNow = owned
        ownedCalendars.withLock { $0 = ownedNow }
        return calendars
    }

    /// The calendars the account owns, as last listed: only a calendar's owner can change its own name, description
    /// and time zone. Kept where the settings pane can ask without waiting.
    private nonisolated let ownedCalendars = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    // MARK: Settings

    /// Every calendar on the list keeps its name (for the account's own, the calendar's name; for others, the name it
    /// shows here), color, default notifications and email notices; the account's own keep a description and time zone.
    public nonisolated func settingsSupport(for calendar: CalendarInfo) -> CalendarSettingsSupport {
        let owns = calendar.isPrimary || ownedCalendars.withLock { $0.contains(calendar.id) }
        return CalendarSettingsSupport(name: true, description: owns, timeZone: owns, color: true, eventReminders: true, emailNotices: true)
    }

    public func loadSettings(for calendar: CalendarInfo) async throws -> CalendarSettings {
        let entry = try await client.get(Self.url("users/me/calendarList/\(WebURL.segment(calendar.id))"))
        let notices = Set(entry["notificationSettings"]["notifications"].array.compactMap { item -> EmailNotice? in
            item["method"].string == "email" ? EmailNotice(rawValue: item["type"].string ?? "") : nil
        })
        let owner = entry["accessRole"].string == "owner" ? "You" : (calendar.id.contains("@") && !calendar.id.contains("calendar.google.com") ? calendar.id : nil)
        return CalendarSettings(name: entry["summaryOverride"].nonEmpty ?? entry["summary"].nonEmpty ?? calendar.name,
                                description: entry["description"].string ?? "", timeZone: entry["timeZone"].nonEmpty,
                                colorHex: WebColor.hex(entry["backgroundColor"].string) ?? calendar.colorHex, owner: owner,
                                eventReminders: Self.popupMinutes(entry["defaultReminders"]), emailNotices: notices)
    }

    /// The calendar's own name, description and time zone (the account's own calendars), then its place on the list:
    /// the name it shows here (others' calendars), color, default notifications and email notices.
    public func saveSettings(_ settings: CalendarSettings, for calendar: CalendarInfo) async throws {
        let listURL = try Self.url("users/me/calendarList/\(WebURL.segment(calendar.id))", [("colorRgbFormat", "true")])
        let current = try await client.get(Self.url("users/me/calendarList/\(WebURL.segment(calendar.id))"))
        let owns = current["accessRole"].string == "owner"
        if owns {
            // Only what changed, so a calendar that refuses one change (a new time zone, say) still takes the others.
            var body: [String: JSONValue] = [:]
            if settings.name != (current["summary"].string ?? "") { body["summary"] = .string(settings.name) }
            if settings.description != (current["description"].string ?? "") { body["description"] = .string(settings.description) }
            if let zone = settings.timeZone, zone != current["timeZone"].string { body["timeZone"] = .string(zone) }
            if !body.isEmpty { _ = try await client.patch(Self.url("calendars/\(WebURL.segment(calendar.id))"), .object(body)) }
        }
        var entry: [String: JSONValue] = [
            "backgroundColor": .string(settings.colorHex.lowercased()), "foregroundColor": .string(WebColor.textColor(on: settings.colorHex)),
            "defaultReminders": .array(settings.eventReminders.map { .object(["method": .string("popup"), "minutes": .number(Double($0))]) }),
            "notificationSettings": .object(["notifications": .array((settings.emailNotices ?? []).sorted { $0.rawValue < $1.rawValue }.map {
                .object(["type": .string($0.rawValue), "method": .string("email")])
            })]),
        ]
        // Others' calendars are renamed for this account's list only; the account's own too where the list already
        // gives it a name of its own, which would hide the new one.
        if !owns || current["summaryOverride"].nonEmpty != nil { entry["summaryOverride"] = .string(settings.name) }
        _ = try await client.patch(listURL, .object(entry))
        defaultReminders[calendar.id] = settings.eventReminders
    }

    // MARK: Subscriptions

    public nonisolated var canSubscribeToPeople: Bool { true }

    /// Adds another person's calendar to the account's calendar list. Google lets it in only when they've shared it
    /// with the account or made it public.
    public func subscribe(toCalendarOf email: String) async throws -> CalendarInfo {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let entry = try await client.post(Self.url("users/me/calendarList"), ["id": .string(address)])
            guard let calendar = Self.calendar(from: entry) else { throw PMailError.protocolError("Google didn’t say which calendar it added") }
            defaultReminders[calendar.id] = Self.popupMinutes(entry["defaultReminders"])
            return calendar
        } catch PMailError.notFound {
            throw PMailError.notSupported("\(address) hasn’t shared their calendar with you, or there’s no calendar for that address.")
        } catch let PMailError.http(status, _) where status == 403 {
            throw PMailError.notSupported("\(address) hasn’t shared their calendar with you.")
        }
    }

    /// Takes a calendar off the account's calendar list; the calendar itself is untouched.
    public func unsubscribe(from calendarID: String) async throws {
        do {
            try await client.delete(Self.url("users/me/calendarList/\(WebURL.segment(calendarID))"))
        } catch PMailError.notFound {
            // Already off the list.
        }
    }

    /// A calendar list entry. Calendars the person can only read and that aren't their own are "other calendars".
    static func calendar(from item: JSONValue) -> CalendarInfo? {
        guard let id = item["id"].nonEmpty else { return nil }
        let role = item["accessRole"].string ?? "reader"
        let readOnly = role == "reader" || role == "freeBusyReader"
        let primary = item["primary"].bool ?? false
        let meet = item["conferenceProperties"]["allowedConferenceSolutionTypes"].strings.contains("hangoutsMeet")
        return CalendarInfo(id: id, name: item["summaryOverride"].nonEmpty ?? item["summary"].nonEmpty ?? id,
                            colorHex: WebColor.hex(item["backgroundColor"].string) ?? "#1A73E8", isPrimary: primary,
                            isReadOnly: readOnly, nativeConference: meet ? .meet : nil, isOther: !primary && readOnly,
                            canUnsubscribe: !primary && readOnly, defaultReminders: popupMinutes(item["defaultReminders"]),
                            isOwned: role == "owner")
    }

    /// Minutes before the start of the pop-up reminders in a list of reminders.
    static func popupMinutes(_ reminders: JSONValue) -> [Int] {
        reminders.array.filter { ($0["method"].string ?? "popup") == "popup" }.compactMap { $0["minutes"].int }
    }

    // MARK: Events

    public func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let client = self.client
        let calendars = WebClient.unique(calendarIDs)
        let pagesByCalendar = try await WebClient.concurrentMap(calendars) { calendarID -> (String, [JSONValue]) in
            do {
                let pages = try await client.pages { token in
                    // Deleted events too, for invitations their organizers canceled (shown marked canceled).
                    var query = [("timeMin", WebDate.utcString(start)), ("timeMax", WebDate.utcString(end)),
                                 ("singleEvents", "true"), ("orderBy", "startTime"), ("maxResults", "2500"), ("showDeleted", "true")]
                    if let token { query.append(("pageToken", token)) }
                    return try Self.eventsURL(calendarID, nil, query)
                }
                return (calendarID, pages)
            } catch PMailError.notFound {
                return (calendarID, [])  // A calendar that's been removed.
            }
        }
        let items = pagesByCalendar.flatMap { $0.1.flatMap { $0["items"].array } }
        let needsColors = items.contains { $0["colorId"].nonEmpty != nil }
        let colors = needsColors ? await eventColorTable() : (eventColors ?? [:])
        var events: [CalendarEvent] = []
        for (calendarID, pages) in pagesByCalendar {
            // The event list says which reminders the calendar uses by default; the calendar list is the fallback.
            let defaults = pages.first.flatMap { $0["defaultReminders"].isNull ? nil : Self.popupMinutes($0["defaultReminders"]) }
                ?? defaultReminders[calendarID] ?? []
            for item in pages.flatMap({ $0["items"].array }) {
                if let event = Self.event(from: item, calendarID: calendarID, defaultReminders: defaults, colors: colors),
                   await isShown(event) {
                    events.append(event)
                }
            }
        }
        events = await withSeriesRecurrence(events)
        remember(events)
        return events.sorted { $0.start < $1.start }
    }

    /// The event colors by ID, fetched the first time they're needed.
    private func eventColorTable() async -> [String: String] {
        if let eventColors { return eventColors }
        guard let json = try? await client.get(Self.url("colors")) else { return [:] }
        var table: [String: String] = [:]
        for (id, value) in json["event"].object ?? [:] {
            if let hex = WebColor.hex(value["background"].string) { table[id] = hex }
        }
        eventColors = table
        return table
    }

    /// Fills in the RRULE lines of repeating events' occurrences from their series, fetching each series once.
    private func withSeriesRecurrence(_ events: [CalendarEvent]) async -> [CalendarEvent] {
        let series = events.compactMap { event in event.seriesID.map { EventKey(calendarID: event.calendarID, eventID: $0) } }
        let missing = Set(series).filter { seriesRecurrence[$0] == nil }
        if !missing.isEmpty {
            let client = self.client
            let found = (try? await WebClient.concurrentMap(Array(missing)) { key -> (EventKey, [String]?) in
                let series = try? await client.get(Self.eventsURL(key.calendarID, key.eventID))
                return (key, series.map { $0["recurrence"].strings })
            }) ?? []
            for (key, rules) in found {
                if let rules { seriesRecurrence[key] = rules }
            }
        }
        return events.map { event in
            guard event.recurrence.isEmpty, let seriesID = event.seriesID,
                  let rules = seriesRecurrence[EventKey(calendarID: event.calendarID, eventID: seriesID)] else { return event }
            var filled = event
            filled.recurrence = rules
            return filled
        }
    }

    private func remember(_ events: [CalendarEvent]) {
        if loaded.count + events.count > 20_000 { loaded.removeAll() }
        for event in events { loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = event }
    }

    /// An event from Google's calendar API.
    static func event(from item: JSONValue, calendarID: String, defaultReminders: [Int],
                      colors: [String: String]) -> CalendarEvent? {
        guard let id = item["id"].nonEmpty, let start = time(item["start"]) else { return nil }
        var end = time(item["end"])?.date ?? start.date.addingTimeInterval(start.isAllDay ? 86_400 : 3_600)
        if end < start.date { end = start.date }
        let attendeeEntries = item["attendees"].array
        let me = attendeeEntries.first { $0["self"].bool == true }
        let myResponse = me.flatMap { $0["organizer"].bool == true ? nil : response(from: $0["responseStatus"].string) }
        let description = item["description"].string
        let notes = description.map(WebText.plainText(fromPossibleHTML:)).flatMap { $0.isEmpty ? nil : $0 }
        let notesHTML = description.flatMap { WebText.looksLikeHTML($0) ? EventDescription.simplified($0) : nil }
        let location = item["location"].nonEmpty
        let usesDefaults = item["reminders"]["useDefault"].bool ?? true
        let reminders = usesDefaults ? defaultReminders : popupMinutes(item["reminders"]["overrides"])
        let organizer = item["organizer"]["email"].nonEmpty.map {
            MailAddress(name: item["organizer"]["displayName"].string, email: $0)
        }
        let type = eventType(item["eventType"].string)
        let kindDetails = type == .outOfOffice ? item["outOfOfficeProperties"] : item["focusTimeProperties"]
        let declineMode = type == .event ? nil : kindDetails["autoDeclineMode"].string
        return CalendarEvent(id: id, calendarID: calendarID, title: item["summary"].string ?? "", start: start.date, end: end,
                             isAllDay: start.isAllDay, timeZone: item["start"]["timeZone"].nonEmpty, location: location,
                             notes: notes,
                             attendees: attendeeEntries.compactMap(attendee(from:)), organizer: organizer,
                             conference: conference(from: item) ?? ConferenceDetector.detect(in: [location, notes]),
                             colorHex: item["colorId"].string.flatMap { colors[$0] }, recurrence: item["recurrence"].strings,
                             seriesID: item["recurringEventId"].nonEmpty, occurrenceDate: time(item["originalStartTime"])?.date,
                             status: status(from: item["status"].string), myResponse: myResponse,
                             availability: item["transparency"].string == "transparent" ? .free : .busy,
                             reminderMinutes: reminders,
                             webLink: WebURL.webLink(item["htmlLink"].string), uid: item["iCalUID"].nonEmpty,
                             etag: item["etag"].nonEmpty, type: type,
                             declinesInvitations: declineMode.map { $0 != "declineNone" } ?? false,
                             declineMessage: type == .event ? nil : kindDetails["declineMessage"].nonEmpty,
                             declinesExisting: declineMode == "declineAllConflictingInvitations",
                             visibility: visibility(item["visibility"].string),
                             guestsCanModify: item["guestsCanModify"].bool ?? false,
                             guestsCanInviteOthers: item["guestsCanInviteOthers"].bool ?? true,
                             guestsCanSeeOtherGuests: item["guestsCanSeeOtherGuests"].bool ?? true, notesHTML: notesHTML)
    }

    /// Google's visibility; "confidential" shows as private.
    static func visibility(_ text: String?) -> EventVisibility {
        switch text {
        case "public": .public
        case "private", "confidential": .private
        default: .default
        }
    }

    /// The kinds of event PMail knows among Google's; the rest (working locations, birthdays) are ordinary events.
    static func eventType(_ text: String?) -> EventType {
        switch text {
        case "outOfOffice": .outOfOffice
        case "focusTime": .focusTime
        default: .event
        }
    }

    /// A start or end: `dateTime` for a timed event, `date` (local midnight) for an all-day one.
    static func time(_ value: JSONValue) -> (date: Date, isAllDay: Bool)? {
        if let text = value["dateTime"].string, let date = WebDate.parse(text) { return (date, false) }
        if let text = value["date"].string, let date = WebDate.localMidnight(text) { return (date, true) }
        return nil
    }

    static func attendee(from value: JSONValue) -> Attendee? {
        guard let email = value["email"].nonEmpty else { return nil }
        return Attendee(address: MailAddress(name: value["displayName"].string, email: email),
                        response: response(from: value["responseStatus"].string) ?? .needsAction,
                        isOptional: value["optional"].bool ?? false, isOrganizer: value["organizer"].bool ?? false)
    }

    static func response(from text: String?) -> AttendeeResponse? {
        switch text {
        case "accepted": .accepted
        case "declined": .declined
        case "tentative": .tentative
        case "needsAction": .needsAction
        default: nil
        }
    }

    static func responseText(_ response: AttendeeResponse) -> String {
        switch response {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .needsAction: "needsAction"
        }
    }

    static func status(from text: String?) -> CalendarEvent.Status {
        switch text {
        case "tentative": .tentative
        case "cancelled": .cancelled
        default: .confirmed
        }
    }

    /// The meeting from `conferenceData` (its video link, code and dial-in numbers) or the older `hangoutLink`.
    static func conference(from item: JSONValue) -> Conference? {
        let data = item["conferenceData"]
        let entryPoints = data["entryPoints"].array
        let phones = entryPoints.filter { $0["entryPointType"].string == "phone" }.compactMap(phoneLine)
        let solution = data["conferenceSolution"]["key"]["type"].string
        if let video = entryPoints.first(where: { $0["entryPointType"].string == "video" }),
           let url = WebURL.webLink(video["uri"].string) {
            let kind: Conference.Kind = solution == "hangoutsMeet" ? .meet : (ConferenceDetector.kind(of: url) ?? .other)
            let code = kind == .meet ? (data["conferenceId"].nonEmpty ?? video["meetingCode"].nonEmpty ?? meetCode(url))
                : video["meetingCode"].nonEmpty
            return Conference(kind: kind, joinURL: url, meetingCode: code, phoneNumbers: phones)
        }
        if let url = WebURL.webLink(item["hangoutLink"].string) {
            return Conference(kind: .meet, joinURL: url, meetingCode: data["conferenceId"].nonEmpty ?? meetCode(url),
                              phoneNumbers: phones)
        }
        return nil
    }

    private static func meetCode(_ url: URL) -> String? {
        let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return code.isEmpty ? nil : code
    }

    /// "+1 612-555-0100 PIN: 123456789#" from a phone entry point.
    static func phoneLine(_ entry: JSONValue) -> String? {
        let number = entry["label"].nonEmpty ?? entry["uri"].string.map { $0.replacingOccurrences(of: "tel:", with: "") }
        guard let number, !number.isEmpty else { return nil }
        guard let pin = entry["pin"].nonEmpty ?? entry["accessCode"].nonEmpty ?? entry["passcode"].nonEmpty else { return number }
        return "\(number) PIN: \(pin)#"
    }

    /// An event as Google sent it back, mapped with the calendar's reminders, the colors and the series' rules.
    private func mapped(_ item: JSONValue, calendarID: String) async -> CalendarEvent? {
        let colors = item["colorId"].nonEmpty == nil ? (eventColors ?? [:]) : await eventColorTable()
        guard let event = Self.event(from: item, calendarID: calendarID, defaultReminders: defaultReminders[calendarID] ?? [],
                                     colors: colors) else { return nil }
        return await withSeriesRecurrence([event]).first
    }

    // MARK: Changes

    public func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        guard Self.isStatusEvent(event.type), takesStatusEvents(event) else {
            var plain = event
            if Self.isStatusEvent(event.type) { plain.type = .event }
            return try await insert(plain, addingConference: addingConference)
        }
        do {
            return try await insert(event, addingConference: false)
        } catch let PMailError.http(status, _) where status == 400 || status == 403 {
            // Only the primary calendars of some Google accounts take them: an ordinary event then.
            refusesStatusEvents.insert(event.calendarID)
            var plain = event
            plain.type = .event
            return try await insert(plain, addingConference: addingConference)
        }
    }

    static func isStatusEvent(_ type: EventType) -> Bool { type == .outOfOffice || type == .focusTime }

    /// Whether to ask Google for out of office or focus time on this calendar: not where it said no before, and never
    /// focus time all day, which Google doesn't have.
    private func takesStatusEvents(_ event: CalendarEvent) -> Bool {
        !refusesStatusEvents.contains(event.calendarID) && !(event.type == .focusTime && event.isAllDay)
    }

    private func insert(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        let colors = event.colorHex == nil ? [:] : await eventColorTable()
        var body = Self.body(for: event, original: nil, isNew: true, includeTimes: true, addingConference: addingConference,
                             colors: colors)
        if addingConference { body["conferenceData"] = Self.conferenceRequest() }
        let url = try Self.eventsURL(event.calendarID, nil, [("conferenceDataVersion", "1"), ("sendUpdates", "all")])
        var saved = try await client.post(url, .object(body))
        if addingConference { saved = await waitForConference(saved, calendarID: event.calendarID) }
        guard let result = await mapped(saved, calendarID: event.calendarID) else {
            throw PMailError.protocolError("the new event couldn’t be read")
        }
        remember([result])
        return result
    }

    public func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        let original = loaded[EventKey(calendarID: event.calendarID, eventID: event.id)]
        // Google keeps an event's kind for good, so a one-off event changing kind is made again as the new kind and the
        // old one goes. Where Google won't take the new kind, the change is saved as it is (the kind kept on this Mac).
        let kind = event.type == .task ? EventType.event : event.type
        if let original, original.type != kind, !event.isRecurring, kind == .event || takesStatusEvents(event) {
            var replacement = event
            replacement.type = kind
            do {
                let made = try await insert(replacement, addingConference: addingConference && kind == .event)
                try? await delete(original, scope: .thisEvent)
                return made
            } catch let PMailError.http(status, _) where status == 400 || status == 403 {
                if Self.isStatusEvent(kind) { refusesStatusEvents.insert(event.calendarID) }
            }
        }
        // Changing every occurrence changes the series, keeping its own start and end.
        let wholeSeries = scope == .allEvents && event.seriesID != nil
        let targetID = wholeSeries ? (event.seriesID ?? event.id) : event.id
        let colorChanged = event.colorHex != nil && event.colorHex != original?.colorHex
        let colors = colorChanged ? await eventColorTable() : (eventColors ?? [:])
        var body = Self.body(for: event, original: original, isNew: false, includeTimes: !wholeSeries,
                             addingConference: addingConference, colors: colors)
        if addingConference { body["conferenceData"] = Self.conferenceRequest() }
        guard !body.isEmpty else { return event }
        let url = try Self.eventsURL(event.calendarID, targetID, [("conferenceDataVersion", "1"), ("sendUpdates", "all")])
        var saved = try await client.patch(url, .object(body))
        if addingConference { saved = await waitForConference(saved, calendarID: event.calendarID) }
        if wholeSeries {
            seriesRecurrence[EventKey(calendarID: event.calendarID, eventID: targetID)] = saved["recurrence"].strings
            // Hand back the occurrence the person was looking at, as it is now.
            if let occurrence = try? await client.get(Self.eventsURL(event.calendarID, event.id)) { saved = occurrence }
        }
        guard let result = await mapped(saved, calendarID: event.calendarID) else {
            throw PMailError.protocolError("the saved event couldn’t be read")
        }
        remember([result])
        return result
    }

    /// Whether a listed event shows: every event that isn't deleted, and invitations their organizer canceled (not
    /// ones the owner declined, which Google lists as deleted once they're removed, or deleted from PMail).
    private func isShown(_ event: CalendarEvent) async -> Bool {
        guard event.status == .cancelled else { return true }
        guard let answer = event.myResponse, answer != .declined else { return false }
        return await !dismissed.contains(event.id)
    }

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        let targetID = scope == .allEvents ? (event.seriesID ?? event.id) : event.id
        // A canceled invitation stays gone once deleted, though Google keeps listing it.
        if event.status == .cancelled { await dismissed.add(event.id) }
        do {
            try await client.delete(Self.eventsURL(event.calendarID, targetID, [("sendUpdates", "all")]))
        } catch PMailError.notFound {
            // Already gone.
        }
        loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = nil
    }

    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        try await respond(to: event, with: response, comment: nil, scope: .thisEvent)
    }

    /// Answers one time of a repeating meeting or (on the series itself) the whole of it, with a message Google sends
    /// the organizer. An answer without one clears an earlier message, which was for the earlier answer.
    public func respond(to event: CalendarEvent, with response: AttendeeResponse, comment: String?, scope: RecurrenceScope) async throws {
        let target = scope == .allEvents ? (event.seriesID ?? event.id) : event.id
        // The whole guest list goes back, so read it fresh and change only the owner's answer.
        let current = try await client.get(Self.eventsURL(event.calendarID, target))
        var attendees = current["attendees"].array
        let mine = attendees.firstIndex { $0["self"].bool == true }
            ?? attendees.firstIndex { $0["email"].string?.caseInsensitiveCompare(event.calendarID) == .orderedSame }
        guard let mine, case var .object(entry) = attendees[mine] else {
            throw PMailError.notSupported("You aren’t a guest at this event, so there’s no invitation to answer.")
        }
        entry["responseStatus"] = .string(Self.responseText(response))
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            entry["comment"] = .string(comment)
        } else {
            entry["comment"] = nil
        }
        attendees[mine] = .object(entry)
        let url = try Self.eventsURL(event.calendarID, target, [("sendUpdates", "all")])
        _ = try await client.patch(url, ["attendees": .array(attendees)])
        for key in loaded.keys where key.calendarID == event.calendarID && (key.eventID == event.id || (scope == .allEvents && loaded[key]?.seriesID == target)) {
            loaded[key]?.myResponse = response
        }
    }

    // MARK: Free and busy

    /// Busy times from Google's free/busy lookup: people in the same organization, or who share their calendar's
    /// free/busy, are known; for the rest, why not.
    public func freeBusy(for addresses: [String], from start: Date, to end: Date) async throws -> [String: FreeBusy] {
        guard !addresses.isEmpty else { return [:] }
        let body: JSONValue = ["timeMin": .string(WebDate.utcString(start)), "timeMax": .string(WebDate.utcString(end)),
                               "items": .array(addresses.map { ["id": .string($0)] })]
        let json = try await client.post(Self.url("freeBusy"), body)
        var found: [String: FreeBusy] = [:]
        for (id, entry) in json["calendars"].object ?? [:] {
            if let reason = entry["errors"].array.first?["reason"].string {
                found[id.lowercased()] = .unknown(reason == "notFound" ? "Their calendar isn’t shared with you."
                                                                       : "Their busy times couldn’t be found.")
                continue
            }
            let busy = entry["busy"].array.compactMap { stretch -> DateInterval? in
                guard let from = stretch["start"].string.flatMap({ WebDate.parse($0) }),
                      let to = stretch["end"].string.flatMap({ WebDate.parse($0) }), to > from else { return nil }
                return DateInterval(start: from, end: to)
            }
            found[id.lowercased()] = FreeBusy(busy: busy.sorted { $0.start < $1.start })
        }
        return Dictionary(addresses.map { ($0, found[$0.lowercased()] ?? .unknown("Their busy times couldn’t be found.")) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Looks at a new event again (up to three times, about a second apart) while Google is still making its meeting,
    /// until the join link is there. The event exists either way, so a failed look just keeps what's known.
    private func waitForConference(_ event: JSONValue, calendarID: String) async -> JSONValue {
        var current = event
        var looks = 0
        while Self.conferenceIsPending(current), looks < 3, let id = current["id"].nonEmpty {
            looks += 1
            try? await client.pause(Self.conferencePollInterval)
            guard let next = try? await client.get(Self.eventsURL(calendarID, id)) else { break }
            current = next
        }
        return current
    }

    static func conferenceIsPending(_ event: JSONValue) -> Bool {
        event["conferenceData"]["createRequest"]["status"]["statusCode"].string == "pending" && conference(from: event) == nil
    }

    /// Asks for a new Google Meet meeting.
    static func conferenceRequest() -> JSONValue {
        ["createRequest": ["requestId": .string(UUID().uuidString), "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    /// The fields to send for an event. For a new event, everything it has; for a change, only what differs from the
    /// event as it was loaded (so a formatted description or a room booking isn't rewritten by accident), or
    /// everything when it wasn't loaded here.
    static func body(for event: CalendarEvent, original: CalendarEvent?, isNew: Bool, includeTimes: Bool, addingConference: Bool,
                     colors: [String: String]) -> [String: JSONValue] {
        let edited = WebEvents.withPastedLink(event, original: original, addingConference: addingConference)
        func changed<Value: Equatable>(_ field: KeyPath<CalendarEvent, Value>) -> Bool {
            original.map { $0[keyPath: field] != edited[keyPath: field] } ?? true
        }
        var body: [String: JSONValue] = [:]
        if changed(\.title), !(isNew && edited.title.isEmpty) { body["summary"] = .string(edited.title) }
        if changed(\.location), !(isNew && edited.location == nil) { body["location"] = .string(edited.location ?? "") }
        // A formatted description goes as Google's simple HTML.
        if changed(\.notes) || changed(\.notesHTML), !(isNew && edited.notes == nil) {
            body["description"] = .string(edited.notesHTML ?? edited.notes ?? "")
        }
        if includeTimes, changed(\.start) || changed(\.end) || changed(\.isAllDay) || changed(\.timeZone) {
            let end = edited.isAllDay && edited.end <= edited.start ? edited.start.addingTimeInterval(86_400) : edited.end
            body["start"] = timeJSON(edited.start, allDay: edited.isAllDay, zone: edited.timeZone, isNew: isNew)
            body["end"] = timeJSON(end, allDay: edited.isAllDay, zone: edited.timeZone, isNew: isNew)
        }
        if changed(\.attendees), !(isNew && edited.attendees.isEmpty) {
            body["attendees"] = .array(edited.attendees.map(attendeeJSON))
        }
        if changed(\.availability) { body["transparency"] = edited.availability == .free ? "transparent" : "opaque" }
        if changed(\.reminderMinutes) {
            body["reminders"] = isNew && edited.reminderMinutes.isEmpty ? ["useDefault": true] : [
                "useDefault": false,
                "overrides": .array(edited.reminderMinutes.prefix(5).map { minutes -> JSONValue in
                    ["method": "popup", "minutes": JSONValue(max(minutes, 0))]
                }),
            ]
        }
        // An empty list only clears the rules when the event was loaded with some, never by default.
        if changed(\.recurrence), !edited.recurrence.isEmpty || original?.recurrence.isEmpty == false {
            body["recurrence"] = JSONValue(edited.recurrence)
        }
        if changed(\.visibility), !(isNew && edited.visibility == .default) { body["visibility"] = .string(edited.visibility.rawValue) }
        if changed(\.guestsCanModify), !(isNew && !edited.guestsCanModify) { body["guestsCanModify"] = .bool(edited.guestsCanModify) }
        if changed(\.guestsCanInviteOthers), !(isNew && edited.guestsCanInviteOthers) {
            body["guestsCanInviteOthers"] = .bool(edited.guestsCanInviteOthers)
        }
        if changed(\.guestsCanSeeOtherGuests), !(isNew && edited.guestsCanSeeOtherGuests) {
            body["guestsCanSeeOtherGuests"] = .bool(edited.guestsCanSeeOtherGuests)
        }
        if changed(\.colorHex), let hex = edited.colorHex.flatMap(WebColor.hex),
           let colorID = colors.first(where: { $0.value == hex })?.key {
            body["colorId"] = .string(colorID)
        }
        if original?.conference?.kind == .meet, edited.conference == nil, !addingConference {
            body["conferenceData"] = .null  // The person took the meeting off.
        }
        // Out of office and focus time: Google's own kinds, with whether invitations for that time are declined. An
        // event's kind is set when it's made; after that only the declining can change.
        if isStatusEvent(edited.type), isNew {
            body["eventType"] = .string(edited.type == .outOfOffice ? "outOfOffice" : "focusTime")
            body[edited.type == .outOfOffice ? "outOfOfficeProperties" : "focusTimeProperties"] = statusProperties(edited)
            if edited.type == .outOfOffice { body["transparency"] = "opaque" }
        } else if isStatusEvent(edited.type), let original, original.type == edited.type,
                  original.declinesInvitations != edited.declinesInvitations || original.declineMessage != edited.declineMessage
                    || original.declinesExisting != edited.declinesExisting {
            body[edited.type == .outOfOffice ? "outOfOfficeProperties" : "focusTimeProperties"] = statusProperties(edited)
        }
        return body
    }

    /// What out of office or focus time does with invitations for its time: declines new ones (and the meetings
    /// already planned, if asked), with the message, or none; focus time also asks chat not to disturb while declining.
    static func statusProperties(_ event: CalendarEvent) -> JSONValue {
        let mode = !event.declinesInvitations ? "declineNone"
            : event.declinesExisting ? "declineAllConflictingInvitations" : "declineOnlyNewConflictingInvitations"
        var value: [String: JSONValue] = ["autoDeclineMode": .string(mode)]
        if event.declinesInvitations, let message = event.declineMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            value["declineMessage"] = .string(message)
        }
        if event.type == .focusTime { value["chatStatus"] = .string(event.declinesInvitations ? "doNotDisturb" : "available") }
        return .object(value)
    }

    /// A start or end for Google: a `date` for an all-day event, else a UTC `dateTime` with the event's time zone. A
    /// change also clears the other form, since Google merges what it's sent.
    static func timeJSON(_ date: Date, allDay: Bool, zone: String?, isNew: Bool) -> JSONValue {
        var value: [String: JSONValue] = [:]
        if allDay {
            value["date"] = .string(WebDate.dayString(date))
            if !isNew { value["dateTime"] = .null }
        } else {
            value["dateTime"] = .string(WebDate.utcString(date))
            value["timeZone"] = .string(zone.flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier)
            if !isNew { value["date"] = .null }
        }
        return .object(value)
    }

    static func attendeeJSON(_ attendee: Attendee) -> JSONValue {
        var value: [String: JSONValue] = ["email": .string(attendee.address.email),
                                          "responseStatus": .string(responseText(attendee.response))]
        if let name = attendee.address.name { value["displayName"] = .string(name) }
        if attendee.isOptional { value["optional"] = true }
        return .object(value)
    }
}
