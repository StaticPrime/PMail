import Foundation

/// People whose calendars an account follows from PMail, for a provider that can read a calendar someone shared but
/// has no way for an app to add it to the account's own list (Microsoft's). Kept in the account's folder.
public actor FollowedCalendars {
    public struct Person: Codable, Sendable, Hashable {
        public var email: String
        public var name: String
        public var colorHex: String
    }

    /// Calendar IDs of people followed start with this.
    public static let prefix = "person:"
    /// The file's name in the account's folder.
    public static let fileName = "Followed Calendars.json"
    static let colors = ["#8E24AA", "#039BE5", "#F4511E", "#0B8043", "#7986CB", "#E67C73"]

    let file: URL?
    private var people: [Person]?

    public init(file: URL?) {
        self.file = file
    }

    public static func calendarID(for email: String) -> String { prefix + email.lowercased() }

    public static func email(from calendarID: String) -> String? {
        calendarID.hasPrefix(prefix) ? String(calendarID.dropFirst(prefix.count)) : nil
    }

    public func all() -> [Person] { load() }

    /// The calendars followed, as calendars.
    public func calendars() -> [CalendarInfo] {
        load().map { CalendarInfo(id: Self.calendarID(for: $0.email), name: $0.name, colorHex: $0.colorHex, isReadOnly: true, isOther: true,
                                  canUnsubscribe: true) }
    }

    /// Follows someone (again, it just keeps the newer name), and returns their calendar.
    @discardableResult
    public func add(email: String, name: String?, colorHex: String?) -> CalendarInfo {
        var all = load().filter { $0.email.lowercased() != email.lowercased() }
        let shown = name.flatMap { $0.isEmpty ? nil : $0 } ?? email
        let person = Person(email: email.lowercased(), name: shown, colorHex: colorHex ?? Self.colors[all.count % Self.colors.count])
        all.append(person)
        save(all)
        return CalendarInfo(id: Self.calendarID(for: person.email), name: person.name, colorHex: person.colorHex, isReadOnly: true, isOther: true,
                            canUnsubscribe: true)
    }

    public func remove(email: String) {
        save(load().filter { $0.email.lowercased() != email.lowercased() })
    }

    private func load() -> [Person] {
        if let people { return people }
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Person].self, from: $0) } ?? []
        people = loaded
        return loaded
    }

    private func save(_ all: [Person]) {
        people = all
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}
