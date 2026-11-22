import Foundation

/// Meetings declined from PMail on a calendar that takes a declined meeting off itself (a Microsoft account's), kept
/// on this Mac so the calendar can still show them, faint and struck through, the way other calendars keep a "No".
/// A meeting goes once the calendar has it again (the organizer sent it again, say), when it's deleted here, or a year
/// after it ended.
public actor DeclinedMeetings {
    /// The JSON file they're kept in; nil keeps them only while PMail runs.
    let file: URL?
    private var kept: [CalendarEvent]?
    /// How long after it ended a declined meeting is still shown.
    static let keptFor: TimeInterval = 365 * 86_400
    /// The file's name in the account's folder.
    public static let fileName = "Declined Meetings.json"

    public init(file: URL?) {
        self.file = file
    }

    /// Keeps a meeting just declined.
    public func keep(_ event: CalendarEvent) {
        var meeting = event
        meeting.myResponse = .declined
        var all = load().filter { $0.id != event.id }
        all.append(meeting)
        save(all)
    }

    /// Lets a meeting go: it was answered again, or deleted.
    public func forget(id: String) {
        let all = load()
        guard all.contains(where: { $0.id == id }) else { return }
        save(all.filter { $0.id != id })
    }

    /// Whether a meeting is one kept here (no longer on the calendar).
    public func contains(id: String) -> Bool {
        load().contains { $0.id == id }
    }

    /// The kept meetings to show beside what the calendar loaded: those on these calendars that overlap the dates and
    /// that the calendar doesn't have again (by ID or iCalendar UID, which lets those go for good).
    public func shown(besides loaded: [CalendarEvent], in calendarIDs: Set<String>, from start: Date, to end: Date,
                      now: Date = Date()) -> [CalendarEvent] {
        let ids = Set(loaded.map(\.id))
        let uids = Set(loaded.compactMap(\.uid))
        let all = load()
        let current = all.filter { meeting in
            !ids.contains(meeting.id) && !(meeting.uid.map(uids.contains) ?? false) && now.timeIntervalSince(meeting.end) < Self.keptFor
        }
        if current.count != all.count { save(current) }
        return current.filter { calendarIDs.contains($0.calendarID) && $0.end > start && $0.start < end }
    }

    private func load() -> [CalendarEvent] {
        if let kept { return kept }
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([CalendarEvent].self, from: $0) } ?? []
        kept = loaded
        return loaded
    }

    private func save(_ meetings: [CalendarEvent]) {
        kept = meetings
        guard let file else { return }
        if meetings.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(meetings).write(to: file, options: .atomic)
    }
}
