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
/// to have dropped (the server timed it out, the network changed), it connects again and tries once more.
public actor IMAPMailService: MailService {
    /// The ID of the virtual folder that lists the inbox's starred (\Flagged) messages.
    public static let starredFolderID = "pmail:starred"

    /// How much of a plain text part to fetch for its snippet.
    static let textSnippetLength = 2048
    /// How much of an HTML part to fetch for its snippet: more than for plain text, since a style sheet often
    /// comes before the first words.
    static let htmlSnippetLength = 8192

    public nonisolated let account: Account
    private let incoming: ServerSettings
    private let credential: Credential
    private let sender: any MailSending
    private let connector: any ByteStreamConnector
    private var client: IMAPClient?
    /// The user name the server accepted, once one has worked (iCloud takes the whole address or the part before
    /// the @, depending on the account).
    private var workingUsername: String?
    /// The mailboxes from the last LIST, for finding Sent, Drafts, Trash, Junk and Archive.
    private var mailboxes: [IMAPMailbox]?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(account: Account, incoming: ServerSettings, credential: Credential, sender: any MailSending,
                connector: any ByteStreamConnector = URLSessionConnector()) {
        self.account = account
        self.incoming = incoming
        self.credential = credential
        self.sender = sender
        self.connector = connector
    }

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: false, hasInboxTabs: false, searchesOnServer: true,
                         canArchive: true, supportsDrafts: true, canMove: true)
    }

    public nonisolated var inboxTabs: [InboxTab] { [] }

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
            // The inbox first, then its starred messages as a folder of their own.
            if let index = folders.firstIndex(where: { $0.role == .inbox }) { folders.insert(folders.remove(at: index), at: 0) }
            let starred = MailFolder(id: Self.starredFolderID, name: "Starred", role: .starred)
            folders.insert(starred, at: folders.first?.role == .inbox ? 1 : 0)
            return folders
        }
    }

    // MARK: Listing

    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        try await withClient { client in
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
    private func listTarget(for folderID: String?, client: IMAPClient) async throws -> (String, IMAPSearchKey?) {
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
    private func summaries(of uids: [UInt32], in mailbox: String, uidValidity: UInt32,
                           client: IMAPClient) async throws -> [MessageSummary] {
        guard !uids.isEmpty else { return [] }
        let fetched = try await client.fetchSummaries(uids)
        let snippets = try await self.snippets(for: fetched, client: client)
        return fetched.compactMap { response in
            guard let uid = response.uid else { return nil }
            return Self.summary(from: response, id: IMAPMessageID(mailbox: mailbox, uidValidity: uidValidity, uid: uid),
                                snippet: snippets[uid] ?? "")
        }
    }

    /// Snippets from the start of each message's text part: one partial fetch for each part number in use.
    private func snippets(for fetched: [IMAPFetchResponse], client: IMAPClient) async throws -> [UInt32: String] {
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
        return MessageSummary(id: id.rawValue, threadID: threadID, folderID: id.mailbox, from: envelope?.from.first,
                              to: envelope?.to ?? [], cc: envelope?.cc ?? [], subject: envelope?.subject ?? "", snippet: snippet,
                              date: envelope?.date ?? response.internalDate ?? Date(timeIntervalSince1970: 0),
                              isUnread: !response.hasFlag("\\Seen"), isStarred: response.hasFlag("\\Flagged"),
                              isDraft: response.hasFlag("\\Draft"), hasAttachments: response.bodyStructure?.hasAttachments ?? false,
                              messageIDHeader: messageID, inReplyTo: inReplyTo, references: references, size: response.size)
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        try await withClient { client in
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
            if messages.isEmpty { throw PMailError.notFound }
            return messages.sorted { $0.summary.date < $1.summary.date }
        }
    }

    /// The messages in a mailbox that belong to a conversation: replies to its first message (by References or
    /// In-Reply-To) and that message itself (by Message-ID).
    private func relatedMessages(in mailbox: String, roots: [String], skipping loaded: Set<IMAPMessageID>,
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
        guard let id = IMAPMessageID(rawValue: summary.id) else { throw PMailError.notFound }
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
        guard let id = IMAPMessageID(rawValue: message.id) else { throw PMailError.notFound }
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
            throw PMailError.notSupported("This account uses folders, not labels.")
        default:
            break
        }
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
    private func destination(for action: MailAction, client: IMAPClient) async throws -> String? {
        switch action {
        case .archive:
            guard let archive = try await mailboxName(for: .archive, client: client) else {
                throw PMailError.notSupported("This account has no Archive folder.")
            }
            return archive
        case .trash:
            guard let trash = try await mailboxName(for: .trash, client: client) else {
                throw PMailError.notSupported("This account has no Trash folder.")
            }
            return trash
        case .markSpam:
            guard let junk = try await mailboxName(for: .spam, client: client) else {
                throw PMailError.notSupported("This account has no Junk folder.")
            }
            return junk
        case .moveToInbox, .notSpam:
            return "INBOX"
        case let .move(folderID):
            return folderID
        default:
            return nil
        }
    }

    private func apply(_ action: MailAction, to uids: [UInt32], in mailbox: String, destination: String?,
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
            } else if let destination {
                try await client.uidMove(uids, to: destination)
            }
        case .archive, .moveToInbox, .markSpam, .notSpam, .move:
            guard let destination, destination != mailbox else { return }
            if destination == Self.starredFolderID {
                try await client.uidStore(uids, adding: true, flags: ["\\Flagged"])
            } else {
                try await client.uidMove(uids, to: destination)
            }
        case .markImportant, .markNotImportant, .addLabel, .removeLabel:
            break
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
        _ = try? await withClient { client in
            guard let sent = try await self.mailboxName(for: .sent, client: client) else { return }
            try await client.append(copy, to: sent, flags: ["\\Seen"])
        }
    }

    public func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        // A draft has to remember its Bcc recipients.
        let raw = MIMEBuilder.buildForSaving(message)
        let replaced = draft.flatMap { IMAPMessageID(rawValue: $0.id) }
        return try await withClient { client in
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
    }

    /// Finds a just-saved draft by its Message-ID, for servers that don't say where APPEND put it.
    private func findDraft(messageID: String, in drafts: String, client: IMAPClient) async throws -> IMAPAppendResult? {
        let selected = try await client.select(drafts, readOnly: true)
        guard let uid = try await client.uidSearch([.header("Message-ID", messageID)]).max() else { return nil }
        return IMAPAppendResult(uidValidity: selected.uidValidity ?? 0, uid: uid)
    }

    public func deleteDraft(_ draft: MessageSummary) async throws {
        guard let id = IMAPMessageID(rawValue: draft.id) else { throw PMailError.notFound }
        try await withClient { client in try await self.delete([id], client: client) }
    }

    /// Deletes messages for good, mailbox by mailbox.
    private func delete(_ ids: [IMAPMessageID], client: IMAPClient) async throws {
        for (mailbox, group) in Self.grouped(ids, by: { $0.mailbox }) {
            let selected = try await ensureSelected(mailbox, writable: true, client: client)
            let uids = group.filter { $0.uidValidity == (selected.uidValidity ?? 0) }.map(\.uid)
            try await client.deleteMessages(uids)
        }
    }

    public func close() async {
        try? await exclusively {
            await self.client?.logout()
            self.client = nil
            self.mailboxes = nil
        }
    }

    // MARK: Connection

    /// Runs `body` with a signed-in client, alone. If the connection had dropped since it was last used, the
    /// service connects again and runs `body` once more.
    private func withClient<T: Sendable>(_ body: (IMAPClient) async throws -> T) async throws -> T {
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

    /// Connects and signs in. On iCloud, a user name the server turns down is tried once more as the part before
    /// the @ (or as the whole address), and whichever works is remembered.
    private func openClient() async throws -> IMAPClient {
        let client = IMAPClient(connector: connector)
        let names = usernameCandidates()
        for (index, name) in names.enumerated() {
            do {
                // The second try reuses the connection, unless the server hung up after the first.
                if !(await client.isConnected) {
                    try await client.connect(host: incoming.host, port: incoming.port, security: incoming.security)
                }
                try await client.signIn(credential.withUsername(name))
                workingUsername = name
                self.client = client
                return client
            } catch PMailError.authenticationFailed where index + 1 < names.count {
                continue
            } catch {
                await client.disconnect()
                throw error
            }
        }
        throw PMailError.authenticationFailed("")
    }

    private func usernameCandidates() -> [String] {
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
    private func ensureSelected(_ mailbox: String, writable: Bool, client: IMAPClient) async throws -> IMAPSelectedMailbox {
        if let current = await client.selectedMailbox, current.name == mailbox, !writable || !current.isReadOnly { return current }
        return try await client.select(mailbox, readOnly: !writable)
    }

    /// The mailbox with a role, from the last LIST (listing first if there hasn't been one).
    private func mailboxName(for role: FolderRole, client: IMAPClient) async throws -> String? {
        let boxes: [IMAPMailbox]
        if let mailboxes {
            boxes = mailboxes
        } else {
            boxes = try await client.listMailboxes()
            mailboxes = boxes
        }
        return IMAPFolderRoles.assign(boxes).first { $0.value == role }?.key
    }

    /// Runs `body` with no other operation in flight, so one operation's SELECT can't pull the mailbox out from
    /// under another's FETCH.
    private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
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
