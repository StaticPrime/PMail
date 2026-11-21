import Foundation

/// A Google account's mail, through Google's mail API. Labels are the folders, conversations are its threads, and
/// whole messages are fetched, sent and saved as drafts in RFC 822 form.
public actor GoogleMailService: MailService {
    /// The account's address.
    public nonisolated let email: String
    let client: WebClient
    /// Draft IDs, by the draft message's ID and by its Message-ID header, so a draft can be replaced or deleted.
    private var draftIDs: [String: String] = [:]

    static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    /// The headers a message list needs, asked for when listing conversations.
    static let listHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "References", "In-Reply-To"]

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
        self.init(email: email, client: WebClient(tokens: tokens, transport: transport))
    }

    init(email: String, client: WebClient) {
        self.email = email
        self.client = client
    }

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: true, canStar: true, canMarkImportant: true, hasInboxTabs: true, searchesOnServer: true,
                         canArchive: true, supportsDrafts: true, canMove: true)
    }

    public nonisolated var inboxTabs: [InboxTab] { Self.tabs }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    // MARK: Folders

    public func loadFolders() async throws -> [MailFolder] {
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

    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
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

        let threadIDs = WebClient.unique(list["threads"].array.compactMap { $0["id"].nonEmpty })
        let metadata = [("format", "metadata")] + Self.listHeaders.map { ("metadataHeaders", $0) }
        let client = self.client
        let threads = try await WebClient.concurrentMap(threadIDs) { id -> JSONValue? in
            do {
                return try await client.get(Self.url("threads/\(WebURL.segment(id))", metadata))
            } catch PMailError.notFound {
                return nil  // Deleted since the list was made.
            }
        }
        let folderID = request.folderID
        let conversations = threads.compactMap { thread -> Conversation? in
            guard let thread, let id = thread["id"].string else { return nil }
            let messages = thread["messages"].array.compactMap(Self.summary(fromMetadata:)).filter {
                Self.isShown($0.labelIDs, listing: folderID)
            }
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

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        let thread = try await client.get(Self.url("threads/\(WebURL.segment(id))", [("format", "minimal")]))
        let entries = thread["messages"].array.filter { $0["id"].nonEmpty != nil }
        let hints = Dictionary((hint?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Trashed and spam messages stay out unless the list showed them (or they're all there is).
        let visible = entries.filter { entry in
            let labels = entry["labelIds"].strings
            return (!labels.contains("TRASH") && !labels.contains("SPAM")) || hints[entry["id"].string ?? ""] != nil
        }
        let client = self.client
        let messages = try await WebClient.concurrentMap(visible.isEmpty ? entries : visible) { entry -> MailMessage? in
            guard let messageID = entry["id"].string else { return nil }
            do {
                let raw = try await client.get(Self.url("messages/\(WebURL.segment(messageID))", [("format", "raw")]))
                return Self.message(fromRaw: raw, hint: hints[messageID])
            } catch PMailError.notFound {
                return nil
            }
        }
        return messages.compactMap { $0 }.sorted { $0.summary.date < $1.summary.date }
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
        return MessageSummary(id: messageID, threadID: result["message"]["threadId"].nonEmpty,
                              labelIDs: labels.isEmpty ? ["DRAFT"] : labels,
                              from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                              snippet: HTMLText.snippet(from: message.textBody), date: message.date, isDraft: true,
                              hasAttachments: !message.attachments.isEmpty, messageIDHeader: message.messageID,
                              inReplyTo: message.inReplyTo, references: message.references)
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
