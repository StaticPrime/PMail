import Foundation

/// What a Google account's sync keeps between calls.
struct GmailSyncState {
    /// Who hears about changes to the mail kept on this Mac.
    var watchers: [@Sendable (MailCopyEvent) -> Void] = []
    var started = false
    var isSyncing = false
    /// Asked to sync while syncing: once more after.
    var syncAgain = false
    /// New inbox mail a sync found, for the next check to announce.
    var unannounced: [MessageSummary] = []
    /// Messages whose snippets are being fetched.
    var fetchingSnippets: Set<String> = []
}

/// Keeping a Google account's mail on this Mac in step with Gmail, over IMAP (see `GmailStore`). Gmail keeps every
/// message but spam and the trash in All Mail, each with its own ID and its labels, so three mailboxes make the whole
/// account: All Mail, Spam and Trash. Each sync of one:
///
/// 1. Opens it with CONDSTORE: when its UIDVALIDITY, next UID, message count and highest modification sequence are as
///    they were, nothing has changed, and that's the whole sync.
/// 2. Fetches what identifies each message added since the highest UID kept (Gmail's message and conversation IDs,
///    labels, flags, arrival), and the flags and labels of every message changed since the modification sequence
///    kept. The first time, that's every message, in one small fetch.
/// 3. Once every mailbox has been looked at, asks for the whole list of UIDs only where the counts disagree, and lets
///    go of messages no longer there (a message moved between them keeps its row: the mailbox it went to has it).
///
/// Then the inbox's new mail is sorted into the category tabs with Gmail's own search, and the headers of messages
/// that don't have them yet come in batches, the inbox's first and the newest first, each batch showing in the lists as
/// it arrives. Snippets come in the background for the conversations listed. Syncs run on the connection for
/// background work, never in the way of what the person does.
extension IMAPMailService {
    /// What a sync fetches to know each message.
    static let gmailIndexItems = "UID X-GM-MSGID X-GM-THRID X-GM-LABELS FLAGS INTERNALDATE"
    /// The header fields a list row needs.
    static let gmailHeaderItems = "UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REFERENCES "
        + "IN-REPLY-TO CONTENT-TYPE LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED X-SPAM-FLAG X-SPAM-STATUS X-SPAM)]"
    /// The most headers fetched at once.
    static let gmailHeaderBatch = 500
    /// How often every message's inbox tab is looked up again (between, only new mail's is).
    static let gmailCategoryRefresh: TimeInterval = 6 * 3600

    // MARK: Watching and starting

    public func watchLocalCopy(_ update: @escaping @Sendable (MailCopyEvent) -> Void) async {
        gmailSync.watchers.append(update)
    }

    /// The store, unless the account hides All Mail from IMAP (then everything comes from the server, as without one).
    func usableGmailStore() async -> GmailStore? {
        guard isGmail, let gmailStore, await gmailStore.setting("noAllMail") == nil else { return nil }
        return gmailStore
    }

    func gmailNotify(_ event: MailCopyEvent) {
        for watcher in gmailSync.watchers { watcher(event) }
    }

    func gmailReportProgress(downloading: Bool) async {
        guard let store = gmailStore else { return }
        let progress = await store.progress()
        gmailNotify(.progress(MailDownloadProgress(downloaded: progress.withHeaders, total: progress.total, isDownloading: downloading)))
    }

    public func startDownloading(inboxTab: String?) async {
        guard gmailStore != nil, !gmailSync.started else { return }
        gmailSync.started = true
        Task { try? await self.syncGmail() }
    }

