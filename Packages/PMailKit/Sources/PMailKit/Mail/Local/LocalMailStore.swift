import Foundation

/// Mail kept on this Mac: each message as an .eml file, with a JSON index of their summaries and flags. POP accounts
/// keep everything here (the server only holds the inbox), and it can hold any local mailbox.
///
/// Folders are just IDs ("INBOX", "Sent", "Drafts", "Trash", or any other string). Every change is written straight
/// away, atomically, so a crash never leaves a half-written index.
public actor LocalMailStore {
    public nonisolated let folder: URL

    private struct Entry: Codable {
        var summary: MessageSummary
        /// The .eml file's name inside the messages folder.
        var file: String
    }

    private struct Index: Codable {
        var version = 1
        var messages: [Entry] = []
        /// Messages deleted for good, so a sync doesn't download them again.
        var deletedIDs: [String] = []
        /// Small settings for whoever uses the store (a POP account's sync state).
        var values: [String: String] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var deletedIDs: Set<String> = []
    private var values: [String: String] = [:]
    private var isLoaded = false

    public init(folder: URL) {
        self.folder = folder
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    /// Whether messages in a folder are drafts: a POP account's Drafts, or the Drafts kept for an IMAP account.
    static func isDraftsFolder(_ folderID: String) -> Bool {
        folderID == "Drafts" || folderID == LocalFolders.draftsID
    }
    private var messagesURL: URL { folder.appendingPathComponent("messages", isDirectory: true) }

    // MARK: Reading

    /// The messages in a folder, newest first.
    public func summaries(in folderID: String) -> [MessageSummary] {
        loadIfNeeded()
        return Self.newestFirst(entries.values.map(\.summary).filter { $0.folderID == folderID })
    }

    /// Every message, newest first.
    public func allSummaries() -> [MessageSummary] {
        loadIfNeeded()
        return Self.newestFirst(entries.values.map(\.summary))
    }

    /// Starred messages in every folder but Trash, newest first.
    public func starredSummaries() -> [MessageSummary] {
        loadIfNeeded()
        return Self.newestFirst(entries.values.map(\.summary).filter { $0.isStarred && $0.folderID != "Trash" })
    }

    public func summary(for id: String) -> MessageSummary? {
        loadIfNeeded()
        return entries[id]?.summary
    }

    /// The message as it was stored.
    public func raw(for id: String) -> Data? {
        loadIfNeeded()
        guard let entry = entries[id] else { return nil }
        return try? Data(contentsOf: messagesURL.appendingPathComponent(entry.file))
    }

    public func contains(id: String) -> Bool {
        loadIfNeeded()
        return entries[id] != nil
    }

    /// How many messages a folder holds, and how many of them are unread.
    public func counts(in folderID: String) -> (total: Int, unread: Int) {
        loadIfNeeded()
        let inFolder = entries.values.filter { $0.summary.folderID == folderID }
        return (inFolder.count, inFolder.filter(\.summary.isUnread).count)
    }

    /// Messages whose subject, sender, recipients or snippet contain every word of `text`, ignoring case and
    /// accents, newest first. With `folderID`, only that folder is searched.
    public func search(_ text: String, in folderID: String? = nil) -> [MessageSummary] {
        loadIfNeeded()
        let words = text.split(whereSeparator: \.isWhitespace).map { Self.folded(String($0)) }
        guard !words.isEmpty else { return [] }
        let found = entries.values.map(\.summary).filter { summary in
            if let folderID, summary.folderID != folderID { return false }
            var fields = [summary.subject, summary.snippet]
            for address in [summary.from].compactMap({ $0 }) + summary.to + summary.cc {
                fields.append(address.name ?? "")
                fields.append(address.email)
            }
            let haystack = Self.folded(fields.joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
        return Self.newestFirst(found)
    }

    // MARK: Changing

    /// Stores a message, reading its summary from the raw source, and returns the summary. A message with the same
    /// ID is replaced. Without an `id`, the message gets a new "local:" one.
    @discardableResult
    public func add(raw: Data, folderID: String, id: String? = nil, isUnread: Bool = true,
                    isStarred: Bool = false) throws -> MessageSummary {
        loadIfNeeded()
        let id = id ?? "local:\(UUID().uuidString.lowercased())"
        var summary = MIMEParser.parse(raw).summary(id: id, folderID: folderID, isUnread: isUnread, isStarred: isStarred,
                                                    size: raw.count)
        summary.isDraft = Self.isDraftsFolder(folderID)
        let file = entries[id]?.file ?? "\(UUID().uuidString.lowercased()).eml"
        do {
            try FileManager.default.createDirectory(at: messagesURL, withIntermediateDirectories: true)
            try raw.write(to: messagesURL.appendingPathComponent(file), options: .atomic)
        } catch {
            throw Self.storageError(error)
        }
        entries[id] = Entry(summary: summary, file: file)
        deletedIDs.remove(id)
        try save()
        return summary
    }

    public func setUnread(_ isUnread: Bool, for ids: [String]) throws {
        try update(ids) { $0.isUnread = isUnread }
    }

    public func setStarred(_ isStarred: Bool, for ids: [String]) throws {
        try update(ids) { $0.isStarred = isStarred }
    }

    public func move(ids: [String], to folderID: String) throws {
        try update(ids) {
            $0.folderID = folderID
            $0.isDraft = Self.isDraftsFolder(folderID)
        }
    }

    /// Deletes messages for good, remembering their IDs so a sync won't bring them back.
    public func delete(ids: [String]) throws {
        loadIfNeeded()
        var changed = false
        for id in ids {
            if let entry = entries.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: messagesURL.appendingPathComponent(entry.file))
                changed = true
            }
            if deletedIDs.insert(id).inserted { changed = true }
        }
        if changed { try save() }
    }

    // MARK: Bookkeeping for syncing

    /// Of these IDs, the ones the store has or has deleted: the ones a sync shouldn't download.
    public func knownIDs(among ids: [String]) -> Set<String> {
        loadIfNeeded()
        return Set(ids.filter { entries[$0] != nil || deletedIDs.contains($0) })
    }

    /// Records IDs as deleted without ever storing them (messages a first sync leaves behind).
    public func markDeleted(ids: [String]) throws {
        loadIfNeeded()
        let before = deletedIDs.count
        deletedIDs.formUnion(ids.filter { entries[$0] == nil })
        if deletedIDs.count != before { try save() }
    }

    /// Forgets deleted IDs with this prefix that aren't in `ids` (messages gone from the server), so the list of
    /// deleted IDs doesn't grow forever.
    public func forgetDeletedIDs(withPrefix prefix: String, notIn ids: Set<String>) throws {
        loadIfNeeded()
        let stale = deletedIDs.filter { $0.hasPrefix(prefix) && !ids.contains($0) }
        guard !stale.isEmpty else { return }
        deletedIDs.subtract(stale)
        try save()
    }

    public func value(forKey key: String) -> String? {
        loadIfNeeded()
        return values[key]
    }

    public func setValue(_ value: String?, forKey key: String) throws {
        loadIfNeeded()
        guard values[key] != value else { return }
        values[key] = value
        try save()
    }

    // MARK: Storage

    private func update(_ ids: [String], _ change: (inout MessageSummary) -> Void) throws {
        loadIfNeeded()
        var changed = false
        for id in ids {
            guard var entry = entries[id] else { continue }
            let before = entry.summary
            change(&entry.summary)
            if entry.summary != before {
                entries[id] = entry
                changed = true
            }
        }
        if changed { try save() }
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        entries = Dictionary(index.messages.map { ($0.summary.id, $0) }, uniquingKeysWith: { _, last in last })
        deletedIDs = Set(index.deletedIDs)
        values = index.values
    }

    private func save() throws {
        let index = Index(messages: entries.values.sorted { $0.summary.id < $1.summary.id }, deletedIDs: deletedIDs.sorted(),
                          values: values)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            throw Self.storageError(error)
        }
    }

    private static func storageError(_ error: Error) -> PMailError {
        .server("PMail couldn’t save mail on this Mac: \(error.localizedDescription)")
    }

    private static func newestFirst(_ summaries: [MessageSummary]) -> [MessageSummary] {
        summaries.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
