import Foundation

// Inbox categories on an IMAP account, sorted on this Mac.
extension IMAPMailService {
    /// What sorting fetches for an inbox message it hasn't sorted yet: the envelope (sender and subject) and the header
    /// fields that say whether it came from a list or a machine. No bodies.
    static let categoryIndexItems = "UID ENVELOPE BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED)]"

    /// A page of one inbox category, or nil when the request isn't for a category tab, searches, or lists another
    /// folder (those list as usual).
    ///
    /// The inbox's newest messages, up to `categoryIndex.limit`, are sorted once each by the rules (`InboxCategorizer`),
    /// from what `categoryIndexItems` fetches, so a listing only fetches the messages that arrived since the last one.
    /// Each message's sender is kept beside its category, so a category the person chooses for a sender applies straight
    /// away. Older messages aren't sorted: they're listed under Primary, so none go missing. The page is the category's
    /// messages, newest first, fetched the way other lists are, and the total counts them.
    /// Unread messages in each category of the inbox: the inbox sorted as for listing (only what isn't yet), then one
    /// search for what's unread.
    public func unreadCounts(inTabs tabs: [InboxTab]) async throws -> [String: Int] {
        guard let sorter, tabs.contains(where: { InboxCategory(tabID: $0.id) != nil }) else { return [:] }
        let chosen = await sorter.senderCategories()
        return try await withClient { client in
            let selected = try await client.select("INBOX", readOnly: true)
            let uidValidity = selected.uidValidity ?? 0
            var counts = Dictionary(uniqueKeysWithValues: InboxCategory.allCases.map { ($0.tabID, 0) })
            guard selected.exists > 0 else { return counts }
            let newestFirst = Array(Set(try await client.uidSearch([.all]))).sorted(by: >)
            try await self.sortInbox(newestFirst, uidValidity: uidValidity, client: client)
            let unread = Set(try await client.uidSearch([.unseen]))
            guard !unread.isEmpty else { return counts }
            for category in InboxCategory.allCases {
                counts[category.tabID] = self.categoryIndex.uids(in: category, newestFirst: newestFirst, chosen: chosen)
                    .filter(unread.contains).count
            }
            return counts
        }
    }

    func categoryPage(_ request: ListRequest) async throws -> ConversationPage? {
        guard let sorter, request.folderID == "INBOX", let category = InboxCategory(tabID: request.tabID),
              (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let chosen = await sorter.senderCategories()
        return try await withClient { client in
            // Opened again each time, so the list sees the inbox as it is now.
            let selected = try await client.select("INBOX", readOnly: true)
            let uidValidity = selected.uidValidity ?? 0
            let uids = selected.exists == 0 ? [] : try await client.uidSearch([.all])
            let newestFirst = Array(Set(uids)).sorted(by: >)
            try await self.sortInbox(newestFirst, uidValidity: uidValidity, client: client)
            let matching = self.categoryIndex.uids(in: category, newestFirst: newestFirst, chosen: chosen)
            let pageSize = max(1, request.pageSize)
            let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
            let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
            let start = overflowed ? matching.count : min(offset, matching.count)
            let end = start + min(pageSize, matching.count - start)
            let summaries = try await self.summaries(of: Array(matching[start..<end]), in: "INBOX", uidValidity: uidValidity,
                                                     client: client)
            return ConversationPage(conversations: Conversation.group(summaries), totalCount: matching.count,
                                    nextPageToken: end < matching.count ? String(pageIndex + 1) : nil)
        }
    }

    /// Sorts the inbox's newest messages (of `newestFirst`, its UIDs) that aren't sorted yet, newest first, a batch to a
    /// FETCH, and forgets the ones that have left. A new UIDVALIDITY starts the index over.
    func sortInbox(_ newestFirst: [UInt32], uidValidity: UInt32, client: IMAPClient) async throws {
        let window = newestFirst.prefix(max(0, categoryIndex.limit))
        categoryIndex.keep(Set(window), uidValidity: uidValidity)
        let unsorted = window.filter { categoryIndex.entries[$0] == nil }
        let batchSize = max(1, categoryIndex.batchSize)
        for start in stride(from: 0, to: unsorted.count, by: batchSize) {
            let batch = Array(unsorted[start..<min(start + batchSize, unsorted.count)])
            for response in try await client.uidFetch(batch, items: Self.categoryIndexItems) {
                guard let uid = response.uid else { continue }
                let message = Self.summary(from: response, id: IMAPMessageID(mailbox: "INBOX", uidValidity: uidValidity, uid: uid),
                                           snippet: "")
                categoryIndex.entries[uid] = IMAPCategoryIndex.Entry(category: InboxCategorizer.category(for: message),
                                                                     sender: InboxSorter.key(for: message.from?.email ?? ""))
            }
        }
    }

    /// Sets how many of the inbox's newest messages are sorted, and how many each FETCH takes, for tests.
    func setCategorySorting(limit: Int, batchSize: Int) {
        categoryIndex.limit = limit
        categoryIndex.batchSize = batchSize
    }

    /// What a message's header fields (lowercased names, as `IMAPHeaderFields.parse` gives them) say about its sender.
    nonisolated static func senderHints(from headers: [String: String]) -> SenderHints? {
        SenderHints(field: { headers[$0] })
    }
}

/// The inbox's messages as the category tabs sorted them, for one UIDVALIDITY: each message's category by the rules and
/// its sender, so a listing only fetches what it hasn't seen and a category chosen for a sender applies at once. It's
/// kept in memory: after a relaunch, the first category listing sorts the inbox again.
struct IMAPCategoryIndex: Sendable {
    struct Entry: Sendable, Hashable {
        /// The category the rules gave the message.
        var category: InboxCategory
        /// Its sender's address in lowercase ("" for none), for the person's choices.
        var sender: String
    }

    /// The most messages sorted: the inbox's newest. Older ones are listed under Primary.
    var limit = 2000
    /// How many messages one FETCH sorts.
    var batchSize = 250
    /// The inbox's UIDVALIDITY when its messages were sorted.
    var uidValidity: UInt32?
    var entries: [UInt32: Entry] = [:]

    /// Keeps only the entries for `uids`, or none when the inbox's UIDVALIDITY has changed (its UIDs name other
    /// messages now).
    mutating func keep(_ uids: Set<UInt32>, uidValidity: UInt32) {
        if self.uidValidity != uidValidity {
            entries = [:]
            self.uidValidity = uidValidity
        } else {
            entries = entries.filter { uids.contains($0.key) }
        }
    }

    /// The UIDs in a category, newest first: by the category chosen for the sender, else the rules'. Messages past the
    /// newest `limit` count as Primary.
    func uids(in category: InboxCategory, newestFirst: [UInt32], chosen: [String: InboxCategory]) -> [UInt32] {
        var result: [UInt32] = []
        for (index, uid) in newestFirst.enumerated() {
            if index >= limit {
                if category == .primary { result.append(uid) }
            } else if let entry = entries[uid], (chosen[entry.sender] ?? entry.category) == category {
                result.append(uid)
            }
        }
        return result
    }
}
