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
        /// When messages downloaded from a server arrived here, by ID, so the server's copies can go after a while.
        var arrivals: [String: Date]?
        /// Of the deleted IDs, the messages that had arrived from a server and were deleted here (rather than ones a
        /// first sync left behind), so the server's copies can go once they're deleted.
        var deletedAfterArriving: [String]?
        /// Small settings for whoever uses the store (a POP account's sync state).
        var values: [String: String] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var deletedIDs: Set<String> = []
    private var arrivals: [String: Date] = [:]
    private var deletedAfterArriving: Set<String> = []
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

    /// Messages with a label, in every folder, newest first.
    public func summaries(withLabel labelID: String) -> [MessageSummary] {
        loadIfNeeded()
        return Self.newestFirst(entries.values.map(\.summary).filter { $0.labelIDs.contains(labelID) })
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
    /// ID is replaced. Without an `id`, the message gets a new "local:" one. `arrived` notes when a message downloaded
    /// from a server got here.
    @discardableResult
    public func add(raw: Data, folderID: String, id: String? = nil, isUnread: Bool = true,
                    isStarred: Bool = false, arrived: Date? = nil) throws -> MessageSummary {
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
        deletedAfterArriving.remove(id)
        if let arrived, arrivals[id] == nil { arrivals[id] = arrived }
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

    /// Adds a label to messages, or takes it off them.
    public func setLabel(_ labelID: String, _ isOn: Bool, for ids: [String]) throws {
        try update(ids) { summary in
            if isOn {
                if !summary.labelIDs.contains(labelID) { summary.labelIDs.append(labelID) }
            } else {
                summary.labelIDs.removeAll { $0 == labelID }
            }
        }
    }

    /// Gives messages exactly these labels.
    public func setLabelIDs(_ labelIDs: [String], for ids: [String]) throws {
        try update(ids) { $0.labelIDs = labelIDs }
    }

    /// Changes a label to another on every message that has it, or takes it off them all when `newID` is nil.
    public func replaceLabel(_ labelID: String, with newID: String?) throws {
        loadIfNeeded()
        let ids = entries.values.filter { $0.summary.labelIDs.contains(labelID) }.map(\.summary.id)
        try update(ids) { summary in
            var labels: [String] = []
            for label in summary.labelIDs {
                guard let kept = label == labelID ? newID : label else { continue }
                if !labels.contains(kept) { labels.append(kept) }
            }
            summary.labelIDs = labels
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
            if arrivals[id] != nil, deletedAfterArriving.insert(id).inserted { changed = true }
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

    /// Forgets deleted IDs and arrivals with this prefix that aren't in `ids` (messages gone from the server), so the
    /// lists don't grow forever.
    public func forgetDeletedIDs(withPrefix prefix: String, notIn ids: Set<String>) throws {
        loadIfNeeded()
        let stale = deletedIDs.filter { $0.hasPrefix(prefix) && !ids.contains($0) }
        let staleArrivals = arrivals.keys.filter { $0.hasPrefix(prefix) && !ids.contains($0) }
        guard !stale.isEmpty || !staleArrivals.isEmpty else { return }
        deletedIDs.subtract(stale)
        deletedAfterArriving.subtract(stale)
        for id in staleArrivals { arrivals[id] = nil }
        try save()
    }

    /// When each of these messages arrived from the server. A message kept here from before arrivals were noted counts
    /// as arriving `now`, so its time starts then; one never downloaded (a first sync left it behind) has none.
    public func arrivals(among ids: [String], now: Date) throws -> [String: Date] {
        loadIfNeeded()
        var found: [String: Date] = [:]
        var noted = false
        for id in ids {
            if let arrived = arrivals[id] {
                found[id] = arrived
            } else if entries[id] != nil {
                arrivals[id] = now
                found[id] = now
                noted = true
            }
        }
        if noted { try save() }
        return found
    }

    /// Of these IDs, the messages that arrived from the server and were then deleted for good here.
    public func deletedAfterArriving(among ids: [String]) -> Set<String> {
        loadIfNeeded()
        return Set(ids.filter { deletedAfterArriving.contains($0) })
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
        arrivals = index.arrivals ?? [:]
        deletedAfterArriving = Set(index.deletedAfterArriving ?? [])
        values = index.values
    }

    private func save() throws {
        let index = Index(messages: entries.values.sorted { $0.summary.id < $1.summary.id }, deletedIDs: deletedIDs.sorted(),
                          arrivals: arrivals.isEmpty ? nil : arrivals,
                          deletedAfterArriving: deletedAfterArriving.isEmpty ? nil : deletedAfterArriving.sorted(), values: values)
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
