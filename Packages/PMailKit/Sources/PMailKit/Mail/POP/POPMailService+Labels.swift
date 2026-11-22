import Foundation

// Labels on a POP account, kept with its mail on this Mac: the label book has their names and colors, and each
// message's labels are in its summary in the store. IDs are label keywords (`LabelKeyword`), as on IMAP accounts.
extension POPMailService {
    /// The labels to list beside the folders, with how many messages outside Trash and Junk have each and how many of
    /// those are unread. Labels on stored messages that the book doesn't know (from a lost book) join it.
    func labelFolders() async -> [MailFolder] {
        guard let labelBook else { return [] }
        let summaries = await store.allSummaries().filter { !Self.setAsideIDs.contains($0.folderID ?? "") }
        var seen = Set<String>()
        await labelBook.discover(summaries.flatMap(\.labelIDs).filter { seen.insert($0).inserted })
        return await labelBook.folders().map { label in
            var folder = label
            let labeled = summaries.filter { $0.labelIDs.contains(label.id) }
            folder.totalCount = labeled.count
            folder.unreadCount = labeled.filter(\.isUnread).count
            return folder
        }
    }

    /// A page of the conversations with a label, outside Trash and Junk, or nil when the request isn't for a label.
    func labelPage(_ request: ListRequest) async throws -> ConversationPage? {
        guard let labelBook, let requested = request.folderID, LabelKeyword.isLabel(requested) else { return nil }
        let label = await labelBook.label(withID: requested)?.id ?? requested
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let found = query.isEmpty ? await store.summaries(withLabel: label)
            : await store.search(query).filter { $0.labelIDs.contains(label) }
        let conversations = Conversation.group(found.filter { !Self.setAsideIDs.contains($0.folderID ?? "") })
        let pageSize = max(1, request.pageSize)
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
        let start = overflowed ? conversations.count : min(offset, conversations.count)
        let end = start + min(pageSize, conversations.count - start)
        return ConversationPage(conversations: Array(conversations[start..<end]), totalCount: conversations.count,
                                nextPageToken: end < conversations.count ? String(pageIndex + 1) : nil)
    }

    /// Adds or removes a label (`.addLabel`, `.removeLabel`) on messages in the store.
    func applyLabel(_ action: MailAction, to messages: [MessageSummary]) async throws {
        guard let labelBook else { throw PMailError.notSupported("POP accounts don’t use labels.") }
        let requested: String
        let adding: Bool
        switch action {
        case let .addLabel(id): (requested, adding) = (id, true)
        case let .removeLabel(id): (requested, adding) = (id, false)
        default: return
        }
        guard LabelKeyword.isLabel(requested) else { throw PMailError.notFound }
        let known = await labelBook.label(withID: requested)?.id
        if adding && known == nil { throw PMailError.notFound }
        try await store.setLabel(known ?? requested, adding, for: messages.map(\.id))
    }

    // MARK: Making, changing and deleting labels

    public func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        guard let labelBook else { throw PMailError.notSupported("This account can’t make labels.") }
        return try await labelBook.create(named: name, colorHex: colorHex).folder
    }

    /// Renames or recolors a label (a nil color leaves its color as it is); renaming moves its messages to the new ID.
    public func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        guard let labelBook else { throw PMailError.notSupported("This account can’t change labels.") }
        guard let current = await labelBook.label(withID: label.id) else { throw PMailError.notFound }
        let newID = try await labelBook.renamedID(current.id, to: name)
        if newID != current.id { try await store.replaceLabel(current.id, with: newID) }
        return try await labelBook.update(current.id, name: name, colorHex: colorHex).folder
    }

    /// Deletes a label, taking it off every message that has it.
    public func deleteLabel(_ label: MailFolder) async throws {
        guard let labelBook else { throw PMailError.notSupported("This account can’t delete labels.") }
        guard let current = await labelBook.label(withID: label.id) else { return }
        try await store.replaceLabel(current.id, with: nil)
        try await labelBook.remove(current.id)
    }
}
