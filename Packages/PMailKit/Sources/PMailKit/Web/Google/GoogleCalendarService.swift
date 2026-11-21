import Foundation

/// A Google account's calendars, through Google's calendar API. New events can get a Google Meet meeting of their own.
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

    static let base = "https://www.googleapis.com/calendar/v3/"
    /// Seconds between looks at a new event while Google is still making its meeting.
    static let conferencePollInterval = 1.0

    struct EventKey: Hashable, Sendable {
        var calendarID: String
        var eventID: String
    }

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(client: WebClient(tokens: tokens, transport: transport))
    }

    init(client: WebClient) {
        self.client = client
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
        for item in pages.flatMap({ $0["items"].array }) {
            guard let calendar = Self.calendar(from: item) else { continue }
            defaultReminders[calendar.id] = Self.popupMinutes(item["defaultReminders"])
            calendars.append(calendar)
        }
        return calendars
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
                            isReadOnly: readOnly, nativeConference: meet ? .meet : nil, isOther: !primary && readOnly)
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
                    var query = [("timeMin", WebDate.utcString(start)), ("timeMax", WebDate.utcString(end)),
                                 ("singleEvents", "true"), ("orderBy", "startTime"), ("maxResults", "2500")]
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
                if let event = Self.event(from: item, calendarID: calendarID, defaultReminders: defaults, colors: colors) {
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
        let notes = item["description"].string.map(WebText.plainText(fromPossibleHTML:)).flatMap { $0.isEmpty ? nil : $0 }
        let location = item["location"].nonEmpty
        let usesDefaults = item["reminders"]["useDefault"].bool ?? true
        let reminders = usesDefaults ? defaultReminders : popupMinutes(item["reminders"]["overrides"])
        let organizer = item["organizer"]["email"].nonEmpty.map {
            MailAddress(name: item["organizer"]["displayName"].string, email: $0)
        }
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
                             etag: item["etag"].nonEmpty)
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

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        let targetID = scope == .allEvents ? (event.seriesID ?? event.id) : event.id
        do {
            try await client.delete(Self.eventsURL(event.calendarID, targetID, [("sendUpdates", "all")]))
        } catch PMailError.notFound {
            // Already gone.
        }
        loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = nil
    }

    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        // The whole guest list goes back, so read it fresh and change only the owner's answer.
        let current = try await client.get(Self.eventsURL(event.calendarID, event.id))
        var attendees = current["attendees"].array
        let mine = attendees.firstIndex { $0["self"].bool == true }
            ?? attendees.firstIndex { $0["email"].string?.caseInsensitiveCompare(event.calendarID) == .orderedSame }
        guard let mine, case var .object(entry) = attendees[mine] else {
            throw PMailError.notSupported("You aren’t a guest at this event, so there’s no invitation to answer.")
        }
        entry["responseStatus"] = .string(Self.responseText(response))
        attendees[mine] = .object(entry)
        let url = try Self.eventsURL(event.calendarID, event.id, [("sendUpdates", "all")])
        _ = try await client.patch(url, ["attendees": .array(attendees)])
        let key = EventKey(calendarID: event.calendarID, eventID: event.id)
        loaded[key]?.myResponse = response
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
        if changed(\.notes), !(isNew && edited.notes == nil) { body["description"] = .string(edited.notes ?? "") }
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
        if changed(\.colorHex), let hex = edited.colorHex.flatMap(WebColor.hex),
           let colorID = colors.first(where: { $0.value == hex })?.key {
            body["colorId"] = .string(colorID)
        }
        if original?.conference?.kind == .meet, edited.conference == nil, !addingConference {
            body["conferenceData"] = .null  // The person took the meeting off.
        }
        return body
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
