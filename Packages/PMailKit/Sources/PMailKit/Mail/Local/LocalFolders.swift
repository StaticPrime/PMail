import Foundation

/// Sent, Drafts and Trash kept on this Mac, for an IMAP account whose server has no folder for them (an iCloud account
/// that has only ever had an inbox, say). The messages live in a `LocalMailStore`. The account's service lists, opens
/// and changes them like its own, and uploads one to the server when it's moved to a server folder.
public struct LocalFolders: Sendable {
    public static let sentID = "pmail:sent"
    public static let draftsID = "pmail:drafts"
    public static let trashID = "pmail:trash"

    /// Each folder that can be kept here: the role it stands in for, its ID and its name.
    static let all: [(role: FolderRole, id: String, name: String)] = [
        (.sent, sentID, "Sent"), (.drafts, draftsID, "Drafts"), (.trash, trashID, "Trash"),
    ]

    public let store: LocalMailStore

    public init(store: LocalMailStore) {
        self.store = store
    }

    /// Whether a folder ID is one of the folders kept on this Mac.
    public static func contains(_ folderID: String?) -> Bool {
        all.contains { $0.id == folderID }
    }

    /// The folders to show beside the server's: one for each of Sent, Drafts and Trash the server has no folder for.
    /// Where the server has its own, the one kept here still shows while it holds messages, as "Sent on this Mac" and
    /// so on, so nothing kept here is hidden.
    func folders(besides serverRoles: Set<FolderRole>) async -> [MailFolder] {
        var folders: [MailFolder] = []
        for kept in Self.all {
            let counts = await store.counts(in: kept.id)
            if !serverRoles.contains(kept.role) {
                folders.append(MailFolder(id: kept.id, name: kept.name, role: kept.role, unreadCount: counts.unread,
                                          totalCount: counts.total))
            } else if counts.total > 0 {
                folders.append(MailFolder(id: kept.id, name: "\(kept.name) on this Mac", unreadCount: counts.unread,
                                          totalCount: counts.total))
            }
        }
        return folders
    }

    /// A page of a kept folder's conversations, newest first; a search looks through that folder on this Mac.
    func page(_ request: ListRequest) async -> ConversationPage {
        let folderID = request.folderID ?? Self.sentID
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summaries = query.isEmpty ? await store.summaries(in: folderID) : await store.search(query, in: folderID)
        let conversations = Conversation.group(summaries)
        let pageSize = max(1, request.pageSize)
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
        let start = overflowed ? conversations.count : min(offset, conversations.count)
        let end = start + min(pageSize, conversations.count - start)
        return ConversationPage(conversations: Array(conversations[start..<end]), totalCount: conversations.count,
                                nextPageToken: end < conversations.count ? String(pageIndex + 1) : nil)
    }

    /// A kept message, whole, with its flags as they are now.
    func message(_ summary: MessageSummary) async throws -> MailMessage {
        guard let raw = await store.raw(for: summary.id) else { throw PMailError.notFound }
        let current = await store.summary(for: summary.id) ?? summary
        return MIMEParser.parse(raw).mailMessage(summary: current, rawSource: raw)
    }

    /// One of a kept message's files.
    func attachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        guard let raw = await store.raw(for: message.id) else { throw PMailError.notFound }
        let parsed = MIMEParser.parse(raw)
        let files = parsed.attachments + parsed.inlineParts
        let match = files.first { $0.id == attachment.id } ?? files.first { $0.filename == attachment.filename }
        guard let data = match?.data else { throw PMailError.notFound }
        return data
    }

    /// Kept messages in a folder that belong to a conversation: replies to one of its `roots` (by References or
    /// In-Reply-To) and the roots themselves (by Message-ID), leaving out Message-IDs already shown.
    func related(in folderID: String, roots: [String], knownMessageIDs: inout Set<String>) async -> [MailMessage] {
        guard !roots.isEmpty else { return [] }
        let wanted = Set(roots)
        var messages: [MailMessage] = []
        for summary in await store.summaries(in: folderID) {
            let pointers = summary.references + [summary.inReplyTo, summary.messageIDHeader].compactMap { $0 }
            guard pointers.contains(where: wanted.contains) else { continue }
            if let header = summary.messageIDHeader, knownMessageIDs.contains(header) { continue }
            guard let message = try? await message(summary) else { continue }
            if let header = summary.messageIDHeader { knownMessageIDs.insert(header) }
            messages.append(message)
        }
        return messages
    }

    /// Saves a draft in the kept Drafts, replacing the earlier version when that was kept here too.
    func saveDraft(_ raw: Data, replacing draft: MessageSummary?) async throws -> MessageSummary {
        var id = "draft:\(UUID().uuidString.lowercased())"
        if let old = draft?.id, await store.contains(id: old) { id = old }
        return try await store.add(raw: raw, folderID: Self.draftsID, id: id, isUnread: false)
    }
}