    public func waitUntilDownloaded(folderIDs: [String]) async {
        guard let store = gmailStore else { return }
        // Looked at every two seconds, for up to two hours.
        for _ in 0..<3_600 {
            if await store.setting("downloaded") != nil || Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Syncing

    /// Brings the mail kept on this Mac in step with Gmail. Asked while a sync is under way, it has that one sync once
    /// more after. New inbox mail found (on any sync but the first) waits in `unannounced` for the next check.
    func syncGmail() async throws {
        guard let store = gmailStore else { return }
        if gmailSync.isSyncing {
            gmailSync.syncAgain = true
            return
        }
        gmailSync.isSyncing = true
        defer { gmailSync.isSyncing = false }
        repeat {
            gmailSync.syncAgain = false
            let firstTime = await store.setting("downloaded") == nil
            if firstTime { await gmailReportProgress(downloading: true) }
            let added = try await BackgroundWork.run { try await self.gmailSyncPass(store) }
            if firstTime {
                await store.setSetting("downloaded", String(Date().timeIntervalSince1970))
            } else if !added.isEmpty {
                gmailSync.unannounced += await store.newInboxMail(among: added)
            }
            await gmailReportProgress(downloading: false)
            gmailNotify(.changed)
        } while gmailSync.syncAgain
    }

    /// One pass over All Mail, Spam and Trash, then the tabs and the missing headers. Returns the messages new to this
    /// Mac.
    func gmailSyncPass(_ store: GmailStore) async throws -> [String] {
        let roles = Self.gmailRoles(try await withClient { client in try await self.knownMailboxes(client: client) })
        func mailbox(_ place: GmailPlace) -> String? {
            let role: FolderRole = switch place {
            case .allMail: .allMail
            case .spam: .spam
            case .trash: .trash
            }
            return roles.first { $0.value == role }?.key
        }
        // An account that hides All Mail from IMAP (Gmail's label settings) can't be kept here: it lists from the
        // server instead.
        guard mailbox(.allMail) != nil else {
            await store.setSetting("noAllMail", "1")
            return []
        }
        if await store.setting("noAllMail") != nil { await store.setSetting("noAllMail", nil) }
        // Spam and Trash before All Mail once there's a copy, so a message moved out of All Mail is where it went
        // before All Mail lets it go; the first time, All Mail first, for the inbox.
        let order: [GmailPlace] = await store.state(of: .allMail) == nil ? [.allMail, .spam, .trash] : [.spam, .trash, .allMail]
        var added: [String] = []
        var counts: [GmailPlace: (mailbox: String, exists: Int)] = [:]
        for place in order {
            guard let name = mailbox(place) else { continue }
            let result = try await gmailSyncIndex(place, mailbox: name, store: store)
            added += result.added
            if let exists = result.exists { counts[place] = (name, exists) }
        }
        // Messages gone from a mailbox, where its count says some went.
        for place in order {
            guard let (name, exists) = counts[place], await store.count(in: place) != exists else { continue }
            let present = try await withClient { client -> [UInt32] in
                let selected = try await self.ensureSelected(name, writable: false, client: client)
                return selected.exists == 0 ? [] : try await client.uidSearch([.all])
            }
            await store.removeMissing(from: place, keeping: Set(present))
        }
        gmailNotify(.changed)
        try await gmailSyncCategories(store, newMessages: added)
        try await gmailFetchMissingHeaders(store)
        return added
    }

    /// Steps 1 and 2 for one mailbox. Returns the messages new to this Mac, and the mailbox's message count (nil when
    /// nothing changed).
    func gmailSyncIndex(_ place: GmailPlace, mailbox: String, store: GmailStore) async throws -> (added: [String], exists: Int?) {
        let known = await store.state(of: place)
        return try await withClient { client -> ([String], Int?) in
            let selected = try await client.select(mailbox, readOnly: true, condstore: true)
            guard let validity = selected.uidValidity else { throw PMailError.protocolError("\(mailbox) has no UIDVALIDITY") }
            if let known, known.uidValidity == validity, known.mailbox == mailbox, let modSeq = selected.highestModSeq,
               modSeq == known.modSeq, (selected.uidNext ?? 0) <= known.highestUID &+ 1, selected.exists == known.count {
                return ([], nil)
            }
            var state = known ?? GmailPlaceState(mailbox: mailbox, uidValidity: validity, highestUID: 0, modSeq: nil, count: 0)
            var added: [String] = []
            if known == nil || known?.uidValidity != validity || known?.mailbox != mailbox {
                // The first time, or UIDs that mean something else now: every message, from the start.
                await store.reset(place)
                state = GmailPlaceState(mailbox: mailbox, uidValidity: validity, highestUID: 0, modSeq: nil, count: 0)
                await store.setState(state, of: place)
                let entries = selected.exists == 0 ? [] : try await client.uidFetch(from: 1, items: Self.gmailIndexItems).compactMap(Self.gmailIndexEntry)
                added = await store.keep(entries, in: place)
                state.highestUID = entries.map(\.uid).max() ?? 0
            } else {
                if selected.exists > 0, (selected.uidNext ?? .max) > state.highestUID &+ 1 {
                    let entries = try await client.uidFetch(from: state.highestUID &+ 1, items: Self.gmailIndexItems).compactMap(Self.gmailIndexEntry)
                    added = await store.keep(entries, in: place)
                    state.highestUID = max(state.highestUID, entries.map(\.uid).max() ?? 0)
                }
                if let since = known?.modSeq, let now = selected.highestModSeq, now != since, let highest = known?.highestUID, highest > 0 {
                    let changed = try await client.uidFetch(from: 1, to: highest, items: "UID FLAGS X-GM-LABELS", changedSince: since)
                    await store.update(changed.compactMap { response in response.uid.map { (uid: $0, flags: response.flags, labels: response.gmailLabels) } }, in: place)
                } else if selected.highestModSeq == nil, let highest = known?.highestUID, highest > 0 {
                    // A server that keeps no modification sequences: every message's flags and labels.
                    let all = try await client.uidFetch(from: 1, to: highest, items: "UID FLAGS X-GM-LABELS")
                    await store.update(all.compactMap { response in response.uid.map { (uid: $0, flags: response.flags, labels: response.gmailLabels) } }, in: place)
                }
            }
            state.modSeq = selected.highestModSeq
            state.count = selected.exists
            await store.setState(state, of: place)
            return (added, selected.exists)
        }
    }

    /// The index entry a FETCH answer gives, when it has everything.
    static func gmailIndexEntry(_ response: IMAPFetchResponse) -> GmailIndexEntry? {
        guard let uid = response.uid, let id = response.gmailMessageID, let thread = response.threadID else { return nil }
        return GmailIndexEntry(id: id, thread: thread, uid: uid, date: response.internalDate ?? Date(), flags: response.flags ?? [],
                               labels: response.gmailLabels ?? [])
    }

    // MARK: Tabs

    /// Sorts messages into the inbox's category tabs with Gmail's own search, in All Mail: every message now and then
    /// (and the first time), else only the new ones. Primary is what's in no other category.
    func gmailSyncCategories(_ store: GmailStore, newMessages: [String]) async throws {
        guard let allMail = await store.state(of: .allMail) else { return }
        let last = await store.setting("categories").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let everything = last.map { Date().timeIntervalSince($0) >= Self.gmailCategoryRefresh } ?? true
        let newUIDs = everything ? [] : await store.uids(of: newMessages, in: .allMail)
        guard everything || !newUIDs.isEmpty else { return }
        try await withClient { client in
            let selected = try await self.ensureSelected(allMail.mailbox, writable: false, client: client)
            guard selected.exists > 0 else { return }
            for tab in Self.gmailTabs where tab.id != "CATEGORY_PERSONAL" {
                guard let search = Self.gmailCategorySearch(tab.id) else { continue }
                let keys: [IMAPSearchKey] = everything ? [.gmailSearch(search)] : [.uids(newUIDs), .gmailSearch(search)]
                await store.setCategory(tab.id, forUIDs: Set(try await client.uidSearch(keys)), replacing: everything)
            }
        }
        if everything { await store.setSetting("categories", String(Date().timeIntervalSince1970)) }
    }

    // MARK: Headers

    /// Fetches the headers of messages that don't have them, a batch at a time (the inbox's first, the newest first),
    /// each batch showing as it arrives.
    func gmailFetchMissingHeaders(_ store: GmailStore) async throws {
        for place in GmailPlace.allCases {
            guard let state = await store.state(of: place) else { continue }
            while true {
                let uids = await store.uidsMissingHeaders(in: place, limit: Self.gmailHeaderBatch)
                guard !uids.isEmpty else { break }
                let fetched = try await withClient { client -> [IMAPFetchResponse] in
                    _ = try await self.ensureSelected(state.mailbox, writable: false, client: client)
                    return try await client.uidFetch(uids, items: Self.gmailHeaderItems)
                }
                var headers: [String: MessageSummary] = [:]
                var answered = Set<UInt32>()
                for response in fetched {
                    guard let uid = response.uid, let id = await store.id(at: uid, in: place) else { continue }
                    answered.insert(uid)
                    headers[id] = Self.gmailSummary(fromHeaders: response)
                }
                // A message gone meanwhile would be asked for again and again: it's kept with what's known.
                for uid in uids where !answered.contains(uid) {
                    if let id = await store.id(at: uid, in: place) { headers[id] = MessageSummary(id: id) }
                }
                await store.keepHeaders(headers)
                gmailNotify(.changed)
                await gmailReportProgress(downloading: true)
            }
        }
    }

    /// A list row from a message's header fields. Whether it has attachments, and whether it's an invitation, are
    /// guessed from its Content-Type until its structure is fetched with its snippet.
    static func gmailSummary(fromHeaders response: IMAPFetchResponse) -> MessageSummary {
        let data = response.headerFields ?? Data()
        let parsed = MIMEParser.parse(data + Data("\r\n".utf8))
        let headers = IMAPHeaderFields.parse(data)
        let contentType = headers["content-type"]?.lowercased() ?? ""
        return MessageSummary(id: "", from: parsed.from, to: parsed.to, cc: parsed.cc, subject: parsed.subject,
                              date: parsed.date ?? response.internalDate ?? Date(), hasAttachments: contentType.hasPrefix("multipart/mixed"),
                              messageIDHeader: parsed.messageID, inReplyTo: parsed.inReplyTo, references: parsed.references,
                              size: response.size, senderHints: senderHints(from: headers),
                              isInvitation: contentType.contains("text/calendar") ? true : nil)
    }

    // MARK: Snippets

    /// Fetches the snippets of listed messages that don't have them, in the background: each message's structure,
    /// then the start of its text.
    func gmailFillSnippets(for conversations: [Conversation]) {
        guard let store = gmailStore else { return }
        let summaries = conversations.flatMap(\.messages)
        guard !summaries.isEmpty else { return }
        Task {
            let ids = await store.ids(for: summaries).filter { !gmailSync.fetchingSnippets.contains($0) }
            let missing = await store.missingSnippets(ids)
            guard !missing.isEmpty else { return }
            gmailSync.fetchingSnippets.formUnion(missing.map(\.id))
            defer { gmailSync.fetchingSnippets.subtract(missing.map(\.id)) }
            try? await BackgroundWork.run { try await self.gmailFetchSnippets(missing, store: store) }
            gmailNotify(.changed)
        }
    }

    /// Fetches messages' structures and the start of their text, place by place, and keeps their snippets.
    func gmailFetchSnippets(_ missing: [(id: String, place: GmailPlace, uid: UInt32)], store: GmailStore) async throws {
        for place in GmailPlace.allCases {
            let here = missing.filter { $0.place == place }
            guard !here.isEmpty, let state = await store.state(of: place) else { continue }
            let found = try await withClient { client -> [String: (snippet: String, hasAttachments: Bool, isInvitation: Bool)] in
                _ = try await self.ensureSelected(state.mailbox, writable: false, client: client)
                let structures = try await client.uidFetch(here.map(\.uid), items: "UID BODYSTRUCTURE")
                let snippets = try await self.snippets(for: structures, client: client)
                var found: [String: (snippet: String, hasAttachments: Bool, isInvitation: Bool)] = [:]
                for response in structures {
                    guard let uid = response.uid, let id = here.first(where: { $0.uid == uid })?.id else { continue }
                    found[id] = (snippets[uid] ?? "", response.bodyStructure?.hasAttachments ?? false, response.bodyStructure?.hasCalendar ?? false)
                }
                return found
            }
            await store.keepSnippets(found)
        }
    }
}
