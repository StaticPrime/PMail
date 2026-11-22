import Foundation

// Labels on an IMAP account: IMAP keywords where the server allows them, else kept on this Mac in the label book.
//
// Label definitions (names and colors) are always in the book. A message has a label by carrying its keyword
// (`LabelKeyword`) in a mailbox whose writable SELECT lists `\*` among its PERMANENTFLAGS, or else by the book keeping
// the label for its Message-ID. A message's labels are read from both. Label keywords the server shows that the book
// doesn't know (made on another Mac) join it. Messages kept on this Mac carry their labels in the store's summaries.
extension IMAPMailService {
    /// The most messages kept in the book that a search inside a label looks up.
    static let labelLookupLimit = 200
    /// The most mailboxes renaming or deleting a label goes through.
    static let labelMailboxLimit = 200
    /// The folders kept on this Mac whose messages stay out of label lists, as Trash and Junk do on the server.
    static let keptSetAside: Set<String> = [LocalFolders.trashID, LocalFolders.spamID]

    /// One message with a label, found one way or another, for putting a label's list in order.
    struct LabelEntry: Sendable {
        enum Source: Sendable {
            /// A message whose summary is in hand.
            case found(MessageSummary)
            /// A message on the server, found by its keyword.
            case server(IMAPMessageID)
            /// A message the book keeps the label for, by Message-ID (as `LabelBook.key(forMessageID:)` gives it).
            case messageID(String)
        }

        var date: Date
        var source: Source
    }

    /// A page of a label's entries.
    struct LabelSlice: Sendable {
        var entries: [LabelEntry]
        /// How many entries the whole list has.
        var total: Int
        var hasMore: Bool
    }

    // MARK: Folders and lists

    /// The labels to list beside the folders: the book's, with any label keywords the selected mailbox's FLAGS name.
    func labelFolders(client: IMAPClient) async throws -> [MailFolder] {
        guard let labelBook else { return [] }
        if let flags = await client.selectedMailbox?.flags { await labelBook.discover(flags) }
        return await labelBook.folders()
    }

    /// Summaries from the selected mailbox with their labels as this Mac knows them (see `LabelBook.labeling`).
    func labeled(_ summaries: [MessageSummary], client: IMAPClient) async -> [MessageSummary] {
        guard let labelBook else { return summaries }
        return await labelBook.labeling(summaries, mailboxFlags: await client.selectedMailbox?.flags ?? [])
    }

