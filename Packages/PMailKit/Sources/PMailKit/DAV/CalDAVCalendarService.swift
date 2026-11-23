import Foundation
import os

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
    /// The signed-in person's principal, where the server names one.
    private var principalURL: URL?
    /// Who the owner is to the server, once asked (for a server that sends its own invitations).
    private var identity: OwnerIdentity?
    private var collections: [String: Collection] = [:]
    /// The calendar data last seen for each resource, by path, so a change can keep what PMail doesn't understand
    /// without downloading the resource again.
    private var resources: [String: Resource] = [:]
    /// Where each event's resource is, by iCalendar UID, as last loaded or saved: the surest way to find an emailed
    /// invitation's copy again, since not every server answers a query by UID.
    private var pathsByUID: [String: String] = [:]

    /// The transport must hand redirects back (WebDAV follows them itself, keeping the sign-in). `iCloud` is for
    /// iCloud's calendar server (see `isICloud`).
    public init(serverURL: URL, credential: Credential, ownerEmail: String, transport: any HTTPTransport = URLSessionTransport(followsRedirects: false),
                iCloud: Bool = false) {
        self.init(serverURL: serverURL, credential: credential, ownerEmail: ownerEmail, transport: transport, timeZone: .current, iCloud: iCloud)
    }

    /// The same, reading all-day and floating times in a given time zone instead of the Mac's.
    init(serverURL: URL, credential: Credential, ownerEmail: String, transport: any HTTPTransport, timeZone: TimeZone, iCloud: Bool = false) {
        self.serverURL = serverURL
        self.ownerEmail = ownerEmail
        client = WebDAVClient(credential: credential, transport: transport)
        localTimeZone = timeZone
        isICloud = iCloud
    }

    /// iCloud's calendar server, which names the owner by their Apple Account (its principal and email) and knows their
    /// other addresses as them. It sends a meeting's invitations, changes and cancellations as the Apple Account's email,
    /// and is left to when that's an iCloud address. Mail sent from iCloud as another provider's address is turned away
    /// or put in junk, so for an Apple Account with an email elsewhere, PMail emails the invitations itself, from the
    /// account's address, and takes in the guests' answers.
    public nonisolated let isICloud: Bool

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
        let found = try await DAVDiscovery.locate(client: client, serverURL: serverURL, wellKnown: "caldav", homeSet: .calendarHomeSet)
        homeURL = found.home
        principalURL = found.principal
        return found.home
    }

    // MARK: Who the owner is to the server

    /// The ways a server names the account's owner on events: their principal (and other such names), and their
    /// addresses other than the account's (iCloud names a meeting's organizer by the Apple Account's email); and the
    /// address it sends their invitations as.
    struct OwnerIdentity: Sendable, Equatable {
        var principalPath: String?
        /// Principal paths and other non-address names, lowercased.
        var names: Set<String> = []
        /// The owner's other addresses, lowercased.
        var otherAddresses: Set<String> = []
        /// The address the server sends the owner's invitations as (iCloud: the Apple Account's email), the one its
        /// address set marks preferred, else its first. Nil when it names none.
        var sendsAs: String?

        /// Whether the server is left to send the owner's invitations: it sends them as an iCloud address (icloud.com,
        /// me.com or mac.com). Not when it doesn't say which address it sends as.
        var invitesItself: Bool { sendsAs.map(Self.isICloudAddress) ?? false }

        static func isICloudAddress(_ email: String) -> Bool {
            guard let at = email.lastIndex(of: "@") else { return false }
            return ["icloud.com", "me.com", "mac.com"].contains(email[email.index(after: at)...].lowercased())
        }
    }

    /// Who the owner is to the server, from their principal's calendar-user-address-set: asked once it answers.
    private func ownerIdentity() async -> OwnerIdentity {
        if let identity { return identity }
        _ = try? await calendarHome()
        let principalPath = principalURL?.path(percentEncoded: true)
        var found = OwnerIdentity(principalPath: principalPath)
        if let principalPath { found.names.insert(principalPath.lowercased()) }
        // Not answering (offline, say) is asked again next time.
        guard let principalURL, let answer = try? await client.propfind(principalURL, depth: 0, properties: [.calendarUserAddressSet]) else {
            return found
        }
        var addresses: [(email: String, preferred: Bool)] = []
        for href in answer.responses.first?.property(.calendarUserAddressSet)?.children(DAVNamespace.dav, "href") ?? [] {
            let text = href.trimmedText
            guard !text.isEmpty else { continue }
            if text.lowercased().hasPrefix("mailto:") {
                let email = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                addresses.append((email, ["1", "true"].contains(href.attributes["preferred"]?.lowercased() ?? "")))
                if !ICalendarEventProperties.isSameMailbox(email, ownerEmail) { found.otherAddresses.insert(email.lowercased()) }
            } else {
                found.names.insert((URL(string: text).flatMap { $0.host == nil ? nil : $0.path(percentEncoded: true) } ?? text).lowercased())
            }
        }
        found.sendsAs = (addresses.first(where: \.preferred) ?? addresses.first)?.email
        let domains = addresses.map { Self.domain(of: $0.email) }
        let own = addresses.contains { ICalendarEventProperties.isSameMailbox($0.email, ownerEmail) } ? "among them" : "not among them"
        let sender = found.sendsAs.map(Self.domain(of:)) ?? "none"
        Self.log.notice("The calendar knows the account by addresses at \(domains.joined(separator: ", "), privacy: .public); the account's own is \(own, privacy: .public); it sends invitations as the one at \(sender, privacy: .public), so \(found.invitesItself ? "it sends them" : "PMail emails them", privacy: .public)")
        identity = found
        return found
    }

    /// An address's domain, all the Mac's log notes of it.
    private static func domain(of email: String) -> String {
        email.split(separator: "@").last.map(String.init) ?? "?"
    }

    /// Lines naming the owner another way (their principal, or another of their addresses) name them by the account's
    /// address (EMAIL; a mailto value too), so PMail knows the owner's own meetings as theirs. The owner listed twice
    /// on one event (their other address added as a guest, say) is listed once.
    static func recognizeOwner(in calendar: inout ICalendarComponent, owner: String, identity: OwnerIdentity) {
        guard !identity.names.isEmpty || !identity.otherAddresses.isEmpty else { return }
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" {
            var ownerAttendeeSeen = false
            var kept: [ICalendarLine] = []
            for var line in calendar.components[event].properties {
                if line.name == "ORGANIZER" || line.name == "ATTENDEE" {
                    let value = line.value.trimmingCharacters(in: .whitespaces)
                    let named = identity.names.contains(value.lowercased())
                        || (URL(string: value).flatMap { $0.host == nil ? nil : $0.path(percentEncoded: true).lowercased() }.map(identity.names.contains) ?? false)
                    let email = ICalendarEventProperties.address(of: line)?.email.lowercased()
                    if named || (email.map(identity.otherAddresses.contains) ?? false) {
                        line.setParameter("EMAIL", owner)
                        if value.lowercased().hasPrefix("mailto:") { line.value = "mailto:" + owner }
                    }
                    if line.name == "ATTENDEE", ICalendarEventProperties.address(of: line).map({ ICalendarEventProperties.isSameMailbox($0.email, owner) }) ?? false {
                        if ownerAttendeeSeen { continue }
                        ownerAttendeeSeen = true
                    }
                }
                kept.append(line)
            }
            calendar.components[event].properties = kept
        }
    }

    /// Names the owner on their own meeting the way Apple's apps do, by their principal on the server with the account's
    /// address (EMAIL), when PMail emails its invitations: the server's copy then names the address they came from,
    /// rather than the Apple Account's.
    static func nameOwner(in calendar: inout ICalendarComponent, owner: String, principalPath: String?) {
        guard let principalPath else { return }
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" && organizes(calendar.components[event], owner) {
            for index in calendar.components[event].properties.indices {
                let line = calendar.components[event].properties[index]
                guard line.name == "ORGANIZER" || line.name == "ATTENDEE",
                      ICalendarEventProperties.address(of: line).map({ ICalendarEventProperties.isSameMailbox($0.email, owner) }) ?? false else { continue }
                calendar.components[event].properties[index].value = principalPath
                calendar.components[event].properties[index].setParameter("EMAIL", owner)
            }
        }
    }

    /// Lines naming the owner by their principal name them by the account's address instead (a mailto value), as an
    /// emailed invitation or answer must: the people it goes to answer that address.
    static func addressOwner(in calendar: inout ICalendarComponent, owner: String) {
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" {
            for index in calendar.components[event].properties.indices {
                let line = calendar.components[event].properties[index]
                guard line.name == "ORGANIZER" || line.name == "ATTENDEE", !line.value.lowercased().hasPrefix("mailto:"),
                      ICalendarEventProperties.address(of: line).map({ ICalendarEventProperties.isSameMailbox($0.email, owner) }) ?? false else { continue }
                calendar.components[event].properties[index].value = "mailto:" + owner
                calendar.components[event].properties[index].setParameter("EMAIL", nil)
            }
        }
    }

    /// Readies a meeting PMail changed for saving to iCloud. When iCloud sends invitations as an iCloud address, every
    /// guest of the owner's meetings is left to it (taking off PMail's mark an earlier save may have put on some).
    /// Otherwise every guest is PMail's to invite by email, so iCloud sends them nothing as the other address, and the
    /// owner is named by the account's address, which the invitations come from.
    private func readyForICloud(_ calendar: inout ICalendarComponent) async {
        let identity = await ownerIdentity()
        if identity.invitesItself {
            Self.leaveGuestsToTheServer(in: &calendar, owner: ownerEmail)
        } else {
            Self.inviteGuestsByEmail(in: &calendar, owner: ownerEmail)
            Self.nameOwner(in: &calendar, owner: ownerEmail, principalPath: identity.principalPath)
        }
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
        let identity = isICloud ? await ownerIdentity() : nil
        for (collection, items) in fetched {
            for item in items {
                resources[item.path] = Resource(etag: item.etag, text: item.text)
                for var calendar in ICalendarComponent.parse(item.text) where calendar.name == "VCALENDAR" {
                    if let identity { Self.recognizeOwner(in: &calendar, owner: ownerEmail, identity: identity) }
                    let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
                    events += reader.events(calendarID: collection.info.id, href: item.path, etag: item.etag, from: start, to: end)
                    for uid in reader.series.compactMap(\.uid) { pathsByUID[uid] = item.path }
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
        var written = writer().newCalendar(for: saved, uid: uid)
        if isICloud { await readyForICloud(&written) }
        let (calendar, etag) = await invitationsAfterSaving(written, etag: try await save(written, to: url, ifMatch: nil, isNew: true), at: url)
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        return reader.firstEvent(calendarID: collection.info.id, href: url.path(percentEncoded: true), etag: etag) ?? saved
    }

    /// After a meeting the owner organizes is saved, the guests the server sent no invitation to (it noted no
    /// SCHEDULE-STATUS for them, or one saying it failed) become PMail's to invite by email (SCHEDULE-AGENT=CLIENT),
    /// so the server leaves them to PMail from then on, and the app emails them; a server that sends them keeps doing
    /// so. iCloud's guests are settled before saving (`readyForICloud`), so this only notes how it went. The calendar
    /// and version as they end up.
    private func invitationsAfterSaving(_ written: ICalendarComponent, etag: String?, at url: URL) async -> (ICalendarComponent, String?) {
        let left = Self.guestsLeftToTheServer(in: written, owner: ownerEmail)
        if isICloud {
            let emailed = Self.guestsInvitedByEmail(in: written, owner: ownerEmail)
            if left > 0 {
                await noteHowTheServerKept(at: url)
            } else if emailed > 0 {
                Self.log.notice("Meeting saved: PMail invites \(emailed, privacy: .public) guests by email, iCloud none")
            }
            return (written, etag)
        }
        guard left > 0 else { return (written, etag) }
        for _ in 0...Self.conflictRetries {
            guard let (data, current) = try? await client.get(url),
                  var stored = ICalendarComponent.parse(String(decoding: data, as: UTF8.self)).first(where: { $0.name == "VCALENDAR" }) else {
                return (written, etag)
            }
            let (invited, takenOver) = Self.takeOverUninvitedGuests(in: &stored, owner: ownerEmail)
            guard takenOver > 0 else {
                Self.log.notice("Meeting saved: the server invited \(invited, privacy: .public) guests")
                resources[url.path(percentEncoded: true)] = Resource(etag: current, text: String(decoding: data, as: UTF8.self))
                return (stored, current)
            }
            do {
                let saved = try await save(stored, to: url, ifMatch: current)
                Self.log.notice("Meeting saved: the server invited \(invited, privacy: .public) guests, PMail invites \(takenOver, privacy: .public) by email")
                return (stored, saved)
            } catch PMailError.conflict {
                continue
            } catch {
                return (written, etag)
            }
        }
        return (written, etag)
    }

    static let log = Logger(subsystem: "com.pugglesoft.PMail", category: "DAV")

    /// Notes in the Mac's log how a server that sends its own invitations kept a meeting just saved, with nothing of
    /// its people: how it names the organizer, whether that's the account, and the delivery status it gave each guest.
    /// When a guest gets no invitation, this says whether the server ever took it on.
    private func noteHowTheServerKept(at url: URL) async {
        guard let (data, _) = try? await client.get(url),
              let stored = ICalendarComponent.parse(String(decoding: data, as: UTF8.self)).first(where: { $0.name == "VCALENDAR" }),
              let event = stored.components.first(where: { $0.name == "VEVENT" }) else { return }
        let organizer = event.property("ORGANIZER")
        let form = organizer.map { line -> String in
            let value = line.value.lowercased()
            return value.hasPrefix("mailto:") ? "an address" : value.hasPrefix("urn:") ? "an id" : value.hasPrefix("/") ? "its account path" : "something else"
        } ?? "nobody"
        let isOwner = organizer.flatMap(ICalendarEventProperties.address(of:)).map { ICalendarEventProperties.isSameMailbox($0.email, ownerEmail) }
        let whose = isOwner == true ? "the account's address" : isOwner == false ? "another address" : "no address"
        let guests = event.properties("ATTENDEE").filter { line in
            ICalendarEventProperties.address(of: line).map { !ICalendarEventProperties.isSameMailbox($0.email, ownerEmail) } ?? true
        }
        let statuses = guests.map { $0.parameter("SCHEDULE-STATUS") ?? "none" }.joined(separator: ", ")
        Self.log.notice("Meeting saved for the server to invite: organizer as \(form, privacy: .public) (\(whose, privacy: .public)), \(guests.count, privacy: .public) other guests, delivery statuses: \(statuses, privacy: .public)")
    }

    /// Hands every guest of the owner's meetings back to the server to invite (taking off SCHEDULE-AGENT=CLIENT, which
    /// an earlier PMail may have put on some).
    static func leaveGuestsToTheServer(in calendar: inout ICalendarComponent, owner: String) {
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" && organizes(calendar.components[event], owner) {
            for index in calendar.components[event].properties.indices where calendar.components[event].properties[index].name == "ATTENDEE"
                && calendar.components[event].properties[index].parameter("SCHEDULE-AGENT")?.uppercased() == "CLIENT" {
                calendar.components[event].properties[index].setParameter("SCHEDULE-AGENT", nil)
            }
        }
    }

    /// Makes every guest of the owner's meetings PMail's to invite by email (SCHEDULE-AGENT=CLIENT), whatever the server
    /// noted for them before, so the server sends them nothing.
    static func inviteGuestsByEmail(in calendar: inout ICalendarComponent, owner: String) {
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" && organizes(calendar.components[event], owner) {
            for index in calendar.components[event].properties.indices where calendar.components[event].properties[index].name == "ATTENDEE"
                && isGuest(calendar.components[event].properties[index], owner) {
                calendar.components[event].properties[index].setParameter("SCHEDULE-AGENT", "CLIENT")
                calendar.components[event].properties[index].setParameter("SCHEDULE-STATUS", nil)
            }
        }
    }

    /// How many guests of the meetings the owner organizes are left to the server to invite (not PMail's).
    static func guestsLeftToTheServer(in calendar: ICalendarComponent, owner: String) -> Int {
        calendar.components.filter { $0.name == "VEVENT" && organizes($0, owner) }.reduce(0) { count, event in
            count + event.properties("ATTENDEE").filter { isGuest($0, owner) && $0.parameter("SCHEDULE-AGENT")?.uppercased() != "CLIENT" }.count
        }
    }

    /// How many guests of the meetings the owner organizes are PMail's to invite by email.
    static func guestsInvitedByEmail(in calendar: ICalendarComponent, owner: String) -> Int {
        calendar.components.filter { $0.name == "VEVENT" && organizes($0, owner) }.reduce(0) { count, event in
            count + event.properties("ATTENDEE").filter { isGuest($0, owner) && $0.parameter("SCHEDULE-AGENT")?.uppercased() == "CLIENT" }.count
        }
    }

    /// Marks the guests the server didn't invite as PMail's to invite (SCHEDULE-AGENT=CLIENT): how many the server
    /// invited, and how many PMail takes over.
    static func takeOverUninvitedGuests(in calendar: inout ICalendarComponent, owner: String) -> (invited: Int, takenOver: Int) {
        var invited = 0
        var takenOver = 0
        for event in calendar.components.indices where calendar.components[event].name == "VEVENT" && organizes(calendar.components[event], owner) {
            for index in calendar.components[event].properties.indices {
                let line = calendar.components[event].properties[index]
                guard line.name == "ATTENDEE", isGuest(line, owner), line.parameter("SCHEDULE-AGENT")?.uppercased() != "CLIENT" else { continue }
                // 1.x: sent, delivered or on its way; 2.x: done. 3.x and 5.x: it couldn't.
                let codes = (line.parameter("SCHEDULE-STATUS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if codes.contains(where: { $0.hasPrefix("1.") || $0.hasPrefix("2.") }) {
                    invited += 1
                    continue
                }
                calendar.components[event].properties[index].setParameter("SCHEDULE-AGENT", "CLIENT")
                calendar.components[event].properties[index].setParameter("SCHEDULE-STATUS", nil)
                takenOver += 1
            }
        }
        return (invited, takenOver)
    }

    private static func organizes(_ event: ICalendarComponent, _ owner: String) -> Bool {
        event.property("ORGANIZER").flatMap(ICalendarEventProperties.address(of:)).map { ICalendarEventProperties.isSameMailbox($0.email, owner) } ?? false
    }

    private static func isGuest(_ line: ICalendarLine, _ owner: String) -> Bool {
        ICalendarEventProperties.address(of: line).map { !ICalendarEventProperties.isSameMailbox($0.email, owner) } ?? false
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
        if isICloud { await readyForICloud(&calendar) }
        let savedURL = moving ? target.url.appendingPathComponent(url.lastPathComponent) : url
        var etag: String?
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
        (calendar, etag) = await invitationsAfterSaving(calendar, etag: etag, at: savedURL)
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

    /// Answers an invitation for the whole series.
    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        try await respond(to: event, with: response, comment: nil, scope: .allEvents)
    }

    /// Answers an invitation: one time of a repeating meeting (in that time's own override) or the whole of it. The
    /// answer is made on the newest version on the server, since only the owner's own reply changes. A server that
    /// schedules sends the organizer the answer itself; for an invitation PMail took in, PMail emails it (with the
    /// message).
    public func respond(to event: CalendarEvent, with response: AttendeeResponse, comment: String?, scope: RecurrenceScope) async throws {
        let collection = try await collection(event.calendarID)
        let url = try resourceURL(of: event, in: collection)
        try await changeNewest(at: url) { calendar in
            try self.writer().respond(response, to: event, in: &calendar, scope: scope)
        }
    }

    /// How many more times an answer or an emailed invitation is tried on the newest version, when something else
    /// changed the event first (Calendar on a Mac taking in the same email, say).
    static let conflictRetries = 3

    /// Whether saving failed because something else got there first: the event changed (412), or another copy with its
    /// UID was made meanwhile (403 or 409 on making one).
    static func isConflict(_ error: any Error) -> Bool {
        if case PMailError.conflict = error { return true }
        if case let PMailError.http(status, _) = error { return status == 403 || status == 409 }
        return false
    }

    /// Makes a change on a resource as it is now on the server, and when something else changes it before the change
    /// is saved, makes it again on that.
    private func changeNewest(at url: URL, _ change: (inout ICalendarComponent) throws -> Void) async throws {
        var attempt = 0
        while true {
            var (calendar, current) = try await editableCalendar(at: url, expectedETag: nil, fresh: true)
            try change(&calendar)
            do {
                _ = try await save(calendar, to: url, ifMatch: current.etag)
                return
            } catch PMailError.conflict where attempt < Self.conflictRetries {
                attempt += 1
            }
        }
    }

    public func replyText(for event: CalendarEvent, response: AttendeeResponse, scope: RecurrenceScope) async throws -> String? {
        guard scope == .thisEvent, event.isRecurring else { return try await invitationText(for: event, method: .reply, attendees: nil) }
        let url = try resourceURL(of: event, in: try await collection(event.calendarID))
        var (calendar, _) = try await editableCalendar(at: url, expectedETag: nil, fresh: true)
        Self.addressOwner(in: &calendar, owner: ownerEmail)
        guard InvitationText.isAnsweredByEmail(calendar), let only = writer().occurrenceOnly(of: event, in: calendar) else { return nil }
        return InvitationText.reply(to: only.serialized, from: MailAddress(email: ownerEmail), response: response)
    }

    // MARK: Undo

    /// The event's resource as the server has it now: as last read, while that's still the version the event came
    /// from (a change made from it can only be to that version), else read again.
    public func snapshot(of event: CalendarEvent) async -> CalendarSnapshot? {
        guard let collection = try? await collection(event.calendarID), let url = try? resourceURL(of: event, in: collection) else { return nil }
        let path = url.path(percentEncoded: true)
        if let cached = resources[path], cached.etag != nil, cached.etag == event.etag {
            return CalendarSnapshot(event: event, location: path, data: cached.text)
        }
        guard let (data, etag) = try? await client.get(url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        resources[path] = Resource(etag: etag, text: text)
        return CalendarSnapshot(event: event, location: path, data: text)
    }

    /// Writes the event's resource back as it was, over whatever is there now (making it again, if it was deleted). A
    /// copy the change made in another calendar is deleted first.
    public func restore(_ snapshot: CalendarSnapshot, removing made: CalendarEvent?) async throws {
        let collection = try await collection(snapshot.event.calendarID)
        guard let url = URL(string: snapshot.location, relativeTo: collection.url)?.absoluteURL else { throw PMailError.notFound }
        if let made, let elsewhere = sourceCollection(of: made), let madeURL = try? resourceURL(of: made, in: elsewhere),
           madeURL.path(percentEncoded: true) != snapshot.location {
            do {
                try await client.delete(madeURL, ifMatch: nil)
            } catch PMailError.notFound {
                // Already gone.
            }
            resources[madeURL.path(percentEncoded: true)] = nil
        }
        // Written as iCalendar wants it (CRLF lines, folded), keeping everything it held.
        let stored = ICalendarComponent.parse(snapshot.data).first { $0.name == "VCALENDAR" }
        let text = stored?.serialized ?? snapshot.data
        var etag = try await client.put(url, data: Data(text.utf8), contentType: "text/calendar; charset=utf-8", ifMatch: nil,
                                        ifNoneMatch: false, extraHeaders: [:])
        if etag == nil { etag = (try? await client.etag(of: url)) ?? nil }
        resources[snapshot.location] = Resource(etag: etag, text: text)
        for uid in (stored?.components ?? []).compactMap({ $0.property("UID")?.value }) { pathsByUID[uid] = snapshot.location }
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

    /// What PMail emails about an event: the invitation or cancellation of a meeting the owner organizes, for the guests
    /// PMail invites by email (the app sends it only to those), and the owner's answer to an invitation PMail took in from
    /// an email. Nil for everything else, which the server sends.
    public func invitationText(for event: CalendarEvent, method: Invitation.Method, attendees: [MailAddress]?) async throws -> String? {
        guard method != .other else { return nil }
        let url = try resourceURL(of: event, in: try await collection(event.calendarID))
        var (calendar, _) = try await editableCalendar(at: url, expectedETag: nil, fresh: true)
        Self.addressOwner(in: &calendar, owner: ownerEmail)
        // A meeting the owner organizes: its invitation, or its cancellation. (Someone else's meeting is theirs to send.)
        switch method {
        case .request, .cancel:
            guard calendar.components.contains(where: { $0.name == "VEVENT" && Self.organizes($0, ownerEmail) }) else { return nil }
            return method == .request ? InvitationText.request(from: calendar.serialized) : InvitationText.cancel(from: calendar.serialized, for: attendees)
        default: break
        }
        guard InvitationText.isAnsweredByEmail(calendar) else { return nil }
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        let answer = reader.firstEvent(calendarID: event.calendarID, href: nil, etag: nil)?.myResponse ?? event.myResponse
        return InvitationText.reply(to: calendar.serialized, from: MailAddress(email: ownerEmail), response: answer ?? .needsAction)
    }

    /// Takes in an invitation that came by email, when the owner is one of its guests. A new one goes on the main
    /// calendar, waiting for an answer, marked as answered by email (so the server doesn't answer too). A newer
    /// version updates the calendar's copy, whoever put it there (PMail, the server, another app), its time moving
    /// asking again; a cancellation marks it canceled. Another app may be taking in the same email (Calendar on a Mac,
    /// say) and change the copy meanwhile: then PMail goes on from the copy as it is now.
    public func receive(_ invitation: Invitation) async throws {
        if invitation.method == .reply { return try await takeAnswer(invitation) }
        guard invitation.method == .request || invitation.method == .cancel,
              !(invitation.organizer.map { ICalendarEventProperties.isSameMailbox($0.email, ownerEmail) } ?? false),
              var incoming = InvitationText.vcalendar(invitation.text) else { return }
        if invitation.method == .request {
            guard InvitationText.hasGuest(ownerEmail, in: incoming) else { return }
            incoming.removeProperties("METHOD")
            InvitationText.noteVersion(&incoming)
        }
        var firstSeen: Found?
        var attempt = 0
        while true {
            let found = try await resource(withUID: invitation.uid, near: invitation.event.start)
            if attempt == 0 { firstSeen = found }
            do {
                try await take(invitation, incoming, over: found, firstSeen: firstSeen)
                return
            } catch let error where Self.isConflict(error) && attempt < Self.conflictRetries {
                attempt += 1
            }
        }
    }

    /// A calendar's copy of an event, found by its UID: where it is, its version, and the copy as PMail last read it
    /// before (when it had, since launching), which may be older.
    struct Found {
        var url: URL
        var etag: String?
        var calendar: ICalendarComponent
        var before: ICalendarComponent?
    }

    /// Takes an emailed invitation's version (or cancellation) onto the calendar's copy as found (or as a new copy).
    private func take(_ invitation: Invitation, _ incoming: ICalendarComponent, over found: Found?, firstSeen: Found?) async throws {
        switch invitation.method {
        case .request:
            guard let found else {
                var copy = incoming
                InvitationText.markAnsweredByEmail(&copy)
                if collections.isEmpty { _ = try await loadCalendars() }
                guard let main = collections.values.first(where: { $0.info.isPrimary }) else {
                    throw PMailError.notSupported("This account has no calendar to add the invitation to.")
                }
                let url = main.url.appendingPathComponent(DAVResourceName.name(for: invitation.uid, fileExtension: "ics"))
                _ = try await save(copy, to: url, ifMatch: nil, isNew: true)
                pathsByUID[invitation.uid] = url.path(percentEncoded: true)
                return
            }
            if InvitationText.isNewer(incoming, than: found.calendar) {
                var newer = incoming
                InvitationText.carryAnswer(of: ownerEmail, from: found.calendar, into: &newer, answer: answer(in: found.calendar))
                try await update(found, to: newer)
                return
            }
            // Already this version, something else having taken it in: an answer given for a time the event no longer
            // has waits again, as if PMail had taken the change in itself. PMail's note of the time says so; failing
            // that, an earlier copy PMail saw (before something else saved first, or when it last read the calendar)
            // with the old time and the same answer.
            var calendar = found.calendar
            var outlived = writer().resetAnswersOutlivedByTheirTime(in: &calendar)
            let earlier = [firstSeen.flatMap { $0.etag != found.etag ? $0.calendar : nil }, found.before].compactMap { $0 }
            if !outlived, let now = answer(in: found.calendar), now != .needsAction,
               earlier.contains(where: { InvitationText.timesDiffer($0, found.calendar) && answer(in: $0) == now }) {
                outlived = InvitationText.resetAnswer(of: ownerEmail, in: &calendar)
            }
            if outlived { try await update(found, to: calendar) }
        case .cancel:
            guard var calendar = found?.calendar, let found,
                  InvitationText.sequence(of: incoming) >= InvitationText.sequence(of: calendar) else { return }
            InvitationText.markCanceled(&calendar, by: incoming)
            try await update(found, to: calendar)
        default:
            return
        }
    }

    /// A guest's answer to a meeting the owner organizes, by email: shown on their line, for a guest PMail invites by
    /// email (the server takes in the others' answers itself).
    private func takeAnswer(_ reply: Invitation) async throws {
        guard let guest = reply.replier else { return }
        var attempt = 0
        while true {
            guard let found = try await resource(withUID: reply.uid, near: reply.event.start) else { return }
            var calendar = found.calendar
            // Whose meeting it is goes by the owner however iCloud names them; only the guest's line changes.
            var known = calendar
            if isICloud { Self.recognizeOwner(in: &known, owner: ownerEmail, identity: await ownerIdentity()) }
            let theirs = known.components.contains { event in
                event.name == "VEVENT" && Self.organizes(event, ownerEmail) && event.properties("ATTENDEE").contains { line in
                    line.parameter("SCHEDULE-AGENT")?.uppercased() == "CLIENT"
                        && (ICalendarEventProperties.address(of: line).map { ICalendarEventProperties.isSameMailbox($0.email, guest.address.email) } ?? false)
                }
            }
            guard theirs, InvitationText.setAnswer(guest.response, of: guest.address.email, in: &calendar) else { return }
            do {
                _ = try await save(calendar, to: found.url, ifMatch: found.etag)
                return
            } catch PMailError.conflict where attempt < Self.conflictRetries {
                attempt += 1
            }
        }
    }

    /// The owner's answer on a calendar's first event.
    private func answer(in calendar: ICalendarComponent) -> AttendeeResponse? {
        ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone).firstEvent(calendarID: "", href: nil, etag: nil)?.myResponse
    }

    /// Saves a newer version of an emailed invitation over the calendar's copy. PMail's own copy stays answered by
    /// email. A copy the server or another app put there keeps the server answering for it, and is changed without the
    /// server sending anything for the owner (Schedule-Reply: F); if the server won't take the change, PMail's own copy
    /// replaces it.
    private func update(_ found: Found, to calendar: ICalendarComponent) async throws {
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
            pathsByUID[uid] = url.path(percentEncoded: true)
        }
    }

    /// The resource holding the event with an iCalendar UID, in any of the account's calendars it can change: where
    /// PMail last saw it, else by asking the server for the UID, else among the events around `when` (servers that don't
    /// answer a query by UID, as iCloud may not, still answer one for a stretch of time).
    private func resource(withUID uid: String, near when: Date?) async throws -> Found? {
        if collections.isEmpty { _ = try await loadCalendars() }
        if let path = pathsByUID[uid] {
            if let found = await resource(at: path, uid: uid) { return found }
            pathsByUID[uid] = nil
        }
        if let found = await firstResource(uid: uid, answering: DAVRequestBody.calendarQuery(uid: uid)) { return found }
        guard let when else { return nil }
        let around = DAVRequestBody.calendarQuery(from: when.addingTimeInterval(-Self.searchReach), to: when.addingTimeInterval(Self.searchReach))
        return await firstResource(uid: uid, answering: around)
    }

    /// How far either side of an invitation's time its copy is looked for, when the server won't find it by UID: as far
    /// as an organizer might move it.
    static let searchReach: TimeInterval = 183 * 86_400

    /// A resource by its path, as it is on the server now, when it still holds the event with the UID.
    private func resource(at path: String, uid: String) async -> Found? {
        guard let collection = collections.values.filter({ path.hasPrefix($0.info.id) && !$0.info.isReadOnly }).max(by: { $0.info.id.count < $1.info.id.count }),
              let url = URL(string: path, relativeTo: collection.url)?.absoluteURL,
              let (data, etag) = try? await client.get(url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return found(text, etag: etag, at: url, uid: uid)
    }

    /// The first resource with the UID among a query's answers, in the calendars that can be changed.
    private func firstResource(uid: String, answering query: Data) async -> Found? {
        for collection in collections.values where !collection.info.isReadOnly {
            let fetched = (try? await Self.fetchEvents(client: client, calendar: collection.url, query: query)) ?? []
            for resource in fetched {
                guard let url = URL(string: resource.path, relativeTo: collection.url)?.absoluteURL,
                      let found = found(resource.text, etag: resource.etag, at: url, uid: uid) else { continue }
                return found
            }
        }
        return nil
    }

    /// A resource's copy of the event with the UID, noting it as seen (with the copy PMail had seen before, if older).
    private func found(_ text: String, etag: String?, at url: URL, uid: String) -> Found? {
        guard let calendar = ICalendarComponent.parse(text).first(where: { $0.name == "VCALENDAR" }),
              calendar.components.contains(where: { $0.name == "VEVENT" && $0.property("UID")?.value == uid }) else { return nil }
        let path = url.path(percentEncoded: true)
        let before = resources[path].flatMap { $0.etag == etag ? nil : $0.text }.flatMap { ICalendarComponent.parse($0).first { $0.name == "VCALENDAR" } }
        resources[path] = Resource(etag: etag, text: text)
        pathsByUID[uid] = path
        return Found(url: url, etag: etag, calendar: calendar, before: before)
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
        guard var calendar = ICalendarComponent.parse(resource.text).first(where: { $0.name == "VCALENDAR" }) else {
            throw PMailError.protocolError("the event on the server couldn’t be read")
        }
        if isICloud { Self.recognizeOwner(in: &calendar, owner: ownerEmail, identity: await ownerIdentity()) }
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
