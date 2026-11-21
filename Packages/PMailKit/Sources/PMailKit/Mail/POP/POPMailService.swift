import Foundation

/// A POP account's mail. The server only holds the inbox, so PMail downloads new messages into a `LocalMailStore`
/// (leaving them on the server) and keeps everything else there too: flags, Sent, Drafts and Trash. A Starred
/// folder shows starred messages from every folder.
///
/// Message IDs are "pop:" plus the server's unique ID (UIDL) for downloaded mail, and "local:" or "draft:" IDs for
/// mail written on this Mac.
public actor POPMailService: MailService {
    public static let inboxID = "INBOX"
    public static let starredID = "pmail:starred"
    public static let sentID = "Sent"
    public static let draftsID = "Drafts"
    public static let trashID = "Trash"

    /// The folders messages can be moved between (Starred only shows messages, it doesn't hold them).
    private static let localFolderIDs: Set<String> = [inboxID, sentID, draftsID, trashID]
    private static let firstSyncKey = "pop.firstSyncDone"
    /// The most messages one check for new mail returns (the newest).
    static let newMailLimit = 50

    public let account: Account
    private let incoming: ServerSettings
    private let credential: Credential
    private let store: LocalMailStore
    private let sender: any MailSending
    private let connector: any ByteStreamConnector
    /// The sync in progress, which hands back the IDs it downloaded, newest first.
    private var syncTask: Task<[String], Error>?
    /// How many of the newest messages the first sync downloads; older ones stay on the server only.
    var firstSyncLimit = 300

    public init(account: Account, incoming: ServerSettings, credential: Credential, store: LocalMailStore,
                sender: any MailSending, connector: any ByteStreamConnector = URLSessionConnector()) {
        self.account = account
        self.incoming = incoming
        self.credential = credential
        self.store = store
        self.sender = sender
        self.connector = connector
    }

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: false, hasInboxTabs: false, searchesOnServer: false,
                         canArchive: false, supportsDrafts: true, canMove: true)
    }

    public nonisolated var inboxTabs: [InboxTab] { [] }

    // MARK: Listing

    public func loadFolders() async throws -> [MailFolder] {
        let starred = await store.starredSummaries()
        var folders: [MailFolder] = []
        for (id, name, role) in [(Self.inboxID, "Inbox", FolderRole.inbox), (Self.starredID, "Starred", .starred),
                                 (Self.sentID, "Sent", .sent), (Self.draftsID, "Drafts", .drafts), (Self.trashID, "Trash", .trash)] {
            if id == Self.starredID {
                folders.append(MailFolder(id: id, name: name, role: role, unreadCount: starred.filter(\.isUnread).count,
                                          totalCount: starred.count))
            } else {
                let counts = await store.counts(in: id)
                folders.append(MailFolder(id: id, name: name, role: role, unreadCount: role == .inbox ? counts.unread : 0,
                                          totalCount: counts.total))
            }
        }
        return folders
    }

    /// A page of conversations. Listing the inbox's first page checks the server for new mail first.
    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let pageSize = max(1, request.pageSize)
        var summaries: [MessageSummary]
        if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            if request.folderID == Self.starredID {
                summaries = await store.search(query).filter { $0.isStarred && $0.folderID != Self.trashID }
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
                summaries = await store.allSummaries().filter { $0.folderID != Self.trashID }
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
    private func sync() async throws -> [String] {
        if let running = syncTask { return try await running.value }
        let task = Task { try await self.downloadNewMessages() }
        syncTask = task
        defer { syncTask = nil }
        return try await task.value
    }

    private func downloadNewMessages() async throws -> [String] {
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
                try await store.add(raw: raw, folderID: Self.inboxID, id: "pop:\(message.uid)", isUnread: true)
                downloaded.append("pop:\(message.uid)")
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
            guard summary.folderID != Self.trashID, let header = summary.messageIDHeader else { return false }
            return wanted.contains(Self.messageIDKey(header))
        }
    }

    /// POP servers can't say when mail arrives; the inbox is checked now and then instead.
    public nonisolated var pushesChanges: Bool { false }

    /// A Message-ID in a form for comparing: without angle brackets or space around it, in lowercase.
    private static func messageIDKey(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        let hintIDs = hint?.messages.map(\.id) ?? []
        let showTrash = !hintIDs.isEmpty && (hint?.messages.allSatisfy { $0.folderID == Self.trashID } ?? false)
        var summaries = await store.allSummaries().filter { $0.threadID == id && (showTrash || $0.folderID != Self.trashID) }
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
        case .archive:
            throw PMailError.notSupported("POP accounts don’t have an archive.")
        case .markSpam, .notSpam:
            throw PMailError.notSupported("POP accounts don’t have a junk folder.")
        case .addLabel, .removeLabel:
            throw PMailError.notSupported("POP accounts don’t use labels.")
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
}
