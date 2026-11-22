import Foundation

// Inbox categories on an IMAP account, sorted on this Mac. Filled in by the categories work.
extension IMAPMailService {
    /// A page of one inbox category, or nil when the request isn't for a category tab.
    func categoryPage(_ request: ListRequest) async throws -> ConversationPage? { nil }

    /// What a message's header fields (lowercased names, as `IMAPHeaderFields.parse` gives them) say about its sender.
    nonisolated static func senderHints(from headers: [String: String]) -> SenderHints? { nil }
}
