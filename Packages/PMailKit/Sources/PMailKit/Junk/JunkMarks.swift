import Foundation

/// An account's messages left in the inbox but marked: as junk, or as from a blocked sender. Each is known by its
/// Message-ID, so a mark follows the message wherever it's listed. Kept in a JSON file in the account's folder.
public actor JunkMarks {
    public enum Mark: String, Codable, Sendable {
        case junk
        case blocked
    }

    private struct Entry: Codable {
        var mark: Mark
        var markedAt: Date
    }

    public let file: URL
    private var entries: [String: Entry]?

    public init(file: URL) {
        self.file = file
    }

    public func mark(_ summaries: [MessageSummary], as mark: Mark, at date: Date = Date()) {
        guard !summaries.isEmpty else { return }
        var current = loaded()
        for summary in summaries { current[Self.key(for: summary)] = Entry(mark: mark, markedAt: date) }
        // The oldest go once there are many: a mark matters while the message is new.
        if current.count > 5_000 {
            current = Dictionary(uniqueKeysWithValues: current.sorted { $0.value.markedAt > $1.value.markedAt }.prefix(4_000).map { ($0.key, $0.value) })
        }
        save(current)
    }

    public func clear(_ summaries: [MessageSummary]) {
        var current = loaded()
        let before = current.count
        for summary in summaries { current[Self.key(for: summary)] = nil }
        if current.count != before { save(current) }
    }

    /// The marks on some messages, by message ID.
    public func marks(for summaries: [MessageSummary]) -> [String: Mark] {
        let current = loaded()
        guard !current.isEmpty else { return [:] }
        var marks: [String: Mark] = [:]
        for summary in summaries {
            if let entry = current[Self.key(for: summary)] { marks[summary.id] = entry.mark }
        }
        return marks
    }

    static func key(for summary: MessageSummary) -> String {
        summary.messageIDHeader?.lowercased() ?? "id:" + summary.id
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = read
        return read
    }

    private func save(_ new: [String: Entry]) {
        entries = new
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            // Kept in memory; written with the next change.
        }
    }
}

/// Messages the person took out of junk (Not spam, Not Junk, or moved out of the spam folder), by Message-ID: PMail
/// never takes them for junk again, whatever the server's own mark on them says, so one moved back to the inbox stays
/// there (a moved message arrives in the inbox as new mail). Kept in a JSON file in the account's folder.
public actor KeptFromJunk {
    /// The file's name in the account's folder.
    public static let fileName = "Not Junk.json"

    public let file: URL
    private var keys: [String: Date]?

    public init(file: URL) {
        self.file = file
    }

    public func keep(_ summaries: [MessageSummary], at date: Date = Date()) {
        guard !summaries.isEmpty else { return }
        var current = loaded()
        for summary in summaries { current[JunkMarks.key(for: summary)] = date }
        // The oldest go once there are many.
        if current.count > 5_000 {
            current = Dictionary(uniqueKeysWithValues: current.sorted { $0.value > $1.value }.prefix(4_000).map { ($0.key, $0.value) })
        }
        keys = current
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: file, options: .atomic)
        } catch {
            // Kept in memory; written with the next change.
        }
    }

    /// Which of some messages (by ID) were taken out of junk.
    public func kept(among summaries: [MessageSummary]) -> Set<String> {
        let current = loaded()
        guard !current.isEmpty else { return [] }
        return Set(summaries.filter { current[JunkMarks.key(for: $0)] != nil }.map(\.id))
    }

    private func loaded() -> [String: Date] {
        if let keys { return keys }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        keys = read
        return read
    }
}

/// The addresses an account has sent mail to, so mail from them isn't taken for junk. Kept in a JSON file in the
/// account's folder.
public actor PreviousRecipients {
    public let file: URL
    private var addresses: [String: Date]?

    public init(file: URL) {
        self.file = file
    }

    public func record(_ emails: [String], at date: Date = Date()) {
        var current = loaded()
        var changed = false
        for email in emails {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard address.contains("@") else { continue }
            if current[address] == nil { changed = true }
            current[address] = max(current[address] ?? date, date)
        }
        guard changed || !emails.isEmpty else { return }
        if current.count > 10_000 {
            current = Dictionary(uniqueKeysWithValues: current.sorted { $0.value > $1.value }.prefix(8_000).map { ($0.key, $0.value) })
        }
        save(current)
    }

    public func contains(_ email: String) -> Bool {
        loaded()[email.lowercased()] != nil
    }

    public func all() -> Set<String> {
        Set(loaded().keys)
    }

    private func loaded() -> [String: Date] {
        if let addresses { return addresses }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        addresses = read
        return read
    }

    private func save(_ new: [String: Date]) {
        addresses = new
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            // Kept in memory; written with the next change.
        }
    }
}
