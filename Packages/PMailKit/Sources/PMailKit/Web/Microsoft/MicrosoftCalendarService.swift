import Foundation

/// A Microsoft account's calendars, through Microsoft Graph. New events can get a Microsoft Teams meeting of their own.
///
/// Deleting a meeting you organized calls it off, which sends everyone invited a cancellation. Outlook takes a meeting
/// you decline off your calendar, so PMail keeps declined meetings (`DeclinedMeetings`) and shows them as declined.
public actor MicrosoftCalendarService: CalendarService {
    let client: WebClient
    /// Meetings declined from PMail, which Outlook has taken off the calendar.
    let declined: DeclinedMeetings
    /// People whose shared calendars the account follows from PMail (Graph can't add them to the account's own list).
    let followed: FollowedCalendars
    /// The events as last loaded or saved, so an update sends only what the person changed.
    private var loaded: [EventKey: CalendarEvent] = [:]
    /// Each series' RRULE lines, from its series master (occurrences don't say how they repeat), by the master's ID.
    private var seriesRecurrence: [String: [String]] = [:]
    /// When each series starts, by its master's ID: a changed rule still starts there.
    private var seriesStarts: [String: Date] = [:]

    static let base = Graph.root + "me/"
    /// Times come back in UTC, whatever zone an event was made in.
    static let headers = ["Prefer": "outlook.timezone=\"UTC\""]
    static let eventFields = "id,subject,body,start,end,isAllDay,location,attendees,organizer,onlineMeeting,"
        + "onlineMeetingProvider,onlineMeetingUrl,isOnlineMeeting,seriesMasterId,originalStart,originalStartTimeZone,showAs,"
        + "isReminderOn,reminderMinutesBeforeStart,webLink,iCalUId,changeKey,responseStatus,isCancelled,type,sensitivity,hideAttendees"
    /// Seconds between looks at a new event while Teams is still making its meeting.
    static let conferencePollInterval = 1.0

    struct EventKey: Hashable, Sendable {
        var calendarID: String
        var eventID: String
    }

    /// `declinedFile` keeps meetings declined from PMail between launches, and `followedFile` the people whose calendars
    /// the account follows.
    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport(), declinedFile: URL? = nil,
                followedFile: URL? = nil) {
        self.init(client: WebClient(tokens: tokens, transport: transport), declinedFile: declinedFile, followedFile: followedFile)
    }

    init(client: WebClient, declinedFile: URL? = nil, followedFile: URL? = nil) {
        self.client = client
        declined = DeclinedMeetings(file: declinedFile)
        followed = FollowedCalendars(file: followedFile)
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
        return items.compactMap { Self.calendar(from: $0, ownerAddress: me) } + (await followed.calendars())
    }

    // MARK: Subscriptions

    public nonisolated var canSubscribeToPeople: Bool { true }

    /// Follows another person's calendar, where they've shared it with the account: Graph reads it, and PMail keeps
    /// the person, since Graph can't add it to the account's own list.
    public func subscribe(toCalendarOf email: String) async throws -> CalendarInfo {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar: JSONValue
        do {
            calendar = try await client.get(Self.personURL(address, "calendar", [("$select", "id,name,owner,hexColor")]), headers: Self.headers)
        } catch PMailError.notFound {
            throw PMailError.notSupported("\(address) hasn’t shared their calendar with you, or there’s no calendar for that address.")
        } catch let PMailError.http(status, _) where status == 403 {
            throw PMailError.notSupported("\(address) hasn’t shared their calendar with you. If they have, sign in to this account again "
                + "to let PMail read calendars shared with it.")
        }
        let name = calendar["owner"]["name"].nonEmpty ?? address
        return await followed.add(email: address, name: name, colorHex: WebColor.hex(calendar["hexColor"].string))
    }

    public func unsubscribe(from calendarID: String) async throws {
        guard let email = FollowedCalendars.email(from: calendarID) else {
            throw PMailError.notSupported("This calendar was added in Outlook. Remove it there, or hide it here.")
        }
        await followed.remove(email: email)
    }

    /// Another person's mailbox, or something in it.
    static func personURL(_ email: String, _ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(Graph.root + "users/\(WebURL.segment(email))/\(path)", query: query)
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
            let window = [("startDateTime", WebDate.utcString(start)), ("endDateTime", WebDate.utcString(end)),
                          ("$top", "500"), ("$select", Self.eventFields)]
            // Someone else's calendar the account follows is read from their mailbox.
            if let email = FollowedCalendars.email(from: calendarID) {
                let items = (try? await client.graphItems(Self.personURL(email, "calendar/calendarView", window), headers: Self.headers)) ?? []
                return items.compactMap { Self.event(from: $0, calendarID: calendarID) }
            }
            let url = try Self.url("calendars/\(WebURL.segment(calendarID))/calendarView", window)
            do {
                let items = try await client.graphItems(url, headers: Self.headers)
                return items.compactMap { Self.event(from: $0, calendarID: calendarID) }
            } catch PMailError.notFound {
                return []  // A calendar that's been removed.
            }
        }
        let events = await withSeriesRecurrence(results.flatMap { $0 })
        remember(events)
        // Meetings declined from PMail, which Outlook took off the calendar.
        let kept = await declined.shown(besides: events, in: Set(calendarIDs), from: start, to: end)
        return (events + kept).sorted { $0.start < $1.start }
    }

    /// Fills in how repeating events repeat, from their series masters, fetching each master once.
    private func withSeriesRecurrence(_ events: [CalendarEvent]) async -> [CalendarEvent] {
        let missing = Set(events.compactMap(\.seriesID)).filter { seriesRecurrence[$0] == nil }
        if !missing.isEmpty {
            let client = self.client
            let found = (try? await WebClient.concurrentMap(Array(missing)) { id -> (String, (lines: [String], start: Date)?) in
                let url = try Self.url("events/\(WebURL.segment(id))", [("$select", "recurrence,start,isAllDay")])
                let master = try? await client.get(url, headers: Self.headers)
                return (id, master.flatMap { master in
                    let isAllDay = master["isAllDay"].bool ?? false
                    guard let start = Self.time(master["start"], allDay: isAllDay) else { return nil }
                    return (Self.recurrenceLines(from: master["recurrence"], start: start, isAllDay: isAllDay), start)
                })
            }) ?? []
            for (id, series) in found {
                guard let series else { continue }
                seriesRecurrence[id] = series.lines
                seriesStarts[id] = series.start
            }
        }
        return events.map { event in
            guard event.recurrence.isEmpty, let seriesID = event.seriesID, let lines = seriesRecurrence[seriesID] else { return event }
            var filled = event
            filled.recurrence = lines
            return filled
        }
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
        let notesHTML = json["body"]["contentType"].string?.lowercased() == "html"
            ? json["body"]["content"].string.flatMap(EventDescription.simplified) : nil
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
                             type: json["showAs"].string == "oof" ? .outOfOffice : .event,
                             visibility: ["private", "confidential"].contains(json["sensitivity"].string ?? "") ? .private : .default,
                             guestsCanSeeOtherGuests: json["hideAttendees"].bool != true, notesHTML: notesHTML)
    }

    // MARK: Repeating

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let ordinalNames = ["first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1]

    /// RRULE lines for Graph's description of how a series repeats (its `recurrence`); none for a missing one.
    static func recurrenceLines(from json: JSONValue, start: Date, isAllDay: Bool) -> [String] {
        let pattern = json["pattern"]
        guard let type = pattern["type"].string else { return [] }
        let interval = max(1, pattern["interval"].int ?? 1)
        let days = pattern["daysOfWeek"].strings.compactMap { weekdayNames.firstIndex(of: $0.lowercased()) }
        let codes = days.map { RepeatRule.weekdayCodes[$0] }
        let ordinal = ordinalNames[pattern["index"].string ?? "first"] ?? 1
        var parts: [String]
        switch type {
        case "daily": parts = ["FREQ=DAILY"]
        case "weekly": parts = ["FREQ=WEEKLY", "BYDAY=" + codes.joined(separator: ",")]
        case "absoluteMonthly": parts = ["FREQ=MONTHLY", "BYMONTHDAY=\(pattern["dayOfMonth"].int ?? Calendar.current.component(.day, from: start))"]
        case "relativeMonthly": parts = ["FREQ=MONTHLY", "BYDAY=" + codes.map { "\(ordinal)\($0)" }.joined(separator: ",")]
        case "absoluteYearly":
            parts = ["FREQ=YEARLY", "BYMONTH=\(pattern["month"].int ?? Calendar.current.component(.month, from: start))",
                     "BYMONTHDAY=\(pattern["dayOfMonth"].int ?? Calendar.current.component(.day, from: start))"]
        case "relativeYearly":
            parts = ["FREQ=YEARLY", "BYMONTH=\(pattern["month"].int ?? Calendar.current.component(.month, from: start))",
                     "BYDAY=" + codes.map { "\(ordinal)\($0)" }.joined(separator: ",")]
        default: return []
        }
        if interval > 1 { parts.insert("INTERVAL=\(interval)", at: 1) }
        let range = json["range"]
        switch range["type"].string {
        case "endDate":
            if let day = range["endDate"].string.flatMap({ WebDate.localMidnight($0) }) {
                parts.append("UNTIL=" + RepeatRule.untilText(day, isAllDay: isAllDay, calendar: .current))
            }
        case "numbered":
            if let count = range["numberOfOccurrences"].int, count > 0 { parts.append("COUNT=\(count)") }
        default:
            break
        }
        return ["RRULE:" + parts.joined(separator: ";")]
    }

    /// Graph's description of how a series repeats, for RRULE lines PMail can show; nil for one it can't.
    static func recurrenceJSON(_ lines: [String], start: Date, isAllDay: Bool, zone: TimeZone) -> JSONValue? {
        guard let rule = RepeatRule(lines: lines, start: start) else { return nil }
        let calendar = Calendar.current
        var pattern: [String: JSONValue] = ["interval": JSONValue(rule.interval)]
        switch rule.frequency {
        case .daily:
            pattern["type"] = "daily"
        case .weekly:
            let days = rule.weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : rule.weekdays.sorted()
            pattern["type"] = "weekly"
            pattern["daysOfWeek"] = .array(days.map { .string(weekdayNames[$0 - 1]) })
            pattern["firstDayOfWeek"] = "sunday"
        case .monthly:
            if let weekdayOfMonth = rule.weekdayOfMonth {
                pattern["type"] = "relativeMonthly"
                pattern["daysOfWeek"] = [.string(weekdayNames[weekdayOfMonth.weekday - 1])]
                pattern["index"] = .string(ordinalNames.first { $0.value == weekdayOfMonth.ordinal }?.key ?? "first")
            } else {
                pattern["type"] = "absoluteMonthly"
                pattern["dayOfMonth"] = JSONValue(calendar.component(.day, from: start))
            }
        case .yearly:
            pattern["type"] = "absoluteYearly"
            pattern["dayOfMonth"] = JSONValue(calendar.component(.day, from: start))
            pattern["month"] = JSONValue(calendar.component(.month, from: start))
        }
        var range: [String: JSONValue] = ["startDate": .string(WebDate.dateTimeString(start, in: zone).prefix(10).description),
                                          "recurrenceTimeZone": .string(zone.identifier)]
        switch rule.end {
        case .never:
            range["type"] = "noEnd"
        case let .on(day):
            range["type"] = "endDate"
            range["endDate"] = .string(WebDate.dayString(day))
        case let .after(count):
            range["type"] = "numbered"
            range["numberOfOccurrences"] = JSONValue(count)
        }
        return ["pattern": .object(pattern), "range": .object(range)]
    }

    // MARK: Free and busy

    /// Busy times from Graph's schedules (work and school accounts can see each other's); for an account that can't
    /// look people up, why not for everyone.
    public func freeBusy(for addresses: [String], from start: Date, to end: Date) async throws -> [String: FreeBusy] {
        guard !addresses.isEmpty else { return [:] }
        let body: JSONValue = ["schedules": .array(addresses.map { .string($0) }),
                               "startTime": ["dateTime": .string(WebDate.utcLocalString(start)), "timeZone": "UTC"],
                               "endTime": ["dateTime": .string(WebDate.utcLocalString(end)), "timeZone": "UTC"],
                               "availabilityViewInterval": 30]
        let json: JSONValue
        do {
            json = try await client.post(Self.url("calendar/getSchedule"), body, headers: Self.headers)
        } catch let PMailError.http(status, _) where (400..<500).contains(status) && status != 401 {
            let reason = "This Microsoft account can’t look up other people’s busy times (only work and school accounts can)."
            return Dictionary(addresses.map { ($0, FreeBusy.unknown(reason)) }, uniquingKeysWith: { first, _ in first })
        }
        var found: [String: FreeBusy] = [:]
        for item in json["value"].array {
            guard let id = item["scheduleId"].string?.lowercased() else { continue }
            if let message = item["error"]["message"].nonEmpty {
                found[id] = .unknown(message)
                continue
            }
            let busy = item["scheduleItems"].array.compactMap { entry -> DateInterval? in
                guard ["busy", "tentative", "oof"].contains(entry["status"].string ?? "busy"),
                      let from = Self.time(entry["start"], allDay: false), let to = Self.time(entry["end"], allDay: false), to > from else { return nil }
                return DateInterval(start: from, end: to)
            }
            found[id] = FreeBusy(busy: busy.sorted { $0.start < $1.start })
        }
        return Dictionary(addresses.map { ($0, found[$0.lowercased()] ?? .unknown("Their busy times couldn’t be found.")) },
                          uniquingKeysWith: { first, _ in first })
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
                             addingConference: addingConference, seriesStart: event.seriesID.flatMap { seriesStarts[$0] })
        if addingConference {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = "teamsForBusiness"
        }
        guard !body.isEmpty else { return event }
        if body["recurrence"] != nil, let seriesID = event.seriesID {
            seriesRecurrence[seriesID] = nil  // Read again with the next load.
        }
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

    /// Deletes an event. A meeting you organized is called off instead, which deletes it and sends everyone invited a
    /// cancellation.
    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        let targetID = scope == .allEvents ? (event.seriesID ?? event.id) : event.id
        if await declined.contains(id: event.id) {
            // Declined, and already off the calendar.
            await declined.forget(id: event.id)
            loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = nil
            return
        }
        let organizesMeeting = event.myResponse == nil && event.attendees.contains { !$0.isOrganizer }
        do {
            if organizesMeeting {
                _ = try await client.post(Self.eventURL(targetID, "cancel"), ["comment": ""], headers: Self.headers)
            } else {
                try await client.delete(Self.eventURL(targetID), headers: Self.headers)
            }
        } catch PMailError.notFound {
            // Already gone.
        }
        loaded[EventKey(calendarID: event.calendarID, eventID: event.id)] = nil
    }

    /// Answers an invitation and sends the answer to the organizer. A declined meeting is kept on this Mac, since
    /// Outlook takes it off the calendar; once it's gone from there, the answer can't be changed.
    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        let action: String
        switch response {
        case .accepted: action = "accept"
        case .tentative: action = "tentativelyAccept"
        case .declined: action = "decline"
        case .needsAction: throw PMailError.notSupported("An answered invitation can’t be set back to unanswered.")
        }
        let wasDeclined = await declined.contains(id: event.id)
        do {
            _ = try await client.post(Self.eventURL(event.id, action), ["sendResponse": true], headers: Self.headers)
        } catch PMailError.notFound where wasDeclined {
            throw PMailError.notSupported("Outlook took this meeting off your calendar when you declined it, so the answer can’t be "
                + "changed. The organizer can send you the invitation again.")
        }
        if response == .declined {
            await declined.keep(event)
        } else if wasDeclined {
            await declined.forget(id: event.id)
        }
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
                     addingConference: Bool, seriesStart: Date? = nil) -> [String: JSONValue] {
        let edited = WebEvents.withPastedLink(event, original: original, addingConference: addingConference)
        func changed<Value: Equatable>(_ field: KeyPath<CalendarEvent, Value>) -> Bool {
            original.map { $0[keyPath: field] != edited[keyPath: field] } ?? true
        }
        var body: [String: JSONValue] = [:]
        if changed(\.title), !(isNew && edited.title.isEmpty) { body["subject"] = .string(edited.title) }
        if changed(\.location), !(isNew && edited.location == nil) {
            body["location"] = ["displayName": .string(edited.location ?? "")]
        }
        if changed(\.notes) || changed(\.notesHTML), !(isNew && edited.notes == nil) {
            body["body"] = edited.notesHTML.map { ["contentType": "html", "content": .string($0)] }
                ?? ["contentType": "text", "content": .string(edited.notes ?? "")]
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
            } else if !edited.recurrence.isEmpty {
                // A repeating event keeps its time of day where the Mac is, across daylight saving changes.
                let zone = TimeZone.current
                body["start"] = ["dateTime": .string(WebDate.dateTimeString(edited.start, in: zone)), "timeZone": .string(zone.identifier)]
                body["end"] = ["dateTime": .string(WebDate.dateTimeString(max(edited.end, edited.start), in: zone)),
                               "timeZone": .string(zone.identifier)]
            } else {
                body["start"] = ["dateTime": .string(WebDate.utcLocalString(edited.start)), "timeZone": "UTC"]
                body["end"] = ["dateTime": .string(WebDate.utcLocalString(max(edited.end, edited.start))), "timeZone": "UTC"]
            }
        }
        // How it repeats: Graph's own description of the rule; no rule stops it repeating.
        if changed(\.recurrence) {
            if let recurrence = recurrenceJSON(edited.recurrence, start: seriesStart ?? edited.start, isAllDay: edited.isAllDay, zone: .current) {
                body["recurrence"] = recurrence
                if body["start"] == nil, includeTimes || isNew {
                    let zone = TimeZone.current
                    body["start"] = ["dateTime": .string(WebDate.dateTimeString(edited.start, in: zone)), "timeZone": .string(zone.identifier)]
                    body["end"] = ["dateTime": .string(WebDate.dateTimeString(max(edited.end, edited.start), in: zone)),
                                   "timeZone": .string(zone.identifier)]
                }
            } else if edited.recurrence.isEmpty, original?.recurrence.isEmpty == false {
                body["recurrence"] = .null
            }
        }
        if changed(\.visibility), !(isNew && edited.visibility == .default) {
            body["sensitivity"] = edited.visibility == .private ? "private" : "normal"
        }
        if changed(\.guestsCanSeeOtherGuests), !(isNew && edited.guestsCanSeeOtherGuests) {
            body["hideAttendees"] = .bool(!edited.guestsCanSeeOtherGuests)
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
