import Foundation

// Labels on a POP account, kept with its mail on this Mac. Filled in by the labels work.
extension POPMailService {
    /// The labels to list beside the folders.
    func labelFolders() async -> [MailFolder] { [] }

    /// A page of the conversations with a label, or nil when the request isn't for a label.
    func labelPage(_ request: ListRequest) async throws -> ConversationPage? { nil }

    /// Adds or removes a label (`.addLabel`, `.removeLabel`).
    func applyLabel(_ action: MailAction, to messages: [MessageSummary]) async throws {
        throw PMailError.notSupported("This account doesn’t have labels yet.")
    }
}
