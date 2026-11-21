import CryptoKit
import Foundation

/// What an account last loaded, kept on the Mac: folders, pages of conversations, conversations read, calendars,
/// events and contacts. PMail shows them at once when it opens and while the account's servers can't be reached.
/// Everything here is a copy; the servers always win.
public actor AccountCache {
    public let folder: URL
    /// How many conversations' messages to keep; the ones read longest ago go first.
    public let conversationLimit: Int
    /// Attachments bigger than this aren't kept (their details are, so they still show).
    public let attachmentLimit: Int
    private var savesSincePrune = 0

    public init(folder: URL, conversationLimit: Int = 1500, attachmentLimit: Int = 5 * 1024 * 1024) {
        self.folder = folder
        self.conversationLimit = conversationLimit
        self.attachmentLimit = attachmentLimit
    }

    // MARK: Mail

    public func folders() -> [MailFolder]? { read([MailFolder].self, "folders.json") }

    public func save(folders: [MailFolder]) { write(folders, "folders.json") }

    /// The page last loaded for a list ("INBOX|primary|0"), if there is one.
    public func page(for key: String) -> ConversationPage? { read(ConversationPage.self, "Pages/\(Self.fileName(key))") }

    public func save(page: ConversationPage, for key: String) { write(page, "Pages/\(Self.fileName(key))") }

    /// A conversation's messages as they were last opened.
    public func conversation(_ id: String) -> [MailMessage]? {
        let url = file("Conversations/\(Self.fileName(id))")
        guard let messages = read([MailMessage].self, url) else { return nil }
        // Reading counts as use, for choosing what to let go.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return messages
    }

    /// Keeps a conversation's messages, without big attachments' data or the raw source.
    public func save(conversation id: String, messages: [MailMessage]) {
        let trimmed = messages.map { message -> MailMessage in
            var message = message
            message.rawSource = nil
            message.attachments = message.attachments.map { attachment in
                var attachment = attachment
                if let data = attachment.data, data.count > attachmentLimit { attachment.data = nil }
                return attachment
            }
            return message
        }
        write(trimmed, "Conversations/\(Self.fileName(id))")
        savesSincePrune += 1
        if savesSincePrune >= 25 {
            savesSincePrune = 0
            prune("Conversations", keeping: conversationLimit)
        }
    }

    /// Updates the flags (read, starred and so on) of messages wherever the cache has them, so a copy shown later
    /// matches what was done.
    public func update(summaries: [MessageSummary]) {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let threads = Set(summaries.map(\.threadID))
        for thread in threads {
            guard var messages = read([MailMessage].self, "Conversations/\(Self.fileName(thread))") else { continue }
            var changed = false
            for index in messages.indices {
                if let summary = byID[messages[index].id] {
                    messages[index].summary = summary
                    changed = true
                }
            }
            if changed { write(messages, "Conversations/\(Self.fileName(thread))") }
        }
    }

    public func syncState() -> MailSyncState? { read(MailSyncState.self, "sync.json") }

    public func save(syncState: MailSyncState?) {
        if let syncState { write(syncState, "sync.json") } else { try? FileManager.default.removeItem(at: file("sync.json")) }
    }

    // MARK: Calendars and contacts

    public func calendars() -> [CalendarInfo]? { read([CalendarInfo].self, "calendars.json") }

    public func save(calendars: [CalendarInfo]) { write(calendars, "calendars.json") }

    private struct StoredEvents: Codable {
        var start: Date
        var end: Date
        var events: [CalendarEvent]
    }

    /// The events last loaded, and the days they cover.
    public func events() -> (interval: DateInterval, events: [CalendarEvent])? {
        guard let stored = read(StoredEvents.self, "events.json"), stored.end >= stored.start else { return nil }
        return (DateInterval(start: stored.start, end: stored.end), stored.events)
    }

    public func save(events: [CalendarEvent], covering interval: DateInterval) {
        write(StoredEvents(start: interval.start, end: interval.end, events: events), "events.json")
    }

    public func contacts() -> [Contact]? { read([Contact].self, "contacts.json") }

    public func save(contacts: [Contact]) { write(contacts, "contacts.json") }

    /// Forgets everything (when the account is removed).
    public func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Files

    /// A file name for a key: its SHA-256, so any key (an IMAP path, a long ID) makes a safe, fixed-length name.
    static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func file(_ path: String) -> URL { folder.appendingPathComponent(path) }

    private func read<T: Decodable>(_ type: T.Type, _ path: String) -> T? { read(type, file(path)) }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ path: String) {
        let url = file(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            // The cache is only a copy: a file that can't be written is simply missing next time.
        }
    }

    /// Keeps the `limit` files in a folder used most recently, deleting the rest.
    private func prune(_ path: String, keeping limit: Int) {
        let directory = file(path)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) { try? FileManager.default.removeItem(at: url) }
    }
}
