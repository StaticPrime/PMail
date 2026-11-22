import Foundation

/// A POP account's mail. The server only holds the inbox, so PMail downloads new messages into a `LocalMailStore`
/// and keeps everything else there too: flags, Sent, Drafts, Archive, Junk and Trash. A Starred folder shows starred
/// messages from every folder.
///
/// Downloaded messages stay on the server unless the account says otherwise (`ServerSettings.removeFromServer`):
/// removed once deleted from PMail, or a day, a week or a month after they arrived.
///
/// Message IDs are "pop:" plus the server's unique ID (UIDL) for downloaded mail, and "local:" or "draft:" IDs for
/// mail written on this Mac.
public actor POPMailService: MailService {
    public static let inboxID = "INBOX"
    public static let starredID = "pmail:starred"
    public static let sentID = "Sent"
    public static let draftsID = "Drafts"
    public static let trashID = "Trash"
    public static let archiveID = "Archive"
    public static let spamID = "Spam"

    /// The folders messages can be moved between (Starred only shows messages, it doesn't hold them).
    static let localFolderIDs: Set<String> = [inboxID, sentID, draftsID, archiveID, spamID, trashID]
    /// Folders whose messages stay out of All Mail, Starred and conversations opened from elsewhere.
    static let setAsideIDs: Set<String> = [spamID, trashID]
    static let firstSyncKey = "pop.firstSyncDone"
    /// The most messages one check for new mail returns (the newest).
    static let newMailLimit = 50

    public let account: Account
    let incoming: ServerSettings
    let credential: Credential
    let store: LocalMailStore
    let sender: any MailSending
    let connector: any ByteStreamConnector
    /// The sync in progress, which hands back the IDs it downloaded, newest first.
    var syncTask: Task<[String], Error>?
    /// How many of the newest messages the first sync downloads; older ones stay on the server only.
    var firstSyncLimit = 300
    /// The time, for telling how long ago a message arrived.
    var now: @Sendable () -> Date = { Date() }

    public init(account: Account, incoming: ServerSettings, credential: Credential, store: LocalMailStore,
                sender: any MailSending, connector: any ByteStreamConnector = URLSessionConnector(),
                labelBook: LabelBook? = nil, sorter: InboxSorter? = nil) {
        self.account = account
        self.incoming = incoming
        self.credential = credential
        self.store = store
        self.sender = sender
        self.connector = connector
        self.labelBook = labelBook
        self.sorter = sorter
    }

    /// The account's labels (names and colors); the messages' labels are kept with them in the store. Nil leaves
    /// labels out.
    nonisolated let labelBook: LabelBook?
    /// Sorts the inbox into categories, shown as tabs; nil leaves the inbox as one list.
    nonisolated let sorter: InboxSorter?

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: false, hasInboxTabs: sorter != nil, searchesOnServer: false,
                         canArchive: true, supportsDrafts: true, canMove: true, canLabel: labelBook != nil,
                         canEditLabels: labelBook != nil)
    }

    public nonisolated var inboxTabs: [InboxTab] { sorter == nil ? [] : InboxCategory.tabs }

    // MARK: Listing

    public func loadFolders() async throws -> [MailFolder] {
        let starred = await store.starredSummaries()
        var folders: [MailFolder] = []
        for (id, name, role) in [(Self.inboxID, "Inbox", FolderRole.inbox), (Self.starredID, "Starred", .starred),
                                 (Self.sentID, "Sent", .sent), (Self.draftsID, "Drafts", .drafts), (Self.archiveID, "Archive", .archive),
                                 (Self.spamID, "Junk", .spam), (Self.trashID, "Trash", .trash)] {
            if id == Self.starredID {
                folders.append(MailFolder(id: id, name: name, role: role, unreadCount: starred.filter(\.isUnread).count,
                                          totalCount: starred.count))
            } else {
                let counts = await store.counts(in: id)
                folders.append(MailFolder(id: id, name: name, role: role, unreadCount: role == .inbox ? counts.unread : 0,
                                          totalCount: counts.total))
            }
        }
        return folders + (await labelFolders())
    }

    /// A page of conversations. Listing the inbox's first page checks the server for new mail first.
    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        if let page = try await labelPage(request) { return page }
        if let page = try await categoryPage(request) { return page }
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let pageSize = max(1, request.pageSize)
        var summaries: [MessageSummary]
        if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            if request.folderID == Self.starredID {
                summaries = await store.search(query).filter { $0.isStarred && !Self.setAsideIDs.contains($0.folderID ?? "") }
            } else {
                summaries = await store.search(query, in: request.folderID)
            }
        } else {
            switch request.folderID {
            case Self.inboxID?:
                if pageIndex == 0 { _ = try await syncInbox() }
                summaries = await store.summaries(in: Self.inboxID)
            case Self.starredID?:
                summaries = await store.starredSummaries()
            case nil:
                summaries = await store.allSummaries().filter { !Self.setAsideIDs.contains($0.folderID ?? "") }
            case let folderID?:
                summaries = await store.summaries(in: folderID)
            }
        }
        let conversations = Conversation.group(summaries)
        let start = pageIndex * pageSize
        let page = start < conversations.count ? Array(conversations[start..<min(start + pageSize, conversations.count)]) : []
        let nextPageToken = start + pageSize < conversations.count ? String(pageIndex + 1) : nil
        return ConversationPage(conversations: page, totalCount: conversations.count, nextPageToken: nextPageToken)
    }

    /// Downloads messages the store doesn't have yet, newest first, and leaves them on the server. The first sync
    /// takes only the newest `firstSyncLimit`. Returns how many arrived. Calls made while a sync runs wait for it.
    @discardableResult
    public func syncInbox() async throws -> Int {
        try await sync().count
    }

    /// Runs a sync, or joins the one in progress, and returns the IDs of the messages it downloaded, newest first.
    func sync() async throws -> [String] {
        if let running = syncTask { return try await running.value }
        let task = Task { try await self.downloadNewMessages() }
        syncTask = task
        defer { syncTask = nil }
        return try await task.value
    }

    func downloadNewMessages() async throws -> [String] {
        let client = POPClient(settings: incoming, credential: credential, connector: connector)
        try await client.connect()
        do {
            let ids = try await client.uidl()
            let serverIDs = ids.map { "pop:\($0.uid)" }
            try await store.forgetDeletedIDs(withPrefix: "pop:", notIn: Set(serverIDs))
            let known = await store.knownIDs(among: serverIDs)
            // Message numbers count up from the oldest, so newest first is from the end.
            var fresh = ids.reversed().filter { !known.contains("pop:\($0.uid)") }
            if await store.value(forKey: Self.firstSyncKey) == nil {
                let limit = max(0, firstSyncLimit)
                if fresh.count > limit {
                    try await store.markDeleted(ids: fresh[limit...].map { "pop:\($0.uid)" })
                    fresh = Array(fresh.prefix(limit))
                }
                try await store.setValue("1", forKey: Self.firstSyncKey)
            }
            var downloaded: [String] = []
            for message in fresh {
                let raw: Data
                do {
                    raw = try await client.retrieve(message.number)
                } catch PMailError.server {
                    continue  // gone since UIDL (another program deleted it)
                }
                try await store.add(raw: raw, folderID: Self.inboxID, id: "pop:\(message.uid)", isUnread: true, arrived: now())
                downloaded.append("pop:\(message.uid)")
            }
            // Only what the account says to remove leaves the server, and only when the session ends with QUIT.
            let leaving = try await copiesLeavingServer(among: serverIDs)
            for message in ids where leaving.contains("pop:\(message.uid)") {
                try? await client.delete(message.number)
            }
            await client.quit()
            return downloaded
        } catch {
            await client.close()
            throw error
        }
    }

    // MARK: New mail

    /// Brings the inbox up to date and returns what this sync downloaded, newest first (at most `newMailLimit`). The
    /// first check, and the first sync this Mac ever makes for the account, download silently: they only bring the
    /// inbox up to date. The store keeps track of what's been downloaded, so the state only marks that a check has
    /// happened.
    public func checkForNewMail(since state: MailSyncState?) async throws -> NewMail {
        let hasSyncedBefore = await store.value(forKey: Self.firstSyncKey) != nil
        let downloaded = try await sync()
        var messages: [MessageSummary] = []
        if state != nil, hasSyncedBefore {
            for id in downloaded.prefix(Self.newMailLimit) {
                if let summary = await store.summary(for: id), summary.folderID == Self.inboxID { messages.append(summary) }
            }
        }
        return NewMail(messages: messages, state: MailSyncState("pop"), inboxUnread: await store.counts(in: Self.inboxID).unread)
    }

    /// Looks the Message-IDs up among the messages on this Mac, leaving out Trash.
    public func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary] {
        let wanted = Set(messageIDs.map(Self.messageIDKey).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        return await store.allSummaries().filter { summary in
            guard !Self.setAsideIDs.contains(summary.folderID ?? ""), let header = summary.messageIDHeader else { return false }
            return wanted.contains(Self.messageIDKey(header))
        }
    }

    /// POP servers can't say when mail arrives; the inbox is checked now and then instead.
    public nonisolated var pushesChanges: Bool { false }

    /// A Message-ID in a form for comparing: without angle brackets or space around it, in lowercase.
    static func messageIDKey(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        let hintIDs = hint?.messages.map(\.id) ?? []
        // A conversation opened from Trash or Junk shows what's there; one opened elsewhere leaves those out.
        let showSetAside = !hintIDs.isEmpty && (hint?.messages.allSatisfy { Self.setAsideIDs.contains($0.folderID ?? "") } ?? false)
        var summaries = await store.allSummaries().filter {
            $0.threadID == id && (showSetAside || !Self.setAsideIDs.contains($0.folderID ?? ""))
        }
        for hintID in hintIDs where !summaries.contains(where: { $0.id == hintID }) {
            if let summary = await store.summary(for: hintID) { summaries.append(summary) }
        }
        guard !summaries.isEmpty else { throw PMailError.notFound }
        var messages: [MailMessage] = []
        for summary in summaries.sorted(by: { $0.date < $1.date }) {
            messages.append(try await loadMessage(summary))
        }
        return messages
    }

    public func loadMessage(_ summary: MessageSummary) async throws -> MailMessage {
        guard let raw = await store.raw(for: summary.id) else { throw PMailError.notFound }
        let current = await store.summary(for: summary.id) ?? summary
        return MIMEParser.parse(raw).mailMessage(summary: current, rawSource: raw)
    }

    public func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        guard let raw = await store.raw(for: message.id) else { throw PMailError.notFound }
        let parsed = MIMEParser.parse(raw)
        guard let data = (parsed.attachments + parsed.inlineParts).first(where: { $0.id == attachment.id })?.data else {
            throw PMailError.notFound
        }
        return data
    }

    // MARK: Changing

    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        let ids = messages.map(\.id)
        switch action {
        case .markRead: try await store.setUnread(false, for: ids)
        case .markUnread: try await store.setUnread(true, for: ids)
        case .star: try await store.setStarred(true, for: ids)
        case .unstar: try await store.setStarred(false, for: ids)
        case .trash: try await store.move(ids: ids, to: Self.trashID)
        case .moveToInbox: try await store.move(ids: ids, to: Self.inboxID)
        case .deleteForever: try await store.delete(ids: ids)
        case let .move(folderID):
            guard Self.localFolderIDs.contains(folderID) else {
                throw PMailError.notSupported("POP accounts can’t move mail there.")
            }
            try await store.move(ids: ids, to: folderID)
        case .archive: try await store.move(ids: ids, to: Self.archiveID)
        case .markSpam: try await store.move(ids: ids, to: Self.spamID)
        case .notSpam: try await store.move(ids: ids, to: Self.inboxID)
        case .addLabel, .removeLabel:
            try await applyLabel(action, to: messages)
        case .markImportant, .markNotImportant:
            throw PMailError.notSupported("POP accounts can’t mark mail as important.")
        }
    }

    /// Sends through the outgoing server, then files a copy in Sent. The copy keeps the Bcc header, so the person can
    /// see who got a blind copy; the message that was sent has none.
    public func send(_ message: OutgoingMessage) async throws {
        let recipients = message.allRecipients.map(\.email)
        guard !recipients.isEmpty else { throw PMailError.server("The message has no recipients.") }
        try await sender.send(MIMEBuilder.build(message), from: message.from.email, to: recipients)
        try await store.add(raw: MIMEBuilder.buildForSaving(message), folderID: Self.sentID, isUnread: false)
    }

    public func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        let id = draft?.id ?? "draft:\(UUID().uuidString.lowercased())"
        return try await store.add(raw: MIMEBuilder.buildForSaving(message), folderID: Self.draftsID, id: id, isUnread: false)
    }

    public func deleteDraft(_ draft: MessageSummary) async throws {
        try await store.delete(ids: [draft.id])
    }

    /// Nothing stays open between calls (each sync has its own connection), so there is nothing to close.
    public func close() async {}

    /// Sets how many messages the first sync downloads, for tests.
    func setFirstSyncLimit(_ limit: Int) {
        firstSyncLimit = limit
    }

    /// Sets the time, for tests.
    func setNow(_ now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    // MARK: Removing from the server

    /// Of the messages on the server, the ones the account says to remove now: none unless the person chose to,
    /// those deleted from PMail, or those that arrived long enough ago. A message PMail never downloaded (one an
    /// account's first sync left behind) is never removed. Arrival times are noted on every sync, whatever the choice,
    /// so a change of mind later counts from when messages really arrived.
    func copiesLeavingServer(among serverIDs: [String]) async throws -> Set<String> {
        let arrivals = try await store.arrivals(among: serverIDs, now: now())
        switch incoming.removeFromServer ?? .never {
        case .never:
            return []
        case .whenDeleted:
            return await store.deletedAfterArriving(among: serverIDs)
        case let timed:
            guard let age = timed.age else { return [] }
            let current = now()
            return Set(arrivals.filter { current.timeIntervalSince($0.value) >= age }.keys)
        }
    }
}
