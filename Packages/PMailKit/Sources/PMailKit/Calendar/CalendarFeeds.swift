import Foundation

/// Calendars followed from a web address (an .ics feed: a school's term dates, a team's fixtures, another calendar
/// app's public link), for any account. PMail keeps the list and a copy of each feed in the account's folder, reads
/// it like any iCalendar file, and fetches it again when it's more than an hour old. They're read-only, listed under
/// "Other calendars".
public actor CalendarFeeds {
    /// One feed: where it comes from and how it shows.
    public struct Feed: Codable, Sendable, Hashable {
        public var id: String
        public var url: URL
        public var name: String
        public var colorHex: String
        public var fetchedAt: Date?
        /// The server's validators from the last fetch, for asking only whether it changed.
        public var etag: String?
        public var lastModified: String?
    }

    /// Calendar IDs of feeds start with this.
    public static let prefix = "feed:"
    /// The folder's name in the account's folder.
    public static let folderName = "Calendar Feeds"
    /// How long a copy is used before the feed is fetched again.
    static let freshFor: TimeInterval = 3_600
    /// The colors feeds are given, in turn.
    static let colors = ["#0B8043", "#8E24AA", "#F4511E", "#039BE5", "#7986CB", "#E67C73", "#33B679", "#F6BF26"]

    let folder: URL
    let transport: any HTTPTransport
    let localTimeZone: TimeZone
    private var feeds: [Feed]?

    public init(folder: URL, transport: any HTTPTransport = URLSessionTransport(), timeZone: TimeZone = .current) {
        self.folder = folder
        self.transport = transport
        localTimeZone = timeZone
    }

    public static func isFeed(_ calendarID: String) -> Bool { calendarID.hasPrefix(prefix) }

    /// The address to fetch: webcal: is the web's own address, sent over HTTPS.
    public static func fetchableURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("webcals://") { trimmed = "https://" + trimmed.dropFirst(10) }
        if trimmed.lowercased().hasPrefix("webcal://") { trimmed = "https://" + trimmed.dropFirst(9) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            return nil
        }
        return url
    }

    /// The feeds as calendars.
    public func calendars() -> [CalendarInfo] {
        load().map { CalendarInfo(id: $0.id, name: $0.name, colorHex: $0.colorHex, isReadOnly: true, isOther: true, canUnsubscribe: true) }
    }

    /// Follows a feed: fetches it once to check it's a calendar, and names it from the feed (or `name`).
    public func subscribe(to address: String, name: String? = nil, now: Date = Date()) async throws -> CalendarInfo {
        guard let url = Self.fetchableURL(address) else {
            throw PMailError.notSupported("That isn’t a calendar address. It starts with webcal:// or https://.")
        }
        var all = load()
        if let existing = all.first(where: { $0.url == url }) {
            return CalendarInfo(id: existing.id, name: existing.name, colorHex: existing.colorHex, isReadOnly: true, isOther: true, canUnsubscribe: true)
        }
        let (data, response) = try await fetch(url, etag: nil, lastModified: nil)
        guard let calendar = ICalendarComponent.parse(data).first(where: { $0.name == "VCALENDAR" }) else {
            throw PMailError.notSupported("There’s no calendar at that address.")
        }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feedName = given.isEmpty ? (calendar.property("X-WR-CALNAME")?.value).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "Calendar" : given
        let feed = Feed(id: Self.prefix + UUID().uuidString.lowercased(), url: url, name: feedName,
                        colorHex: Self.colors[all.count % Self.colors.count], fetchedAt: now,
                        etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        try keep(data, for: feed)
        all.append(feed)
        try save(all)
        return CalendarInfo(id: feed.id, name: feed.name, colorHex: feed.colorHex, isReadOnly: true, isOther: true, canUnsubscribe: true)
    }

    /// Stops following a feed and lets its copy go.
    public func unsubscribe(_ calendarID: String) throws {
        let all = load()
        guard all.contains(where: { $0.id == calendarID }) else { return }
        try? FileManager.default.removeItem(at: copyURL(calendarID))
        try save(all.filter { $0.id != calendarID })
    }

    /// The events of these feeds in `start..<end`, from their copies, each fetched again first when it's stale. A feed
    /// that can't be fetched shows its last copy.
    public func events(in calendarIDs: [String], from start: Date, to end: Date, now: Date = Date()) async -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for feed in load() where calendarIDs.contains(feed.id) {
            if now.timeIntervalSince(feed.fetchedAt ?? .distantPast) >= Self.freshFor { await refresh(feed, now: now) }
            guard let data = try? Data(contentsOf: copyURL(feed.id)) else { continue }
            for calendar in ICalendarComponent.parse(data) where calendar.name == "VCALENDAR" {
                let reader = ICalendarReader(calendar: calendar, ownerEmail: nil, localTimeZone: localTimeZone)
                events += reader.events(calendarID: feed.id, href: nil, etag: nil, from: start, to: end).map { event in
                    var event = event
                    event.id = feed.id + "/" + event.id
                    return event
                }
            }
        }
        return events
    }

    /// Fetches a feed again (asking only whether it changed, when the server allows), keeping the copy if it can't.
    private func refresh(_ feed: Feed, now: Date) async {
        var updated = feed
        updated.fetchedAt = now
        if let (data, response) = try? await fetch(feed.url, etag: feed.etag, lastModified: feed.lastModified), response.statusCode != 304,
           ICalendarComponent.parse(data).contains(where: { $0.name == "VCALENDAR" }) {
            try? keep(data, for: feed)
            updated.etag = response.value(forHTTPHeaderField: "ETag")
            updated.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        }
        var all = load()
        if let index = all.firstIndex(where: { $0.id == feed.id }) { all[index] = updated }
        try? save(all)
    }

    private func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/calendar, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 304 || (200..<300).contains(response.statusCode) else {
            throw PMailError.server("The calendar’s address answered with error \(response.statusCode).")
        }
        return (data, response)
    }

    // MARK: Storage

    private var listURL: URL { folder.appendingPathComponent("Feeds.json") }

    private func copyURL(_ id: String) -> URL {
        folder.appendingPathComponent(String(id.dropFirst(Self.prefix.count)) + ".ics")
    }

    private func keep(_ data: Data, for feed: Feed) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: copyURL(feed.id), options: .atomic)
    }

    private func load() -> [Feed] {
        if let feeds { return feeds }
        let loaded = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder().decode([Feed].self, from: $0) } ?? []
        feeds = loaded
        return loaded
    }

    private func save(_ all: [Feed]) throws {
        feeds = all
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: listURL, options: .atomic)
    }
}