    /// A page of the messages with a label, newest first, in conversations, or nil when the request isn't for a label.
    /// It gathers the messages kept on this Mac with the label, those the book keeps it for, and, unless the server has
    /// shown it doesn't take keywords, those UID SEARCH KEYWORD finds in All Mail (or else where `lookupOrder` looks:
    /// never Trash or Junk), ordered by when they arrived.
    func labelPage(_ request: ListRequest) async throws -> ConversationPage? {
        guard let labelBook, let requested = request.folderID, LabelKeyword.isLabel(requested),
              !(mailboxes ?? []).contains(where: { $0.name == requested }) else { return nil }
        let label = await labelBook.label(withID: requested)?.id ?? requested
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var entries: [LabelEntry] = []
        if let store = localFolders?.store {
            let kept = query.isEmpty ? await store.summaries(withLabel: label)
                : await store.search(query).filter { $0.labelIDs.contains(label) }
            for summary in kept where !Self.keptSetAside.contains(summary.folderID ?? "") {
                entries.append(LabelEntry(date: summary.date, source: .found(summary)))
            }
        }
        let keptKeys = Set(entries.compactMap { entry -> String? in
            guard case let .found(summary) = entry.source else { return nil }
            return LabelBook.key(forMessageID: summary.messageIDHeader)
        })
        let assigned = await labelBook.messages(withLabel: label).filter { !keptKeys.contains($0.key) }
        if query.isEmpty {
            entries += assigned.map { LabelEntry(date: $0.date, source: .messageID($0.key)) }
        } else if !assigned.isEmpty {
            // A search looks the newest of them up and keeps the ones that match.
            let words = IMAPSearchKey.words(in: query)
            for summary in try await findMessages(withMessageIDs: assigned.prefix(Self.labelLookupLimit).map(\.key))
            where Self.summary(summary, matches: words) {
                entries.append(LabelEntry(date: summary.date, source: .found(summary)))
            }
        }
        let pageSize = max(1, request.pageSize)
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let gathered = entries
        let paged: LabelSlice
        if await labelBook.keywordsAllowed() != false {
            paged = try await withClient { client in
                let found = try await self.keywordEntries(label, query: query, client: client)
                var slice = Self.slice(gathered + found, pageIndex: pageIndex, pageSize: pageSize)
                slice.entries = try await self.summarizingServerEntries(slice.entries, client: client)
                return slice
            }
        } else {
            // A server without keywords has nothing to search, so the page is made here.
            paged = Self.slice(gathered, pageIndex: pageIndex, pageSize: pageSize)
        }
        let picked = paged.entries
        // Messages known only by their Message-ID are looked up wherever they are now.
        let keys = picked.compactMap { entry -> String? in
            guard case let .messageID(key) = entry.source else { return nil }
            return key
        }
        var byKey: [String: MessageSummary] = [:]
        if !keys.isEmpty {
            for summary in try await findMessages(withMessageIDs: keys) {
                if let key = LabelBook.key(forMessageID: summary.messageIDHeader), byKey[key] == nil { byKey[key] = summary }
            }
        }
        var summaries: [MessageSummary] = []
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        for entry in picked {
            let summary: MessageSummary?
            switch entry.source {
            case let .found(found): summary = found
            case let .messageID(key): summary = byKey[key]
            case .server: summary = nil
            }
            guard let summary, seenIDs.insert(summary.id).inserted else { continue }
            // The same message found twice (in two mailboxes, or by keyword and in the book) shows once.
            if let key = LabelBook.key(forMessageID: summary.messageIDHeader), !seenKeys.insert(key).inserted { continue }
            summaries.append(summary)
        }
        return ConversationPage(conversations: Conversation.group(summaries), totalCount: paged.total,
                                nextPageToken: paged.hasMore ? String(pageIndex + 1) : nil)
    }

    /// One page of a label's entries, newest first, with how many there are in all.
    static func slice(_ entries: [LabelEntry], pageIndex: Int, pageSize: Int) -> LabelSlice {
        let ordered = newestFirst(entries)
        let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
        let start = overflowed ? ordered.count : min(offset, ordered.count)
        let end = start + min(pageSize, ordered.count - start)
        return LabelSlice(entries: Array(ordered[start..<end]), total: ordered.count, hasMore: end < ordered.count)
    }

