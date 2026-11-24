import Foundation
import os

/// The places a Gmail message can be: All Mail (everything but spam and the trash, labels and all), Spam or Trash.
/// Every message is in exactly one, and has a UID there.
enum GmailPlace: String, Sendable, CaseIterable {
    case allMail = "all"
    case spam
    case trash
}

/// A list Gmail shows: a label's (the inbox, Sent, Drafts, Important or one of the account's), an inbox tab's, Starred,
/// All Mail, Spam or Trash.
enum GmailView: Sendable, Hashable {
    /// Conversations with a message carrying the label: Gmail's own by its backslash name ("\Inbox"), or one of the
    /// account's by name.
    case label(String)
    /// Inbox conversations in a category tab (Primary holds those in none of the others).
    case inboxTab(String)
    case starred
    case allMail
    case spam
    case trash

    /// The place whose messages the list shows.
    var place: GmailPlace {
        switch self {
        case .spam: .spam
        case .trash: .trash
        default: .allMail
        }
    }
}

/// What the first quick fetch says about one message: who it is, where, its conversation, labels and flags.
struct GmailIndexEntry: Sendable, Equatable {
    var id: String
    var thread: String
    var uid: UInt32
    var date: Date
    var flags: [String]
    var labels: [String]

    var isUnread: Bool { !flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame } }
    var isStarred: Bool { flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame } }
}

/// Where a place is up to: its mailbox, UIDVALIDITY, highest UID and modification sequence, and how many messages it
/// had.
struct GmailPlaceState: Sendable, Equatable {
    var mailbox: String
    var uidValidity: UInt32
    var highestUID: UInt32
    var modSeq: UInt64?
    var count: Int
}

