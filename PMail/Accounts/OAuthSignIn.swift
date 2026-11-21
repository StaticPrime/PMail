import AppKit
import AuthenticationServices
import PMailKit

/// Signs in through a provider's own page, in the system's secure sign-in window: PKCE, the code, then tokens and
/// who signed in. Nothing about the sign-in is kept by the browser afterwards.
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(with provider: OAuthProvider, loginHint: String? = nil) async throws -> (tokens: OAuthTokens, identity: OAuthIdentity) {
        let client = OAuthClient(provider: provider)
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let url = client.authorizationURL(pkce: pkce, state: state, loginHint: loginHint)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let handler: (URL?, Error?) -> Void = { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: PMailError.cancelled)
                } else {
                    continuation.resume(throwing: PMailError.authenticationFailed(error?.localizedDescription ?? "The sign-in window closed."))
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(provider.callbackScheme), completionHandler: handler)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: provider.callbackScheme, completionHandler: handler)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: PMailError.authenticationFailed("The sign-in window couldn’t be opened."))
            }
        }
        session = nil
        let code = try client.authorizationCode(from: callback, expectedState: state)
        let tokens = try await client.exchange(code: code, pkce: pkce)
        let identity = try await client.identity(for: tokens)
        return (tokens, identity)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}
