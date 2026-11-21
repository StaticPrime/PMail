import Foundation
@testable import PMailKit

/// An outgoing server that keeps what it was asked to send.
final class IMAPRecordingSender: MailSending, @unchecked Sendable {
    struct Sent {
        var raw: Data
        var from: String
        var to: [String]
    }

    private let lock = NSLock()
    private var messages: [Sent] = []

    var sent: [Sent] { lock.withLock { messages } }

    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {
        lock.withLock { messages.append(Sent(raw: raw, from: sender, to: recipients)) }
    }
}

/// Access tokens handed out in order, one at a time until invalidated.
final class IMAPFakeTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var current: String?
    private var invalidationCount = 0

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    /// How often the client asked for a fresh token.
    var invalidations: Int { lock.withLock { invalidationCount } }

    func accessToken() async throws -> String {
        lock.withLock {
            if let current { return current }
            let next = tokens.isEmpty ? "spent" : tokens.removeFirst()
            current = next
            return next
        }
    }

    func invalidateAccessToken() async {
        lock.withLock {
            current = nil
            invalidationCount += 1
        }
    }
}

/// Pieces of pretend IMAP sessions.
enum IMAPScript {
    typealias Step = ScriptedByteStream.Step

    static let capabilities = "IMAP4rev1 SASL-IR AUTH=PLAIN SPECIAL-USE MOVE UIDPLUS LITERAL+"

    static func greeting(_ capabilities: String = capabilities) -> String {
        "* OK [CAPABILITY \(capabilities)] PMail test server ready\r\n"
    }

    /// AUTHENTICATE PLAIN with the initial response inline, answered with the server's capabilities.
    static func signIn(_ tag: String, username: String = "pug@example.com", password: String = "secret",
                       capabilities: String = capabilities) -> Step {
        .expect("\(tag) AUTHENTICATE PLAIN \(SASL.plain(username: username, password: password))",
                reply: "\(tag) OK [CAPABILITY \(capabilities)] Signed in\r\n")
    }

    /// Lines with CRLF after each.
    static func lines(_ lines: String...) -> String {
        lines.map { $0 + "\r\n" }.joined()
    }

    /// A literal: `{n}`, CRLF and the text.
    static func literal(_ text: String) -> String {
        "{\(text.utf8.count)}\r\n\(text)"
    }

    /// The usual mailboxes, with special-use attributes.
    static let mailboxLines = [
        #"* LIST (\HasNoChildren) "/" "INBOX""#,
        #"* LIST (\HasNoChildren \Sent) "/" "Sent Messages""#,
        #"* LIST (\HasNoChildren \Drafts) "/" "Drafts""#,
        #"* LIST (\HasNoChildren \Trash) "/" "Deleted Messages""#,
        #"* LIST (\HasNoChildren \Junk) "/" "Junk""#,
        #"* LIST (\HasNoChildren \Archive) "/" "Archive""#,
    ]

    static func list(_ tag: String, extra: [String] = []) -> Step {
        .expect("\(tag) LIST \"\" \"*\"",
                reply: (mailboxLines + extra).map { $0 + "\r\n" }.joined() + "\(tag) OK LIST completed\r\n")
    }

    static func select(_ tag: String, _ mailbox: String = "INBOX", exists: Int = 3, uidValidity: UInt32 = 7,
                       readOnly: Bool = false) -> Step {
        .expect("\(tag) \(readOnly ? "EXAMINE" : "SELECT") \"\(mailbox)\"",
                reply: lines("* \(exists) EXISTS", "* 0 RECENT", "* OK [UIDVALIDITY \(uidValidity)] UIDs valid",
                             "* OK [UIDNEXT 100] Predicted next UID",
                             "\(tag) OK [\(readOnly ? "READ-ONLY" : "READ-WRITE")] Done"))
    }

    static func ok(_ tag: String, _ command: String, untagged: [String] = []) -> Step {
        .expect("\(tag) \(command)", reply: (untagged + ["\(tag) OK Done"]).map { $0 + "\r\n" }.joined())
    }
}

/// An account and service wired to scripted connections.
struct IMAPHarness {
    let service: IMAPMailService
    let sender: IMAPRecordingSender
    let connector: ScriptedConnector

    init(_ streams: [ScriptedByteStream], kind: AccountKind = .other, email: String = "pug@example.com",
         username: String = "pug@example.com", host: String = "imap.example.com", password: String = "secret",
         localStore: LocalMailStore? = nil) {
        let account = Account(kind: kind, name: "Pug Tester", email: email)
        let incoming = ServerSettings(mailProtocol: .imap, host: host, port: 993, security: .tls, username: username)
        sender = IMAPRecordingSender()
        connector = ScriptedConnector(streams)
        let credential = Credential.password(username: username, password: password)
        service = IMAPMailService(account: account, incoming: incoming, credential: credential, sender: sender,
                                  connector: connector, localStore: localStore)
    }
}

extension IMAPMessageID {
    static func inbox(_ uid: UInt32, uidValidity: UInt32 = 7) -> String {
        IMAPMessageID(mailbox: "INBOX", uidValidity: uidValidity, uid: uid).rawValue
    }
}
