import Foundation

/// Where a message lives on an IMAP server: its mailbox, the mailbox's UIDVALIDITY and the message's UID. Its
/// `rawValue` ("imap:<uidvalidity>:<uid>:<mailbox>") is the `MessageSummary.id` the IMAP mail service gives out.
public struct IMAPMessageID: RawRepresentable, Sendable, Hashable {
    /// The mailbox's full path, decoded ("INBOX", "Projects/Café").
    public var mailbox: String
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("imap:") else { return nil }
        let fields = rawValue.dropFirst(5).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let uidValidity = UInt32(fields[0]), let uid = UInt32(fields[1]), !fields[2].isEmpty else {
            return nil
        }
        self.init(mailbox: String(fields[2]), uidValidity: uidValidity, uid: uid)
    }

    public var rawValue: String { "imap:\(uidValidity):\(uid):\(mailbox)" }
}

/// The mail of an iCloud Mail or other IMAP account: folders, conversations, messages and actions over one IMAP
/// connection, with sending handed to an outgoing (SMTP) server.
///
/// The service keeps a single connection and runs one operation at a time on it. When the connection turns out
/// to have dropped (the server timed it out, the network changed), it connects again and tries once more. Waiting
/// for changes (IMAP IDLE) happens on a second connection of its own, so it never holds the other calls up.
///
/// Given a local store, it keeps Sent, Drafts, Archive, Junk and Trash on this Mac when the server has no folder for
/// them: sent copies and drafts are saved there, and archived, junk or deleted messages are copied there before they
/// leave the server.
public actor IMAPMailService: MailService {
    /// The ID of the virtual folder that lists the inbox's starred (\Flagged) messages.
    public static let starredFolderID = "pmail:starred"

    /// How much of a plain text part to fetch for its snippet.
    static let textSnippetLength = 2048
    /// How much of an HTML part to fetch for its snippet: more than for plain text, since a style sheet often
    /// comes before the first words.
    static let htmlSnippetLength = 8192
    /// The most messages one check for new mail returns (the newest).
    static let newMailLimit = 50
    /// The most mailboxes one lookup by Message-ID opens.
    static let lookupMailboxLimit = 40
    /// The longest one IDLE runs before it's renewed: servers may drop a connection that has been quiet for 30 minutes.
    static let longestIdle: TimeInterval = 25 * 60
    /// The longest one wait for a change lasts, however long the caller asked for.
    static let longestWait: TimeInterval = 24 * 60 * 60

    public nonisolated let account: Account
    let incoming: ServerSettings
    let credential: Credential
    let sender: any MailSending
    let connector: any ByteStreamConnector
    var client: IMAPClient?
    /// The user name the server accepted, once one has worked (iCloud takes the whole address or the part before
    /// the @, depending on the account).
    var workingUsername: String?
    /// The mailboxes from the last LIST, for finding Sent, Drafts, Trash, Junk and Archive.
    var mailboxes: [IMAPMailbox]?
    var isBusy = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// Sent, Drafts and Trash kept on this Mac for a server without them (nil: such a server's mail can't be deleted
    /// and its sent copies aren't kept).
    let localFolders: LocalFolders?
    /// The second connection, which waits for changes in the inbox.
    var changeClient: IMAPClient?
    /// How long each read on `changeClient` may take, when the connector is the network's.
    var changeStreamTimeout: TimeInterval = 0
    var isWaitingForChange = false
    var changeWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many times `close()` has run, so a wait can tell it was cut short.
    var closeCount = 0
    /// How often a server without IDLE is asked about the inbox while waiting for a change, in seconds.
    var pollInterval: TimeInterval = 60

    public init(account: Account, incoming: ServerSettings, credential: Credential, sender: any MailSending,
                connector: any ByteStreamConnector = URLSessionConnector(), localStore: LocalMailStore? = nil,
                labelBook: LabelBook? = nil, sorter: InboxSorter? = nil) {
        self.account = account
        self.incoming = incoming
        self.credential = credential
        self.sender = sender
        self.connector = connector
        localFolders = localStore.map(LocalFolders.init(store:))
        self.labelBook = labelBook
        self.sorter = sorter
    }

    /// The account's labels kept on this Mac (their names and colors, and which messages have them where the server
    /// can't keep that); nil leaves labels out.
    nonisolated let labelBook: LabelBook?
    /// Sorts the inbox into categories, shown as tabs; nil leaves the inbox as one list.
    nonisolated let sorter: InboxSorter?
    /// The inbox's messages as the category tabs sorted them (see IMAPMailService+Categories.swift).
    var categoryIndex = IMAPCategoryIndex()

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: false, hasInboxTabs: sorter != nil, searchesOnServer: true,
                         canArchive: true, supportsDrafts: true, canMove: true, canLabel: labelBook != nil,
                         canEditLabels: labelBook != nil)
    }

    public nonisolated var inboxTabs: [InboxTab] { sorter == nil ? [] : InboxCategory.tabs }

    // MARK: Folders

    public func loadFolders() async throws -> [MailFolder] {
        try await withClient { client in
            var boxes = try await client.listMailboxes()
            // Every account has an inbox, even on a server that leaves it out of LIST.
            if !boxes.contains(where: \.isInbox) { boxes.insert(IMAPMailbox(name: "INBOX"), at: 0) }
            self.mailboxes = boxes
            let roles = IMAPFolderRoles.assign(boxes)
            let names = Set(boxes.map(\.name))
            var folders: [MailFolder] = []
            for box in boxes {
                var unread = 0
                var total: Int?
                if box.isSelectable {
                    do {
                        let status = try await client.status(box.name)
                        unread = status.unseen ?? 0
                        total = status.messages
                    } catch PMailError.server {
                        // A mailbox the server won't count is still worth showing.
                    }
                }
                let parent = box.parentName.flatMap { names.contains($0) ? $0 : nil }
                folders.append(MailFolder(id: box.name, name: box.displayName, role: roles[box.name], unreadCount: unread,
                                          totalCount: total, parentID: parent, isSelectable: box.isSelectable))
            }
            folders += try await self.labelFolders(client: client)
            // Sent, Drafts and Trash the server doesn't have are kept on this Mac.
            if let local = self.localFolders { folders += await local.folders(besides: Set(roles.values)) }
            // The inbox first, then its starred messages as a folder of their own.
            if let index = folders.firstIndex(where: { $0.role == .inbox }) { folders.insert(folders.remove(at: index), at: 0) }
            let starred = MailFolder(id: Self.starredFolderID, name: "Starred", role: .starred)
            folders.insert(starred, at: folders.first?.role == .inbox ? 1 : 0)
            return folders
        }
    }

    // MARK: Listing

    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        if let local = localFolders, LocalFolders.contains(request.folderID) { return await local.page(request) }
        if let page = try await labelPage(request) { return page }
        if let page = try await categoryPage(request) { return page }
        return try await withClient { client in
            let (mailbox, filter) = try await self.listTarget(for: request.folderID, client: client)
            // Opened again each time, so the list sees the mailbox as it is now.
            let selected = try await client.select(mailbox, readOnly: true)
            var keys = filter.map { [$0] } ?? []
            keys += IMAPSearchKey.matching(query: request.query ?? "")
            let uids = selected.exists == 0 ? [] : try await client.uidSearch(keys.isEmpty ? [.all] : keys)
            let newestFirst = Array(Set(uids)).sorted(by: >)
            let pageSize = max(1, request.pageSize)
            let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
            let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
            let start = overflowed ? newestFirst.count : min(offset, newestFirst.count)
            let end = start + min(pageSize, newestFirst.count - start)
            let page = Array(newestFirst[start..<end])
            let summaries = try await self.summaries(of: page, in: mailbox, uidValidity: selected.uidValidity ?? 0, client: client)
            return ConversationPage(conversations: Conversation.group(summaries), totalCount: newestFirst.count,
                                    nextPageToken: end < newestFirst.count ? String(pageIndex + 1) : nil)
        }
    }

    /// The mailbox to list for a folder ID, and the search that narrows it (the starred folder is the inbox's
    /// flagged messages; no folder means all mail, or the inbox on servers without an All Mail folder).
    func listTarget(for folderID: String?, client: IMAPClient) async throws -> (String, IMAPSearchKey?) {
        switch folderID {
        case Self.starredFolderID?:
            return ("INBOX", .flagged)
        case let folderID?:
            return (folderID, nil)
        case nil:
            return (try await mailboxName(for: .allMail, client: client) ?? "INBOX", nil)
        }
    }

    /// Summaries for messages in the selected mailbox, with snippets.
    func summaries(of uids: [UInt32], in mailbox: String, uidValidity: UInt32,
                           client: IMAPClient) async throws -> [MessageSummary] {
        guard !uids.isEmpty else { return [] }
        let fetched = try await client.fetchSummaries(uids)
        let snippets = try await self.snippets(for: fetched, client: client)
        return await labeled(fetched.compactMap { response in
            guard let uid = response.uid else { return nil }
            return Self.summary(from: response, id: IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: uid),
                                snippet: snippets[uid] ?? "")
        }, client: client)
    }

    /// Snippets from the start of each message's text part: one partial fetch for each part number in use.
    func snippets(for fetched: [IMAPFetchResponse], client: IMAPClient) async throws -> [UInt32: String] {
        struct Request: Hashable, Comparable {
            var section: String
            var length: Int
            static func < (lhs: Request, rhs: Request) -> Bool { (lhs.section, lhs.length) < (rhs.section, rhs.length) }
        }
        var parts: [UInt32: IMAPBodyPart] = [:]
        var requests: [Request: [UInt32]] = [:]
        for response in fetched {
            guard let uid = response.uid, let part = response.bodyStructure?.snippetPart, Self.isSectionNumber(part.section) else {
                continue
            }
            parts[uid] = part
            let length = part.subtype == "html" ? Self.htmlSnippetLength : Self.textSnippetLength
            requests[Request(section: part.section, length: length), default: []].append(uid)
        }
        var snippets: [UInt32: String] = [:]
        for request in requests.keys.sorted() {
            guard let uids = requests[request] else { continue }
            for response in try await client.fetchSection(request.section, of: uids, length: request.length) {
                guard let uid = response.uid, let part = parts[uid], let data = response.section(request.section) else { continue }
                snippets[uid] = part.snippet(from: data)
            }
        }
        return snippets
    }

    /// A message list row from a FETCH response. The conversation is the server's own conversation ID when it has
    /// one, else the first message in References, else In-Reply-To, else the message's own Message-ID.
    static func summary(from response: IMAPFetchResponse, id: IMAPMessageID, snippet: String) -> MessageSummary {
        let envelope = response.envelope
        let headers = response.headerFields.map(IMAPHeaderFields.parse) ?? [:]
        let references = headers["references"].map(MessageIDs.all(in:)) ?? []
        let inReplyTo = envelope?.inReplyTo ?? headers["in-reply-to"].flatMap(MessageIDs.first(in:))
        let messageID = envelope?.messageID
        let threadID = response.threadID ?? references.first ?? inReplyTo ?? messageID ?? id.rawValue
        return MessageSummary(id: id.rawValue, threadID: threadID, folderID: id.mailbox, labelIDs: keywordLabelIDs(response.flags),
                              from: envelope?.from.first,
                              to: envelope?.to ?? [], cc: envelope?.cc ?? [], subject: envelope?.subject ?? "", snippet: snippet,
                              date: envelope?.date ?? response.internalDate ?? Date(timeIntervalSince1970: 0),
                              isUnread: !response.hasFlag("\\Seen"), isStarred: response.hasFlag("\\Flagged"),
                              isDraft: response.hasFlag("\\Draft"), hasAttachments: response.bodyStructure?.hasAttachments ?? false,
                              messageIDHeader: messageID, inReplyTo: inReplyTo, references: references, size: response.size,
                              senderHints: senderHints(from: headers))
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        let kept = (hint?.messages ?? []).filter { IMAPMessageID(rawValue: $0.id) == nil }
        // A conversation kept wholly on this Mac opens without the server.
        if let local = localFolders, let hint, !kept.isEmpty, kept.count == hint.messages.count {
            var messages: [MailMessage] = []
            for summary in kept { messages.append(try await local.message(summary)) }
            return messages.sorted { $0.summary.date < $1.summary.date }
        }
        return try await withClient { client in
            var messages: [MailMessage] = []
            var loaded = Set<IMAPMessageID>()
            var messageIDs = Set<String>()
            let known = (hint?.messages ?? []).compactMap { summary in IMAPMessageID(rawValue: summary.id).map { (summary, $0) } }
            for (mailbox, group) in Self.grouped(known, by: { $0.1.mailbox }) {
                let selected = try await self.ensureSelected(mailbox, writable: false, client: client)
                let uidValidity = selected.uidValidity ?? 0
                var byUID: [UInt32: MessageSummary] = [:]
                for (summary, messageID) in group where messageID.uidValidity == uidValidity { byUID[messageID.uid] = summary }
                for response in try await client.fetchMessages(byUID.keys.sorted()) {
                    guard let uid = response.uid, var summary = byUID[uid], let raw = response.section("") else { continue }
                    Self.applyFlags(response.flags, to: &summary)
                    loaded.insert(IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: uid))
                    if let header = summary.messageIDHeader { messageIDs.insert(header) }
                    messages.append(MIMEParser.parse(raw).mailMessage(summary: summary, rawSource: raw))
                }
            }
            // Replies sent from this account are filed in Sent, not with the rest of the conversation.
            let roots = Self.threadRoots(of: hint?.messages ?? [], conversationID: id)
            var places: [String] = []
            if let sent = try await self.mailboxName(for: .sent, client: client) { places.append(sent) }
            if hint == nil { places.insert("INBOX", at: 0) }
            for mailbox in places where !roots.isEmpty {
                messages += try await self.relatedMessages(in: mailbox, roots: roots, skipping: loaded,
                                                           knownMessageIDs: &messageIDs, client: client)
            }
            if let local = self.localFolders {
                // Its messages kept on this Mac, and replies in the Sent kept here.
                for summary in kept {
                    guard let message = try? await local.message(summary) else { continue }
                    if let header = message.summary.messageIDHeader, !messageIDs.insert(header).inserted { continue }
                    messages.append(message)
                }
                messages += await local.related(in: LocalFolders.sentID, roots: roots, knownMessageIDs: &messageIDs)
            }
            if messages.isEmpty { throw PMailError.notFound }
            return messages.sorted { $0.summary.date < $1.summary.date }
        }
    }

    /// The messages in a mailbox that belong to a conversation: replies to its first message (by References or
    /// In-Reply-To) and that message itself (by Message-ID).
    func relatedMessages(in mailbox: String, roots: [String], skipping loaded: Set<IMAPMessageID>,
                                 knownMessageIDs: inout Set<String>, client: IMAPClient) async throws -> [MailMessage] {
        let selected = try await ensureSelected(mailbox, writable: false, client: client)
        let criteria = roots.map { root in
            IMAPSearchKey.or(.or(.header("References", root), .header("In-Reply-To", root)), .header("Message-ID", root))
        }
        guard selected.exists > 0, let search = IMAPSearchKey.any(criteria) else { return [] }
        let uidValidity = selected.uidValidity ?? 0
        let found = try await client.uidSearch([search]).filter {
            !loaded.contains(IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: $0))
        }
        guard !found.isEmpty else { return [] }
        var messages: [MailMessage] = []
        for response in try await client.fetchSummaries(found, withMessage: true) {
            guard let uid = response.uid, let raw = response.section("") else { continue }
            let parsed = MIMEParser.parse(raw)
            let summary = Self.summary(from: response, id: IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: uid),
                                       snippet: parsed.snippet)
            // A message sent to yourself is in the inbox and in Sent: show it once.
            if let header = summary.messageIDHeader, !knownMessageIDs.insert(header).inserted { continue }
            messages.append(parsed.mailMessage(summary: summary, rawSource: raw))
        }
        return messages
    }

    /// The Message-IDs a conversation's replies point back to: each message's first References entry, else its
    /// In-Reply-To, else its own Message-ID.
    static func threadRoots(of messages: [MessageSummary], conversationID: String) -> [String] {
        var roots: [String] = []
        for message in messages {
            if let root = message.references.first ?? message.inReplyTo ?? message.messageIDHeader, !roots.contains(root) {
                roots.append(root)
            }
        }
        if roots.isEmpty, conversationID.hasPrefix("<"), conversationID.hasSuffix(">") { roots.append(conversationID) }
        return Array(roots.prefix(4))
    }

    public func loadMessage(_ summary: MessageSummary) async throws -> MailMessage {
        guard let id = IMAPMessageID(rawValue: summary.id) else {
            if let local = localFolders { return try await local.message(summary) }
            throw PMailError.notFound
        }
        return try await withClient { client in
            let selected = try await self.ensureSelected(id.mailbox, writable: false, client: client)
            guard (selected.uidValidity ?? 0) == id.uidValidity, let response = try await client.fetchMessages([id.uid]).first,
                  let raw = response.section("") else { throw PMailError.notFound }
            var updated = summary
            Self.applyFlags(response.flags, to: &updated)
            return MIMEParser.parse(raw).mailMessage(summary: updated, rawSource: raw)
        }
    }

    public func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        if let data = attachment.data { return data }
        guard let id = IMAPMessageID(rawValue: message.id) else {
            if let local = localFolders { return try await local.attachment(attachment, in: message) }
            throw PMailError.notFound
        }
        return try await withClient { client in
            let selected = try await self.ensureSelected(id.mailbox, writable: false, client: client)
            guard (selected.uidValidity ?? 0) == id.uidValidity else { throw PMailError.notFound }
            if Self.isSectionNumber(attachment.id) {
                let response = try await client.uidFetch([id.uid], items: "UID BODYSTRUCTURE BODY.PEEK[\(attachment.id)]").first
                if let part = response?.bodyStructure?.part(atSection: attachment.id), !part.isMultipart,
                   let data = response?.section(attachment.id) {
                    return part.decodedContent(data)
                }
            }
            // The part number isn't one the server knows: read the whole message and find the file in it.
            guard let raw = try await client.fetchMessages([id.uid]).first?.section("") else { throw PMailError.notFound }
            let parsed = MIMEParser.parse(raw)
            let files = parsed.attachments + parsed.inlineParts
            let match = files.first { $0.id == attachment.id }
                ?? files.first { $0.filename == attachment.filename && $0.size == attachment.size }
                ?? files.first { $0.filename == attachment.filename }
            guard let data = match?.data else { throw PMailError.notFound }
            return data
        }
    }

    // MARK: Actions

    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        switch action {
        case .markImportant, .markNotImportant:
            throw PMailError.notSupported("This account doesn’t mark messages as important.")
        case .addLabel, .removeLabel:
            return try await applyLabel(action, to: messages)
        default:
            break
        }
        let kept = messages.filter { IMAPMessageID(rawValue: $0.id) == nil }
        if let local = localFolders, !kept.isEmpty { try await performKept(action, on: kept, local: local) }
        let ids = messages.compactMap { IMAPMessageID(rawValue: $0.id) }
        guard !ids.isEmpty else { return }
        try await withClient { client in
            let destination = try await self.destination(for: action, client: client)
            var skipped = false
            for (mailbox, group) in Self.grouped(ids, by: { $0.mailbox }) {
                let selected = try await self.ensureSelected(mailbox, writable: true, client: client)
                // UIDs from before the mailbox's UIDVALIDITY changed would point at other messages.
                let uids = group.filter { $0.uidValidity == (selected.uidValidity ?? 0) }.map(\.uid)
                if uids.count < group.count { skipped = true }
                guard !uids.isEmpty else { continue }
                try await self.apply(action, to: uids, in: mailbox, destination: destination, client: client)
            }
            if skipped { throw PMailError.notFound }
        }
    }

    /// The mailbox an action moves messages to, found by its role.
    func destination(for action: MailAction, client: IMAPClient) async throws -> String? {
        switch action {
        case .archive:
            if let archive = try await mailboxName(for: .archive, client: client) { return archive }
            // A server without an Archive: archived mail goes to the Archive kept on this Mac.
            guard localFolders != nil else { throw PMailError.notSupported("This account has no Archive folder.") }
            return LocalFolders.archiveID
        case .trash:
            if let trash = try await mailboxName(for: .trash, client: client) { return trash }
            // A server without a Trash: deleted mail goes to the Trash kept on this Mac.
            guard localFolders != nil else { throw PMailError.notSupported("This account has no Trash folder.") }
            return LocalFolders.trashID
        case .markSpam:
            if let junk = try await mailboxName(for: .spam, client: client) { return junk }
            // A server without a spam folder: spam goes to the Junk kept on this Mac.
            guard localFolders != nil else { throw PMailError.notSupported("This account has no Junk folder.") }
            return LocalFolders.spamID
        case .moveToInbox, .notSpam:
            return "INBOX"
        case let .move(folderID):
            return folderID
        default:
            return nil
        }
    }

    func apply(_ action: MailAction, to uids: [UInt32], in mailbox: String, destination: String?,
                       client: IMAPClient) async throws {
        switch action {
        case .markRead: try await client.uidStore(uids, adding: true, flags: ["\\Seen"])
        case .markUnread: try await client.uidStore(uids, adding: false, flags: ["\\Seen"])
        case .star: try await client.uidStore(uids, adding: true, flags: ["\\Flagged"])
        case .unstar: try await client.uidStore(uids, adding: false, flags: ["\\Flagged"])
        case .deleteForever: try await client.deleteMessages(uids)
        case .trash:
            // Trashing what's already in the trash deletes it for good.
            if mailbox == destination {
                try await client.deleteMessages(uids)
            } else if let destination, LocalFolders.contains(destination) {
                try await keepOnMac(uids, in: destination, client: client)
            } else if let destination {
                try await client.uidMove(uids, to: destination)
            }
        case .archive, .moveToInbox, .markSpam, .notSpam, .move:
            guard let destination, destination != mailbox else { return }
            if destination == Self.starredFolderID {
                try await client.uidStore(uids, adding: true, flags: ["\\Flagged"])
            } else if LocalFolders.contains(destination), localFolders != nil {
                try await keepOnMac(uids, in: destination, client: client)
            } else {
                try await client.uidMove(uids, to: destination)
            }
        case .markImportant, .markNotImportant, .addLabel, .removeLabel:
            break
        }
    }

    // MARK: Kept on this Mac

    /// The server's mailbox with a role, from the last LIST when there's been one, so a folder kept on this Mac can be
    /// used without connecting.
    func serverMailbox(for role: FolderRole) async throws -> String? {
        if let mailboxes { return IMAPFolderRoles.assign(mailboxes).first { $0.value == role }?.key }
        return try await withClient { client in try await self.mailboxName(for: role, client: client) }
    }

    /// Copies messages from the selected mailbox into a folder kept on this Mac, with their flags, then deletes them
    /// from the server. Only what's safely on the Mac leaves the server.
    func keepOnMac(_ uids: [UInt32], in folderID: String, client: IMAPClient) async throws {
        guard let store = localFolders?.store else { return }
        var kept: [UInt32] = []
        for response in try await client.fetchMessages(uids) {
            guard let uid = response.uid, let raw = response.section("") else { continue }
            var flags = MessageSummary(id: "")
            Self.applyFlags(response.flags ?? [], to: &flags)
            let summary = try await store.add(raw: raw, folderID: folderID, isUnread: flags.isUnread, isStarred: flags.isStarred)
            try await keepLabels(response.flags, of: summary, in: store)
            kept.append(uid)
        }
        try await client.deleteMessages(kept)
    }

    /// Actions on messages kept on this Mac. Flags change here. Delete moves a message to the Trash (the server's, or
    /// the one kept here), and deletes it for good from the Trash kept here. Moving one to a server folder, back to the
    /// inbox say, uploads it there.
    func performKept(_ action: MailAction, on messages: [MessageSummary], local: LocalFolders) async throws {
        let store = local.store
        let ids = messages.map(\.id)
        switch action {
        case .markRead: try await store.setUnread(false, for: ids)
        case .markUnread: try await store.setUnread(true, for: ids)
        case .star: try await store.setStarred(true, for: ids)
        case .unstar: try await store.setStarred(false, for: ids)
        case .deleteForever: try await store.delete(ids: ids)
        case .trash:
            var inTrash: [String] = []
            var elsewhere: [String] = []
            for id in ids {
                if await store.summary(for: id)?.folderID == LocalFolders.trashID { inTrash.append(id) } else { elsewhere.append(id) }
            }
            try await store.delete(ids: inTrash)
            guard !elsewhere.isEmpty else { return }
            if let trash = try await serverMailbox(for: .trash) {
                try await upload(elsewhere, to: trash)
            } else {
                try await store.move(ids: elsewhere, to: LocalFolders.trashID)
            }
        case .moveToInbox, .notSpam:
            try await upload(ids, to: "INBOX")
        case .archive:
            if let archive = try await serverMailbox(for: .archive) {
                try await upload(ids, to: archive)
            } else {
                try await store.move(ids: ids, to: LocalFolders.archiveID)
            }
        case .markSpam:
            if let junk = try await serverMailbox(for: .spam) {
                try await upload(ids, to: junk)
            } else {
                try await store.move(ids: ids, to: LocalFolders.spamID)
            }
        case let .move(folderID):
            if LocalFolders.contains(folderID) {
                try await store.move(ids: ids, to: folderID)
            } else if folderID == Self.starredFolderID {
                try await store.setStarred(true, for: ids)
            } else {
                try await upload(ids, to: folderID)
            }
        case .markImportant, .markNotImportant, .addLabel, .removeLabel:
            break
        }
    }

    /// Uploads messages kept on this Mac to a server mailbox, with their flags, letting each copy here go once it's
    /// there.
    func upload(_ ids: [String], to mailbox: String) async throws {
        guard let store = localFolders?.store else { return }
        try await withClient { client in
            for id in ids {
                guard let raw = await store.raw(for: id), let summary = await store.summary(for: id) else { continue }
                var flags: [String] = []
                if !summary.isUnread { flags.append("\\Seen") }
                if summary.isStarred { flags.append("\\Flagged") }
                flags += try await self.labelFlags(forUploading: summary)
                _ = try await client.append(raw, to: mailbox, flags: flags)
                try await store.delete(ids: [id])
            }
        }
    }

    // MARK: Sending and drafts

    public func send(_ message: OutgoingMessage) async throws {
        let raw = MIMEBuilder.build(message)
        do {
            try await sender.send(raw, from: message.from.email, to: message.allRecipients.map(\.email))
        } catch let error as PMailError {
            throw error
        } catch is CancellationError {
            throw PMailError.cancelled
        } catch {
            throw PMailError.connectionFailed(error.localizedDescription)
        }
        // File a copy in Sent. The message has already gone, so a failure here mustn't look like a failed send
        // (which could make someone send it again).
        // The copy keeps its Bcc line, so Sent shows who else it went to.
        let copy = MIMEBuilder.buildForSaving(message)
        let filed = (try? await withClient { client -> Bool in
            guard let sent = try await self.mailboxName(for: .sent, client: client) else { return false }
            _ = try await client.append(copy, to: sent, flags: ["\\Seen"])
            return true
        }) ?? false
        // Without a Sent on the server (or when filing it there failed), the copy is kept in the Sent on this Mac.
        if !filed, let local = localFolders {
            _ = try? await local.store.add(raw: copy, folderID: LocalFolders.sentID, isUnread: false)
        }
    }

    public func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        // A draft has to remember its Bcc recipients.
        let raw = MIMEBuilder.buildForSaving(message)
        // Without a Drafts folder on the server, drafts are kept on this Mac.
        if let local = localFolders, try await serverMailbox(for: .drafts) == nil {
            return try await local.saveDraft(raw, replacing: draft)
        }
        let replaced = draft.flatMap { IMAPMessageID(rawValue: $0.id) }
        // An earlier version kept on this Mac (from before the server had Drafts) goes once this one is saved.
        let keptVersion = draft.flatMap { IMAPMessageID(rawValue: $0.id) == nil ? $0.id : nil }
        let saved = try await withClient { client -> MessageSummary? in
            guard let drafts = try await self.mailboxName(for: .drafts, client: client) else {
                throw PMailError.notSupported("This account has no Drafts folder.")
            }
            let appended = try await client.append(raw, to: drafts, flags: ["\\Draft", "\\Seen"])
            // The new version is saved; the rest is tidying up, and a failure there mustn't lose it.
            if let replaced { try? await self.delete([replaced], client: client) }
            var location = appended
            if location == nil { location = try? await self.findDraft(messageID: message.messageID, in: drafts, client: client) }
            guard let location else { return nil }
            let id = IMAPMessageID(mailbox: drafts, uidValidity: location.uidValidity, uid: location.uid)
            let threadID = message.threadID ?? message.references.first ?? message.inReplyTo ?? message.messageID
            return MessageSummary(id: id.rawValue, threadID: threadID, folderID: drafts, from: message.from, to: message.to,
                                  cc: message.cc, subject: message.subject, snippet: HTMLText.snippet(from: message.textBody),
                                  date: message.date, isUnread: false, isDraft: true,
                                  hasAttachments: !message.attachments.isEmpty, messageIDHeader: message.messageID,
                                  inReplyTo: message.inReplyTo, references: message.references, size: raw.count)
        }
        if let keptVersion { try? await localFolders?.store.delete(ids: [keptVersion]) }
        return saved
    }

    /// Finds a just-saved draft by its Message-ID, for servers that don't say where APPEND put it.
    func findDraft(messageID: String, in drafts: String, client: IMAPClient) async throws -> IMAPAppendResult? {
        let selected = try await client.select(drafts, readOnly: true)
        guard let uid = try await client.uidSearch([.header("Message-ID", messageID)]).max() else { return nil }
        return IMAPAppendResult(uidValidity: selected.uidValidity ?? 0, uid: uid)
    }

    public func deleteDraft(_ draft: MessageSummary) async throws {
        guard let id = IMAPMessageID(rawValue: draft.id) else {
            if let local = localFolders { return try await local.store.delete(ids: [draft.id]) }
            throw PMailError.notFound
        }
        try await withClient { client in try await self.delete([id], client: client) }
    }

    /// Deletes messages for good, mailbox by mailbox.
    func delete(_ ids: [IMAPMessageID], client: IMAPClient) async throws {
        for (mailbox, group) in Self.grouped(ids, by: { $0.mailbox }) {
            let selected = try await ensureSelected(mailbox, writable: true, client: client)
            let uids = group.filter { $0.uidValidity == (selected.uidValidity ?? 0) }.map(\.uid)
            try await client.deleteMessages(uids)
        }
    }

    public func close() async {
        closeCount += 1
        // The connection that waits for changes goes at once, which ends a wait in progress.
        if let waiting = changeClient {
            changeClient = nil
            if isWaitingForChange { await waiting.disconnect() } else { await waiting.logout() }
        }
        try? await exclusively {
            await self.client?.logout()
            self.client = nil
            self.mailboxes = nil
        }
    }

    // MARK: New mail

    /// Checks the inbox with STATUS (UIDNEXT, UIDVALIDITY and UNSEEN), and fetches the messages from the stored UIDNEXT
    /// up when there are any, newest first, at most `newMailLimit`. When the inbox is the mailbox selected on the
    /// connection, where STATUS isn't reliable on every server, UID SEARCH finds them instead (and the unread count
    /// is left out). The state is "<uidvalidity>:<uidnext>"; when UIDVALIDITY changes, what's new can't be told, so the
    /// check starts over from a fresh state without any messages.
    public func checkForNewMail(since state: MailSyncState?) async throws -> NewMail {
        let known = state.flatMap { IMAPInboxState($0) }
        return try await withClient { client in
            if let selected = await client.selectedMailbox, selected.name == "INBOX" {
                return try await self.newMail(inSelectedInbox: selected, since: known, client: client)
            }
            let status = try await client.status("INBOX", items: ["UIDNEXT", "UIDVALIDITY", "UNSEEN"])
            guard let uidValidity = status.uidValidity, let uidNext = status.uidNext else {
                // A server that leaves them out: look in the inbox itself.
                let selected = try await client.select("INBOX", readOnly: true)
                return try await self.newMail(inSelectedInbox: selected, since: known, client: client)
            }
            guard let known, known.uidValidity == uidValidity, uidNext > known.uidNext else {
                // The first check, nothing new, or UIDs that started over.
                let current = IMAPInboxState(uidValidity: uidValidity, uidNext: uidNext)
                return NewMail(messages: [], state: current.syncState, inboxUnread: status.unseen)
            }
            let selected = try await client.select("INBOX", readOnly: true)
            var news = try await self.newMail(inSelectedInbox: selected, since: known, atLeast: uidNext, client: client)
            news.inboxUnread = status.unseen
            return news
        }
    }

    /// What's new in the inbox while it's the selected mailbox: the messages from the stored UIDNEXT up, found with
    /// UID SEARCH. `uidNext` is a UIDNEXT the server gave meanwhile, for the next state.
    func newMail(inSelectedInbox selected: IMAPSelectedMailbox, since known: IMAPInboxState?, atLeast uidNext: UInt32 = 0,
                         client: IMAPClient) async throws -> NewMail {
        let uidValidity = selected.uidValidity ?? 0
        let continuing = known?.uidValidity == uidValidity
        let first = max(1, (continuing ? known?.uidNext : selected.uidNext) ?? 1)
        // `UID n:*` always takes in the newest message, even when its UID is below n.
        let newestFirst = Set(try await client.uidSearch([.uidsFrom(first)])).filter { $0 >= first }.sorted(by: >)
        // Past everything found, so a message that arrived since STATUS isn't announced twice.
        let next = max(first, uidNext, selected.uidNext ?? 0, newestFirst.first.map(Self.uid(after:)) ?? 0)
        let state = IMAPInboxState(uidValidity: uidValidity, uidNext: next).syncState
        guard continuing, !newestFirst.isEmpty else { return NewMail(messages: [], state: state) }
        let picked = Array(newestFirst.prefix(Self.newMailLimit))
        let found = try await summaries(of: picked, in: "INBOX", uidValidity: uidValidity, client: client)
        return NewMail(messages: found.sorted { Self.uid(of: $0) > Self.uid(of: $1) }, state: state)
    }

    // MARK: Finding messages

    /// Searches the inbox, the archive and All Mail, Sent, Drafts and then the account's own folders (never Trash or
    /// Junk), at most `lookupMailboxLimit` of them, with UID SEARCH on the Message-ID header, and stops once every ID
    /// has turned up.
    public func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary] {
        var wanted: [(key: String, id: String)] = []
        for id in messageIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.messageIDKey(trimmed)
            let isRepeat = wanted.contains { $0.key == key }
            guard !key.isEmpty, !isRepeat, !trimmed.contains(where: \.isNewline) else { continue }
            wanted.append((key, trimmed))
        }
        guard !wanted.isEmpty else { return [] }
        // Messages kept on this Mac (snoozed into the Archive kept here, say) are found without the server.
        var kept: [MessageSummary] = []
        if let local = localFolders {
            kept = await local.find(Set(wanted.map(\.key)), key: Self.messageIDKey)
            let keptKeys = Set(kept.compactMap { $0.messageIDHeader.map(Self.messageIDKey) })
            wanted.removeAll { keptKeys.contains($0.key) }
        }
        guard !wanted.isEmpty else { return kept }
        let alsoKept = kept
        return try await withClient { client in
            let boxes = try await self.knownMailboxes(client: client)
            var missing = wanted
            var found: [MessageSummary] = alsoKept
            for mailbox in Self.lookupOrder(boxes, limit: Self.lookupMailboxLimit) {
                if missing.isEmpty { break }
                let selected: IMAPSelectedMailbox
                do {
                    selected = try await client.select(mailbox, readOnly: true)
                } catch PMailError.server {
                    continue  // Gone since the last LIST, or not open to this account.
                }
                guard selected.exists > 0 else { continue }
                var uids = Set<UInt32>()
                for start in stride(from: 0, to: missing.count, by: 20) {
                    let batch = missing[start..<min(start + 20, missing.count)]
                    guard let search = IMAPSearchKey.any(batch.map { .header("Message-ID", $0.id) }) else { continue }
                    uids.formUnion(try await client.uidSearch([search]))
                }
                guard !uids.isEmpty else { continue }
                let summaries = try await self.summaries(of: uids.sorted(), in: mailbox, uidValidity: selected.uidValidity ?? 0,
                                                         client: client)
                // A HEADER search matches part of the field, so each message's own Message-ID decides.
                let keys = Set(missing.map(\.key))
                let matched = summaries.filter { $0.messageIDHeader.map { keys.contains(Self.messageIDKey($0)) } ?? false }
                let foundKeys = Set(matched.compactMap { $0.messageIDHeader.map(Self.messageIDKey) })
                found += matched
                missing.removeAll { foundKeys.contains($0.key) }
            }
            return found
        }
    }

    /// Where `findMessages` looks, in order: the inbox, the archive and All Mail, Sent, Drafts, then the account's own
    /// folders as LIST gave them. Never Trash or Junk or the folders inside them, nor virtual folders of flagged or
    /// important mail, which only repeat messages from elsewhere.
    static func lookupOrder(_ boxes: [IMAPMailbox], limit: Int) -> [String] {
        let roles = IMAPFolderRoles.assign(boxes)
        let skipped = boxes.filter { roles[$0.name] == .trash || roles[$0.name] == .spam }
        func isInsideSkipped(_ box: IMAPMailbox) -> Bool {
            skipped.contains { other in
                guard let delimiter = other.delimiter else { return false }
                return box.name.hasPrefix(other.name + delimiter)
            }
        }
        let selectable = boxes.filter(\.isSelectable)
        var order = ["INBOX"]
        for role in [FolderRole.archive, .allMail, .sent, .drafts] {
            for box in selectable where roles[box.name] == role && !order.contains(box.name) { order.append(box.name) }
        }
        for box in selectable where roles[box.name] == nil && !order.contains(box.name) && !isInsideSkipped(box)
            && !box.hasAttribute("\\Flagged") && !box.hasAttribute("\\Important") {
            order.append(box.name)
        }
        return Array(order.prefix(max(1, limit)))
    }

    // MARK: Waiting for changes

    /// True for IMAP: `waitForChange` listens with IDLE, and asks every minute on servers without it.
    public nonisolated var pushesChanges: Bool { true }

    /// Waits on a second connection of its own with the inbox open read-only, so other calls carry on meanwhile. With
    /// IDLE (renewed every 25 minutes) it returns true as soon as the server reports new mail, an expunge or a flag
    /// change; on a server without IDLE it asks with NOOP every `pollInterval` seconds and returns true when the
    /// message count or flags change. Cancelling the task ends the wait and throws `.cancelled`. A connection that broke
    /// is made again on the next call. Waits run one at a time.
    public func waitForChange(timeout: TimeInterval) async throws -> Bool {
        guard timeout > 0 else { return false }
        let wait = min(timeout, Self.longestWait)
        return try await oneWaitAtATime {
            let deadline = ContinuousClock.now + .seconds(wait)
            let closes = self.closeCount
            // Each read may take as long as one IDLE, with time to spare.
            let streamTimeout = min(wait, Self.longestIdle) + 120
            do {
                while true {
                    if Task.isCancelled { throw PMailError.cancelled }
                    // Made again here when the last one broke.
                    let client = try await self.changeConnection(streamTimeout: streamTimeout)
                    guard await client.hasCapability("IDLE") else {
                        return try await self.pollForChange(on: client, until: deadline)
                    }
                    let start = ContinuousClock.now
                    let roundEnd = min(deadline, start + .seconds(Self.longestIdle))
                    if try await client.idle(until: roundEnd) { return true }
                    let now = ContinuousClock.now
                    if now >= deadline { return false }
                    if now < roundEnd, now - start < .seconds(self.pollInterval) {
                        // The server ended the IDLE straight away: ask now and then rather than again and again.
                        return try await self.pollForChange(on: client, until: deadline)
                    }
                }
            } catch {
                // close() dropped the connection while it waited.
                if self.closeCount != closes { throw PMailError.cancelled }
                throw error
            }
        }
    }

    /// Waits for a change on a server without IDLE by asking with NOOP every `pollInterval` seconds: true once the
    /// inbox's message count or a message's flags change, false at the deadline.
    func pollForChange(on client: IMAPClient, until deadline: ContinuousClock.Instant) async throws -> Bool {
        var count = await client.selectedMailbox?.exists
        while ContinuousClock.now < deadline {
            let next = min(deadline, ContinuousClock.now + .seconds(max(pollInterval, 0.01)))
            do {
                try await Task.sleep(until: next, clock: .continuous)
            } catch {
                throw PMailError.cancelled
            }
            let responses = try await client.noop()
            if responses.contains(where: { Self.reportsChange($0, knownCount: count) }) { return true }
            count = await client.selectedMailbox?.exists
        }
        return false
    }

    /// Whether a response to NOOP says the inbox changed: a different message count, an expunge, or new flags.
    static func reportsChange(_ response: IMAPUntaggedResponse, knownCount: Int?) -> Bool {
        switch response {
        case let .exists(count): count != knownCount
        case .expunge, .fetch: true
        default: false
        }
    }

    /// The connection that waits for changes, signed in and with the inbox open read-only. It's made when there's none
    /// or it has dropped, and made again when its reads can't wait as long as needed.
    func changeConnection(streamTimeout: TimeInterval) async throws -> IMAPClient {
        let client: IMAPClient
        if let current = changeClient, await current.isConnected,
           !(connector is URLSessionConnector) || changeStreamTimeout >= streamTimeout {
            client = current
        } else {
            if let current = changeClient { await current.disconnect() }
            client = IMAPClient(connector: changeConnector(streamTimeout: streamTimeout))
            // Kept before connecting, so close() can drop it while it connects.
            changeClient = client
            changeStreamTimeout = streamTimeout
            try await connectAndSignIn(client)
        }
        if await client.selectedMailbox?.name != "INBOX" { try await client.select("INBOX", readOnly: true) }
        guard changeClient === client else {
            // close() was called meanwhile.
            await client.disconnect()
            throw PMailError.cancelled
        }
        return client
    }

    /// The service's connector, with reads that wait at least `streamTimeout` seconds when it's the network's (a
    /// quiet IDLE mustn't look like a server that stopped answering).
    func changeConnector(streamTimeout: TimeInterval) -> any ByteStreamConnector {
        guard var network = connector as? URLSessionConnector else { return connector }
        network.timeout = max(network.timeout, streamTimeout)
        return network
    }

    /// Runs `body` with no other wait in flight: they share one connection.
    func oneWaitAtATime<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if isWaitingForChange {
            await withCheckedContinuation { changeWaiters.append($0) }
        } else {
            isWaitingForChange = true
        }
        defer {
            if changeWaiters.isEmpty { isWaitingForChange = false } else { changeWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Sets how often a server without IDLE is asked about the inbox, for tests.
    func setPollInterval(_ seconds: TimeInterval) {
        pollInterval = seconds
    }

    // MARK: Connection

    /// Runs `body` with a signed-in client, alone. If the connection had dropped since it was last used, the
    /// service connects again and runs `body` once more.
    func withClient<T: Sendable>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        try await exclusively {
            if let client = self.client, await client.isConnected {
                do {
                    return try await body(client)
                } catch PMailError.connectionFailed {
                    self.client = nil
                }
            }
            let client = try await self.openClient()
            return try await body(client)
        }
    }

    /// Connects and signs in the main connection.
    func openClient() async throws -> IMAPClient {
        let client = IMAPClient(connector: connector)
        try await connectAndSignIn(client)
        self.client = client
        return client
    }

    /// Connects a client and signs it in. On iCloud, a user name the server turns down is tried once more as the part
    /// before the @ (or as the whole address), and whichever works is remembered.
    func connectAndSignIn(_ client: IMAPClient) async throws {
        let names = usernameCandidates()
        for (index, name) in names.enumerated() {
            do {
                // The second try reuses the connection, unless the server hung up after the first.
                if !(await client.isConnected) {
                    try await client.connect(host: incoming.host, port: incoming.port, security: incoming.security)
                }
                try await client.signIn(credential.withUsername(name))
                workingUsername = name
                return
            } catch PMailError.authenticationFailed where index + 1 < names.count {
                continue
            } catch {
                await client.disconnect()
                throw error
            }
        }
        throw PMailError.authenticationFailed("")
    }

    func usernameCandidates() -> [String] {
        let configured = incoming.username.isEmpty ? credential.username : incoming.username
        if let workingUsername { return [workingUsername] }
        let isICloud = account.kind == .icloud || incoming.host.lowercased().hasSuffix("mail.me.com")
        guard isICloud, !configured.isEmpty else { return [configured] }
        if let at = configured.firstIndex(of: "@") {
            let local = String(configured[..<at])
            return local.isEmpty ? [configured] : [configured, local]
        }
        let accountLocal = account.email.split(separator: "@").first.map(String.init)
        let address = accountLocal?.caseInsensitiveCompare(configured) == .orderedSame ? account.email : "\(configured)@icloud.com"
        return [configured, address]
    }

    /// Selects a mailbox unless it's already selected in a way that will do.
    func ensureSelected(_ mailbox: String, writable: Bool, client: IMAPClient) async throws -> IMAPSelectedMailbox {
        if let current = await client.selectedMailbox, current.name == mailbox, !writable || !current.isReadOnly { return current }
        return try await client.select(mailbox, readOnly: !writable)
    }

    /// The mailbox with a role, from the last LIST (listing first if there hasn't been one).
    func mailboxName(for role: FolderRole, client: IMAPClient) async throws -> String? {
        IMAPFolderRoles.assign(try await knownMailboxes(client: client)).first { $0.value == role }?.key
    }

    /// The mailboxes from the last LIST, listing them first if there hasn't been one.
    func knownMailboxes(client: IMAPClient) async throws -> [IMAPMailbox] {
        if let mailboxes { return mailboxes }
        let boxes = try await client.listMailboxes()
        mailboxes = boxes
        return boxes
    }

    /// Runs `body` with no other operation in flight, so one operation's SELECT can't pull the mailbox out from
    /// under another's FETCH.
    func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        defer {
            if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: Helpers

    static func applyFlags(_ flags: [String]?, to summary: inout MessageSummary) {
        guard let flags else { return }
        func has(_ flag: String) -> Bool { flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } }
        summary.isUnread = !has("\\Seen")
        summary.isStarred = has("\\Flagged")
        summary.isDraft = has("\\Draft")
    }

    /// Groups items by a key, keeping the order keys first appear in.
    static func grouped<Element, Key: Hashable>(_ elements: [Element], by key: (Element) -> Key) -> [(Key, [Element])] {
        var order: [Key] = []
        var groups: [Key: [Element]] = [:]
        for element in elements {
            let value = key(element)
            if groups[value] == nil { order.append(value) }
            groups[value, default: []].append(element)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Whether text is a MIME part number ("2", "1.2"), safe to put in a FETCH command.
    static func isSectionNumber(_ text: String) -> Bool {
        !text.isEmpty && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { piece in
            !piece.isEmpty && piece.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        }
    }

    /// The UID after `uid`, staying put at the largest one there can be.
    static func uid(after uid: UInt32) -> UInt32 {
        uid < .max ? uid + 1 : uid
    }

    /// A summary's UID, from its ID (0 for an ID this service didn't make).
    static func uid(of summary: MessageSummary) -> UInt32 {
        IMAPMessageID(rawValue: summary.id)?.uid ?? 0
    }

    /// A Message-ID in a form for comparing: without angle brackets or space around it, in lowercase.
    static func messageIDKey(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }
}

/// Where `IMAPMailService.checkForNewMail` is up to in the inbox: its UIDVALIDITY and UIDNEXT, kept in a
/// `MailSyncState` as "<uidvalidity>:<uidnext>".
struct IMAPInboxState: Hashable {
    var uidValidity: UInt32
    var uidNext: UInt32

    init(uidValidity: UInt32, uidNext: UInt32) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }

    /// Reads a state the IMAP service made; nil for anything else.
    init?(_ state: MailSyncState) {
        let fields = state.value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 2, let uidValidity = UInt32(fields[0]), let uidNext = UInt32(fields[1]) else { return nil }
        self.init(uidValidity: uidValidity, uidNext: uidNext)
    }

    var syncState: MailSyncState { MailSyncState("\(uidValidity):\(uidNext)") }
}

/// Which mailboxes are the special folders.
enum IMAPFolderRoles {
    /// The usual names of special folders on servers without special-use attributes, most likely first.
    static let usualNames: [(FolderRole, [String])] = [
        (.sent, ["Sent", "Sent Messages", "Sent Items", "Sent Mail"]),
        (.drafts, ["Drafts"]),
        (.trash, ["Trash", "Deleted Messages", "Deleted Items", "Bin"]),
        (.spam, ["Junk", "Spam", "Junk E-mail", "Junk Email"]),
        (.archive, ["Archive", "Archives", "All Mail"]),
    ]

    /// Roles by mailbox name: INBOX, then special-use attributes, then the usual names for roles still missing
    /// (among top-level mailboxes and the inbox's own subfolders). Each role goes to one mailbox at most.
    static func assign(_ mailboxes: [IMAPMailbox]) -> [String: FolderRole] {
        var roles: [String: FolderRole] = [:]
        var taken = Set<FolderRole>()
        for mailbox in mailboxes {
            guard let role = mailbox.specialUseRole, !taken.contains(role) else { continue }
            roles[mailbox.name] = role
            taken.insert(role)
        }
        let candidates = mailboxes.filter { mailbox in
            mailbox.isSelectable && mailbox.specialUseRole == nil && (mailbox.parentName == nil || mailbox.parentName == "INBOX")
        }
        for (role, names) in usualNames where !taken.contains(role) {
            for name in names {
                let match = candidates.first { mailbox in
                    roles[mailbox.name] == nil && mailbox.displayName.caseInsensitiveCompare(name) == .orderedSame
                }
                if let match {
                    roles[match.name] = role
                    taken.insert(role)
                    break
                }
            }
        }
        return roles
    }
}
