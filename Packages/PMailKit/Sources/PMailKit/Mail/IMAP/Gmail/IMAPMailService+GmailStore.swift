import Foundation

/// A Google account's lists, conversations, counts and changes, from and to the mail kept on this Mac
/// (`GmailStore`): lists never ask the server; a search does (Gmail's own search, in All Mail), and opening a
/// conversation fetches the text of messages not opened before.
extension IMAPMailService {
    // MARK: Lists

    /// A page of a list from the store, or of a search from Gmail's own search with its rows from the store.
    func gmailStorePage(_ request: ListRequest, store: GmailStore) async throws -> ConversationPage {
        let pageSize = max(1, request.pageSize)
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty { return try await gmailSearchPage(query, pageIndex: pageIndex, pageSize: pageSize, store: store) }
        let view = try await gmailView(for: request.folderID, tab: request.tabID)
        let page = await store.page(view, offset: pageIndex * pageSize, limit: pageSize + max(request.extra, 0))
        gmailFillSnippets(for: page.conversations)
        return ConversationPage(conversations: page.conversations, totalCount: page.total,
                                nextPageToken: (pageIndex + 1) * pageSize < page.total ? String(pageIndex + 1) : nil)
    }

    /// The list a folder (and, for the inbox, a tab) shows.
    func gmailView(for folderID: String?, tab: String?) async throws -> GmailView {
        guard let folderID else { return .allMail }
        if folderID == "INBOX" {
            if let tab, Self.gmailCategorySearch(tab) != nil { return .inboxTab(tab) }
            return .label("\\Inbox")
        }
        let roles = Self.gmailRoles(try await withClient { client in try await self.knownMailboxes(client: client) })
        switch roles[folderID] {
        case .starred?: return .starred
        case .important?: return .label("\\Important")
        case .sent?: return .label("\\Sent")
        case .drafts?: return .label("\\Draft")
        case .allMail?: return .allMail
        case .spam?: return .spam
        case .trash?: return .trash
        default: return .label(folderID)
        }
    }

    /// A page of what Gmail's own search finds in All Mail, newest first, as conversations of the messages found. Rows
    /// come from the store; messages it doesn't have yet are fetched and kept.
    func gmailSearchPage(_ query: String, pageIndex: Int, pageSize: Int, store: GmailStore) async throws -> ConversationPage {
        guard let allMail = await store.state(of: .allMail) else { return ConversationPage(conversations: []) }
        let newestFirst = try await withClient { client -> [UInt32] in
            let selected = try await self.ensureSelected(allMail.mailbox, writable: false, client: client)
            return selected.exists == 0 ? [] : Array(Set(try await client.uidSearch([.gmailSearch(query)]))).sorted(by: >)
        }
        let start = min(pageIndex * pageSize, newestFirst.count)
        let pageUIDs = Array(newestFirst[start..<min(start + pageSize, newestFirst.count)])
        var rows = await store.summaries(atUIDs: pageUIDs, in: .allMail)
        let have = Set(rows.compactMap { IMAPMessageID(rawValue: $0.id)?.uid })
        let missing = pageUIDs.filter { !have.contains($0) }
        if !missing.isEmpty {
            let fetched = try await withClient { client -> [IMAPFetchResponse] in
                _ = try await self.ensureSelected(allMail.mailbox, writable: false, client: client)
                return try await client.uidFetch(missing, items: Self.gmailIndexItems + " " + String(Self.gmailHeaderItems.dropFirst("UID ".count)))
            }
            await store.keep(fetched.compactMap(Self.gmailIndexEntry), in: .allMail)
            var headers: [String: MessageSummary] = [:]
            for response in fetched {
                if let id = response.gmailMessageID { headers[id] = Self.gmailSummary(fromHeaders: response) }
            }
            await store.keepHeaders(headers)
            rows = await store.summaries(atUIDs: pageUIDs, in: .allMail)
        }
        let conversations = Conversation.group(rows)
        gmailFillSnippets(for: conversations)
        return ConversationPage(conversations: conversations, totalCount: newestFirst.count,
                                nextPageToken: start + pageSize < newestFirst.count ? String(pageIndex + 1) : nil)
    }

    // MARK: Conversations