    /// The messages on the server with a label's keyword (and matching a search), with when they arrived.
    func keywordEntries(_ label: String, query: String, client: IMAPClient) async throws -> [LabelEntry] {
        let boxes = try await knownMailboxes(client: client)
        var entries: [LabelEntry] = []
        for mailbox in Self.labelSearchOrder(boxes) {
            let selected: IMAPSelectedMailbox
            do {
                selected = try await client.select(mailbox, readOnly: true)
            } catch PMailError.server {
                continue  // Gone since the last LIST, or not open to this account.
            }
            if let labelBook { await labelBook.discover(selected.flags) }
            guard selected.exists > 0 else { continue }
            let uids = try await client.uidSearch([.keyword(label)] + IMAPSearchKey.matching(query: query))
            guard !uids.isEmpty else { continue }
            let uidValidity = selected.uidValidity ?? 0
            for response in try await client.uidFetch(uids, items: "UID INTERNALDATE") {
                guard let uid = response.uid else { continue }
                let id = IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: uid)
                entries.append(LabelEntry(date: response.internalDate ?? Date(timeIntervalSince1970: 0), source: .server(id)))
            }
        }
        return entries
    }

    /// The page's messages on the server as summaries, fetched mailbox by mailbox, leaving out any gone since.
    func summarizingServerEntries(_ page: [LabelEntry], client: IMAPClient) async throws -> [LabelEntry] {
        let onServer = page.compactMap { entry -> IMAPMessageID? in
            guard case let .server(id) = entry.source else { return nil }
            return id
        }
        var found: [String: MessageSummary] = [:]
        for (mailbox, ids) in Self.grouped(onServer, by: { $0.mailbox }) {
            let selected = try await ensureSelected(mailbox, writable: false, client: client)
            let uidValidity = selected.uidValidity ?? 0
            let uids = ids.filter { $0.uidValidity == uidValidity }.map(\.uid)
            for summary in try await summaries(of: uids, in: mailbox, uidValidity: uidValidity, client: client) {
                found[summary.id] = summary
            }
        }
        return page.compactMap { entry in
            guard case let .server(id) = entry.source else { return entry }
            return found[id.rawValue].map { LabelEntry(date: entry.date, source: .found($0)) }
        }
    }

    /// Where a label's messages are searched for: All Mail when the server has one (it holds everything outside Trash
    /// and Junk), else where `lookupOrder` looks.
    static func labelSearchOrder(_ boxes: [IMAPMailbox], limit: Int = lookupMailboxLimit) -> [String] {
        let roles = IMAPFolderRoles.assign(boxes)
        if let all = boxes.first(where: { $0.isSelectable && roles[$0.name] == .allMail }) { return [all.name] }
        return lookupOrder(boxes, limit: limit)
    }

    /// Where renaming or deleting a label changes its keyword: where it's searched for, then Trash and Junk.
    static func labelMaintenanceOrder(_ boxes: [IMAPMailbox]) -> [String] {
        let roles = IMAPFolderRoles.assign(boxes)
        var order = labelSearchOrder(boxes, limit: labelMailboxLimit)
        for box in boxes where box.isSelectable && [.trash, .spam].contains(roles[box.name]) && !order.contains(box.name) {
            order.append(box.name)
        }
        return order
    }

    /// Entries newest first, keeping the order they were found in for ones from the same moment.
    static func newestFirst(_ entries: [LabelEntry]) -> [LabelEntry] {
        entries.enumerated().sorted { first, second in
            first.element.date != second.element.date ? first.element.date > second.element.date : first.offset < second.offset
        }.map(\.element)
    }

    /// Whether a message's subject, people or snippet hold every word, ignoring case and accents.
    static func summary(_ summary: MessageSummary, matches words: [String]) -> Bool {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        var fields = [summary.subject, summary.snippet]
        for address in [summary.from].compactMap({ $0 }) + summary.to + summary.cc {
            fields += [address.name ?? "", address.email]
        }
        let haystack = folded(fields.joined(separator: " "))
        return words.allSatisfy { haystack.contains(folded($0)) }
    }

    // MARK: Labeling messages

    /// Adds or removes a label (`.addLabel`, `.removeLabel`): on messages kept on this Mac, in the store; on the
    /// server, as the label's keyword in mailboxes that take keywords, else in the book by Message-ID.
    func applyLabel(_ action: MailAction, to messages: [MessageSummary]) async throws {
        guard let labelBook else { throw PMailError.notSupported("This account doesn’t have labels.") }
        let requested: String
        let adding: Bool
        switch action {
        case let .addLabel(id): (requested, adding) = (id, true)
        case let .removeLabel(id): (requested, adding) = (id, false)
        default: return
        }
        guard LabelKeyword.isLabel(requested) else { throw PMailError.notFound }
        if adding { await labelBook.discover([requested]) }
        let known = await labelBook.label(withID: requested)?.id
        // A deleted label isn't put on anything again.
        if adding && known == nil { throw PMailError.notFound }
        let label = known ?? requested
        let kept = messages.filter { IMAPMessageID(rawValue: $0.id) == nil }
        if let store = localFolders?.store, !kept.isEmpty {
            try await store.setLabel(label, adding, for: kept.map(\.id))
            if !adding { try await labelBook.unassign(label, from: kept) }
        }
        let onServer = messages.compactMap { summary in IMAPMessageID(rawValue: summary.id).map { (summary, $0) } }
        guard !onServer.isEmpty else { return }
        try await withClient { client in
            var skipped = false
            var unkeyed = 0
            for (mailbox, group) in Self.grouped(onServer, by: { $0.1.mailbox }) {
                let selected = try await self.ensureSelected(mailbox, writable: true, client: client)
                // UIDs from before the mailbox's UIDVALIDITY changed would point at other messages.
                let current = group.filter { $0.1.uidValidity == (selected.uidValidity ?? 0) }
                if current.count < group.count { skipped = true }
                guard !current.isEmpty else { continue }
                // A server known to drop label keywords keeps its labels in the book, whatever it says it takes.
                let ignored = await labelBook.keywordsIgnored()
                let takesKeywords = Self.takesKeywords(selected) && !ignored
                // A mailbox the server only opens read-only says nothing about what it takes elsewhere.
                if !selected.isReadOnly { try await labelBook.noteKeywords(allowed: Self.takesKeywords(selected)) }
                if takesKeywords, adding {
                    let after = try await client.uidStoreReportingFlags(current.map { $0.1.uid }, adding: true, flags: [label])
                    // A server can say it takes keywords and still not keep them: what didn't stay goes in the book,
                    // and so does every label from now on, so a label always lists its conversations.
                    let dropped = current.filter { pair in
                        !(after[pair.1.uid] ?? []).contains { $0.caseInsensitiveCompare(label) == .orderedSame }
                    }
                    if !dropped.isEmpty {
                        try await labelBook.noteKeywordsIgnored()
                        unkeyed += try await labelBook.assign(label, to: try await self.withMessageIDs(dropped, client: client))
                    }
                } else if takesKeywords {
                    try await client.uidStore(current.map { $0.1.uid }, adding: adding, flags: [label])
                    // Kept in the book from before (from a mailbox that didn't take keywords), it goes from there too.
                    try await labelBook.unassign(label, from: current.map { $0.0 })
                } else if adding {
                    unkeyed += try await labelBook.assign(label, to: try await self.withMessageIDs(current, client: client))
                } else {
                    try await labelBook.unassign(label, from: try await self.withMessageIDs(current, client: client))
                }
            }
            if skipped { throw PMailError.notFound }
            if unkeyed > 0 { throw PMailError.notSupported("A message without a Message-ID can’t be labeled on this server.") }
        }
    }

    /// Whether a mailbox opened to change flags takes keywords of PMail's choosing (`\*` among its PERMANENTFLAGS).
    /// A mailbox opened read-only never says, so it doesn't count.
    static func takesKeywords(_ selected: IMAPSelectedMailbox) -> Bool {
        !selected.isReadOnly && selected.permanentFlags.contains("\\*")
    }

    /// The summaries with their Message-IDs, fetched from the selected mailbox for any that came without one.
    func withMessageIDs(_ group: [(MessageSummary, IMAPMessageID)], client: IMAPClient) async throws -> [MessageSummary] {
        let missing = group.filter { $0.0.messageIDHeader == nil }.map { $0.1.uid }
        var headers: [UInt32: String] = [:]
        if !missing.isEmpty {
            for response in try await client.uidFetch(missing, items: "UID ENVELOPE") {
                if let uid = response.uid, let messageID = response.envelope?.messageID { headers[uid] = messageID }
            }
        }
        return group.map { pair in
            var summary = pair.0
            if summary.messageIDHeader == nil { summary.messageIDHeader = headers[pair.1.uid] }
            return summary
        }
    }

    /// The label IDs a message's flags carry: its label keywords, as the server spells them.
    nonisolated static func keywordLabelIDs(_ flags: [String]?) -> [String] {
        var labels: [String] = []
        for flag in flags ?? [] where LabelKeyword.isLabel(flag) && !labels.contains(where: { LabelKeyword.same($0, flag) }) {
            labels.append(flag)
        }
        return labels
    }

    // MARK: Making, changing and deleting labels

    /// Makes a label. It's kept in the book; the server only hears of it once a message has it.
    public func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        guard let labelBook else { throw PMailError.notSupported("This account can’t make labels.") }
        return try await labelBook.create(named: name, colorHex: colorHex).folder
    }

    /// Renames or recolors a label (a nil color leaves its color as it is). A new name is a new keyword: its messages on
    /// the server get the new keyword in place of the old, and those kept on this Mac or in the book move to it too.
    public func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        guard let labelBook else { throw PMailError.notSupported("This account can’t change labels.") }
        guard let current = await labelBook.label(withID: label.id) else { throw PMailError.notFound }
        let newID = try await labelBook.renamedID(current.id, to: name)
        if newID != current.id {
            if await labelBook.keywordsAllowed() != false { try await retag(current.id, to: newID) }
            try await localFolders?.store.replaceLabel(current.id, with: newID)
        }
        return try await labelBook.update(current.id, name: name, colorHex: colorHex).folder
    }

    /// Deletes a label: its keyword comes off its messages on the server, and it goes from those kept on this Mac and
    /// from the book.
    public func deleteLabel(_ label: MailFolder) async throws {
        guard let labelBook else { throw PMailError.notSupported("This account can’t delete labels.") }
        guard let current = await labelBook.label(withID: label.id) else { return }
        if await labelBook.keywordsAllowed() != false { try await retag(current.id, to: nil) }
        try await localFolders?.store.replaceLabel(current.id, with: nil)
        try await labelBook.remove(current.id)
    }

    /// Changes a label's keyword on every message on the server that has it, mailbox by mailbox (Trash and Junk too):
    /// to `new`, or off them when `new` is nil.
    func retag(_ old: String, to new: String?) async throws {
        try await withClient { client in
            let boxes = try await self.knownMailboxes(client: client)
            for mailbox in Self.labelMaintenanceOrder(boxes) {
                let selected: IMAPSelectedMailbox
                do {
                    selected = try await client.select(mailbox, readOnly: true)
                } catch PMailError.server {
                    continue
                }
                guard selected.exists > 0 else { continue }
                let uids = try await client.uidSearch([.keyword(old)])
                guard !uids.isEmpty else { continue }
                // A mailbox the server only opens read-only can't change, so it's left as it is.
                guard try await !client.select(mailbox, readOnly: false).isReadOnly else { continue }
                if let new { try await client.uidStore(uids, adding: true, flags: [new]) }
                try await client.uidStore(uids, adding: false, flags: [old])
            }
        }
    }

    // MARK: Messages kept on this Mac

    /// Gives a message just kept on this Mac the labels it had on the server: its label keywords and those the book
    /// keeps for it.
    func keepLabels(_ flags: [String]?, of summary: MessageSummary, in store: LocalMailStore) async throws {
        guard let labelBook else { return }
        let labels = await labelBook.labels(forKeywords: Self.keywordLabelIDs(flags), messageID: summary.messageIDHeader)
        if !labels.isEmpty { try await store.setLabelIDs(labels, for: [summary.id]) }
    }

    /// The label keywords to upload a message kept on this Mac with, when the server takes keywords; otherwise the book
    /// keeps its labels, by Message-ID, so they stay with it.
    func labelFlags(forUploading summary: MessageSummary) async throws -> [String] {
        guard let labelBook, !summary.labelIDs.isEmpty else { return [] }
        if await labelBook.keywordsAllowed() == true { return summary.labelIDs.filter(LabelKeyword.isLabel) }
        try await labelBook.assign(summary.labelIDs, to: summary)
        return []
    }
}
