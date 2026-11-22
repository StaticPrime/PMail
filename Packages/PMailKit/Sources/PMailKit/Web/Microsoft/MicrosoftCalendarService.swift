import Foundation

/// A Microsoft account's calendars, through Microsoft Graph. New events can get a Microsoft Teams meeting of their own.
public actor MicrosoftCalendarService: CalendarService {
    let client: WebClient
    /// The events as last loaded or saved, so an update sends only what the person changed.
    private var loaded: [EventKey: CalendarEvent] = [:]

    static let base = Graph.root + "me/"
    /// Times come back in UTC, whatever zone an event was made in.
    static let headers = ["Prefer": "outlook.timezone=\"UTC\""]
    static let eventFields = "id,subject,body,start,end,isAllDay,location,attendees,organizer,onlineMeeting,"
        + "onlineMeetingProvider,onlineMeetingUrl,isOnlineMeeting,seriesMasterId,originalStart,originalStartTimeZone,showAs,"
        + "isReminderOn,reminderMinutesBeforeStart,webLink,iCalUId,changeKey,responseStatus,isCancelled,type"
    /// Seconds between looks at a new event while Teams is still making its meeting.
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

    /// An event's address, or one of its actions ("accept"). Reading it asks for just the fields PMail uses.
    static func eventURL(_ id: String, _ action: String? = nil, forReading: Bool = false) throws -> URL {
        try url("events/\(WebURL.segment(id))" + (action.map { "/\($0)" } ?? ""), forReading ? [("$select", eventFields)] : [])
    }

    // MARK: Calendars

    public func loadCalendars() async throws -> [CalendarInfo] {
        let items = try await client.graphItems(Self.url("calendars", [("$top", "100")]), headers: Self.headers)
        let me = items.first { $0["isDefaultCalendar"].bool == true }?["owner"]["address"].string
        return items.compactMap { Self.calendar(from: $0, ownerAddress: me) }
    }

    /// A calendar. Calendars someone else owns, and ones that can't be changed, are "other calendars".
    static func calendar(from json: JSONValue, ownerAddress: String?) -> CalendarInfo? {
        guard let id = json["id"].nonEmpty else { return nil }
        let isDefault = json["isDefaultCalendar"].bool ?? false
        let canEdit = json["canEdit"].bool ?? false
        let owner = json["owner"]["address"].string?.lowercased()
        let ownedElsewhere = owner != nil && ownerAddress != nil && owner != ownerAddress?.lowercased()
        let teams = json["allowedOnlineMeetingProviders"].strings.contains("teamsForBusiness")
        return CalendarInfo(id: id, name: json["name"].string ?? "",
                            colorHex: WebColor.hex(json["hexColor"].string) ?? colorHex(json["color"].string),
                            isPrimary: isDefault, isReadOnly: !canEdit, nativeConference: teams ? .teams : nil,
                            isOther: !isDefault && (ownedElsewhere || !canEdit))
    }

    /// The color for one of Graph's named calendar colors.
    static func colorHex(_ name: String?) -> String {
        switch name {
        case "lightBlue": "#4A9BE8"
        case "lightGreen": "#5DB761"
        case "lightOrange": "#F09A3E"
        case "lightGray": "#9E9E9E"
        case "lightYellow": "#E8C43B"
        case "lightTeal": "#3EB5B0"
        case "lightPink": "#E66BA3"
        case "lightBrown": "#A87B5A"
        case "lightRed": "#E05A5A"
        default: "#0078D4"
        }
    }

    // MARK: Events

    public func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let client = self.client
        let results = try await WebClient.concurrentMap(WebClient.unique(calendarIDs)) { calendarID -> [CalendarEvent] in
            let url = try Self.url("calendars/\(WebURL.segment(calendarID))/calendarView",
                                   [("startDateTime", WebDate.utcString(start)), ("endDateTime", WebDate.utcString(end)),
                                    ("$top", "500"), ("$select", Self.eventFields)])
            do {
                let items = try await client.graphItems(url, headers: Self.headers)
                return items.compactMap { Self.event(from: $0, calendarID: calendarID) }
            } catch PMailError.notFound {
                return []  // A calendar that's been removed.
            }
        }
        let events = results.flatMap { $0 }.sorted { $0.start < $1.start }
        remember(events)
        return events
    }

    private func remember(_ events: [CalendarEvent]) {
        if loaded.count + events.count > 20_000 { loaded.removeAll() }
        for event in events { loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = event }
    }

    /// An event from Graph (asked for with times in UTC).
    static func event(from json: JSONValue, calendarID: String) -> CalendarEvent? {
        guard let id = json["id"].nonEmpty else { return nil }
        let isAllDay = json["isAllDay"].bool ?? false
        guard let start = time(json["start"], allDay: isAllDay) else { return nil }
        var end = time(json["end"], allDay: isAllDay) ?? start.addingTimeInterval(isAllDay ? 86_400 : 3_600)
        if end < start { end = start }
        let location = json["location"]["displayName"].nonEmpty
        let notes = notesText(json["body"])
        let organizer = Graph.address(json["organizer"])
        let reminders = json["isReminderOn"].bool == true ? [max(json["reminderMinutesBeforeStart"].int ?? 15, 0)] : []
        // Graph often names zones its own way ("Pacific Standard Time"); only zone names the Mac knows are kept.
        let zone = json["originalStartTimeZone"].string.flatMap(TimeZone.init(identifier:))?.identifier
        return CalendarEvent(id: id, calendarID: calendarID, title: json["subject"].string ?? "", start: start, end: end,
                             isAllDay: isAllDay, timeZone: zone, location: location, notes: notes,
                             attendees: json["attendees"].array.compactMap { attendee(from: $0, organizer: organizer) },
                             organizer: organizer,
                             conference: conference(from: json) ?? ConferenceDetector.detect(in: [location, notes]),
                             seriesID: json["seriesMasterId"].nonEmpty,
                             occurrenceDate: json["originalStart"].string.flatMap { WebDate.parse($0) },
                             status: json["isCancelled"].bool == true ? .cancelled : .confirmed,
                             myResponse: myResponse(json["responseStatus"]["response"].string),
                             availability: json["showAs"].string == "free" ? .free : .busy, reminderMinutes: reminders,
                             webLink: WebURL.webLink(json["webLink"].string), uid: json["iCalUId"].nonEmpty,
                             etag: json["changeKey"].nonEmpty ?? json["@odata.etag"].nonEmpty,
                             type: json["showAs"].string == "oof" ? .outOfOffice : .event)
    }

    /// A start or end. All-day events become local midnight of their date; others are read in their own zone (UTC).
    static func time(_ json: JSONValue, allDay: Bool) -> Date? {
        guard let text = json["dateTime"].string else { return nil }
        if allDay { return WebDate.localMidnight(text) }
        let zone = json["timeZone"].string.flatMap(TimeZone.init(identifier:)) ?? .gmt
        return WebDate.parse(text, defaultZone: zone)
    }

    static func notesText(_ body: JSONValue) -> String? {
        guard let content = body["content"].string else { return nil }
        let text = body["contentType"].string?.lowercased() == "html" ? WebText.plainText(fromHTML: content) : content
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func attendee(from json: JSONValue, organizer: MailAddress?) -> Attendee? {
        guard let address = Graph.address(json) else { return nil }
        let answer = json["status"]["response"].string
        let response: AttendeeResponse = switch answer {
        case "accepted", "organizer": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        default: .needsAction
        }
        return Attendee(address: address, response: response, isOptional: json["type"].string == "optional",
                        isOrganizer: answer == "organizer" || organizer?.isSameMailbox(as: address) == true)
    }

    /// The owner's own answer, when they're a guest (not for their own events, or ones without guests).
    static func myResponse(_ answer: String?) -> AttendeeResponse? {
        switch answer {
        case "accepted": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        case "notResponded": .needsAction
        default: nil
        }
    }

    /// The meeting from `onlineMeeting` (a Teams meeting's join link and dial-in numbers) or `onlineMeetingUrl`.
    static func conference(from json: JSONValue) -> Conference? {
        let meeting = json["onlineMeeting"]
        let link = meeting["joinUrl"].nonEmpty ?? json["onlineMeetingUrl"].nonEmpty
        guard let url = WebURL.webLink(link) else { return nil }
        let kind: Conference.Kind = json["onlineMeetingProvider"].string == "teamsForBusiness" ? .teams
            : (ConferenceDetector.kind(of: url) ?? .other)
        let pin = meeting["conferenceId"].nonEmpty
        var numbers = meeting["phones"].array.compactMap { $0["number"].nonEmpty }
        if numbers.isEmpty { numbers = [meeting["tollNumber"].nonEmpty, meeting["tollFreeNumber"].nonEmpty].compactMap { $0 } }
        let phones = numbers.map { number in pin.map { "\(number) PIN: \($0)#" } ?? number }
        return Conference(kind: kind, joinURL: url, phoneNumbers: phones)
    }

    // MARK: Changes

    public func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        var body = Self.body(for: event, original: nil, isNew: true, includeTimes: true, addingConference: addingConference)
        if addingConference {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = "teamsForBusiness"
        }
        var saved = try await client.post(Self.url("calendars/\(WebURL.segment(event.calendarID))/events"), .object(body),
                                          headers: Self.headers)
        if addingConference { saved = await waitForJoinURL(saved) }
        guard let result = Self.event(from: saved, calendarID: event.calendarID) else {
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
        var body = Self.body(for: event, original: original, isNew: false, includeTimes: !wholeSeries,
                             addingConference: addingConference)
        if addingConference {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = "teamsForBusiness"
        }
        guard !body.isEmpty else { return event }
        var saved = try await client.patch(Self.eventURL(targetID), .object(body), headers: Self.headers)
        if addingConference { saved = await waitForJoinURL(saved) }
        if wholeSeries, let occurrence = try? await client.get(Self.eventURL(event.id, forReading: true), headers: Self.headers) {
            saved = occurrence  // The occurrence the person was looking at, as it is now.
        }
        guard let result = Self.event(from: saved, calendarID: event.calendarID) else {
            throw PMailError.protocolError("the saved event couldn’t be read")
        }
        remember([result])
        return result
    }

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        let targetID = scope == .allEvents ? (event.seriesID ?? event.id) : event.id
        do {
            try await client.delete(Self.eventURL(targetID), headers: Self.headers)
        } catch PMailError.notFound {
            // Already gone.
        }
        loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = nil
    }

    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        let action: String
        switch response {
        case .accepted: action = "accept"
        case .tentative: action = "tentativelyAccept"
        case .declined: action = "decline"
        case .needsAction: throw PMailError.notSupported("An answered invitation can’t be set back to unanswered.")
        }
        _ = try await client.post(Self.eventURL(event.id, action), ["sendResponse": true], headers: Self.headers)
        loaded[EventKey(calendarID: event.calendarID, eventID: event.id)]?.myResponse = response
    }

    /// Looks at a new event again (up to three times, about a second apart) until its meeting's join link is there.
    /// The event exists either way, so a failed look just keeps what's known.
    private func waitForJoinURL(_ event: JSONValue) async -> JSONValue {
        var current = event
        var looks = 0
        while Self.conference(from: current) == nil, looks < 3, let id = current["id"].nonEmpty {
            looks += 1
            try? await client.pause(Self.conferencePollInterval)
            guard let next = try? await client.get(Self.eventURL(id, forReading: true), headers: Self.headers) else { break }
            current = next
        }
        return current
    }

    /// The fields to send for an event: everything for a new one; for a change, only what differs from the event as
    /// it was loaded (or everything when it wasn't loaded here).
    static func body(for event: CalendarEvent, original: CalendarEvent?, isNew: Bool, includeTimes: Bool,
                     addingConference: Bool) -> [String: JSONValue] {
        let edited = WebEvents.withPastedLink(event, original: original, addingConference: addingConference)
        func changed<Value: Equatable>(_ field: KeyPath<CalendarEvent, Value>) -> Bool {
            original.map { $0[keyPath: field] != edited[keyPath: field] } ?? true
        }
        var body: [String: JSONValue] = [:]
        if changed(\.title), !(isNew && edited.title.isEmpty) { body["subject"] = .string(edited.title) }
        if changed(\.location), !(isNew && edited.location == nil) {
            body["location"] = ["displayName": .string(edited.location ?? "")]
        }
        if changed(\.notes), !(isNew && edited.notes == nil) {
            body["body"] = ["contentType": "text", "content": .string(edited.notes ?? "")]
        }
        if includeTimes, changed(\.start) || changed(\.end) || changed(\.isAllDay) {
            body["isAllDay"] = .bool(edited.isAllDay)
            if edited.isAllDay {
                let first = WebDate.startOfDay(edited.start)
                var last = WebDate.startOfDay(edited.end)
                if last <= first {
                    last = Calendar.current.date(byAdding: .day, value: 1, to: first) ?? first.addingTimeInterval(86_400)
                }
                let zone = TimeZone.current
                let zoneName = JSONValue.string(zone.identifier)
                body["start"] = ["dateTime": .string(WebDate.dateTimeString(first, in: zone)), "timeZone": zoneName]
                body["end"] = ["dateTime": .string(WebDate.dateTimeString(last, in: zone)), "timeZone": zoneName]
            } else {
                body["start"] = ["dateTime": .string(WebDate.utcLocalString(edited.start)), "timeZone": "UTC"]
                body["end"] = ["dateTime": .string(WebDate.utcLocalString(max(edited.end, edited.start))), "timeZone": "UTC"]
            }
        }
        if changed(\.attendees), !(isNew && edited.attendees.isEmpty) {
            body["attendees"] = .array(edited.attendees.map { attendee -> JSONValue in
                ["emailAddress": Graph.addressJSON(attendee.address)["emailAddress"],
                 "type": attendee.isOptional ? "optional" : "required"]
            })
        }
        // Out of office is how an event shows (showAs "oof"); focus time has no such thing, and is kept on this Mac.
        if edited.type == .outOfOffice {
            if original?.type != .outOfOffice { body["showAs"] = "oof" }
        } else if changed(\.availability) || original?.type == .outOfOffice {
            body["showAs"] = edited.availability == .free ? "free" : "busy"
        }
        if changed(\.reminderMinutes) {
            body["isReminderOn"] = .bool(!edited.reminderMinutes.isEmpty)
            // Graph keeps one reminder per event: the first.
            if let minutes = edited.reminderMinutes.first { body["reminderMinutesBeforeStart"] = JSONValue(max(minutes, 0)) }
        }
        return body
    }
}
