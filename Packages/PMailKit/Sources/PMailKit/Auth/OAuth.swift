import CryptoKit
import Foundation

/// A provider's OAuth 2.0 sign-in: its endpoints, PMail's registration with it and what PMail asks to use.
public struct OAuthProvider: Sendable, Hashable {
    public var kind: AccountKind
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Only for registrations that come with one; apps registered as native clients have none.
    public var clientSecret: String?
    /// Where the provider sends the browser back to, with the sign-in's result.
    public var redirectURI: String
    public var scopes: [String]
    /// Further query parameters for the sign-in page, in order.
    public var extraParameters: [String: String]

    public init(kind: AccountKind, authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String? = nil,
                redirectURI: String, scopes: [String], extraParameters: [String: String] = [:]) {
        self.kind = kind
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraParameters = extraParameters
    }

    /// The scheme of the redirect URI, which the sign-in window watches for.
    public var callbackScheme: String { URL(string: redirectURI)?.scheme ?? "" }

    /// Google: mail (full access, which IMAP-style permanent deletion needs), calendars and contacts.
    public static func google(clientID: String, clientSecret: String? = nil, redirectURI: String? = nil) -> OAuthProvider {
        OAuthProvider(kind: .google,
                      authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                      tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                      clientID: clientID, clientSecret: clientSecret,
                      redirectURI: redirectURI ?? googleRedirectURI(forClientID: clientID),
                      scopes: ["openid", "email", "profile", "https://mail.google.com/",
                               // The signature, kept with the account's send-as address.
                               "https://www.googleapis.com/auth/gmail.settings.basic",
                               "https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/contacts",
                               "https://www.googleapis.com/auth/contacts.other.readonly", "https://www.googleapis.com/auth/tasks",
                               "https://www.googleapis.com/auth/directory.readonly"],
                      // Offline access with consent, so the answer always includes a refresh token.
                      extraParameters: ["access_type": "offline", "prompt": "consent", "include_granted_scopes": "true"])
    }

    /// Microsoft: mail (with the mailbox settings that hold its categories, PMail's labels), calendars (Teams meetings
    /// are made on calendar events) and contacts, through Microsoft Graph.
    public static func microsoft(clientID: String, tenant: String? = nil, redirectURI: String? = nil) -> OAuthProvider {
        let tenant = tenant.flatMap { $0.isEmpty ? nil : $0 } ?? "common"
        let base = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0"
        return OAuthProvider(kind: .microsoft,
                             authorizationEndpoint: URL(string: "\(base)/authorize")!,
                             tokenEndpoint: URL(string: "\(base)/token")!,
                             clientID: clientID,
                             redirectURI: redirectURI ?? "msauth.com.pugglesoft.PMail://auth",
                             scopes: ["openid", "profile", "email", "offline_access", "User.Read", "Mail.ReadWrite", "Mail.Send",
                                      "MailboxSettings.ReadWrite", "Calendars.ReadWrite", "Calendars.Read.Shared", "Contacts.ReadWrite", "Tasks.ReadWrite",
                                      "People.Read"],
                             // No prompt=select_account: the sign-in window keeps nothing, so there's never an account to
                             // pick, and with the address as a login hint Microsoft's account picker can send some work
                             // accounts back to itself after they're picked.
                             extraParameters: ["response_mode": "query"])
    }

    /// Google's redirect for apps registered as native clients: the client ID's parts reversed as a URL scheme.
    /// "1234-abc.apps.googleusercontent.com" gives "com.googleusercontent.apps.1234-abc:/oauth2redirect".
    public static func googleRedirectURI(forClientID clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(prefix):/oauth2redirect"
    }
}

/// Which providers this copy of PMail can sign in to, from environment variables (for runs from Xcode or a shell)
/// or, failing that, from the app's Info.plist (filled in from build settings of the same names when it's built).
///
/// | Variable | What it holds |
/// | --- | --- |
/// | `PMAIL_GOOGLE_CLIENT_ID` | The OAuth client ID registered for PMail with Google |
/// | `PMAIL_GOOGLE_CLIENT_SECRET` | Optional: that client's secret, for registrations that have one |
/// | `PMAIL_GOOGLE_REDIRECT_URI` | Optional: a redirect URI other than the reversed client ID |
/// | `PMAIL_MICROSOFT_CLIENT_ID` | The application (client) ID registered for PMail with Microsoft |
/// | `PMAIL_MICROSOFT_TENANT` | Optional: `common` (the default), `consumers`, `organizations` or a tenant ID |
/// | `PMAIL_MICROSOFT_REDIRECT_URI` | Optional: a redirect URI other than `msauth.com.pugglesoft.PMail://auth` |
public struct OAuthConfiguration: Sendable, Hashable {
    public var google: OAuthProvider?
    public var microsoft: OAuthProvider?

