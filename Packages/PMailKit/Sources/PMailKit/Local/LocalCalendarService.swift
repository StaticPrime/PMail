import Foundation

/// The calendar of an account with no calendar server: one writable calendar, "Calendar", kept in a folder as an
/// iCalendar file per event. Repeating events, single-occurrence changes and invitations work as they do on a
/// server, and each event's `resourceHref` is its file's name.
public actor LocalCalendarService: CalendarService {
    /// The ID of the one calendar.
    public static let calendarID = "local"

    private let store: LocalFileStore
    private let ownerEmail: String
    private let localTimeZone: TimeZone

    public init(folder: URL, ownerEmail: String) {
        self.init(folder: folder, ownerEmail: ownerEmail, timeZone: .current)
    }

    /// The same, reading all-day and floating times in a given time zone instead of the Mac's.
    init(folder: URL, ownerEmail: String, timeZone: TimeZone) {
        store = LocalFileStore(folder: folder, fileExtension: "ics")
        self.ownerEmail = ownerEmail
        localTimeZone = timeZone
    }

    public func loadCalendars() async throws -> [CalendarInfo] {
        [CalendarInfo(id: Self.calendarID, name: "Calendar", isPrimary: true)]
    }

    public func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard calendarIDs.contains(Self.calendarID), start < end else { return [] }
        var events: [CalendarEvent] = []
        for name in try store.names() {
            guard let (data, etag) = try? store.read(name) else { continue }
            for calendar in ICalendarComponent.parse(data) where calendar.name == "VCALENDAR" {
                events += reader(calendar).events(calendarID: Self.calendarID, href: name, etag: etag, from: start, to: end)
            }
        }
        return events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    public func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        guard event.calendarID == Self.calendarID else { throw PMailError.notFound }
        let uid = event.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let name = LocalFileStore.fileName(for: uid, fileExtension: "ics")
        guard !store.exists(name) else { throw PMailError.conflict }
        var saved = event
        saved.uid = uid
        let calendar = writer().newCalendar(for: saved, uid: uid)
        let etag = try store.write(Data(calendar.serialized.utf8), to: name)
        return reader(calendar).firstEvent(calendarID: Self.calendarID, href: name, etag: etag) ?? saved
    }

    public func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        var (name, calendar, etag) = try file(of: event)
        if let expected = event.etag, expected != etag { throw PMailError.conflict }
        let key = try writer().update(&calendar, with: event, scope: scope)
        let newETag = try store.write(Data(calendar.serialized.utf8), to: name)
        let reader = reader(calendar)
        if let series = reader.series(for: event) ?? reader.series.first,
           let saved = reader.event(in: series, key: key, calendarID: Self.calendarID, href: name, etag: newETag) {
            return saved
        }
        var saved = event
        saved.etag = newETag
        return saved
    }

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        var (name, calendar, etag) = try file(of: event)
        if let expected = event.etag, expected != etag { throw PMailError.conflict }
        if scope == .allEvents || !event.isRecurring {
            try store.delete(name)
        } else if try writer().deleteOccurrence(of: event, from: &calendar) {
            try store.delete(name)
        } else {
            try store.write(Data(calendar.serialized.utf8), to: name)
        }
    }

    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        var (name, calendar, _) = try file(of: event)
        try writer().respond(response, to: event, in: &calendar)
        try store.write(Data(calendar.serialized.utf8), to: name)
    }

    // MARK: Files

    private func reader(_ calendar: ICalendarComponent) -> ICalendarReader {
        ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
    }

    private func writer() -> ICalendarWriter {
        ICalendarWriter(ownerEmail: ownerEmail, localTimeZone: localTimeZone)
    }

    /// The file an event lives in: its `resourceHref`, or else the file holding its UID.
    private func file(of event: CalendarEvent) throws -> (name: String, calendar: ICalendarComponent, etag: String) {
        guard event.calendarID == Self.calendarID else { throw PMailError.notFound }
        var candidates: [String] = []
        if let href = event.resourceHref, store.exists(href) { candidates.append(href) }
        if let uid = event.seriesID ?? event.uid {
            let name = LocalFileStore.fileName(for: uid, fileExtension: "ics")
            if store.exists(name) { candidates.append(name) }
        }
        for name in candidates {
            let (data, etag) = try store.read(name)
            if let calendar = ICalendarComponent.parse(data).first(where: { $0.name == "VCALENDAR" }) { return (name, calendar, etag) }
        }
        throw PMailError.notFound
    }
}
