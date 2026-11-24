import Foundation

/// A Google account's mail, through Google's mail API. Labels are the folders, conversations are its threads, and
/// whole messages are fetched, sent and saved as drafts in RFC 822 form.
public actor GoogleMailService: MailService {
    /// The account's address.
    public nonisolated let email: String
    let client: WebClient
    /// Draft IDs, by the draft message's ID and by its Message-ID header, so a draft can be replaced or deleted.
    private var draftIDs: [String: String] = [:]
    /// List rows fetched before, by thread, with the history ID the list gave the thread then. A thread the list gives
    /// the same history ID again hasn't changed (a new message or a label would have moved it on), so its row isn't
    /// fetched again: Google counts every thread fetched toward what the account may spend in a minute.
    private var listedRows: [String: (historyID: String, messages: [MessageSummary])] = [:]
    /// The most rows kept.
    static let keptRows = 2_000

    static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    /// The headers a message list needs, asked for when listing conversations.
    static let listHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "References", "In-Reply-To"]
    /// The query that fetches a thread or message with only what a list row needs.
    static let metadataQuery: [(String, String)] = [("format", "metadata")] + listHeaders.map { ("metadataHeaders", $0) }

    /// The inbox's category tabs. Their IDs are the category labels.
    static let tabs: [InboxTab] = [
        InboxTab(id: "CATEGORY_PERSONAL", name: "Primary", symbol: "tray"),
        InboxTab(id: "CATEGORY_PROMOTIONS", name: "Promotions", symbol: "tag"),
        InboxTab(id: "CATEGORY_SOCIAL", name: "Social", symbol: "person.2"),
        InboxTab(id: "CATEGORY_UPDATES", name: "Updates", symbol: "info.circle"),
        InboxTab(id: "CATEGORY_FORUMS", name: "Forums", symbol: "bubble.left.and.bubble.right"),
    ]

    /// The system labels shown as special folders, with their names. Other system labels (UNREAD, CHAT and the
    /// categories) aren't shown.
    static let systemFolders: [String: (role: FolderRole, name: String)] = [
        "INBOX": (.inbox, "Inbox"),
        "STARRED": (.starred, "Starred"),
        "IMPORTANT": (.important, "Important"),
        "SENT": (.sent, "Sent"),
        "DRAFT": (.drafts, "Drafts"),
        "SPAM": (.spam, "Spam"),
        "TRASH": (.trash, "Trash"),
    ]

    public init(email: String, tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        // Google counts what each person's requests cost in a minute, and refuses a person too many requests going
        // at once; PMail keeps its own count and its own limit to stay under both.
        let budget = RequestBudget(capacity: Self.unitsPerMinute, backgroundShare: Self.backgroundShare,
                                   cost: { GoogleMailService.quotaCost($0, $1) })
        let gate = RequestGate(limit: Self.requestsAtOnce)
        self.init(email: email, client: WebClient(tokens: tokens, transport: transport, budget: budget, gate: gate))
    }

    init(email: String, client: WebClient) {
        self.email = email
        self.client = client
    }

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: true, canStar: true, canMarkImportant: true, hasInboxTabs: true, searchesOnServer: true,
                         canArchive: true, supportsDrafts: true, canMove: true, canLabel: true, canEditLabels: true,
                         syncsSignature: true)
    }

    public nonisolated var inboxTabs: [InboxTab] { Self.tabs }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    // MARK: Folders

    public func loadFolders() async throws -> [MailFolder] {
        try await fetchFolders()
    }

    /// Every label, with its counts, from Google.
    func fetchFolders() async throws -> [MailFolder] {
        let labels = try await client.get(Self.url("labels"))["labels"].array
        let counted = labels.compactMap { label -> String? in
            guard let id = label["id"].string else { return nil }
            return label["type"].string == "user" || ["INBOX", "DRAFT", "SPAM"].contains(id) ? id : nil
        }
        let client = self.client
        let details = try await WebClient.concurrentMap(counted) { id -> (String, JSONValue) in
            let detail = try? await client.get(Self.url("labels/\(WebURL.segment(id))"))
            return (id, detail ?? .null)
        }
        return Self.folders(from: labels, details: Dictionary(details, uniquingKeysWith: { first, _ in first }))
    }

    /// Folders from the account's labels: system labels as special folders, user labels nested by the "/" in their names.
    /// Counts are of conversations, except Drafts, which counts every draft (as a drafts badge does).
    static func folders(from labels: [JSONValue], details: [String: JSONValue]) -> [MailFolder] {
        var system: [MailFolder] = []
        var user: [(id: String, name: String, label: JSONValue)] = []
        for label in labels {
            guard let id = label["id"].nonEmpty else { continue }
            if label["type"].string == "user" {
                user.append((id, label["name"].string ?? id, label))
                continue
            }
            guard let known = systemFolders[id] else { continue }
            let detail = details[id] ?? .null
            let unread = id == "DRAFT" ? detail["messagesTotal"].int : detail["threadsUnread"].int
            let total = id == "DRAFT" ? detail["messagesTotal"].int : detail["threadsTotal"].int
            system.append(MailFolder(id: id, name: known.name, role: known.role, kind: .folder, unreadCount: unread ?? 0,
                                     totalCount: total))
        }
        system.sort { ($0.role?.sortOrder ?? 99) < ($1.role?.sortOrder ?? 99) }

        let idsByName = Dictionary(user.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        user.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let labelFolders = user.map { entry -> MailFolder in
            let parts = entry.name.components(separatedBy: "/")
            var parentID: String?
            var name = entry.name
            if parts.count > 1 {
                for length in stride(from: parts.count - 1, to: 0, by: -1) {
                    if let parent = idsByName[parts[0..<length].joined(separator: "/")], parent != entry.id {
                        parentID = parent
                        name = parts[length...].joined(separator: "/")
                        break
                    }
                }
            }
            let detail = details[entry.id] ?? .null
            return MailFolder(id: entry.id, name: name, kind: .label, unreadCount: detail["threadsUnread"].int ?? 0,
                              totalCount: detail["threadsTotal"].int, parentID: parentID,
                              colorHex: WebColor.hex(entry.label["color"]["backgroundColor"].string))
        }
        return system + labelFolders
    }

    // MARK: Listing

    /// A page of a list (or a search), from Google.
    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        try await listFromGoogle(request)
    }

    /// A page of a list (or a search) from Google. Rows kept from before are used again for threads that haven't changed
    /// since; only the rest are fetched.
    private func listFromGoogle(_ request: ListRequest) async throws -> ConversationPage {
        var query: [(String, String)] = []
        if let folderID = request.folderID, !folderID.isEmpty {
            query.append(("labelIds", folderID))
            if folderID == "INBOX", let tab = request.tabID, !tab.isEmpty { query.append(("labelIds", tab)) }
            if folderID == "SPAM" || folderID == "TRASH" { query.append(("includeSpamTrash", "true")) }
        }
        if let search = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            query.append(("q", search))
        }
        query.append(("maxResults", String(min(max(request.pageSize, 1), 500))))
        if let token = request.pageToken, !token.isEmpty { query.append(("pageToken", token)) }
        let list = try await client.get(Self.url("threads", query))

        let listed = list["threads"].array
        let threadIDs = WebClient.unique(listed.compactMap { $0["id"].nonEmpty })
        var historyIDs: [String: String] = [:]
        for thread in listed {
            guard let id = thread["id"].nonEmpty, historyIDs[id] == nil, let historyID = thread["historyId"].nonEmpty else { continue }
            historyIDs[id] = historyID
        }
        // Rows fetched before for threads that haven't changed since are used again; only the rest are fetched.
        var rows: [String: [MessageSummary]] = [:]
        for id in threadIDs {
            if let historyID = historyIDs[id], let kept = listedRows[id], kept.historyID == historyID { rows[id] = kept.messages }
        }
        let client = self.client
        let fetched = try await WebClient.concurrentMap(threadIDs.filter { rows[$0] == nil }) { id -> (String, JSONValue?) in
            do {
                return (id, try await client.get(Self.url("threads/\(WebURL.segment(id))", Self.metadataQuery)))
            } catch PMailError.notFound {
                return (id, nil)  // Deleted since the list was made.
            }
        }
        for case let (id, thread?) in fetched {
            let messages = thread["messages"].array.compactMap(Self.summary(fromMetadata:))
            rows[id] = messages
            if let historyID = historyIDs[id] { listedRows[id] = (historyID, messages) }
        }
        if listedRows.count > Self.keptRows {
            let showing = Set(threadIDs)
            listedRows = listedRows.filter { showing.contains($0.key) }
        }
        let folderID = request.folderID
        let conversations = threadIDs.compactMap { id -> Conversation? in
            let messages = (rows[id] ?? []).filter { Self.isShown($0.labelIDs, listing: folderID) }
            return messages.isEmpty ? nil : Conversation(id: id, messages: messages)
        }
        return ConversationPage(conversations: conversations, totalCount: list["resultSizeEstimate"].int,
                                nextPageToken: list["nextPageToken"].nonEmpty)
    }

    /// Whether a message belongs in a list: Trash and Spam show only their own messages, and other lists leave
    /// trashed and spam messages out.
    static func isShown(_ labels: [String], listing folderID: String?) -> Bool {
        switch folderID {
        case "TRASH": labels.contains("TRASH")
        case "SPAM": labels.contains("SPAM")
        default: !labels.contains("TRASH") && !labels.contains("SPAM")
        }
    }

    /// A list row from a message fetched with `format=metadata`.
    static func summary(fromMetadata message: JSONValue) -> MessageSummary? {
        guard let id = message["id"].nonEmpty else { return nil }
        let labels = message["labelIds"].strings
        var headers: [String: String] = [:]
        for header in message["payload"]["headers"].array {
            guard let name = header["name"].string?.lowercased(), headers[name] == nil else { continue }
            headers[name] = header["value"].string ?? ""
        }
        let date = internalDate(message) ?? headers["date"].flatMap(MailDate.parse) ?? Date()
        return MessageSummary(id: id, threadID: message["threadId"].nonEmpty ?? id, labelIDs: labels,
                              from: headers["from"].flatMap { WebAddresses.parse($0).first },
                              to: headers["to"].map(WebAddresses.parse) ?? [], cc: headers["cc"].map(WebAddresses.parse) ?? [],
                              subject: headers["subject"].map(EncodedWords.decode) ?? "",
                              snippet: HTMLText.decodeEntities(message["snippet"].string ?? ""), date: date,
                              isUnread: labels.contains("UNREAD"), isStarred: labels.contains("STARRED"),
                              isImportant: labels.contains("IMPORTANT"), isDraft: labels.contains("DRAFT"),
                              hasAttachments: message["payload"]["mimeType"].string?.lowercased() == "multipart/mixed",
                              messageIDHeader: headers["message-id"].flatMap(nonEmpty),
                              inReplyTo: headers["in-reply-to"].flatMap(nonEmpty),
                              references: headers["references"].map(WebAddresses.messageIDs) ?? [],
                              size: message["sizeEstimate"].int)
    }

    /// When Google received a message (`internalDate`, milliseconds since 1970, sent as a string).
    static func internalDate(_ message: JSONValue) -> Date? {
        message["internalDate"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// List rows for messages, fetched a few at a time with the headers listing asks for. Messages deleted in the
    /// meantime are left out.
    static func summaries(ofMessages ids: [String], client: WebClient) async throws -> [MessageSummary] {
        try await WebClient.concurrentMap(ids) { id -> MessageSummary? in
            do {
                let message = try await client.get(Self.url("messages/\(WebURL.segment(id))", Self.metadataQuery))
                return Self.summary(fromMetadata: message)
            } catch PMailError.notFound {
                return nil
            }
        }.compactMap { $0 }
    }

    // MARK: New mail

    /// The most new messages one check returns.
    static let newMailLimit = 50
    /// How many pages of history (500 changes each) a check reads before it starts again from now instead.
    static let historyPageLimit = 20

    /// New mail from the mailbox's history: the state is the history ID the last check got to. Messages added since
    /// then count while they're still in the inbox, unless they were sent or saved as drafts from the account itself.
    public func checkForNewMail(since state: MailSyncState?) async throws -> NewMail {
        let client = self.client
        async let unread = Self.inboxUnread(client)
        // The first check (or one with a state from something else) starts from now.
        guard let start = state.flatMap({ UInt64($0.value) }) else {
            return NewMail(messages: [], state: try await Self.currentHistory(client), inboxUnread: await unread)
        }
        let pages: [JSONValue]
        do {
            pages = try await client.pages(maxPages: Self.historyPageLimit) { token in
                var query = [("startHistoryId", String(start)), ("historyTypes", "messageAdded"), ("labelId", "INBOX"),
                             ("maxResults", "500")]
                if let token { query.append(("pageToken", token)) }
                return try Self.url("history", query)
            }
        } catch PMailError.notFound {
            // The history isn't kept that far back (it lasts about a week): start again from now.
            return NewMail(messages: [], state: try await Self.currentHistory(client), inboxUnread: await unread)
        }
        if pages.last?["nextPageToken"].nonEmpty != nil {
            // More happened than one check reads: start again from now rather than announce only the oldest of it.
            return NewMail(messages: [], state: try await Self.currentHistory(client), inboxUnread: await unread)
        }
        let records = pages.flatMap { $0["history"].array }
        // History runs oldest first. A message its labels there already rule out (mail sent from the account) isn't fetched.
        var seen = Set<String>()
        var candidates: [String] = []
        for record in records.reversed() {
            for added in record["messagesAdded"].array.reversed() {
                guard let id = added["message"]["id"].nonEmpty, seen.insert(id).inserted else { continue }
                let labels = added["message"]["labelIds"].strings
                if labels.isEmpty || Self.isNewInInbox(labels) { candidates.append(id) }
            }
        }
        // The labels as they are now decide: a message archived since it came isn't new mail any more.
        let messages = try await Self.summaries(ofMessages: Array(candidates.prefix(Self.newMailLimit)), client: client)
            .filter { Self.isNewInInbox($0.labelIDs) }
        let latest = (pages.map { $0["historyId"] } + records.map { $0["id"] }).compactMap(Self.historyID).max() ?? start
        return NewMail(messages: messages, state: MailSyncState(String(max(latest, start))), inboxUnread: await unread)
    }

    /// Whether a message with these labels is new mail: in the inbox, and not sent or drafted from the account (nor in
    /// Trash or Spam).
    static func isNewInInbox(_ labels: [String]) -> Bool {
        labels.contains("INBOX") && !labels.contains { ["DRAFT", "SENT", "TRASH", "SPAM"].contains($0) }
    }

    /// A history ID, which Google sends as a string of digits.
    static func historyID(_ json: JSONValue) -> UInt64? {
        if let text = json.string { return UInt64(text.trimmingCharacters(in: .whitespaces)) }
        return json.int.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    /// The mailbox's history ID now, for a check that starts from now.
    static func currentHistory(_ client: WebClient) async throws -> MailSyncState {
        let profile = try await client.get(Self.url("profile"))
        guard let id = historyID(profile["historyId"]) else { throw PMailError.protocolError("the mailbox had no history ID") }
        return MailSyncState(String(id))
    }

    /// How many messages in the inbox are unread, or nil when that can't be had (a check doesn't need it).
    static func inboxUnread(_ client: WebClient) async -> Int? {
        guard let address = try? Self.url("labels/INBOX") else { return nil }
        return try? await client.get(address)["messagesUnread"].int
    }

    // MARK: Finding messages

    /// Searches for each Message-ID with `rfc822msgid:`. The search leaves Trash and Spam out, and so does a check of
    /// the labels after it.
    public func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary] {
        let searches = WebClient.unique(messageIDs.compactMap(WebAddresses.bareMessageID))
        let client = self.client
        let found = try await WebClient.concurrentMap(searches) { messageID -> [String] in
            let list = try await client.get(Self.url("messages", [("q", "rfc822msgid:\(messageID)")]))
            return list["messages"].array.compactMap { $0["id"].nonEmpty }
        }
        return try await Self.summaries(ofMessages: WebClient.unique(found.flatMap { $0 }), client: client)
            .filter { Self.isShown($0.labelIDs, listing: nil) }
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        try await loadConversation(id: id, hint: hint, known: [])
    }

    /// A message never changes once it's in the mailbox, only its labels: one kept from opening the conversation
    /// before is used again with its labels as they are now, and only the others are fetched.
    public func loadConversation(id: String, hint: Conversation?, known: [MailMessage]) async throws -> [MailMessage] {
        // Which messages the conversation has, with their labels.
        let thread = try await client.get(Self.url("threads/\(WebURL.segment(id))", [("format", "minimal")]))
        let entries: [(id: String, labels: [String], summary: MessageSummary?)] = thread["messages"].array.compactMap { entry in
            entry["id"].nonEmpty.map { ($0, entry["labelIds"].strings, nil) }
        }
        let hints = Dictionary((hint?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Trashed and spam messages stay out unless the list showed them (or they're all there is).
        let visible = entries.filter { entry in
            (!entry.labels.contains("TRASH") && !entry.labels.contains("SPAM")) || hints[entry.id] != nil
        }
        let kept = Dictionary(known.filter { $0.htmlBody != nil || $0.textBody != nil }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let client = self.client
        let messages = try await WebClient.concurrentMap(visible.isEmpty ? entries : visible) { entry -> MailMessage? in
            if let message = kept[entry.id] { return Self.relabeled(message, entry.labels) }
            do {
                let raw = try await client.get(Self.url("messages/\(WebURL.segment(entry.id))", [("format", "raw")]))
                return Self.message(fromRaw: raw, hint: hints[entry.id] ?? entry.summary)
            } catch PMailError.notFound {
                return nil
            }
        }
        return messages.compactMap { $0 }.sorted { $0.summary.date < $1.summary.date }
    }

    /// A message kept from before with its labels (and so its read, starred, important and draft marks) as they are
    /// now. Google leaves a message with no labels without a label list.
    static func relabeled(_ message: MailMessage, _ labels: [String]) -> MailMessage {
        var message = message
        message.summary = relabeled(message.summary, labels)
        return message
    }

    static func relabeled(_ summary: MessageSummary, _ labels: [String]) -> MessageSummary {
        var summary = summary
        summary.labelIDs = labels
        summary.isUnread = labels.contains("UNREAD")
        summary.isStarred = labels.contains("STARRED")
        summary.isImportant = labels.contains("IMPORTANT")
        summary.isDraft = labels.contains("DRAFT")
        return summary
    }

    public func loadMessage(_ summary: MessageSummary) async throws -> MailMessage {
        let raw = try await client.get(Self.url("messages/\(WebURL.segment(summary.id))", [("format", "raw")]))
        return Self.message(fromRaw: raw, hint: summary)
    }

    public func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        if let data = attachment.data { return data }
        let full = try await loadMessage(message)
        if let data = (full.attachments + full.inlineParts).first(where: { $0.id == attachment.id })?.data { return data }
        throw PMailError.notFound
    }

    /// A whole message from a `format=raw` answer: the base64url RFC 822 text parsed, with Google's labels. A message
    /// whose text can't be read still comes back, with what the list knew about it.
    static func message(fromRaw json: JSONValue, hint: MessageSummary?) -> MailMessage {
        guard let text = json["raw"].string, let data = TransferEncoding.decodeBase64(text), !data.isEmpty else {
            return MailMessage(summary: summary(fromRaw: json, parsed: ParsedMessage(), hint: hint))
        }
        let parsed = MIMEParser.parse(data)
        return parsed.mailMessage(summary: summary(fromRaw: json, parsed: parsed, hint: hint), rawSource: data)
    }

    /// The summary for a fetched message: Google's labels and dates, the message's own headers, and what the list
    /// already knew for anything the headers leave out.
    static func summary(fromRaw json: JSONValue, parsed: ParsedMessage, hint: MessageSummary?) -> MessageSummary {
        let id = json["id"].nonEmpty ?? hint?.id ?? ""
        let labels = json["labelIds"].array.isEmpty ? (hint?.labelIDs ?? []) : json["labelIds"].strings
        return MessageSummary(id: id, threadID: json["threadId"].nonEmpty ?? hint?.threadID, labelIDs: labels,
                              from: parsed.from ?? hint?.from, to: parsed.to.isEmpty ? hint?.to ?? [] : parsed.to,
                              cc: parsed.cc.isEmpty ? hint?.cc ?? [] : parsed.cc,
                              subject: parsed.subject.isEmpty ? hint?.subject ?? "" : parsed.subject,
                              snippet: json["snippet"].string.map(HTMLText.decodeEntities) ?? hint?.snippet ?? parsed.snippet,
                              date: internalDate(json) ?? parsed.date ?? hint?.date ?? Date(),
                              isUnread: labels.contains("UNREAD"), isStarred: labels.contains("STARRED"),
                              isImportant: labels.contains("IMPORTANT"), isDraft: labels.contains("DRAFT"),
                              hasAttachments: !parsed.attachments.isEmpty || (hint?.hasAttachments ?? false),
                              messageIDHeader: parsed.messageID ?? hint?.messageIDHeader,
                              inReplyTo: parsed.inReplyTo ?? hint?.inReplyTo,
                              references: parsed.references.isEmpty ? hint?.references ?? [] : parsed.references,
                              size: json["sizeEstimate"].int ?? hint?.size)
    }

    // MARK: Actions

    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        let ids = WebClient.unique(messages.map(\.id).filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        let outOfTrash = ["TRASH", "SPAM"].filter { label in messages.contains { $0.labelIDs.contains(label) } }
        switch action {
        case .markRead: try await modify(ids, remove: ["UNREAD"])
        case .markUnread: try await modify(ids, add: ["UNREAD"])
        case .star: try await modify(ids, add: ["STARRED"])
        case .unstar: try await modify(ids, remove: ["STARRED"])
        case .markImportant: try await modify(ids, add: ["IMPORTANT"])
        case .markNotImportant: try await modify(ids, remove: ["IMPORTANT"])
        case .archive: try await modify(ids, remove: ["INBOX"])
        case .moveToInbox: try await modify(ids, add: ["INBOX"], remove: outOfTrash)
        case .markSpam: try await modify(ids, add: ["SPAM"], remove: ["INBOX"])
        case .notSpam: try await modify(ids, add: ["INBOX"], remove: ["SPAM"])
        case let .addLabel(label): try await modify(ids, add: [label])
        case let .removeLabel(label): try await modify(ids, remove: [label])
        case let .move(folderID):
            switch folderID {
            case "INBOX": try await modify(ids, add: ["INBOX"], remove: outOfTrash)
            case "TRASH": try await trash(ids)
            case "SPAM": try await modify(ids, add: ["SPAM"], remove: ["INBOX"])
            default: try await modify(ids, add: [folderID], remove: ["INBOX"] + outOfTrash)
            }
        case .trash: try await trash(ids)
        case .deleteForever:
            for chunk in WebClient.chunked(ids, size: 1000) {
                _ = try await client.post(Self.url("messages/batchDelete"), ["ids": JSONValue(chunk)])
            }
        }
    }

    /// Adds and removes labels on many messages at once (up to 1,000 per request).
    private func modify(_ ids: [String], add: [String] = [], remove: [String] = []) async throws {
        for chunk in WebClient.chunked(ids, size: 1000) {
            var body: [String: JSONValue] = ["ids": JSONValue(chunk)]
            if !add.isEmpty { body["addLabelIds"] = JSONValue(add) }
            if !remove.isEmpty { body["removeLabelIds"] = JSONValue(remove) }
            _ = try await client.post(Self.url("messages/batchModify"), .object(body))
        }
    }

    private func trash(_ ids: [String]) async throws {
        let client = self.client
        _ = try await WebClient.concurrentMap(ids) { id in
            do {
                _ = try await client.post(Self.url("messages/\(WebURL.segment(id))/trash"))
            } catch PMailError.notFound {
                // Already gone.
            }
        }
    }

    // MARK: Sending and drafts

    public func send(_ message: OutgoingMessage) async throws {
        _ = try await client.post(Self.url("messages/send"), Self.rawMessage(message, threadID: message.threadID))
    }

    /// A list row for a message sent or saved from here.
    static func summary(of message: OutgoingMessage, id: String, threadID: String?, labels: [String]) -> MessageSummary {
        MessageSummary(id: id, threadID: threadID, labelIDs: labels, from: message.from, to: message.to, cc: message.cc,
                       subject: message.subject, snippet: HTMLText.snippet(from: message.textBody), date: message.date,
                       isUnread: labels.contains("UNREAD"), isStarred: labels.contains("STARRED"), isDraft: labels.contains("DRAFT"),
                       hasAttachments: !message.attachments.isEmpty, messageIDHeader: message.messageID,
                       inReplyTo: message.inReplyTo, references: message.references)
    }

    /// The `{raw, threadId}` form of a message that Google's mail API takes.
    static func rawMessage(_ message: OutgoingMessage, threadID: String?) -> JSONValue {
        var body: [String: JSONValue] = ["raw": .string(WebBase64.urlEncoded(WebMIME.build(message)))]
        if let threadID, !threadID.isEmpty { body["threadId"] = .string(threadID) }
        return .object(body)
    }

    public func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        let inner = Self.rawMessage(message, threadID: message.threadID ?? draft?.threadID)
        var saved: JSONValue?
        if let draft, let draftID = try await findDraftID(for: draft) {
            do {
                let url = try Self.url("drafts/\(WebURL.segment(draftID))")
                saved = try await client.put(url, ["id": .string(draftID), "message": inner])
            } catch PMailError.notFound {
                saved = nil  // Sent or deleted somewhere else: save it as a new draft.
            }
        }
        let result: JSONValue
        if let saved {
            result = saved
        } else {
            result = try await client.post(Self.url("drafts"), ["message": inner])
        }
        if let draft { forget(draft) }
        guard let draftID = result["id"].nonEmpty, let messageID = result["message"]["id"].nonEmpty else {
            throw PMailError.protocolError("the saved draft had no ID")
        }
        draftIDs[messageID] = draftID
        draftIDs[message.messageID] = draftID
        let labels = result["message"]["labelIds"].strings
        var summary = Self.summary(of: message, id: messageID, threadID: result["message"]["threadId"].nonEmpty,
                                   labels: labels.isEmpty ? ["DRAFT"] : labels)
        summary.isDraft = true
        return summary
    }

    public func deleteDraft(_ draft: MessageSummary) async throws {
        guard let draftID = try await findDraftID(for: draft) else { return }  // Not a draft any more.
        do {
            try await client.delete(Self.url("drafts/\(WebURL.segment(draftID))"))
        } catch PMailError.notFound {
            // Already gone.
        }
        forget(draft)
    }

    /// The draft ID for a draft message: remembered from saving it, else found among the account's drafts.
    private func findDraftID(for draft: MessageSummary) async throws -> String? {
        if let id = draftIDs[draft.id] { return id }
        if let header = draft.messageIDHeader, let id = draftIDs[header] { return id }
        var token: String?
        var pages = 0
        repeat {
            var query = [("maxResults", "500")]
            if let token { query.append(("pageToken", token)) }
            let page = try await client.get(Self.url("drafts", query))
            let match = page["drafts"].array.first { $0["message"]["id"].string == draft.id }
            if let id = match?["id"].nonEmpty {
                draftIDs[draft.id] = id
                return id
            }
            token = page["nextPageToken"].nonEmpty
            pages += 1
        } while token != nil && pages < 20
        if let header = draft.messageIDHeader, !header.isEmpty {
            let found = try await client.get(Self.url("drafts", [("q", "rfc822msgid:\(header)"), ("maxResults", "1")]))
            if let id = found["drafts"][0]["id"].nonEmpty {
                draftIDs[draft.id] = id
                return id
            }
        }
        return nil
    }

    private func forget(_ draft: MessageSummary) {
        draftIDs[draft.id] = nil
        if let header = draft.messageIDHeader { draftIDs[header] = nil }
    }

    public func close() async {}
}
