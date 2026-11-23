import Foundation

/// An account's calendars on a CalDAV server (RFC 4791), such as iCloud's. It finds the calendars, reads events with
/// their repeats expanded, and saves changes back without losing anything other programs stored in them.
///
/// Calendar IDs are the calendars' URL paths, and each event's `resourceHref` is the path of the resource it lives
/// in. CalDAV calendars have no video meetings of their own, so `addingConference` is ignored; a meeting link already
/// on an event (a pasted FaceTime link) is saved with it.
public actor CalDAVCalendarService: CalendarService {
    private struct Collection: Sendable {
        var url: URL
        var info: CalendarInfo
    }

    private struct Resource: Sendable {
        var etag: String?
        var text: String
    }

    private struct FetchedResource: Sendable {
        var path: String
        var etag: String?
        var text: String
    }

    private let serverURL: URL
    private let ownerEmail: String
    private let client: WebDAVClient
    private let localTimeZone: TimeZone
    private var homeURL: URL?
    private var collections: [String: Collection] = [:]
    /// The calendar data last seen for each resource, by path, so a change can keep what PMail doesn't understand
    /// without downloading the resource again.
    private var resources: [String: Resource] = [:]

    public init(serverURL: URL, credential: Credential, ownerEmail: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(serverURL: serverURL, credential: credential, ownerEmail: ownerEmail, transport: transport, timeZone: .current)
    }

    /// The same, reading all-day and floating times in a given time zone instead of the Mac's.
    init(serverURL: URL, credential: Credential, ownerEmail: String, transport: any HTTPTransport, timeZone: TimeZone) {
        self.serverURL = serverURL
        self.ownerEmail = ownerEmail
        client = WebDAVClient(credential: credential, transport: transport)
        localTimeZone = timeZone
    }

    // MARK: Calendars

    public func loadCalendars() async throws -> [CalendarInfo] {
        let home = try await calendarHome()
        let answer = try await client.propfind(home, depth: 1, properties: [
            .resourceType, .displayName, .supportedCalendarComponentSet, .calendarColor, .calendarOrder, .currentUserPrivilegeSet,
        ])
        var found: [(collection: Collection, order: Int?)] = []
        for response in answer.responses where response.isAvailable {
            guard let types = response.property(.resourceType), types.child(DAVNamespace.calDAV, "calendar") != nil else { continue }
            if let set = response.property(.supportedCalendarComponentSet) {
                // Reminders lists and other calendars without events aren't shown.
                let components = set.children(DAVNamespace.calDAV, "comp").compactMap { $0.attributes["name"]?.uppercased() }
                if !components.isEmpty && !components.contains("VEVENT") { continue }
            }
            guard let url = answer.url(for: response.href) else { continue }
            let displayName = response.property(.displayName)?.trimmedText ?? ""
            let name = displayName.isEmpty ? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : displayName
            let isSubscribed = types.child(DAVNamespace.calendarServer, "subscribed") != nil
            let isShared = types.child(DAVNamespace.calendarServer, "shared") != nil
            var info = CalendarInfo(id: url.path(percentEncoded: true), name: name,
                                    isReadOnly: isSubscribed || !Self.canWrite(response.property(.currentUserPrivilegeSet)),
                                    isOther: isSubscribed || isShared)
            if let color = response.property(.calendarColor).flatMap({ ICalendarColor.normalizedHex($0.trimmedText) }) {
                info.colorHex = color
            }
            found.append((Collection(url: url, info: info), response.property(.calendarOrder).flatMap { Int($0.trimmedText) }))
        }
        var ordered = found.enumerated().sorted { ($0.element.order ?? Int.max, $0.offset) < ($1.element.order ?? Int.max, $1.offset) }
            .map(\.element.collection)
        // New events go to the person's own first writable calendar (the lowest calendar-order).
        if let primary = ordered.firstIndex(where: { !$0.info.isReadOnly && !$0.info.isOther }) { ordered[primary].info.isPrimary = true }
        collections = Dictionary(ordered.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.map(\.info)
    }

    /// Whether a current-user-privilege-set lets the person change events. No set at all means the server doesn't
    /// say, so the calendar is taken to be writable.
    private static func canWrite(_ privileges: DAVElement?) -> Bool {
        guard let privileges else { return true }
        let names = privileges.children(DAVNamespace.dav, "privilege").flatMap(\.children).map(\.name)
        return names.contains { $0 == "write" || $0 == "write-content" || $0 == "all" }
    }

    private func calendarHome() async throws -> URL {
        if let homeURL { return homeURL }
        let home = try await DAVDiscovery.home(client: client, serverURL: serverURL, wellKnown: "caldav", homeSet: .calendarHomeSet)
        homeURL = home
        return home
    }

    private func collection(_ id: String) async throws -> Collection {
        if collections[id] == nil { _ = try await loadCalendars() }
        guard let collection = collections[id] else { throw PMailError.notFound }
        return collection
    }

    private func writableCollection(_ id: String) async throws -> Collection {
        let collection = try await collection(id)
        guard !collection.info.isReadOnly else { throw PMailError.notSupported("This calendar can’t be changed.") }
        return collection
    }

    // MARK: Events

    public func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard start < end, !calendarIDs.isEmpty else { return [] }
        if calendarIDs.contains(where: { collections[$0] == nil }) { _ = try await loadCalendars() }
        var seen = Set<String>()
        let targets = calendarIDs.compactMap { id in seen.insert(id).inserted ? collections[id] : nil }
        let client = self.client
        let query = DAVRequestBody.calendarQuery(from: start, to: end)
        var fetched: [(collection: Collection, resources: [FetchedResource])] = []
        var failures: [PMailError] = []
        await withTaskGroup(of: (Collection, Result<[FetchedResource], PMailError>).self) { group in
            for target in targets {
                group.addTask {
                    do {
                        return (target, .success(try await Self.fetchEvents(client: client, calendar: target.url, query: query)))
                    } catch let error as PMailError {
                        return (target, .failure(error))
                    } catch {
                        return (target, .failure(.connectionFailed(error.localizedDescription)))
                    }
                }
            }
            for await (target, result) in group {
                switch result {
                case let .success(resources): fetched.append((target, resources))
                case let .failure(error): failures.append(error)
                }
            }
        }
        // One calendar failing (a shared calendar taken away) doesn't hide the others, unless the sign-in failed.
        if let refused = failures.first(where: \.needsSignIn) { throw refused }
        if fetched.isEmpty, let failure = failures.first { throw failure }
        var events: [CalendarEvent] = []
        for (collection, items) in fetched {
            for item in items {
                resources[item.path] = Resource(etag: item.etag, text: item.text)
                for calendar in ICalendarComponent.parse(item.text) where calendar.name == "VCALENDAR" {
                    let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
                    events += reader.events(calendarID: collection.info.id, href: item.path, etag: item.etag, from: start, to: end)
                }
            }
        }
        return events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Every resource in a calendar with an event in the query's window, with its data.
    private static func fetchEvents(client: WebDAVClient, calendar: URL, query: Data) async throws -> [FetchedResource] {
        let answer = try await client.report(calendar, depth: 1, body: query)
        let calendarPath = calendar.path(percentEncoded: true)
        var resources: [FetchedResource] = []
        var missing: [String] = []
        for response in answer.responses where response.isAvailable {
            guard let url = answer.url(for: response.href), url.path(percentEncoded: true) != calendarPath else { continue }
            if let data = response.property(.calendarData)?.text, data.contains("BEGIN:") {
                let etag = response.property(.getETag)?.trimmedText
                resources.append(FetchedResource(path: url.path(percentEncoded: true), etag: etag, text: data))
            } else {
                missing.append(response.href)
            }
        }
        // Servers that leave the data out of query answers are asked for it by name, a hundred at a time.
        var index = 0
        while index < missing.count {
            let batch = Array(missing[index..<min(index + 100, missing.count)])
            index += 100
            let answer = try await client.report(calendar, depth: 1, body: DAVRequestBody.calendarMultiget(batch))
            for response in answer.responses where response.isAvailable {
                guard let url = answer.url(for: response.href), let data = response.property(.calendarData)?.text,
                      data.contains("BEGIN:") else { continue }
                let etag = response.property(.getETag)?.trimmedText
                resources.append(FetchedResource(path: url.path(percentEncoded: true), etag: etag, text: data))
            }
        }
        return resources
    }

    public func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        let collection = try await writableCollection(event.calendarID)
        let uid = event.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let url = collection.url.appendingPathComponent(DAVResourceName.name(for: uid, fileExtension: "ics"))
        var saved = event
        saved.uid = uid
        let calendar = writer().newCalendar(for: saved, uid: uid)
        let etag = try await save(calendar, to: url, ifMatch: nil, isNew: true)
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        return reader.firstEvent(calendarID: collection.info.id, href: url.path(percentEncoded: true), etag: etag) ?? saved
    }

    /// Saves changes to an event. Giving a whole event another `calendarID` moves it there (it's saved in the new
    /// calendar, then removed from the old one); a single occurrence can't leave its series, so it stays put.
    public func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        let target = try await writableCollection(event.calendarID)
        let source = sourceCollection(of: event) ?? target
        guard !source.info.isReadOnly else { throw PMailError.notSupported("This calendar can’t be changed.") }
        let url = try resourceURL(of: event, in: source)
        var (calendar, current) = try await editableCalendar(at: url, expectedETag: event.etag, fresh: false)
        let moving = source.info.id != target.info.id && (scope == .allEvents || !event.isRecurring)
        let key = try writer().update(&calendar, with: event, scope: moving ? .allEvents : scope)
        let savedURL = moving ? target.url.appendingPathComponent(url.lastPathComponent) : url
        let etag: String?
        if moving {
            etag = try await save(calendar, to: savedURL, ifMatch: nil, isNew: true)
            do {
                try await client.delete(url, ifMatch: event.etag ?? current.etag)
                resources[url.path(percentEncoded: true)] = nil
            } catch {
                // Don't leave the event in both calendars.
                try? await client.delete(savedURL, ifMatch: etag)
                resources[savedURL.path(percentEncoded: true)] = nil
                throw error
            }
        } else {
            etag = try await save(calendar, to: url, ifMatch: event.etag ?? current.etag)
        }
        let calendarID = moving ? target.info.id : source.info.id
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        if let series = reader.series(for: event) ?? reader.series.first,
           let saved = reader.event(in: series, key: key, calendarID: calendarID, href: savedURL.path(percentEncoded: true), etag: etag) {
            return saved
        }
        var saved = event
        saved.calendarID = calendarID
        saved.etag = etag
        return saved
    }

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        let collection = try await writableCollection(event.calendarID)
        let url = try resourceURL(of: event, in: collection)
        if scope == .allEvents || !event.isRecurring {
            try await client.delete(url, ifMatch: event.etag)
            resources[url.path(percentEncoded: true)] = nil
            return
        }
        var (calendar, current) = try await editableCalendar(at: url, expectedETag: event.etag, fresh: false)
        if try writer().deleteOccurrence(of: event, from: &calendar) {
            try await client.delete(url, ifMatch: event.etag ?? current.etag)
            resources[url.path(percentEncoded: true)] = nil
        } else {
            _ = try await save(calendar, to: url, ifMatch: event.etag ?? current.etag)
        }
    }

    /// Answers an invitation for the whole series. The answer is made on the newest version on the server, since
    /// only the owner's own reply changes.
    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        let collection = try await collection(event.calendarID)
        let url = try resourceURL(of: event, in: collection)
        var (calendar, current) = try await editableCalendar(at: url, expectedETag: nil, fresh: true)
        try writer().respond(response, to: event, in: &calendar)
        _ = try await save(calendar, to: url, ifMatch: current.etag)
    }

    // MARK: Settings

    /// The account's own calendars keep their name, description and color on the server.
    public nonisolated func settingsSupport(for calendar: CalendarInfo) -> CalendarSettingsSupport {
        let owns = !calendar.isReadOnly && !calendar.isOther
        return CalendarSettingsSupport(name: owns, description: owns, color: owns)
    }

    public func loadSettings(for calendar: CalendarInfo) async throws -> CalendarSettings {
        let collection = try await collection(calendar.id)
        let answer = try await client.propfind(collection.url, depth: 0, properties: [.displayName, .calendarDescription, .calendarColor])
        let found = answer.responses.first { $0.href == calendar.id } ?? answer.responses.first
        let name = found?.property(.displayName)?.trimmedText ?? ""
        return CalendarSettings(name: name.isEmpty ? calendar.name : name,
                                description: found?.property(.calendarDescription)?.text ?? "",
                                colorHex: found?.property(.calendarColor).flatMap { ICalendarColor.normalizedHex($0.trimmedText) } ?? calendar.colorHex,
                                owner: calendar.isOther ? nil : "You")
    }

    public func saveSettings(_ settings: CalendarSettings, for calendar: CalendarInfo) async throws {
        guard settingsSupport(for: calendar).name else { return }
        let collection = try await writableCollection(calendar.id)
        try await client.proppatch(collection.url, [(.displayName, settings.name), (.calendarDescription, settings.description),
                                                    (.calendarColor, settings.colorHex.uppercased() + "FF")])
        collections[calendar.id]?.info.name = settings.name
        collections[calendar.id]?.info.colorHex = settings.colorHex
    }

    // MARK: Invitations by email

    /// The server may not take in invitations that come by email (iCloud doesn't, unless it's set to), so PMail does.
    public nonisolated var takesInEmailedInvitations: Bool { true }

    /// The owner's answer to an invitation PMail took in from an email, which PMail emails to the organizer. Nil for
    /// everything else: the server sends its own invitations, cancellations and answers.
    public func invitationText(for event: CalendarEvent, method: Invitation.Method, attendees: [MailAddress]?) async throws -> String? {
        guard method == .reply else { return nil }
        let url = try resourceURL(of: event, in: try await collection(event.calendarID))
        let (calendar, _) = try await editableCalendar(at: url, expectedETag: nil, fresh: true)
        guard InvitationText.isAnsweredByEmail(calendar) else { return nil }
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        let answer = reader.firstEvent(calendarID: event.calendarID, href: nil, etag: nil)?.myResponse ?? event.myResponse
        return InvitationText.reply(to: calendar.serialized, from: MailAddress(email: ownerEmail), response: answer ?? .needsAction)
    }

    /// Takes in an invitation that came by email, when the owner is one of its guests. A new one goes on the main
    /// calendar, waiting for an answer, marked as answered by email (so the server doesn't answer too). A newer
    /// version updates the calendar's copy, whoever put it there (PMail, the server, another app), its time moving
    /// asking again; a cancellation marks it canceled.
    public func receive(_ invitation: Invitation) async throws {
        guard invitation.method == .request || invitation.method == .cancel,
              !(invitation.organizer.map { ICalendarEventProperties.isSameMailbox($0.email, ownerEmail) } ?? false),
              var incoming = InvitationText.vcalendar(invitation.text) else { return }
        let found = try await resource(withUID: invitation.uid)
        switch invitation.method {
        case .request:
            guard InvitationText.hasGuest(ownerEmail, in: incoming) else { return }
            incoming.removeProperties("METHOD")
            InvitationText.noteVersion(&incoming)
            guard let found else {
                InvitationText.markAnsweredByEmail(&incoming)
                if collections.isEmpty { _ = try await loadCalendars() }
                guard let main = collections.values.first(where: { $0.info.isPrimary }) else {
                    throw PMailError.notSupported("This account has no calendar to add the invitation to.")
                }
                let url = main.url.appendingPathComponent(DAVResourceName.name(for: invitation.uid, fileExtension: "ics"))
                _ = try await save(incoming, to: url, ifMatch: nil, isNew: true)
                return
            }
            guard InvitationText.isNewer(incoming, than: found.calendar) else { return }
            let reader = ICalendarReader(calendar: found.calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
            InvitationText.carryAnswer(of: ownerEmail, from: found.calendar, into: &incoming,
                                       answer: reader.firstEvent(calendarID: "", href: nil, etag: nil)?.myResponse)
            try await update(found, to: incoming)
        case .cancel:
            guard var calendar = found?.calendar, let found,
                  InvitationText.sequence(of: incoming) >= InvitationText.sequence(of: calendar) else { return }
            InvitationText.markCanceled(&calendar, by: incoming)
            try await update(found, to: calendar)
        default:
            return
        }
    }

    /// Saves a newer version of an emailed invitation over the calendar's copy. PMail's own copy stays answered by
    /// email. A copy the server or another app put there keeps the server answering for it, and is changed without the
    /// server sending anything for the owner (Schedule-Reply: F); if the server won't take the change, PMail's own copy
    /// replaces it.
    private func update(_ found: (url: URL, etag: String?, calendar: ICalendarComponent), to calendar: ICalendarComponent) async throws {
        var newer = calendar
        if InvitationText.isAnsweredByEmail(found.calendar) {
            InvitationText.markAnsweredByEmail(&newer)
            _ = try await save(newer, to: found.url, ifMatch: found.etag)
            return
        }
        do {
            _ = try await save(newer, to: found.url, ifMatch: found.etag, scheduleReply: false)
        } catch let PMailError.http(status, _) where status == 403 || status == 409 {
            try await client.delete(found.url, ifMatch: found.etag, extraHeaders: ["Schedule-Reply": "F"])
            resources[found.url.path(percentEncoded: true)] = nil
            InvitationText.markAnsweredByEmail(&newer)
            let uid = InvitationText.mainEvent(of: newer)?.property("UID")?.value ?? UUID().uuidString
            let url = found.url.deletingLastPathComponent().appendingPathComponent(DAVResourceName.name(for: uid, fileExtension: "ics"))
            _ = try await save(newer, to: url, ifMatch: nil, isNew: true)
        }
    }

    /// The resource holding the event with an iCalendar UID, in any of the account's calendars it can change.
    private func resource(withUID uid: String) async throws -> (url: URL, etag: String?, calendar: ICalendarComponent)? {
        if collections.isEmpty { _ = try await loadCalendars() }
        let query = DAVRequestBody.calendarQuery(uid: uid)
        for collection in collections.values where !collection.info.isReadOnly {
            let fetched = (try? await Self.fetchEvents(client: client, calendar: collection.url, query: query)) ?? []
            for resource in fetched {
                guard let calendar = ICalendarComponent.parse(resource.text).first(where: { $0.name == "VCALENDAR" }),
                      calendar.components.contains(where: { $0.name == "VEVENT" && $0.property("UID")?.value == uid }),
                      let url = URL(string: resource.path, relativeTo: collection.url)?.absoluteURL else { continue }
                resources[url.path(percentEncoded: true)] = Resource(etag: resource.etag, text: resource.text)
                return (url, resource.etag, calendar)
            }
        }
        return nil
    }

    // MARK: Resources

    private func writer() -> ICalendarWriter {
        ICalendarWriter(ownerEmail: ownerEmail, localTimeZone: localTimeZone)
    }

    /// The calendar an event's resource is in now, by its path.
    private func sourceCollection(of event: CalendarEvent) -> Collection? {
        guard let href = event.resourceHref else { return nil }
        let path = URL(string: href)?.path(percentEncoded: true) ?? href
        return collections.values.filter { path.hasPrefix($0.info.id) }.max { $0.info.id.count < $1.info.id.count }
    }

    private func resourceURL(of event: CalendarEvent, in collection: Collection) throws -> URL {
        guard let href = event.resourceHref, !href.isEmpty, let url = URL(string: href, relativeTo: collection.url)?.absoluteURL else {
            throw PMailError.notFound
        }
        return url
    }

    /// A resource's calendar as it is on the server: from what was last read when it's still that version, else
    /// downloaded.
    private func editableCalendar(at url: URL, expectedETag: String?, fresh: Bool) async throws -> (ICalendarComponent, Resource) {
        let path = url.path(percentEncoded: true)
        let resource: Resource
        if !fresh, let cached = resources[path], cached.etag != nil, cached.etag == expectedETag {
            resource = cached
        } else {
            let (data, etag) = try await client.get(url)
            resource = Resource(etag: etag, text: String(decoding: data, as: UTF8.self))
            resources[path] = resource
        }
        guard let calendar = ICalendarComponent.parse(resource.text).first(where: { $0.name == "VCALENDAR" }) else {
            throw PMailError.protocolError("the event on the server couldn’t be read")
        }
        return (calendar, resource)
    }

    /// Saves a calendar resource and returns its new ETag (asking for it when the server doesn't send it back). Without
    /// `scheduleReply`, the server is asked not to send the owner's answer for the change (RFC 6638's Schedule-Reply).
    private func save(_ calendar: ICalendarComponent, to url: URL, ifMatch: String?, isNew: Bool = false,
                      scheduleReply: Bool = true) async throws -> String? {
        let text = calendar.serialized
        var etag = try await client.put(url, data: Data(text.utf8), contentType: "text/calendar; charset=utf-8", ifMatch: ifMatch,
                                        ifNoneMatch: isNew, extraHeaders: scheduleReply ? [:] : ["Schedule-Reply": "F"])
        if etag == nil { etag = (try? await client.etag(of: url)) ?? nil }
        resources[url.path(percentEncoded: true)] = Resource(etag: etag, text: text)
        return etag
    }
}