    /// A whole conversation from the store, with the text of its messages: kept from opening it before where that's
    /// given, else fetched (and nothing else asked). Nil when the store doesn't have it (it opens the usual way).
    func gmailStoreConversation(id: String, hint: Conversation?, known: [MailMessage], store: GmailStore) async throws -> [MailMessage]? {
        guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        // A conversation listed in Spam or Trash shows its messages there.
        let listedIn = hint?.messages.compactMap { IMAPMessageID(rawValue: $0.id)?.mailbox }.first
        var place = GmailPlace.allMail
        for candidate in [GmailPlace.spam, .trash] where await store.state(of: candidate)?.mailbox == listedIn { place = candidate }
        let summaries = await store.conversation(id, in: place)
        guard !summaries.isEmpty else { return nil }
        let kept = Dictionary(known.filter { $0.htmlBody != nil || $0.textBody != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var messages: [MailMessage] = []
        var missing: [MessageSummary] = []
        for summary in summaries {
            if var message = kept[summary.id] {
                message.summary = summary
                messages.append(message)
            } else {
                missing.append(summary)
            }
        }
        if !missing.isEmpty {
            messages += try await withClient { client -> [MailMessage] in
                var fetched: [MailMessage] = []
                let places = missing.compactMap { summary in IMAPMessageID(rawValue: summary.id).map { (summary, $0) } }
                for (mailbox, group) in Self.grouped(places, by: { $0.1.mailbox }) {
                    let selected = try await self.ensureSelected(mailbox, writable: false, client: client)
                    var byUID: [UInt32: MessageSummary] = [:]
                    for (summary, place) in group where place.uid > 0 && place.uidValidity == (selected.uidValidity ?? 0) {
                        byUID[place.uid] = summary
                    }
                    for response in try await client.fetchMessages(byUID.keys.sorted()) {
                        guard let uid = response.uid, let summary = byUID[uid], let raw = response.section("") else { continue }
                        fetched.append(MIMEParser.parse(raw).mailMessage(summary: summary, rawSource: raw))
                    }
                }
                return fetched
            }
        }
        return messages.isEmpty ? nil : messages.sorted { $0.summary.date < $1.summary.date }
    }

    // MARK: Changes made here

    /// Shows an action in the store at once, the way Gmail will have it (the next sync brings the server's own word).
    func gmailApplyLocally(_ action: MailAction, to messages: [MessageSummary], roles: [String: FolderRole]) async {
        guard let store = gmailStore else { return }
        let ids = await store.ids(for: messages)
        // Messages the store doesn't place (found by a search elsewhere, say) come right with a sync.
        if ids.count < messages.count { gmailSyncSoon() }
        guard !ids.isEmpty else { return }
        let places = await store.places(of: ids)
        let outOfTrashOrSpam = ids.filter { places[$0] == .trash || places[$0] == .spam }
        let inTrash = ids.filter { places[$0] == .trash }
        switch action {
        case .markRead: await store.setUnread(false, for: ids)
        case .markUnread: await store.setUnread(true, for: ids)
        case .star: await store.setStarred(true, for: ids)
        case .unstar: await store.setStarred(false, for: ids)
        case .markImportant: await store.relabel(ids, adding: ["\\Important"], removing: [])
        case .markNotImportant: await store.relabel(ids, adding: [], removing: ["\\Important"])
        case .archive:
            await store.relabel(ids, adding: [], removing: ["\\Inbox"])
            await store.move(outOfTrashOrSpam, to: .allMail)
        case .moveToInbox, .notSpam:
            await store.relabel(ids, adding: ["\\Inbox"], removing: [])
            await store.move(outOfTrashOrSpam, to: .allMail)
        case .markSpam:
            await store.move(ids.filter { places[$0] != .spam }, to: .spam)
        case .trash:
            await store.delete(inTrash)
            await store.move(ids.filter { places[$0] != .trash }, to: .trash)
        case .deleteForever:
            await store.delete(outOfTrashOrSpam)
            await store.move(ids.filter { places[$0] == .allMail }, to: .trash)
        case let .addLabel(label): await store.relabel(ids, adding: [label], removing: [])
        case let .removeLabel(label): await store.relabel(ids, adding: [], removing: [label])
        case let .move(folderID):
            switch roles[folderID] {
            case .inbox?: await gmailApplyLocally(.moveToInbox, to: messages, roles: roles)
            case .trash?: await gmailApplyLocally(.trash, to: messages, roles: roles)
            case .spam?: await gmailApplyLocally(.markSpam, to: messages, roles: roles)
            case .allMail?: await gmailApplyLocally(.archive, to: messages, roles: roles)
            case .starred?: await gmailApplyLocally(.star, to: messages, roles: roles)
            case .important?: await gmailApplyLocally(.markImportant, to: messages, roles: roles)
            case .sent?, .drafts?: return
            default:
                await store.relabel(ids, adding: [folderID], removing: ["\\Inbox"])
                await store.move(outOfTrashOrSpam, to: .allMail)
            }
        }
        gmailNotify(.changed)
    }

    // MARK: New mail

    /// A check for new mail with the store: a sync, then the new inbox mail it found.
    func gmailCheckForNewMail(store: GmailStore) async throws -> NewMail {
        try await syncGmail()
        let fresh = gmailSync.unannounced.sorted { $0.date < $1.date }.suffix(Self.newMailLimit)
        gmailSync.unannounced = []
        let state = await store.state(of: .allMail)
        let unread = await store.unreadConversations(in: .label("\\Inbox"))
        return NewMail(messages: Array(fresh), state: MailSyncState("gmail:\(state?.uidValidity ?? 0):\(state?.highestUID ?? 0)"),
                       inboxUnread: unread)
    }

    /// After something PMail itself put on the server (a sent message, a saved draft): a sync soon brings it in.
    func gmailSyncSoon() {
        guard gmailStore != nil else { return }
        Task { try? await self.syncGmail() }
    }

    // MARK: Counts

    /// Unread conversations for a folder the way Gmail counts them (Drafts counts its drafts), from the store.
    func gmailStoreCounts(for folderID: String, role: FolderRole?, store: GmailStore) async -> (unread: Int, total: Int?) {
        switch role {
        case .inbox?: return (await store.unreadConversations(in: .label("\\Inbox")), nil)
        case .spam?: return (await store.unreadConversations(in: .spam), nil)
        case .drafts?:
            let drafts = await store.messages(withLabel: "\\Draft")
            return (drafts, drafts)
        case nil: return (await store.unreadConversations(in: .label(folderID)), nil)
        default: return (0, nil)
        }
    }
}
