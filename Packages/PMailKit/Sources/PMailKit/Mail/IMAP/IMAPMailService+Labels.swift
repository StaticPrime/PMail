import Foundation

// Labels on an IMAP account: IMAP keywords where the server allows them, else kept on this Mac in the label book.
// Filled in by the labels work; until then an IMAP account has no labels.
extension IMAPMailService {
    /// The labels to list beside the folders.
    func labelFolders(client: IMAPClient) async throws -> [MailFolder] { [] }

    /// A page of the conversations with a label, or nil when the request isn't for a label.
    func labelPage(_ request: ListRequest) async throws -> ConversationPage? { nil }

    /// Adds or removes a label (`.addLabel`, `.removeLabel`).
    func applyLabel(_ action: MailAction, to messages: [MessageSummary]) async throws {
        throw PMailError.notSupported("This account doesn’t have labels yet.")
    }

    /// The label IDs a message's flags carry (its label keywords).
    nonisolated static func keywordLabelIDs(_ flags: [String]?) -> [String] { [] }
}
