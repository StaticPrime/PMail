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

    /// New messages in the inbox since `state`, cheaply: the background check for new mail calls this every few
    /// minutes for every account. With no state (the first check ever), it returns no messages, only the state to
    /// start from, so a first launch doesn't announce the whole inbox.
    func checkForNewMail(since state: MailSyncState?) async throws -> NewMail

    /// The messages with these Message-ID headers (with angle brackets) anywhere in the account apart from Trash and
    /// Spam, to find messages again after they moved (moving can change a message's ID). Unknown ones are left out.
    func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary]

    /// Whether `waitForChange` hears from the server the moment the inbox changes (IMAP IDLE).
    var pushesChanges: Bool { get }

    /// Waits until the server says the inbox changed (true) or `timeout` seconds pass (false), on a connection of its
    /// own so other calls aren't held up. Services that can't be told return false straight away.
    func waitForChange(timeout: TimeInterval) async throws -> Bool

    // Labels (where `capabilities.canEditLabels`). Labels are listed by `loadFolders` as folders of kind `.label`;
    // listing one lists the conversations with it, wherever they are.

    /// Makes a label. `colorHex` is "#RRGGBB", or nil for the account's default.
    func createLabel(named name: String, colorHex: String?) async throws -> MailFolder
    /// Renames or recolors a label (a nil color leaves its color as it is), and returns it as it is now (its ID may
    /// change).
    func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder
    /// Deletes a label; the messages that had it keep everything else.
    func deleteLabel(_ label: MailFolder) async throws
}

/// Where a service is up to in an account's inbox, for asking what's new since then. Only the service that made it
/// understands it.
public struct MailSyncState: Codable, Sendable, Hashable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// What arrived in the inbox since the last check.
public struct NewMail: Sendable {
    /// Messages that arrived in the inbox since the last check (still there, read or not), newest first.
    public var messages: [MessageSummary]
    /// Pass this to the next check.
    public var state: MailSyncState
    /// How many messages in the inbox are unread now, when the service knows without extra work.
    public var inboxUnread: Int?

    public init(messages: [MessageSummary], state: MailSyncState, inboxUnread: Int? = nil) {
        self.messages = messages
        self.state = state
        self.inboxUnread = inboxUnread
    }
}

extension MailService {
    public func checkForNewMail(since state: MailSyncState?) async throws -> NewMail {
        throw PMailError.notSupported("This account can’t be checked for new mail yet.")
    }

    public func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary] {
        throw PMailError.notSupported("This account can’t look messages up yet.")
    }

    public var pushesChanges: Bool { false }

    public func waitForChange(timeout: TimeInterval) async throws -> Bool { false }

    public func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        throw PMailError.notSupported("This account can’t make labels.")
    }

    public func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        throw PMailError.notSupported("This account can’t change labels.")
    }

    public func deleteLabel(_ label: MailFolder) async throws {
        throw PMailError.notSupported("This account can’t delete labels.")
    }
}

/// Hands a finished message to an outgoing (SMTP) server.
public protocol MailSending: Sendable {
    /// Sends `raw` (a complete RFC 5322 message) from `sender` to every address in `recipients` (the envelope:
    /// To, Cc and Bcc together).
    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws
}