/// A Google account's mail kept on this Mac: one row per message, by Gmail's own message ID, with its conversation,
/// labels, flags, inbox tab, place and UID, and its list row (headers and snippet). Every list, page, count and
/// conversation comes from here without asking the server. Kept in an SQLite database in the account's folder.
actor GmailStore {
    static let fileName = "Mail.sqlite"

    private let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let log = Logger(subsystem: "com.pugglesoft.PMail", category: "Storage")
    /// Each place's state, kept in memory too: every row read needs its mailbox and UIDVALIDITY for its ID.
    private var places: [GmailPlace: GmailPlaceState] = [:]

    /// The store in a file, or in memory when `file` is nil (for tests).
    init(file: URL?) throws {
        let db = try SQLiteDatabase(file: file)
        try db.execute(Self.schema)
        var found: [GmailPlace: GmailPlaceState] = [:]
        try db.query("SELECT place, mailbox, uid_validity, highest_uid, modseq, count FROM places") { row in
            guard let place = row.text(0).flatMap(GmailPlace.init(rawValue:)), let mailbox = row.text(1) else { return }
            found[place] = GmailPlaceState(mailbox: mailbox, uidValidity: UInt32(truncatingIfNeeded: row.integer(2)),
                                           highestUID: UInt32(truncatingIfNeeded: row.integer(3)),
                                           modSeq: row.text(4).flatMap { UInt64($0) }, count: row.int(5))
        }
        self.db = db
        places = found
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY NOT NULL, thread TEXT NOT NULL, place TEXT NOT NULL,
            uid INTEGER NOT NULL, date REAL NOT NULL, unread INTEGER NOT NULL, starred INTEGER NOT NULL, category TEXT,
            has_headers INTEGER NOT NULL DEFAULT 0, has_snippet INTEGER NOT NULL DEFAULT 0, summary BLOB);
        CREATE INDEX IF NOT EXISTS messages_by_thread ON messages(thread);
        CREATE INDEX IF NOT EXISTS messages_by_place ON messages(place, uid);
        CREATE TABLE IF NOT EXISTS labels (label TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (label, id)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS labels_by_message ON labels(id);
        CREATE TABLE IF NOT EXISTS places (place TEXT PRIMARY KEY NOT NULL, mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL,
            highest_uid INTEGER NOT NULL, modseq TEXT, count INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
        """

    // MARK: Places

    func state(of place: GmailPlace) -> GmailPlaceState? { places[place] }

    func setState(_ state: GmailPlaceState, of place: GmailPlace) {
        places[place] = state
        keep("a place's state") {
            try db.run("INSERT OR REPLACE INTO places (place, mailbox, uid_validity, highest_uid, modseq, count) VALUES (?, ?, ?, ?, ?, ?)",
                       [.text(place.rawValue), .text(state.mailbox), .integer(Int64(state.uidValidity)), .integer(Int64(state.highestUID)),
                        .optionalText(state.modSeq.map(String.init)), .int(state.count)])
        }
    }

    /// Lets go of everything in a place (its UIDs mean nothing any more) and starts it over.
    func reset(_ place: GmailPlace) {
        places[place] = nil
        keep("a reset") {
            try db.transaction {
                try db.run("DELETE FROM labels WHERE id IN (SELECT id FROM messages WHERE place = ?)", [.text(place.rawValue)])
                try db.run("DELETE FROM messages WHERE place = ?", [.text(place.rawValue)])
                try db.run("DELETE FROM places WHERE place = ?", [.text(place.rawValue)])
            }
        }
    }

    /// How many messages the place has here.
    func count(in place: GmailPlace) -> Int {
        read("a count") { try db.integer("SELECT COUNT(*) FROM messages WHERE place = ? AND uid > 0", [.text(place.rawValue)]) } ?? 0
    }

    /// The place's UIDs here.
    func uids(in place: GmailPlace) -> Set<UInt32> {
        read("UIDs") {
            var found = Set<UInt32>()
            try db.query("SELECT uid FROM messages WHERE place = ? AND uid > 0", [.text(place.rawValue)]) { found.insert(UInt32(truncatingIfNeeded: $0.integer(0))) }
            return found
        } ?? []
    }

    // MARK: Keeping messages

    /// Keeps what the quick fetch said about messages in a place: new ones join (their headers still to come), known
    /// ones (by Gmail's ID, wherever they were) take the place, UID, flags and labels given. Returns the IDs of the
    /// messages that are new here.
    @discardableResult
    func keep(_ entries: [GmailIndexEntry], in place: GmailPlace) -> [String] {
        guard !entries.isEmpty else { return [] }
        var added: [String] = []
        keep("messages") {
            try db.transaction {
                for entry in entries {
                    let known = try db.integer("SELECT COUNT(*) FROM messages WHERE id = ?", [.text(entry.id)]) > 0
                    if known {
                        try db.run("UPDATE messages SET thread = ?, place = ?, uid = ?, date = ?, unread = ?, starred = ? WHERE id = ?",
                                   [.text(entry.thread), .text(place.rawValue), .integer(Int64(entry.uid)), .real(entry.date.timeIntervalSince1970),
                                    .int(entry.isUnread ? 1 : 0), .int(entry.isStarred ? 1 : 0), .text(entry.id)])
                    } else {
                        try db.run("""
                            INSERT INTO messages (id, thread, place, uid, date, unread, starred) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, [.text(entry.id), .text(entry.thread), .text(place.rawValue), .integer(Int64(entry.uid)),
                                  .real(entry.date.timeIntervalSince1970), .int(entry.isUnread ? 1 : 0), .int(entry.isStarred ? 1 : 0)])
                        added.append(entry.id)
                    }
                    try setLabels(entry.labels, of: entry.id)
                }
            }
        }
        return added
    }

    /// Flags and labels that changed for messages in a place, by UID. Labels are left alone when not given.
    func update(_ changes: [(uid: UInt32, flags: [String]?, labels: [String]?)], in place: GmailPlace) {
        guard !changes.isEmpty else { return }
        keep("changes") {
            try db.transaction {
                for change in changes {
                    guard let id = try messageID(at: change.uid, in: place) else { continue }
                    if let flags = change.flags {
                        let entry = GmailIndexEntry(id: id, thread: "", uid: change.uid, date: Date(), flags: flags, labels: [])
                        try db.run("UPDATE messages SET unread = ?, starred = ? WHERE id = ?",
                                   [.int(entry.isUnread ? 1 : 0), .int(entry.isStarred ? 1 : 0), .text(id)])
                    }
                    if let labels = change.labels { try setLabels(labels, of: id) }
                }
            }
        }
    }

    /// Lets go of a place's messages whose UIDs the server no longer has.
    func removeMissing(from place: GmailPlace, keeping present: Set<UInt32>) {
        let gone = uids(in: place).subtracting(present)
        guard !gone.isEmpty else { return }
        keep("deletions") {
            try db.transaction {
                for uid in gone {
                    guard let id = try messageID(at: uid, in: place) else { continue }
                    try removeRow(id)
                }
            }
        }
    }

    /// The list rows (headers) of messages, by Gmail ID.
    func keepHeaders(_ summaries: [String: MessageSummary]) {
        guard !summaries.isEmpty else { return }
        keep("headers") {
            try db.transaction {
                for (id, summary) in summaries {
                    try db.run("UPDATE messages SET summary = ?, has_headers = 1 WHERE id = ?", [.blob(try encoder.encode(summary)), .text(id)])
                }
            }
        }
    }

    /// Messages' snippets (and what their structure says: attachments, invitations), by Gmail ID.
    func keepSnippets(_ snippets: [String: (snippet: String, hasAttachments: Bool, isInvitation: Bool)]) {
        guard !snippets.isEmpty else { return }
        keep("snippets") {
            try db.transaction {
                for (id, found) in snippets {
                    guard var summary = try storedSummary(id) else { continue }
                    summary.snippet = found.snippet
                    summary.hasAttachments = found.hasAttachments
                    summary.isInvitation = found.isInvitation
                    try db.run("UPDATE messages SET summary = ?, has_snippet = 1 WHERE id = ?", [.blob(try encoder.encode(summary)), .text(id)])
                }
            }
        }
    }

    /// Inbox tabs for messages in All Mail, by UID. With `replacing` (a whole category searched again), messages it
    /// had that weren't found go back to none (Primary).
    func setCategory(_ category: String, forUIDs uids: Set<UInt32>, replacing: Bool) {
        keep("categories") {
            try db.transaction {
                if replacing {
                    try db.run("UPDATE messages SET category = NULL WHERE category = ? AND place = 'all'", [.text(category)])
                }
                for uid in uids {
                    try db.run("UPDATE messages SET category = ? WHERE place = 'all' AND uid = ?", [.text(category), .integer(Int64(uid))])
                }
            }
        }
    }

    // MARK: Changes made here

    /// Adds and takes away labels, here at once (the server's own answer comes with the next sync).
    func relabel(_ ids: [String], adding added: [String], removing removed: [String]) {
        keep("labels") {
            try db.transaction {
                for id in ids {
                    if !removed.isEmpty {
                        try db.run("DELETE FROM labels WHERE id = ? AND label IN (SELECT value FROM json_each(?))", [.text(id), .text(Self.json(removed))])
                    }
                    for label in added {
                        try db.run("INSERT OR IGNORE INTO labels (label, id) VALUES (?, ?)", [.text(label), .text(id)])
                    }
                }
            }
        }
    }

    func setUnread(_ unread: Bool, for ids: [String]) {
        keep("read marks") {
            try db.run("UPDATE messages SET unread = ? WHERE id IN (SELECT value FROM json_each(?))", [.int(unread ? 1 : 0), .text(Self.json(ids))])
        }
    }

    func setStarred(_ starred: Bool, for ids: [String]) {
        keep("stars") {
            try db.run("UPDATE messages SET starred = ? WHERE id IN (SELECT value FROM json_each(?))", [.int(starred ? 1 : 0), .text(Self.json(ids))])
        }
    }

    /// Messages moved to another place: there at once, their new UIDs to come with the next sync of it.
    func move(_ ids: [String], to place: GmailPlace) {
        keep("a move") {
            try db.run("UPDATE messages SET place = ?, uid = 0 WHERE id IN (SELECT value FROM json_each(?))",
                       [.text(place.rawValue), .text(Self.json(ids))])
        }
    }

    /// Messages deleted for good.
    func delete(_ ids: [String]) {
        keep("deletions") {
            try db.transaction { for id in ids { try removeRow(id) } }
        }
    }

    // MARK: What's missing

    /// UIDs in a place whose headers haven't come yet: the inbox's first, then the rest, newest first.
    func uidsMissingHeaders(in place: GmailPlace, limit: Int) -> [UInt32] {
        read("missing headers") {
            var found: [UInt32] = []
            try db.query("""
                SELECT m.uid FROM messages m WHERE m.place = ? AND m.uid > 0 AND m.has_headers = 0
                ORDER BY EXISTS (SELECT 1 FROM labels l WHERE l.id = m.id AND l.label = '\\Inbox') DESC, m.date DESC LIMIT ?
                """, [.text(place.rawValue), .int(limit)]) { found.append(UInt32(truncatingIfNeeded: $0.integer(0))) }
            return found
        } ?? []
    }

    /// Of these messages, the places and UIDs of those whose snippets haven't come yet.
    func missingSnippets(_ ids: [String]) -> [(id: String, place: GmailPlace, uid: UInt32)] {
        read("missing snippets") {
            var found: [(String, GmailPlace, UInt32)] = []
            try db.query("""
                SELECT id, place, uid FROM messages WHERE id IN (SELECT value FROM json_each(?)) AND has_snippet = 0 AND has_headers = 1 AND uid > 0
                """, [.text(Self.json(ids))]) { row in
                if let id = row.text(0), let place = row.text(1).flatMap(GmailPlace.init(rawValue:)) {
                    found.append((id, place, UInt32(truncatingIfNeeded: row.integer(2))))
                }
            }
            return found
        } ?? []
    }

    /// How many messages there are, and how many have their headers.
    func progress() -> (withHeaders: Int, total: Int) {
        read("progress") {
            (try db.integer("SELECT COUNT(*) FROM messages WHERE has_headers = 1"), try db.integer("SELECT COUNT(*) FROM messages"))
        } ?? (0, 0)
    }

    // MARK: Reading

    /// The UIDs these messages have in a place (those in it, with one).
    func uids(of ids: [String], in place: GmailPlace) -> [UInt32] {
        read("UIDs") {
            var found: [UInt32] = []
            try db.query("SELECT uid FROM messages WHERE id IN (SELECT value FROM json_each(?)) AND place = ? AND uid > 0",
                         [.text(Self.json(ids)), .text(place.rawValue)]) { found.append(UInt32(truncatingIfNeeded: $0.integer(0))) }
            return found
        } ?? []
    }

    /// Where these messages are, by Gmail ID.
    func places(of ids: [String]) -> [String: GmailPlace] {
        read("places") {
            var found: [String: GmailPlace] = [:]
            try db.query("SELECT id, place FROM messages WHERE id IN (SELECT value FROM json_each(?))", [.text(Self.json(ids))]) { row in
                if let id = row.text(0), let place = row.text(1).flatMap(GmailPlace.init(rawValue:)) { found[id] = place }
            }
            return found
        } ?? [:]
    }

    /// The Gmail ID of the message at a UID in a place.
    func id(at uid: UInt32, in place: GmailPlace) -> String? {
        read("an ID") { try messageID(at: uid, in: place) } ?? nil
    }

    /// The Gmail IDs of messages, from their list rows' IDs (where they were when listed).
    func ids(for summaries: [MessageSummary]) -> [String] {
        summaries.compactMap { summary in
            guard let place = IMAPMessageID(rawValue: summary.id) else { return nil }
            guard let found = places.first(where: { $0.value.mailbox == place.mailbox && $0.value.uidValidity == place.uidValidity })?.key else { return nil }
            return id(at: place.uid, in: found)
        }
    }

    /// A page of a list, newest conversation first, and how many conversations the list has. A conversation shows its
    /// messages in the list's place (All Mail's for every list but Spam and Trash) whose headers have come.
    func page(_ view: GmailView, offset: Int, limit: Int) -> (conversations: [Conversation], total: Int) {
        read("a list") {
            let (threads, values) = Self.threads(in: view)
            let place = view.place.rawValue
            let total = try db.integer("""
                SELECT COUNT(DISTINCT m.thread) FROM messages m WHERE m.place = ? AND m.has_headers = 1 AND m.thread IN (\(threads))
                """, [.text(place)] + values)
            var order: [String] = []
            try db.query("""
                SELECT m.thread, MAX(m.date) AS latest FROM messages m WHERE m.place = ? AND m.has_headers = 1 AND m.thread IN (\(threads))
                GROUP BY m.thread ORDER BY latest DESC, m.thread LIMIT ? OFFSET ?
                """, [.text(place)] + values + [.int(max(limit, 0)), .int(max(offset, 0))]) { row in
                if let thread = row.text(0) { order.append(thread) }
            }
            let messages = try rows("m.thread IN (SELECT value FROM json_each(?)) AND m.place = ? AND m.has_headers = 1",
                                    [.text(Self.json(order)), .text(place)])
            let byThread = Dictionary(grouping: messages, by: \.threadID)
            return (order.compactMap { thread in byThread[thread].map { Conversation(id: thread, messages: $0) } }, total)
        } ?? ([], 0)
    }

    /// A conversation's messages, oldest first: those in All Mail, or in Spam or Trash.
    func conversation(_ thread: String, in place: GmailPlace) -> [MessageSummary] {
        read("a conversation") { try rows("m.thread = ? AND m.place = ? AND m.has_headers = 1", [.text(thread), .text(place.rawValue)]) } ?? []
    }

    /// The list rows of messages at these UIDs in a place, with headers.
    func summaries(atUIDs uids: [UInt32], in place: GmailPlace) -> [MessageSummary] {
        read("list rows") {
            try rows("m.place = ? AND m.uid IN (SELECT value FROM json_each(?)) AND m.has_headers = 1",
                     [.text(place.rawValue), .text(Self.json(uids.map(String.init)))])
        } ?? []
    }

    /// Conversations in a list with an unread message.
    func unreadConversations(in view: GmailView) -> Int {
        read("an unread count") {
            let (threads, values) = Self.threads(in: view)
            return try db.integer("""
                SELECT COUNT(DISTINCT m.thread) FROM messages m WHERE m.place = ? AND m.unread = 1 AND m.thread IN (\(threads))
                """, [.text(view.place.rawValue)] + values)
        } ?? 0
    }

    /// Messages with a label (drafts, say).
    func messages(withLabel label: String) -> Int {
        read("a count") {
            try db.integer("SELECT COUNT(*) FROM labels l JOIN messages m ON m.id = l.id WHERE l.label = ? AND m.place = 'all'", [.text(label)])
        } ?? 0
    }

    /// Unread inbox messages under a tab.
    func unreadMessages(inTab tab: String) -> Int {
        read("an unread count") {
            try db.integer("""
                SELECT COUNT(*) FROM labels l JOIN messages m ON m.id = l.id
                WHERE l.label = '\\Inbox' AND m.place = 'all' AND m.unread = 1 AND \(Self.categoryCondition(tab, column: "m.category"))
                """, Self.categoryValues(tab))
        } ?? 0
    }

    /// New inbox messages, unread and not sent from the account, among these Gmail IDs.
    func newInboxMail(among ids: [String]) -> [MessageSummary] {
        read("new mail") {
            try rows("""
                m.id IN (SELECT value FROM json_each(?)) AND m.place = 'all' AND m.unread = 1 AND m.has_headers = 1
                AND EXISTS (SELECT 1 FROM labels l WHERE l.id = m.id AND l.label = '\\Inbox')
                AND NOT EXISTS (SELECT 1 FROM labels l WHERE l.id = m.id AND l.label IN ('\\Sent', '\\Draft'))
                """, [.text(Self.json(ids))])
        } ?? []
    }

    // MARK: Settings

    func setting(_ key: String) -> String? {
        read("a setting") {
            var value: String?
            try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { value = $0.text(0) }
            return value
        } ?? nil
    }

    func setSetting(_ key: String, _ value: String?) {
        keep("a setting") {
            if let value {
                try db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [.text(key), .text(value)])
            } else {
                try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
            }
        }
    }

    // MARK: Rows

    /// The conversations in a list (as SQL selecting thread IDs, with its values).
    private static func threads(in view: GmailView) -> (String, [SQLiteValue]) {
        switch view {
        case let .label(label):
            return ("SELECT x.thread FROM labels l JOIN messages x ON x.id = l.id WHERE l.label = ? AND x.place = 'all'", [.text(label)])
        case let .inboxTab(tab):
            return ("""
                SELECT x.thread FROM labels l JOIN messages x ON x.id = l.id
                WHERE l.label = '\\Inbox' AND x.place = 'all' AND \(categoryCondition(tab, column: "x.category"))
                """, categoryValues(tab))
        case .starred: return ("SELECT thread FROM messages WHERE place = 'all' AND starred = 1", [])
        case .allMail: return ("SELECT thread FROM messages WHERE place = 'all'", [])
        case .spam: return ("SELECT thread FROM messages WHERE place = 'spam'", [])
        case .trash: return ("SELECT thread FROM messages WHERE place = 'trash'", [])
        }
    }

    /// Primary holds the inbox's messages in no other category.
    private static func categoryCondition(_ tab: String, column: String) -> String {
        tab == "CATEGORY_PERSONAL" ? "(\(column) IS NULL OR \(column) = 'CATEGORY_PERSONAL')" : "\(column) = ?"
    }

    private static func categoryValues(_ tab: String) -> [SQLiteValue] {
        tab == "CATEGORY_PERSONAL" ? [] : [.text(tab)]
    }

    /// List rows for messages matching a condition on `m`, oldest first, with their IDs, flags and labels as they are now.
    private func rows(_ condition: String, _ values: [SQLiteValue]) throws -> [MessageSummary] {
        var found: [(id: String, summary: MessageSummary)] = []
        try db.query("""
            SELECT m.id, m.thread, m.place, m.uid, m.date, m.unread, m.starred, m.summary FROM messages m WHERE \(condition) ORDER BY m.date, m.id
            """, values) { row in
            guard let id = row.text(0), let thread = row.text(1), let place = row.text(2).flatMap(GmailPlace.init(rawValue:)),
                  let state = places[place] else { return }
            var summary = row.blob(7).flatMap { try? decoder.decode(MessageSummary.self, from: $0) } ?? MessageSummary(id: id)
            let uid = UInt32(truncatingIfNeeded: row.integer(3))
            summary.id = IMAPMessageID(mailbox: state.mailbox, uidValidity: state.uidValidity, uid: uid).rawValue
            summary.threadID = thread
            summary.folderID = state.mailbox
            summary.date = Date(timeIntervalSince1970: row.real(4))
            summary.isUnread = row.int(5) != 0
            summary.isStarred = row.int(6) != 0
            found.append((id, summary))
        }
        var labels: [String: [String]] = [:]
        try db.query("SELECT id, label FROM labels WHERE id IN (SELECT value FROM json_each(?))", [.text(Self.json(found.map(\.id)))]) { row in
            if let id = row.text(0), let label = row.text(1) { labels[id, default: []].append(label) }
        }
        return found.map { entry in
            var summary = entry.summary
            let raw = labels[entry.id] ?? []
            summary.labelIDs = IMAPMailService.gmailLabelIDs(raw)
            summary.isImportant = raw.contains("\\Important")
            summary.isDraft = raw.contains("\\Draft")
            return summary
        }
    }

    private func setLabels(_ labels: [String], of id: String) throws {
        try db.run("DELETE FROM labels WHERE id = ?", [.text(id)])
        for label in Set(labels) { try db.run("INSERT OR IGNORE INTO labels (label, id) VALUES (?, ?)", [.text(label), .text(id)]) }
    }

    private func removeRow(_ id: String) throws {
        try db.run("DELETE FROM labels WHERE id = ?", [.text(id)])
        try db.run("DELETE FROM messages WHERE id = ?", [.text(id)])
    }

    private func messageID(at uid: UInt32, in place: GmailPlace) throws -> String? {
        var found: String?
        try db.query("SELECT id FROM messages WHERE place = ? AND uid = ?", [.text(place.rawValue), .integer(Int64(uid))]) { found = $0.text(0) }
        return found
    }

    private func storedSummary(_ id: String) throws -> MessageSummary? {
        var found: MessageSummary?
        try db.query("SELECT summary FROM messages WHERE id = ?", [.text(id)]) { row in
            found = row.blob(0).flatMap { try? decoder.decode(MessageSummary.self, from: $0) }
        }
        return found
    }

    private static func json(_ values: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(values), as: UTF8.self)) ?? "[]"
    }

    private func keep(_ what: String, _ work: () throws -> Void) {
        do { try work() } catch { Self.log.error("Couldn’t keep \(what, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    private func read<T>(_ what: String, _ work: () throws -> T) -> T? {
        do { return try work() } catch {
            Self.log.error("Couldn’t read \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
