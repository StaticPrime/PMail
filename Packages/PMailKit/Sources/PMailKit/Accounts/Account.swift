import Foundation

/// The kinds of account PMail connects to. Google and Microsoft accounts sign in through the provider's own page
/// and use its mail, calendar and contacts services; iCloud and other accounts use the standard internet protocols.
public enum AccountKind: String, Codable, Sendable, CaseIterable, Hashable {
    case google
    case microsoft
    case icloud
    case other

    /// The provider's name, as the add-account sheet shows it.
    public var displayName: String {
        switch self {
        case .google: "Google"
        case .microsoft: "Microsoft"
        case .icloud: "iCloud"
        case .other: "Other"
        }
    }

    /// Whether the account signs in through the provider's web page (OAuth 2.0) rather than with a password.
    public var signsInWithBrowser: Bool { self == .google || self == .microsoft }
}

/// The internet mail protocols an iCloud or other account can use.
public enum MailProtocol: String, Codable, Sendable, Hashable, CaseIterable {
    case imap
    case pop3
    case smtp

    public var displayName: String {
        switch self {
        case .imap: "IMAP"
        case .pop3: "POP"
        case .smtp: "SMTP"
        }
    }
}

/// How a connection to a mail server is protected.
public enum ConnectionSecurity: String, Codable, Sendable, Hashable, CaseIterable {
    /// TLS from the first byte (IMAP 993, POP 995, SMTP 465).
    case tls
    /// A plain connection upgraded with STARTTLS before signing in (IMAP 143, POP 110, SMTP 587).
    case startTLS
    /// No encryption at all. Only offered for servers on a trusted network.
    case none

    public var displayName: String {
        switch self {
        case .tls: "SSL/TLS"
        case .startTLS: "STARTTLS"
        case .none: "None"
        }
    }
}

/// How PMail proves who it is to a mail server.
public enum ServerAuthentication: String, Codable, Sendable, Hashable {
    case password
    case oauth2
}

/// Where a mail server is and how to sign in to it.
public struct ServerSettings: Codable, Sendable, Hashable {
    public var mailProtocol: MailProtocol
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity
    public var username: String
    public var authentication: ServerAuthentication

    public init(mailProtocol: MailProtocol, host: String, port: Int? = nil, security: ConnectionSecurity = .tls,
                username: String, authentication: ServerAuthentication = .password) {
        self.mailProtocol = mailProtocol
        self.host = host
        self.port = port ?? Self.defaultPort(for: mailProtocol, security: security)
        self.security = security
        self.username = username
        self.authentication = authentication
    }

    /// The usual port for a protocol and kind of security.
    public static func defaultPort(for mailProtocol: MailProtocol, security: ConnectionSecurity) -> Int {
        switch (mailProtocol, security) {
        case (.imap, .tls): 993
        case (.imap, _): 143
        case (.pop3, .tls): 995
        case (.pop3, _): 110
        case (.smtp, .tls): 465
        case (.smtp, .startTLS): 587
        case (.smtp, .none): 25
        }
    }
}

/// One account the person added: whose it is, what kind, and (for iCloud and other accounts) where its servers are.
/// Passwords and tokens are never kept here; they live in the keychain under the account's `id`.
public struct Account: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: AccountKind
    /// The person's name, as it goes on messages they send ("Jamie Rivera").
    public var name: String
    /// The address mail is sent from.
    public var email: String
    /// Which of the avatar colors the account uses where it has no picture.
    public var colorIndex: Int
    /// The incoming server (IMAP or POP), for iCloud and other accounts.
    public var incoming: ServerSettings?
    /// The outgoing server (SMTP), for iCloud and other accounts.
    public var outgoing: ServerSettings?
    /// The CalDAV server for the account's calendars, if it has one. iCloud accounts always do.
    public var calendarServer: URL?
    /// The CardDAV server for the account's contacts, if it has one. iCloud accounts always do.
    public var contactsServer: URL?
    /// The name used to sign in to the calendar and contacts servers (an iCloud account's Apple Account email).
    public var serverLoginName: String?
    /// Plain text added under new messages, after "-- ".
    public var signature: String
    /// The account's picture, as the provider gave it.
    public var pictureURL: URL?
    public var addedAt: Date

    public init(id: UUID = UUID(), kind: AccountKind, name: String, email: String, colorIndex: Int = 0,
                incoming: ServerSettings? = nil, outgoing: ServerSettings? = nil, calendarServer: URL? = nil,
                contactsServer: URL? = nil, serverLoginName: String? = nil, signature: String = "",
                pictureURL: URL? = nil, addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.email = email
        self.colorIndex = colorIndex
        self.incoming = incoming
        self.outgoing = outgoing
        self.calendarServer = calendarServer
        self.contactsServer = contactsServer
        self.serverLoginName = serverLoginName
        self.signature = signature
        self.pictureURL = pictureURL
        self.addedAt = addedAt
    }

    /// The account's own address, for writing "me" in conversations.
    public var address: MailAddress { MailAddress(name: name.isEmpty ? nil : name, email: email) }

    /// Initials for the avatar: the first letters of the first and last names, or the address's first letter.
    public var initials: String { Self.initials(name: name, email: email) }

    public static func initials(name: String, email: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        if let first = words.first?.first {
            if words.count > 1, let last = words.last?.first { return "\(first)\(last)".uppercased() }
            return String(first).uppercased()
        }
        return email.first.map { String($0).uppercased() } ?? "?"
    }
}
