import Foundation

/// Everything that can go wrong talking to a mail, calendar or contacts server, worded for the person using PMail.
public enum PMailError: Error, Sendable, Equatable, LocalizedError {
    /// The account has no password or token saved (it needs signing in again).
    case notSignedIn
    /// The server turned the user name, password or token down. The text is the server's own reason, if it gave one.
    case authenticationFailed(String)
    /// The server couldn't be reached, or the connection broke.
    case connectionFailed(String)
    /// The server understood but refused (an IMAP NO or BAD, an SMTP 5xx). The text is the server's reason.
    case server(String)
    /// A web service answered with an HTTP error.
    case http(status: Int, message: String)
    /// The server's answer couldn't be understood.
    case protocolError(String)
    /// The account or server can't do this.
    case notSupported(String)
    /// The message, event or contact isn't there any more.
    case notFound
    /// Someone changed it on the server first (an ETag or change key didn't match).
    case conflict
    case cancelled
    case timedOut
    /// Sign-in through the provider's page isn't set up in this copy of PMail (no client ID).
    case notConfigured(String)
    /// The account's organization lets only its administrators approve apps like PMail, and none has yet.
    case needsAdminApproval

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "This account needs to be signed in again."
        case let .authenticationFailed(reason): reason.isEmpty ? "The server didn’t accept the sign-in." : "The server didn’t accept the sign-in: \(reason)"
        case let .connectionFailed(reason): reason.isEmpty ? "The server couldn’t be reached." : "The server couldn’t be reached: \(reason)"
        case let .server(reason): reason.isEmpty ? "The server refused." : reason
        case let .http(status, message): message.isEmpty ? "The server answered with error \(status)." : "\(message) (error \(status))"
        case let .protocolError(detail): "The server’s answer couldn’t be read\(detail.isEmpty ? "." : ": \(detail)")"
        case let .notSupported(what): what.isEmpty ? "This account can’t do that." : what
        case .notFound: "It isn’t on the server any more."
        case .conflict: "It was changed somewhere else first. Try again."
        case .cancelled: "Cancelled."
        case .timedOut: "The server took too long to answer."
        case let .notConfigured(what): what
        case .needsAdminApproval: "Your organization needs to approve PMail before you can sign in."
        }
    }

    /// Whether signing in again might help.
    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .authenticationFailed: true
        case let .http(status, _): status == 401
        default: false
        }
    }
}
