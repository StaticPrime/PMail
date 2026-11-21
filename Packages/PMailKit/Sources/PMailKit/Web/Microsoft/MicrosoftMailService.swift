import Foundation

/// A Microsoft account's mail, through Microsoft Graph. Mail lives in folders; flagged messages show in a Starred
/// folder of their own, and whole messages are fetched, sent and saved as drafts in MIME form.
public actor MicrosoftMailService: MailService {
    /// The account's address.
    public nonisolated let email: String
    let client: WebClient
    /// The special folders' IDs and roles, looked up once.
    private var wellKnown: [String: FolderRole]?
    /// Set when the server turns down the Focused/Other filter (accounts without a Focused Inbox).
    private var focusedFilterRefused = false

    static let base = Graph.root + "me/"
    /// The Starred folder: every flagged message, wherever it's filed.
    public static let flaggedFolderID = "pmail:flagged"
    /// Message IDs that stay the same when a message moves between folders.
    static let headers = ["Prefer": "IdType=\"ImmutableId\""]
    static let listHeaders = ["Prefer": "IdType=\"ImmutableId\"", "ConsistencyLevel": "eventual"]
    static let messageFields = "id,conversationId,subject,bodyPreview,from,toRecipients,ccRecipients,receivedDateTime,isRead,"
        + "flag,importance,hasAttachments,isDraft,internetMessageId,parentFolderId"
    /// The special folders, by the names Graph knows them by.
    static let wellKnownNames: [(name: String, role: FolderRole)] = [
        ("inbox", .inbox), ("sentitems", .sent), ("drafts", .drafts), ("deleteditems", .trash), ("junkemail", .spam),
        ("archive", .archive),
    ]
    static let tabs: [InboxTab] = [
        InboxTab(id: "focused", name: "Focused", symbol: "scope"),
        InboxTab(id: "other", name: "Other", symbol: "tray.2"),
    ]

    public init(email: String, tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(email: email, client: WebClient(tokens: tokens, transport: transport))
    }

    init(email: String, client: WebClient) {
        self.email = email
        self.client = client
    }

    public nonisolated var capabilities: MailCapabilities {
        MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: true, hasInboxTabs: true, searchesOnServer: true,
                         canArchive: true, supportsDrafts: true, canMove: true)
    }

    public nonisolated var inboxTabs: [InboxTab] { Self.tabs }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    // MARK: Folders

    public func loadFolders() async throws -> [MailFolder] {
        let roles = await wellKnownFolders()
        let client = self.client
        var level = try await client.graphItems(Self.url("mailFolders", [("$top", "100")]), headers: Self.headers)
        var all = level
        // Nested folders, a level at a time.
        for _ in 0..<12 {
            let parents = level.filter { ($0["childFolderCount"].int ?? 0) > 0 }.compactMap { $0["id"].nonEmpty }
            guard !parents.isEmpty else { break }
            level = try await WebClient.concurrentMap(parents) { id -> [JSONValue] in
                do {
                    let url = try Self.url("mailFolders/\(WebURL.segment(id))/childFolders", [("$top", "100")])
                    return try await client.graphItems(url, headers: Self.headers)
                } catch PMailError.notFound {
                    return []
                }
            }.flatMap { $0 }
            all += level
        }
        return Self.folders(from: all, roles: roles)
    }

    /// Folders in tree order (each followed by the folders inside it), then the Starred folder.
    static func folders(from items: [JSONValue], roles: [String: FolderRole]) -> [MailFolder] {
        let ids = Set(items.compactMap { $0["id"].nonEmpty })
        var children: [String: [MailFolder]] = [:]
        var topLevel: [MailFolder] = []
        var seen = Set<String>()
        for item in items {
            guard let id = item["id"].nonEmpty, seen.insert(id).inserted else { continue }
            let parentID = item["parentFolderId"].nonEmpty.flatMap { ids.contains($0) && $0 != id ? $0 : nil }
            let folder = MailFolder(id: id, name: item["displayName"].string ?? "", role: roles[id], kind: .folder,
                                    unreadCount: item["unreadItemCount"].int ?? 0, totalCount: item["totalItemCount"].int,
                                    parentID: parentID)
            if let parentID { children[parentID, default: []].append(folder) } else { topLevel.append(folder) }
        }
        var ordered: [MailFolder] = []
        var placed = Set<String>()
        func place(_ folder: MailFolder) {
            guard placed.insert(folder.id).inserted else { return }
            ordered.append(folder)
            for child in children[folder.id] ?? [] { place(child) }
        }
        topLevel.forEach(place)
        for folder in children.values.flatMap({ $0 }) where !placed.contains(folder.id) { place(folder) }
        ordered.append(MailFolder(id: flaggedFolderID, name: "Starred", role: .starred, kind: .folder))
        return ordered
    }

    /// The special folders' IDs, fetched once (a folder that doesn't exist, like an older account's Archive, is skipped).
    private func wellKnownFolders() async -> [String: FolderRole] {
        if let wellKnown { return wellKnown }
        let client = self.client
        let found = (try? await WebClient.concurrentMap(Self.wellKnownNames) { entry -> (String, FolderRole)? in
            let url = try Self.url("mailFolders/\(entry.name)", [("$select", "id")])
            let folder = try? await client.get(url, headers: Self.headers)
            guard let id = folder?["id"].nonEmpty else { return nil }
            return (id, entry.role)
        }) ?? []
        let roles = Dictionary(found.compactMap { $0 }, uniquingKeysWith: { first, _ in first })
        if roles.values.contains(.inbox) { wellKnown = roles }
        return roles
    }

    // MARK: Listing

    public func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        let search = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let flagged = request.folderID == Self.flaggedFolderID
        if let token = request.pageToken, !token.isEmpty, let next = Graph.url(fromLink: token) {
            return try await page(at: next, flaggedOnly: flagged && !search.isEmpty)
        }
        let collection: String
        if let folderID = request.folderID, !folderID.isEmpty, !flagged {
            collection = "mailFolders/\(WebURL.segment(folderID))/messages"
        } else {
            collection = "messages"
        }
        let pageSize = min(max(request.pageSize, 1), 1000)
        var query = [("$top", String(pageSize)), ("$select", Self.messageFields)]
        var tab: String?
        if search.isEmpty {
            var filters: [String] = []
            if flagged { filters.append("flag/flagStatus eq 'flagged'") }
            if let tabID = request.tabID, ["focused", "other"].contains(tabID), !focusedFilterRefused,
               await isInbox(request.folderID) {
                tab = tabID
                filters.append("inferenceClassification eq '\(tabID)'")
            }
            query.append(("$orderby", "receivedDateTime desc"))
            // Graph wants the sort's property filtered first when a list is both filtered and sorted.
            if !filters.isEmpty {
                query.append(("$filter", (["receivedDateTime ge 1900-01-01T00:00:00Z"] + filters).joined(separator: " and ")))
            }
            query.append(("$count", "true"))
            if request.pageIndex > 0 { query.append(("$skip", String(min(request.pageIndex, 1_000_000) * pageSize))) }
        } else {
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            query.append(("$search", "\"\(escaped)\""))
        }
        do {
            return try await page(at: Self.url(collection, query), flaggedOnly: flagged && !search.isEmpty)
        } catch let PMailError.http(status, _) where status == 400 && tab != nil {
            focusedFilterRefused = true  // No Focused Inbox here: list everything instead.
            return try await listConversations(request)
        }
    }

    private func isInbox(_ folderID: String?) async -> Bool {
        guard let folderID, !folderID.isEmpty else { return false }
        if folderID.lowercased() == "inbox" { return true }
        return await wellKnownFolders()[folderID] == .inbox
    }

    private func page(at url: URL, flaggedOnly: Bool) async throws -> ConversationPage {
        let json = try await client.get(url, headers: Self.listHeaders)
        var summaries = json["value"].array.compactMap(Self.summary(from:))
        if flaggedOnly { summaries = summaries.filter(\.isStarred) }
        return ConversationPage(conversations: Conversation.group(summaries), totalCount: json["@odata.count"].int,
                                nextPageToken: json["@odata.nextLink"].nonEmpty)
    }

    /// A list row from a Graph message.
    static func summary(from json: JSONValue) -> MessageSummary? {
        guard let id = json["id"].nonEmpty else { return nil }
        return MessageSummary(id: id, threadID: json["conversationId"].nonEmpty ?? id, folderID: json["parentFolderId"].nonEmpty,
                              from: Graph.address(json["from"]), to: json["toRecipients"].array.compactMap(Graph.address),
                              cc: json["ccRecipients"].array.compactMap(Graph.address), subject: json["subject"].string ?? "",
                              snippet: HTMLText.snippet(from: json["bodyPreview"].string ?? ""),
                              date: json["receivedDateTime"].string.flatMap { WebDate.parse($0) } ?? Date(),
                              isUnread: !(json["isRead"].bool ?? true), isStarred: json["flag"]["flagStatus"].string == "flagged",
                              isImportant: json["importance"].string == "high", isDraft: json["isDraft"].bool ?? false,
                              hasAttachments: json["hasAttachments"].bool ?? false,
                              messageIDHeader: json["internetMessageId"].nonEmpty)
    }

    // MARK: Reading

    public func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        let filter = "conversationId eq \(Graph.literal(id))"
        let url = try Self.url("messages", [("$filter", filter), ("$select", Self.messageFields), ("$top", "100")])
        let items = try await client.graphItems(url, headers: Self.headers, maxPages: 5)
        var summaries = items.compactMap(Self.summary(from:))
        if summaries.isEmpty { summaries = hint?.messages ?? [] }
        // Deleted and junk messages stay out unless the list showed them (or they're all there is).
        let hidden = Set(await wellKnownFolders().filter { $0.value == .trash || $0.value == .spam }.map(\.key))
        let hinted = Set(hint?.messages.map(\.id) ?? [])
        let visible = summaries.filter { !hidden.contains($0.folderID ?? "") || hinted.contains($0.id) }
        let client = self.client
        let messages = try await WebClient.concurrentMap(visible.isEmpty ? summaries : visible) { summary -> MailMessage? in
            do {
                return try await Self.fullMessage(summary, client: client)
            } catch PMailError.notFound {
                return nil
            }
        }
        return messages.compactMap { $0 }.sorted { $0.summary.date < $1.summary.date }
    }

    public func loadMessage(_ summary: MessageSummary) async throws -> MailMessage {
        try await Self.fullMessage(summary, client: client)
    }

    public func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        if let data = attachment.data { return data }
        let full = try await loadMessage(message)
        if let data = (full.attachments + full.inlineParts).first(where: { $0.id == attachment.id })?.data { return data }
        throw PMailError.notFound
    }

    /// A whole message: its MIME text (`$value`) parsed, with Graph's summary.
    static func fullMessage(_ summary: MessageSummary, client: WebClient) async throws -> MailMessage {
        let data = try await client.data(url("messages/\(WebURL.segment(summary.id))/$value"), headers: headers)
        let parsed = MIMEParser.parse(data)
        var merged = summary
        merged.inReplyTo = merged.inReplyTo ?? parsed.inReplyTo
        if merged.references.isEmpty { merged.references = parsed.references }
        merged.messageIDHeader = merged.messageIDHeader ?? parsed.messageID
        if merged.subject.isEmpty { merged.subject = parsed.subject }
        if merged.from == nil { merged.from = parsed.from }
        return parsed.mailMessage(summary: merged, rawSource: data)
    }

    // MARK: Actions

    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        let ids = WebClient.unique(messages.map(\.id).filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        switch action {
        case .markRead: try await patch(ids, ["isRead": true])
        case .markUnread: try await patch(ids, ["isRead": false])
        case .star: try await patch(ids, ["flag": ["flagStatus": "flagged"]])
        case .unstar: try await patch(ids, ["flag": ["flagStatus": "notFlagged"]])
        case .markImportant: try await patch(ids, ["importance": "high"])
        case .markNotImportant: try await patch(ids, ["importance": "normal"])
        case .archive: try await move(ids, to: "archive")
        case .moveToInbox, .notSpam: try await move(ids, to: "inbox")
        case .trash: try await move(ids, to: "deleteditems")
        case .markSpam: try await move(ids, to: "junkemail")
        case let .move(folderID):
            if folderID == Self.flaggedFolderID {
                try await patch(ids, ["flag": ["flagStatus": "flagged"]])
            } else {
                try await move(ids, to: folderID)
            }
        case .deleteForever:
            try await client.graphBatch(ids.map {
                GraphBatchRequest(method: "DELETE", url: Self.batchPath($0), headers: Self.headers)
            })
        case .addLabel, .removeLabel:
            throw PMailError.notSupported("Microsoft accounts file mail in folders and don’t have labels.")
        }
    }

    private func patch(_ ids: [String], _ change: JSONValue) async throws {
        try await client.graphBatch(ids.map {
            GraphBatchRequest(method: "PATCH", url: Self.batchPath($0), body: change, headers: Self.headers)
        })
    }

    /// Moves messages to a folder, by ID or by Graph's name for a special folder ("archive", "deleteditems").
    private func move(_ ids: [String], to destination: String) async throws {
        try await client.graphBatch(ids.map {
            GraphBatchRequest(method: "POST", url: Self.batchPath($0) + "/move", body: ["destinationId": .string(destination)],
                              headers: Self.headers)
        })
    }

    static func batchPath(_ id: String) -> String { "/me/messages/\(WebURL.segment(id))" }

    // MARK: Sending and drafts

    public func send(_ message: OutgoingMessage) async throws {
        let mime = WebMIME.build(message).base64EncodedString()
        _ = try await client.send("POST", Self.url("sendMail"), body: Data(mime.utf8), contentType: "text/plain",
                                  headers: Self.headers)
    }

    public func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        let mime = WebMIME.build(message).base64EncodedString()
        let saved = try await client.json("POST", Self.url("messages"), body: Data(mime.utf8), contentType: "text/plain",
                                          headers: Self.headers)
        // The new draft is safe, so the old one goes; if that fails, a spare copy is better than a lost draft.
        if let draft, draft.id != saved["id"].string {
            try? await client.delete(Self.url("messages/\(WebURL.segment(draft.id))"), headers: Self.headers)
        }
        guard var summary = Self.summary(from: saved) else { return nil }
        summary.isDraft = true
        summary.messageIDHeader = summary.messageIDHeader ?? message.messageID
        if summary.subject.isEmpty { summary.subject = message.subject }
        if summary.to.isEmpty { summary.to = message.to }
        return summary
    }

    public func deleteDraft(_ draft: MessageSummary) async throws {
        do {
            try await client.delete(Self.url("messages/\(WebURL.segment(draft.id))"), headers: Self.headers)
        } catch PMailError.notFound {
            // Already gone.
        }
    }

    public func close() async {}
}
