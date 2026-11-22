import Foundation

// Inbox categories on a POP account, sorted on this Mac.
extension POPMailService {
    /// A page of one inbox category, or nil when the request isn't for a category tab, searches, or lists another
    /// folder (those list as usual).
    ///
    /// The inbox's messages are sorted by the sorter (the category chosen for a sender, else the rules), then listed the
    /// way the inbox is: as conversations, newest first, and the first page checks the server for new mail first.
    func categoryPage(_ request: ListRequest) async throws -> ConversationPage? {
        guard let sorter, request.folderID == Self.inboxID, let category = InboxCategory(tabID: request.tabID),
              (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pageIndex = max(0, request.pageToken.flatMap { Int($0) } ?? request.pageIndex)
        let pageSize = max(1, request.pageSize)
        if pageIndex == 0 { _ = try await syncInbox() }
        let inbox = await store.summaries(in: Self.inboxID)
        let categories = await sorter.categories(of: inbox)
        let conversations = Conversation.group(zip(inbox, categories).compactMap { $1 == category ? $0 : nil })
        let (offset, overflowed) = pageIndex.multipliedReportingOverflow(by: pageSize)
        let start = overflowed ? conversations.count : min(offset, conversations.count)
        let end = start + min(pageSize, conversations.count - start)
        return ConversationPage(conversations: Array(conversations[start..<end]), totalCount: conversations.count,
                                nextPageToken: end < conversations.count ? String(pageIndex + 1) : nil)
    }
}
