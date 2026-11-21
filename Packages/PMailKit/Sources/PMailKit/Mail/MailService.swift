import Foundation

/// One account's mail, however it's reached: an IMAP or POP server, or a provider's mail web service.
///
/// Implementations are thread-safe (usually actors) and may be called from any task. Every method throws
/// `PMailError` for failures the person should hear about.
public protocol MailService: AnyObject, Sendable {
    var capabilities: MailCapabilities { get }
    /// The tabs across the top of the inbox; empty when the service has none.
    var inboxTabs: [InboxTab] { get }

    /// Every folder and label, with unread counts. Special folders have their `role` set.
    func loadFolders() async throws -> [MailFolder]

    /// A page of conversations, newest first.
    func listConversations(_ request: ListRequest) async throws -> ConversationPage

    /// Every message in a conversation, oldest first, with bodies. `hint` is the conversation as the list had it,
    /// for services that can't look a conversation up by ID alone.
    func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage]

    /// One whole message, with its body.
    func loadMessage(_ summary: MessageSummary) async throws -> MailMessage

    /// An attachment's bytes, for one whose `data` wasn't loaded with the message.
    func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data

    /// Archives, deletes, stars, marks, moves or labels messages, all at once.
    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws

    /// Sends a message, and files a copy in Sent if the server doesn't do that itself.
    func send(_ message: OutgoingMessage) async throws

    /// Saves a draft, replacing an earlier version of it, and returns the saved draft (nil if the service can't
    /// say what it saved).
    func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary?

    func deleteDraft(_ draft: MessageSummary) async throws

    /// Signs out of the server and closes connections. The service may be used again afterwards (it reconnects).
    func close() async
}

/// Hands a finished message to an outgoing (SMTP) server.
public protocol MailSending: Sendable {
    /// Sends `raw` (a complete RFC 5322 message) from `sender` to every address in `recipients` (the envelope:
    /// To, Cc and Bcc together).
    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws
}
