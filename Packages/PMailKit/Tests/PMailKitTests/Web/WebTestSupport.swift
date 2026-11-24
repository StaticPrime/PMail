import Foundation
@testable import PMailKit

/// Tokens for web service tests: "token-1" until it's thrown away, then "token-2", and so on.
final class WebTestTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 1
    private var thrownAway = 0

    /// How many times a token was thrown away after the server turned it down.
    var invalidations: Int { lock.withLock { thrownAway } }

    func accessToken() async throws -> String {
        lock.withLock { "token-\(generation)" }
    }

    func invalidateAccessToken() async {
        lock.withLock {
            generation += 1
            thrownAway += 1
        }
    }
}

/// Records the waits a web client asks for, instead of waiting.
final class WebTestPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var waits: [Double] { lock.withLock { recorded } }

    func record(_ seconds: Double) {
        lock.withLock { recorded.append(seconds) }
    }
}

extension WebClient {
    /// A client for tests: the stub server, test tokens, and waits that return at once (recorded in `pauses`).
    static func test(_ transport: StubTransport, tokens: WebTestTokens = WebTestTokens(),
                     pauses: WebTestPauses = WebTestPauses()) -> WebClient {
        WebClient(tokens: tokens, transport: transport, pause: { pauses.record($0) }, jitter: { 1 })
    }
}

/// Fixture helpers for the web service tests.
enum WebFixtures {
    /// base64url without padding, the way Google's mail API sends raw messages.
    static func base64url(_ text: String) -> String {
        WebBase64.urlEncoded(Data(text.utf8))
    }

    /// A moment from ISO 8601 text ("2026-11-23T15:00:00Z"), read by Foundation rather than the code under test.
    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    /// Midnight starting a day in the Mac's time zone, as all-day events keep it.
    static func localMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}

extension URLRequest {
    /// Every value of a query parameter that may repeat (`labelIds=INBOX&labelIds=CATEGORY_SOCIAL`).
    func queryValues(named name: String) -> [String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return items.filter { $0.name == name }.compactMap(\.value)
    }

    /// The body as a JSON value.
    var bodyJSONValue: JSONValue {
        httpBody.flatMap { try? JSONValue.parse($0) } ?? .null
    }

    var authorization: String? { value(forHTTPHeaderField: "Authorization") }
}