    public init(google: OAuthProvider? = nil, microsoft: OAuthProvider? = nil) {
        self.google = google
        self.microsoft = microsoft
    }

    /// The names of the settings, as environment variables and build settings.
    public static let variableNames = ["PMAIL_GOOGLE_CLIENT_ID", "PMAIL_GOOGLE_CLIENT_SECRET", "PMAIL_GOOGLE_REDIRECT_URI",
                                       "PMAIL_MICROSOFT_CLIENT_ID", "PMAIL_MICROSOFT_TENANT", "PMAIL_MICROSOFT_REDIRECT_URI"]

    /// The Info.plist key for a setting: "PMAIL_GOOGLE_CLIENT_ID" is kept as "PMailGoogleClientID".
    public static func infoKey(for variable: String) -> String {
        let words = variable.split(separator: "_").dropFirst().map { word -> String in
            let lower = word.lowercased()
            return lower == "id" ? "ID" : lower == "uri" ? "URI" : lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return "PMail" + words.joined()
    }

    /// Reads the settings. An environment variable wins over the Info.plist; empty values and unexpanded build
    /// settings ("$(…)") count as missing.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> OAuthConfiguration {
        func value(_ variable: String) -> String? {
            for candidate in [environment[variable], info[infoKey(for: variable)] as? String] {
                guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      !text.hasPrefix("$(") else { continue }
                return text
            }
            return nil
        }
        var configuration = OAuthConfiguration()
        if let clientID = value("PMAIL_GOOGLE_CLIENT_ID") {
            configuration.google = .google(clientID: clientID, clientSecret: value("PMAIL_GOOGLE_CLIENT_SECRET"),
                                           redirectURI: value("PMAIL_GOOGLE_REDIRECT_URI"))
        }
        if let clientID = value("PMAIL_MICROSOFT_CLIENT_ID") {
            configuration.microsoft = .microsoft(clientID: clientID, tenant: value("PMAIL_MICROSOFT_TENANT"),
                                                 redirectURI: value("PMAIL_MICROSOFT_REDIRECT_URI"))
        }
        return configuration
    }

    public func provider(for kind: AccountKind) -> OAuthProvider? {
        switch kind {
        case .google: google
        case .microsoft: microsoft
        default: nil
        }
    }
}

/// A PKCE pair (RFC 7636): a random verifier kept by PMail and its SHA-256 challenge sent with the sign-in.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// A new pair with a 43-character verifier made from 32 random bytes.
    public static func generate() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PKCE(verifier: base64URL(Data(bytes)))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64url without padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The tokens a sign-in gives: a short-lived access token and the refresh token that gets new ones.
public struct OAuthTokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var idToken: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil, idToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.idToken = idToken
    }

    /// Whether the access token has run out, or will within a minute.
    public func isExpired(at now: Date = Date()) -> Bool { now.addingTimeInterval(60) >= expiresAt }
}

/// What the provider says about who signed in.
public struct OAuthIdentity: Sendable, Hashable {
    public var name: String
    public var email: String
    public var pictureURL: URL?

    public init(name: String, email: String, pictureURL: URL? = nil) {
        self.name = name
        self.email = email
        self.pictureURL = pictureURL
    }

    /// The claims in an ID token (it came straight from the provider over TLS, so its signature isn't checked).
    public static func fromIDToken(_ token: String) -> OAuthIdentity? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = TransferEncoding.decodeBase64(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let email = (claims["email"] as? String) ?? (claims["preferred_username"] as? String) ?? (claims["upn"] as? String)
        guard let email, email.contains("@") else { return nil }
        let name = (claims["name"] as? String) ?? ""
        return OAuthIdentity(name: name, email: email, pictureURL: (claims["picture"] as? String).flatMap(URL.init(string:)))
    }
}

/// Talks to a provider's sign-in endpoints.
public struct OAuthClient: Sendable {
    public let provider: OAuthProvider
    public let transport: any HTTPTransport

    public init(provider: OAuthProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.provider = provider
        self.transport = transport
    }

    /// The provider's sign-in page, for the sign-in window to open.
    public func authorizationURL(pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: provider.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        for key in provider.extraParameters.keys.sorted() { items.append(URLQueryItem(name: key, value: provider.extraParameters[key])) }
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        // "+" must be escaped in query values, which URLComponents leaves alone.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The authorization code from the page the provider redirected to. Throws `.cancelled` if the person said no.
    public func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" || error == "consent_required" { throw PMailError.cancelled }
            throw PMailError.authenticationFailed(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw PMailError.authenticationFailed("The sign-in answer didn’t match the request.") }
        guard let code = value("code"), !code.isEmpty else { throw PMailError.authenticationFailed("The provider sent no sign-in code.") }
        return code
    }

