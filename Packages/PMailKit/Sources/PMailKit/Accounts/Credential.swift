import Foundation

/// Gives out OAuth 2.0 access tokens, refreshing them when they run out.
public protocol AccessTokenProvider: Sendable {
    /// A current access token, refreshed first if it has expired or is about to.
    func accessToken() async throws -> String
    /// Forgets the current access token, so the next `accessToken()` refreshes it. Call it after a server turns a
    /// token down (HTTP 401, or an IMAP/SMTP authentication failure), then try once more.
    func invalidateAccessToken() async
}

/// What an account signs in to its servers with.
public enum Credential: Sendable {
    /// A user name and password (for iCloud, an app-specific password).
    case password(username: String, password: String)
    /// An OAuth 2.0 access token for `username`, used as a bearer token for web services and with SASL XOAUTH2 for
    /// IMAP, POP and SMTP.
    case oauth(username: String, tokens: any AccessTokenProvider)

    public var username: String {
        switch self {
        case let .password(username, _): username
        case let .oauth(username, _): username
        }
    }

    /// The same credential for another user name (iCloud signs in to mail and to calendars with different names).
    public func withUsername(_ username: String) -> Credential {
        switch self {
        case let .password(_, password): .password(username: username, password: password)
        case let .oauth(_, tokens): .oauth(username: username, tokens: tokens)
        }
    }

    /// An `Authorization` header value for web requests: Basic for a password, Bearer for a token.
    public func authorizationHeader() async throws -> String {
        switch self {
        case let .password(username, password):
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case let .oauth(_, tokens):
            return "Bearer " + (try await tokens.accessToken())
        }
    }
}

/// SASL initial responses, already base64-encoded, for IMAP `AUTHENTICATE`, SMTP `AUTH` and POP `AUTH`.
public enum SASL {
    /// PLAIN (RFC 4616): an empty authorization identity, the user name and the password.
    public static func plain(username: String, password: String) -> String {
        Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
    }

    /// XOAUTH2, as the big providers' IMAP, POP and SMTP servers take it.
    public static func xoauth2(username: String, accessToken: String) -> String {
        Data("user=\(username)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}".utf8).base64EncodedString()
    }

    /// The user name and password for LOGIN, each base64-encoded on its own.
    public static func login(username: String, password: String) -> (username: String, password: String) {
        (Data(username.utf8).base64EncodedString(), Data(password.utf8).base64EncodedString())
    }
}
