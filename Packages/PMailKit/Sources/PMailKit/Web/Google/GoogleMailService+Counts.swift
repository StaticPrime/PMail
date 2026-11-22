import Foundation

extension GoogleMailService {
    /// Unread messages in the inbox under each tab: messages with the inbox, unread and the tab's category labels,
    /// counted from one page of up to 500 (past that, the server's estimate).
    public func unreadCounts(inTabs tabs: [InboxTab]) async throws -> [String: Int] {
        let client = self.client
        return try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for tab in tabs {
                group.addTask {
                    let query = [("labelIds", "INBOX"), ("labelIds", "UNREAD"), ("labelIds", tab.id), ("maxResults", "500")]
                    let list = try await client.get(Self.url("messages", query))
                    let counted = list["messages"].array.count
                    let more = list["nextPageToken"].nonEmpty != nil
                    return (tab.id, more ? max(counted, list["resultSizeEstimate"].int ?? counted) : counted)
                }
            }
            var counts: [String: Int] = [:]
            for try await (id, count) in group { counts[id] = count }
            return counts
        }
    }
}