    /// Trades the authorization code for tokens.
    public func exchange(code: String, pkce: PKCE) async throws -> OAuthTokens {
        var fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", provider.redirectURI),
                      ("client_id", provider.clientID), ("code_verifier", pkce.verifier)]
        if let secret = provider.clientSecret { fields.append(("client_secret", secret)) }
        return try await requestTokens(fields, keeping: nil)
    }

    /// New tokens from the refresh token. Providers that don't send a new refresh token keep the old one.
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw PMailError.notSignedIn }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", provider.clientID)]
        if provider.kind == .microsoft { fields.append(("scope", provider.scopes.joined(separator: " "))) }
        if let secret = provider.clientSecret { fields.append(("client_secret", secret)) }
        return try await requestTokens(fields, keeping: tokens)
    }

    private func requestTokens(_ fields: [(String, String)], keeping old: OAuthTokens?) async throws -> OAuthTokens {
        let request = URLRequest(url: provider.tokenEndpoint, method: "POST",
                                 headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                 body: FormEncoding.encode(fields))
        let (data, response) = try await transport.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard response.isSuccess else {
            let error = json["error"] as? String ?? ""
            let description = json["error_description"] as? String ?? ""
            if error == "invalid_grant" {
                throw PMailError.authenticationFailed("The sign-in has expired or was revoked. Sign in again.")
            }
            throw PMailError.authenticationFailed(description.isEmpty ? (error.isEmpty ? "error \(response.statusCode)" : error) : description)
        }
        guard let access = json["access_token"] as? String else { throw PMailError.protocolError("no access token in the answer") }
        let lifetime = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: (json["refresh_token"] as? String) ?? old?.refreshToken,
                           expiresAt: Date().addingTimeInterval(lifetime), scope: (json["scope"] as? String) ?? old?.scope,
                           idToken: (json["id_token"] as? String) ?? old?.idToken)
    }

    /// Who signed in: from the ID token, or else from the provider's profile endpoint.
    public func identity(for tokens: OAuthTokens) async throws -> OAuthIdentity {
        if let token = tokens.idToken, let identity = OAuthIdentity.fromIDToken(token), !identity.name.isEmpty { return identity }
        let url: URL = provider.kind == .microsoft ? URL(string: "https://graph.microsoft.com/v1.0/me")!
            : URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
        let (data, response) = try await transport.data(for: URLRequest(url: url, method: "GET",
                                                                        headers: ["Authorization": "Bearer \(tokens.accessToken)"]))
        guard response.isSuccess, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let token = tokens.idToken, let identity = OAuthIdentity.fromIDToken(token) { return identity }
            throw PMailError.http(status: response.statusCode, message: "Your account’s name and address couldn’t be read.")
        }
        let email = (json["email"] as? String) ?? (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? ""
        let name = (json["name"] as? String) ?? (json["displayName"] as? String) ?? ""
        guard email.contains("@") else { throw PMailError.protocolError("the provider gave no email address") }
        return OAuthIdentity(name: name, email: email, pictureURL: (json["picture"] as? String).flatMap(URL.init(string:)))
    }
}

/// Gives services a current access token, refreshing it once at a time when it runs out, and hands every new set of
/// tokens to `onUpdate` so they're saved.
public actor OAuthTokenProvider: AccessTokenProvider {
    private let client: OAuthClient
    private var tokens: OAuthTokens
    private var refreshing: Task<OAuthTokens, Error>?
    private let onUpdate: @Sendable (OAuthTokens) -> Void
    private let now: @Sendable () -> Date

    public init(client: OAuthClient, tokens: OAuthTokens, now: @escaping @Sendable () -> Date = Date.init,
                onUpdate: @escaping @Sendable (OAuthTokens) -> Void) {
        self.client = client
        self.tokens = tokens
        self.now = now
        self.onUpdate = onUpdate
    }

    public var currentTokens: OAuthTokens { tokens }

    public func accessToken() async throws -> String {
        if !tokens.isExpired(at: now()) { return tokens.accessToken }
        return try await refreshedTokens().accessToken
    }

    public func invalidateAccessToken() async {
        tokens.expiresAt = .distantPast
    }

    private func refreshedTokens() async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        let client = self.client
        let old = tokens
        let task = Task { try await client.refresh(old) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        onUpdate(fresh)
        return fresh
    }
}
