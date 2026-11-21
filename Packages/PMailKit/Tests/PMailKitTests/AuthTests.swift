import Foundation
import Testing
@testable import PMailKit

@Suite struct AuthTests {
    @Test func pkceChallengeMatchesTheStandardsExample() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE.generate()
        #expect(fresh.verifier.count == 43)
        #expect(!fresh.verifier.contains("=") && !fresh.verifier.contains("+") && !fresh.verifier.contains("/"))
    }

    @Test func configurationComesFromTheEnvironmentThenTheInfoPlist() {
        let empty = OAuthConfiguration.load(environment: [:], info: ["PMailGoogleClientID": "$(PMAIL_GOOGLE_CLIENT_ID)",
                                                                     "PMailMicrosoftClientID": ""])
        #expect(empty.google == nil && empty.microsoft == nil)

        let fromInfo = OAuthConfiguration.load(environment: [:], info: ["PMailGoogleClientID": "1234-abc.apps.googleusercontent.com"])
        #expect(fromInfo.google?.redirectURI == "com.googleusercontent.apps.1234-abc:/oauth2redirect")
        #expect(fromInfo.google?.callbackScheme == "com.googleusercontent.apps.1234-abc")

        let fromEnvironment = OAuthConfiguration.load(
            environment: ["PMAIL_MICROSOFT_CLIENT_ID": "abcd-ef", "PMAIL_MICROSOFT_TENANT": "consumers",
                          "PMAIL_GOOGLE_CLIENT_ID": "env-id.apps.googleusercontent.com"],
            info: ["PMailGoogleClientID": "plist-id.apps.googleusercontent.com"])
        #expect(fromEnvironment.google?.clientID == "env-id.apps.googleusercontent.com")
        #expect(fromEnvironment.microsoft?.tokenEndpoint.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
        #expect(fromEnvironment.microsoft?.redirectURI == "msauth.com.pugglesoft.PMail://auth")
        #expect(OAuthConfiguration.infoKey(for: "PMAIL_MICROSOFT_REDIRECT_URI") == "PMailMicrosoftRedirectURI")
    }

    @Test func authorizationURLCarriesPKCEAndScopes() throws {
        let client = OAuthClient(provider: .google(clientID: "1234-abc.apps.googleusercontent.com"), transport: StubTransport())
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = client.authorizationURL(pkce: pkce, state: "s1", loginHint: "jamie@example.com")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(value("code_challenge") == pkce.challenge && value("code_challenge_method") == "S256")
        #expect(value("response_type") == "code" && value("state") == "s1" && value("access_type") == "offline")
        #expect(value("scope")?.contains("https://mail.google.com/") == true)
        #expect(value("login_hint") == "jamie@example.com")
    }

    @Test func callbacksGiveTheCodeOrAReason() throws {
        let client = OAuthClient(provider: .microsoft(clientID: "id"), transport: StubTransport())
        let code = try client.authorizationCode(from: URL(string: "msauth.com.pugglesoft.PMail://auth?code=abc&state=s1")!, expectedState: "s1")
        #expect(code == "abc")
        #expect(throws: PMailError.cancelled) {
            try client.authorizationCode(from: URL(string: "msauth.com.pugglesoft.PMail://auth?error=access_denied&state=s1")!, expectedState: "s1")
        }
        #expect(throws: PMailError.self) {
            try client.authorizationCode(from: URL(string: "msauth.com.pugglesoft.PMail://auth?code=abc&state=other")!, expectedState: "s1")
        }
    }

    @Test func exchangeAndRefreshKeepTheRefreshToken() async throws {
        let transport = StubTransport()
        transport.on("POST", "/token") { request in
            if request.bodyText.contains("grant_type=authorization_code") {
                return .json(#"{"access_token": "a1", "refresh_token": "r1", "expires_in": 3600, "id_token": "x.eyJlbWFpbCI6ImphbWllQGV4YW1wbGUuY29tIiwibmFtZSI6IkphbWllIFJpdmVyYSJ9.y"}"#)
            }
            return .json(#"{"access_token": "a2", "expires_in": "1800"}"#)
        }
        let client = OAuthClient(provider: .google(clientID: "id.apps.googleusercontent.com"), transport: transport)
        let pkce = PKCE.generate()
        let tokens = try await client.exchange(code: "c", pkce: pkce)
        #expect(tokens.accessToken == "a1" && tokens.refreshToken == "r1")
        #expect(transport.requests.first?.bodyText.contains("code_verifier=\(pkce.verifier)") == true)
        let identity = try await client.identity(for: tokens)
        #expect(identity.email == "jamie@example.com" && identity.name == "Jamie Rivera")
        let refreshed = try await client.refresh(tokens)
        #expect(refreshed.accessToken == "a2" && refreshed.refreshToken == "r1")
    }

    @Test func revokedRefreshTokensAskToSignInAgain() async {
        let transport = StubTransport()
        transport.on("POST", "/token") { _ in .json(#"{"error": "invalid_grant"}"#, status: 400) }
        let client = OAuthClient(provider: .google(clientID: "id"), transport: transport)
        await #expect {
            _ = try await client.refresh(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantPast))
        } throws: { error in
            (error as? PMailError)?.needsSignIn == true
        }
    }

    @Test func tokenProviderRefreshesOnceWhenExpired() async throws {
        let transport = StubTransport()
        transport.on("POST", "/common/oauth2/v2.0/token") { _ in .json(#"{"access_token": "fresh", "expires_in": 3600}"#) }
        let client = OAuthClient(provider: .microsoft(clientID: "id"), transport: transport)
        let saved = SavedTokens()
        let provider = OAuthTokenProvider(client: client,
                                          tokens: OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)),
                                          onUpdate: { saved.set($0) })
        #expect(try await provider.accessToken() == "old")
        await provider.invalidateAccessToken()
        async let first = provider.accessToken()
        async let second = provider.accessToken()
        #expect(try await [first, second] == ["fresh", "fresh"])
        #expect(transport.sent("POST", "/").count == 1)
        #expect(saved.get()?.accessToken == "fresh")
        #expect(transport.requests.first?.bodyText.contains("scope=") == true)
    }

    @Test func accountsAndSecretsSaveAndLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailAccounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountStore(fileURL: folder.appendingPathComponent("Accounts.json"))
        #expect(store.load().isEmpty)
        let presets = ServerPresets.iCloud(email: "pug@icloud.com")
        let account = Account(kind: .icloud, name: "Pug", email: "pug@icloud.com", incoming: presets.incoming, outgoing: presets.outgoing,
                              calendarServer: presets.calendar, contactsServer: presets.contacts, serverLoginName: presets.login)
        try store.save([account])
        #expect(store.load() == [account])

        let secrets = MemorySecretStore()
        try secrets.setSecret(.password("app-specific"), for: account.id)
        #expect(try secrets.secret(for: account.id) == .password("app-specific"))
        try secrets.setSecret(nil, for: account.id)
        #expect(try secrets.secret(for: account.id) == nil)
    }
}

/// Tokens handed to `onUpdate`, kept for checking.
private final class SavedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?
    func set(_ tokens: OAuthTokens) { lock.withLock { self.tokens = tokens } }
    func get() -> OAuthTokens? { lock.withLock { tokens } }
}
