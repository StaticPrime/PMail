import Foundation

/// A conversation put away until later: taken out of the inbox now, and brought back, unread, at `wakeAt`.
public struct Snooze: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// The conversation as it was when snoozed, for the Snoozed list.
    public var conversation: Conversation
    public var wakeAt: Date
    public var snoozedAt: Date
    /// Its messages' Message-ID headers, for finding them again after they moved (moving can change their IDs).
    public var messageIDs: [String]

    public init(id: UUID = UUID(), conversation: Conversation, wakeAt: Date, snoozedAt: Date = Date()) {
        self.id = id
        self.conversation = conversation
        self.wakeAt = wakeAt
        self.snoozedAt = snoozedAt
        messageIDs = conversation.messages.compactMap(\.messageIDHeader)
    }

    /// The folder the Snoozed list goes by.
    public static let folderID = "pmail:snoozed"
}

/// An account's snoozed conversations, kept on the Mac.
public actor SnoozeBook {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Every snooze, the soonest to wake first.
    public func all() -> [Snooze] {
        guard let data = try? Data(contentsOf: file), let snoozes = try? JSONDecoder().decode([Snooze].self, from: data) else { return [] }
        return snoozes.sorted { $0.wakeAt < $1.wakeAt }
    }

    /// Adds a snooze, replacing any earlier snooze of the same conversation.
    public func add(_ snooze: Snooze) throws {
        var snoozes = all().filter { $0.conversation.id != snooze.conversation.id }
        snoozes.append(snooze)
        try save(snoozes)
    }

    public func remove(_ id: UUID) {
        try? save(all().filter { $0.id != id })
    }

    public func snooze(forConversation id: String) -> Snooze? { all().first { $0.conversation.id == id } }

    /// The snoozes whose time has come.
    public func due(at date: Date) -> [Snooze] { all().filter { $0.wakeAt <= date } }

    private func save(_ snoozes: [Snooze]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snoozes).write(to: file, options: .atomic)
        } catch {
            throw PMailError.server("The snooze couldn’t be kept on this Mac: \(error.localizedDescription)")
        }
    }
}

/// The times offered for snoozing a conversation and scheduling a message.
public enum LaterTimes {
    public struct Choice: Sendable, Hashable {
        public var title: String
        public var date: Date
    }

    /// Later today (6 PM, while it's before 5), tomorrow at 8, this weekend (Saturday at 8, until Friday) and next
    /// week (Monday at 8).
    public static func snooze(now: Date, calendar: Calendar = .current) -> [Choice] {
        var choices: [Choice] = []
        let today = calendar.startOfDay(for: now)
        if calendar.component(.hour, from: now) < 17, let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) {
            choices.append(Choice(title: "Later today", date: evening))
        }
        if let tomorrow = at(8, daysAfter: 1, from: today, calendar: calendar) { choices.append(Choice(title: "Tomorrow", date: tomorrow)) }
        let weekday = calendar.component(.weekday, from: now)
        if weekday != 7 && weekday != 1, let saturday = next(weekday: 7, at: 8, after: now, calendar: calendar) {
            choices.append(Choice(title: "This weekend", date: saturday))
        }
        if let monday = next(weekday: 2, at: 8, after: now, calendar: calendar) { choices.append(Choice(title: "Next week", date: monday)) }
        return choices
    }

    /// Tomorrow morning (8), tomorrow afternoon (1) and Monday morning (8), the next Monday after tomorrow.
    public static func scheduleSend(now: Date, calendar: Calendar = .current) -> [Choice] {
        let today = calendar.startOfDay(for: now)
        var choices: [Choice] = []
        if let morning = at(8, daysAfter: 1, from: today, calendar: calendar) { choices.append(Choice(title: "Tomorrow morning", date: morning)) }
        if let afternoon = at(13, daysAfter: 1, from: today, calendar: calendar) {
            choices.append(Choice(title: "Tomorrow afternoon", date: afternoon))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let monday = next(weekday: 2, at: 8, after: tomorrow, calendar: calendar) {
            choices.append(Choice(title: "Monday morning", date: monday))
        }
        return choices
    }

    private static func at(_ hour: Int, daysAfter days: Int, from day: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: day).flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
    }

    /// The next given weekday (1 is Sunday) after `date`'s day, at `hour`.
    private static func next(weekday: Int, at hour: Int, after date: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: date)
        let current = calendar.component(.weekday, from: day)
        let ahead = (weekday - current + 7) % 7
        return at(hour, daysAfter: ahead == 0 ? 7 : ahead, from: day, calendar: calendar)
    }
}
