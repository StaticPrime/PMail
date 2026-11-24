import Foundation
import Testing
@testable import PMailKit

/// Refusals for going too fast for the minute or for having too many requests going at once are waited out and tried
/// again; daily limits and missing permission aren't, since waiting a little doesn't cure them.
@Suite struct WebClientRateLimitTests {
    private func url(_ path: String) throws -> URL {
        try #require(URL(string: "https://api.example.com" + path))
    }

    /// Google's refusal when an account spends more than its units for the minute.
    static let perMinute = #"""
    {"error": {"code": 403,
     "message": "Quota exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per user' of service 'gmail.googleapis.com' for consumer 'project_number:1234'.",
     "errors": [{"message": "Quota exceeded", "domain": "usageLimits", "reason": "rateLimitExceeded"}],
     "status": "PERMISSION_DENIED"}}
    """#

    @Test func aPerMinuteRefusalIsWaitedOutAndTriedAgain() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in
            transport.sent("GET", "/thing").count == 1 ? .json(Self.perMinute, status: 403) : .json(#"{"ok": true}"#)
        }
        let json = try await WebClient.test(transport, pauses: pauses).get(url("/thing"))
        #expect(json["ok"].bool == true)
        #expect(pauses.waits == [5])
    }

    @Test func refusalsThatGoOnAreSaidPlainly() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in .json(Self.perMinute, status: 403) }
        let client = WebClient.test(transport, pauses: pauses)
        await #expect(throws: PMailError.server(WebClient.slowDownMessage)) { try await client.get(url("/thing")) }
        #expect(transport.requests.count == 4)
        #expect(pauses.waits == [5, 10, 20])
    }

    @Test func aBudgetedClientPausesTheAccountsRequestsAfterARefusal() async throws {
        let transport = StubTransport()
        let clock = BudgetClock()
        transport.on("GET", "/thing") { _ in
            transport.sent("GET", "/thing").count == 1 ? .json(Self.perMinute, status: 403) : .json(#"{"ok": true}"#)
        }
        let client = WebClient(tokens: WebTestTokens(), transport: transport, budget: .test(clock, costing: 5), pause: { _ in })
        _ = try await client.get(url("/thing"))
        #expect(clock.waits == [5])
        #expect(transport.requests.count == 2)
    }

    /// Google's refusal when an account has too many requests going at once, with the same reason as going too fast.
    static let tooManyAtOnce = #"""
    {"error": {"code": 429, "message": "Too many concurrent requests for user",
     "errors": [{"domain": "global", "reason": "rateLimitExceeded", "message": "Too many concurrent requests for user"}]}}
    """#

    @Test func tooManyAtOnceIsTriedAgainAfterAMomentWithoutPausingTheAccount() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        let clock = BudgetClock()
        transport.on("GET", "/thing") { _ in
            transport.sent("GET", "/thing").count == 1 ? .json(Self.tooManyAtOnce, status: 429) : .json(#"{"ok": true}"#)
        }
        let client = WebClient(tokens: WebTestTokens(), transport: transport, budget: .test(clock, costing: 5),
                               pause: { pauses.record($0) }, jitter: { 1 })
        #expect(try await client.get(url("/thing"))["ok"].bool == true)
        #expect(pauses.waits == [0.5])
        #expect(clock.waits.isEmpty, "the minute isn't counted as spent")
        #expect(WebClient.refusal(status: 429, data: Data(Self.tooManyAtOnce.utf8)) == .tooManyAtOnce)
        #expect(WebClient.refusal(status: 403, data: Data(Self.perMinute.utf8)) == .tooFastForTheMinute)
    }

    @Test func tooManyAtOnceThatGoesOnGivesUpWaitingLongerEachTime() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in .json(Self.tooManyAtOnce, status: 429) }
        let client = WebClient.test(transport, pauses: pauses)
        await #expect(throws: PMailError.http(status: 429, message: "Too many concurrent requests for user")) {
            try await client.get(url("/thing"))
        }
        #expect(transport.requests.count == 6)
        #expect(pauses.waits == [0.5, 1, 2, 4, 8])
    }

    @Test func serverErrorsToReadsAreTriedAgainButNotToChanges() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/thing") { _ in
            transport.sent("GET", "/thing").count == 1 ? .json(#"{"error": {"message": "Backend Error"}}"#, status: 500)
                : .json(#"{"ok": true}"#)
        }
        transport.on("POST", "/send") { _ in .json(#"{"error": {"message": "Backend Error"}}"#, status: 500) }
        let client = WebClient.test(transport, pauses: pauses)
        #expect(try await client.get(url("/thing"))["ok"].bool == true)
        #expect(pauses.waits == [1])
        await #expect(throws: PMailError.http(status: 500, message: "Backend Error")) { try await client.post(url("/send")) }
        #expect(transport.sent("POST", "/send").count == 1, "a change might have gone through, so it isn't sent twice")
    }

    @Test func waitsDoubleUpToTheirCapAndJitterTakesUpToHalfOff() {
        #expect((1...5).map { WebClient.backoff(attempt: $0, base: 5, cap: 60, jitter: 1) } == [5, 10, 20, 40, 60])
        #expect(WebClient.backoff(attempt: 2, base: 5, cap: 60, jitter: 0) == 5)
        #expect(WebClient.backoff(attempt: 2, base: 5, cap: 60, jitter: 0.5) == 7.5)
    }

    @Test func dailyLimitsAndMissingPermissionAreNotWaitedOn() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "/daily") { _ in
            .json(#"""
            {"error": {"code": 403,
             "message": "Quota exceeded for quota metric 'Queries' and limit 'Queries per day' of service 'gmail.googleapis.com'.",
             "errors": [{"domain": "usageLimits", "reason": "dailyLimitExceeded"}]}}
            """#, status: 403)
        }
        transport.on("GET", "/scopes") { _ in
            .json(#"{"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "status": "PERMISSION_DENIED"}}"#,
                  status: 403)
        }
        let client = WebClient.test(transport, pauses: pauses)
        await #expect(throws: PMailError.self) { try await client.get(url("/daily")) }
        await #expect(throws: PMailError.http(status: 403, message: "Request had insufficient authentication scopes.")) {
            try await client.get(url("/scopes"))
        }
        #expect(transport.requests.count == 2)
        #expect(pauses.waits.isEmpty)
    }
}
