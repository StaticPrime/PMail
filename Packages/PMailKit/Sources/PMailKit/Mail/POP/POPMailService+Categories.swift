import Foundation

// Inbox categories on a POP account, sorted on this Mac. Filled in by the categories work.
extension POPMailService {
    /// A page of one inbox category, or nil when the request isn't for a category tab.
    func categoryPage(_ request: ListRequest) async throws -> ConversationPage? { nil }
}
