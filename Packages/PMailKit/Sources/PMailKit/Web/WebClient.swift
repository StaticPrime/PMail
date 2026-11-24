import Foundation
import os

/// Talks to a provider's JSON web API for one account. It adds the bearer token, gets a fresh token and tries once
/// more when a token is turned down, waits and tries again when the service says it's busy, that the account has too
/// many requests going or that it's going too fast for the minute, keeps within what the account may spend in a
/// minute and have going at once when the service limits that, and turns error answers into `PMailError`s worded for
/// the person.
struct WebClient: Sendable {
    let tokens: any AccessTokenProvider
    let transport: any HTTPTransport
    /// The longest wait, in seconds, that a busy answer's `Retry-After` can ask for.
    var maxRetryDelay: Double
    /// How many times a busy answer (HTTP 429 or 503, or a server error to a GET) is tried again.
    var busyRetries: Int
    /// What the account may spend in a minute, for a service that counts it (Google's mail API): requests wait for
    /// room instead of being refused.
    let budget: RequestBudget?
    /// How many requests the account may have going at once, for a service that limits it (Google's mail API).
    let gate: RequestGate?
    /// How many times a refusal for going too fast for the minute is tried again.
    var rateLimitRetries: Int
    /// Waits a number of seconds. Tests swap in one that returns at once.
    let pause: @Sendable (Double) async throws -> Void
    /// From 0 to 1, for spreading out the waits before trying again, so requests refused together don't come back
    /// together. Tests use 1, which waits the whole time.
    let jitter: @Sendable () -> Double

    /// How many times a refusal for having too many requests going at once is tried again.
    static let crowdedRetries = 5
    /// Notes on waiting and refusals, in the Console app under the "Requests" category.
    static let log = Logger(subsystem: "com.pugglesoft.PMail", category: "Requests")

    init(tokens: any AccessTokenProvider, transport: any HTTPTransport, maxRetryDelay: Double = 5, busyRetries: Int = 2,
         budget: RequestBudget? = nil, gate: RequestGate? = nil, rateLimitRetries: Int = 3,
         pause: @escaping @Sendable (Double) async throws -> Void = WebClient.sleep,
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.tokens = tokens
        self.transport = transport
        self.maxRetryDelay = maxRetryDelay
        self.busyRetries = busyRetries
        self.budget = budget
        self.gate = gate
        self.rateLimitRetries = rateLimitRetries
        self.pause = pause
        self.jitter = jitter
    }

    /// Really waits, for the app.
    static func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
    }

    // MARK: Requests

    /// Sends a request and returns the body and response of a successful answer (any 2xx status).
    func send(_ method: String, _ url: URL, body: Data? = nil, contentType: String? = nil,
              headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let inBackground = BackgroundWork.isRunning
        var triedNewToken = false
        var busyAttempts = 0
        var rateLimitAttempts = 0
        var crowdedAttempts = 0
        while true {
            if let budget {
                try await Self.mappingErrors { try await budget.spend(method, url, inBackground: inBackground) }
            }
            let token = try await Self.mappingErrors { try await tokens.accessToken() }
            var allHeaders = headers
            allHeaders["Authorization"] = "Bearer \(token)"
            if let contentType { allHeaders["Content-Type"] = contentType }
            let request = URLRequest(url: url, method: method, headers: allHeaders, body: body)
            let (data, response) = try await transmit(request, inBackground: inBackground)
            let status = response.statusCode
            if (200..<300).contains(status) { return (data, response) }
            if status == 401 {
                if triedNewToken { throw PMailError.authenticationFailed(Self.errorMessage(from: data)) }
                triedNewToken = true
                await tokens.invalidateAccessToken()
                continue
            }
            switch Self.refusal(status: status, data: data) {
            case .tooManyAtOnce?:
                // Too many requests going for the account (others of PMail's, or another app's): a moment's wait, a
                // little longer each time.
                guard crowdedAttempts < Self.crowdedRetries else { throw Self.error(status: status, data: data) }
                crowdedAttempts += 1
                let wait = Self.backoff(attempt: crowdedAttempts, base: 0.5, cap: 8, jitter: jitter())
                Self.log.notice("Too many requests going at once; trying again in \(wait, format: .fixed(precision: 1)) s")
                try await Self.mappingErrors { try await pause(wait) }
                continue
            case .tooFastForTheMinute?:
                // Too fast for the minute: wait a little, longer each time, and if it goes on, say so plainly.
                guard rateLimitAttempts < rateLimitRetries else { throw PMailError.server(Self.slowDownMessage) }
                rateLimitAttempts += 1
                if let budget {
                    await budget.refused()
                } else {
                    let asked = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), attempt: 0, cap: 60)
                    let wait = asked > 0 ? asked : Self.backoff(attempt: rateLimitAttempts, base: 5, cap: 60, jitter: jitter())
                    try await Self.mappingErrors { try await pause(wait) }
                }
                continue
            case nil:
                break
            }
            if Self.isBusy(status: status, method: method), busyAttempts < busyRetries {
                busyAttempts += 1
                let asked = response.value(forHTTPHeaderField: "Retry-After")
                let wait = asked == nil
                    ? Self.backoff(attempt: busyAttempts, base: 1, cap: maxRetryDelay, jitter: jitter())
                    : Self.retryDelay(asked, attempt: busyAttempts, cap: maxRetryDelay)
                try await Self.mappingErrors { try await pause(wait) }
                continue
            }
            throw Self.error(status: status, data: data)
        }
    }

    /// Sends one request on its way, taking a place among the account's requests going at once where the service
    /// limits them.
    private func transmit(_ request: URLRequest, inBackground: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let gate else { return try await Self.mappingErrors { try await transport.data(for: request) } }
        await gate.enter(inBackground: inBackground)
        do {
            let answer = try await Self.mappingErrors { try await transport.data(for: request) }
            await gate.leave(inBackground: inBackground)
            return answer
        } catch {
            await gate.leave(inBackground: inBackground)
            throw error
        }
    }

    /// Whether an unsuccessful answer is worth trying again after a moment: the service is busy, or a server error
    /// answered a request that's safe to send twice.
    static func isBusy(status: Int, method: String) -> Bool {
        status == 429 || status == 503 || (method.uppercased() == "GET" && [500, 502, 504].contains(status))
    }

    /// Sends a request with an optional body and reads the JSON answer (`.null` when the answer is empty).
    func json(_ method: String, _ url: URL, body: Data?, contentType: String?,
              headers: [String: String] = [:]) async throws -> JSONValue {
        var allHeaders = headers
        if allHeaders["Accept"] == nil { allHeaders["Accept"] = "application/json" }
        let (data, _) = try await send(method, url, body: body, contentType: contentType, headers: allHeaders)
        do {
            return try JSONValue.parse(data)
        } catch {
            throw PMailError.protocolError("the answer wasn’t valid JSON")
        }
    }

    /// Sends a request with an optional JSON body and reads the JSON answer.
    func json(_ method: String, _ url: URL, _ body: JSONValue? = nil, headers: [String: String] = [:]) async throws -> JSONValue {
        try await json(method, url, body: body?.encoded(), contentType: body == nil ? nil : "application/json", headers: headers)
    }

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> JSONValue {
        try await json("GET", url, headers: headers)
    }

    func post(_ url: URL, _ body: JSONValue? = nil, headers: [String: String] = [:]) async throws -> JSONValue {
        try await json("POST", url, body, headers: headers)
    }

    func patch(_ url: URL, _ body: JSONValue, headers: [String: String] = [:]) async throws -> JSONValue {
        try await json("PATCH", url, body, headers: headers)
    }

    func put(_ url: URL, _ body: JSONValue, headers: [String: String] = [:]) async throws -> JSONValue {
        try await json("PUT", url, body, headers: headers)
    }

    func delete(_ url: URL, headers: [String: String] = [:]) async throws {
        _ = try await send("DELETE", url, headers: headers)
    }

    /// The raw body of a GET, for answers that aren't JSON (a whole message as RFC 822 text).
    func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await send("GET", url, headers: headers).0
    }

    /// Fetches a file that needs no sign-in (a contact's picture), without sending the token anywhere.
    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.mappingErrors { try await transport.data(for: URLRequest(url: url, method: "GET")) }
        guard response.isSuccess else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    /// Every page of a list that pages with `nextPageToken` (Google's services), at most `maxPages` of them.
    func pages(maxPages: Int = 50, headers: [String: String] = [:],
               _ makeURL: (_ pageToken: String?) throws -> URL) async throws -> [JSONValue] {
        var pages: [JSONValue] = []
        var token: String?
        repeat {
            let page = try await get(try makeURL(token), headers: headers)
            pages.append(page)
            let next = page["nextPageToken"].nonEmpty
            if next != nil, next == token { break }
            token = next
        } while token != nil && pages.count < maxPages
        return pages
    }

    // MARK: Errors

    /// Runs some work, turning anything it throws into a `PMailError`.
    static func mappingErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as PMailError {
            throw error
        } catch is CancellationError {
            throw PMailError.cancelled
        } catch {
            throw PMailError.connectionFailed(error.localizedDescription)
        }
    }

    /// What PMail says when a service keeps refusing because the account is going too fast.
    static let slowDownMessage = "The server asked PMail to slow down for a minute. Try again shortly."

    /// Why a service refused a request that waiting a little can cure.
    enum Refusal: Equatable {
        /// The account has too many requests going at once (Google: "Too many concurrent requests for user").
        case tooManyAtOnce
        /// The account is going too fast for the minute (a per-minute quota, which passes).
        case tooFastForTheMinute
    }

    /// Why an answer refuses, when waiting a little cures it: too many requests at once, or too fast for the minute.
    /// A daily limit or missing permission, which waiting doesn't cure, is nil, like any other answer.
    static func refusal(status: Int, data: Data) -> Refusal? {
        guard status == 403 || status == 429, let json = try? JSONValue.parse(data) else { return nil }
        let error = json["error"]
        let details = error["errors"].array + error["details"].array
        let messages = ([error["message"].string] + details.map { $0["message"].string }).compactMap { $0?.lowercased() }
        let reasons = details.compactMap { $0["reason"].string }
        if messages.contains(where: { $0.contains("per day") }) || reasons.contains("dailyLimitExceeded") { return nil }
        // Google gives this the same reason as going too fast; only the message tells them apart.
        if messages.contains(where: { $0.contains("concurrent") }) { return .tooManyAtOnce }
        if reasons.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"].contains($0) })
            || messages.contains(where: { $0.contains("quota exceeded") && $0.contains("per minute") }) {
            return .tooFastForTheMinute
        }
        return nil
    }

    /// How long to wait before trying again for the `attempt`th time (from 1): `base` seconds, doubling each time,
    /// never more than `cap`, with up to half taken off by `jitter` (from 0 to 1; 1 takes nothing off).
    static func backoff(attempt: Int, base: Double, cap: Double, jitter: Double) -> Double {
        let whole = min(base * pow(2, Double(max(attempt, 1) - 1)), cap)
        return whole * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }

    /// The error for an unsuccessful HTTP status.
    static func error(status: Int, data: Data) -> PMailError {
        switch status {
        case 401: .authenticationFailed(errorMessage(from: data))
        case 404, 410: .notFound
        case 412: .conflict
        default: .http(status: status, message: errorMessage(from: data))
        }
    }

    /// The service's own explanation from an error answer: Google's and Microsoft's `error.message`, an OAuth
    /// `error_description`, or short plain text. Empty when there's nothing readable.
    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONValue.parse(data) {
            if let message = json["error"]["message"].nonEmpty { return message }
            if let message = json["error_description"].nonEmpty { return message }
            if let message = json["error"].nonEmpty { return message }
            if let message = json["message"].nonEmpty { return message }
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.count <= 200, !text.hasPrefix("<"), !text.hasPrefix("{") { return text }
        return ""
    }

    /// How long to wait before trying a busy request again: what `Retry-After` asks (seconds or an HTTP date), else 1
    /// then 2 seconds, never more than `cap`.
    static func retryDelay(_ header: String?, attempt: Int, cap: Double, now: Date = Date()) -> Double {
        var asked: Double?
        if let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            if let seconds = Double(header) {
                asked = seconds
            } else if let date = MailDate.parse(header) {
                asked = date.timeIntervalSince(now)
            }
        }
        let wait = asked ?? Double(attempt)
        guard wait.isFinite else { return cap }
        return min(max(wait, 0), cap)
    }

    // MARK: Fan-out

    /// Runs `transform` on every item, at most `limit` at a time, and returns the results in the items' order. The
    /// first error stops the rest.
    static func concurrentMap<Item: Sendable, Output: Sendable>(
        _ items: [Item], limit: Int = 8, _ transform: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> [Output] {
        guard !items.isEmpty else { return [] }
        var results = [Output?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            while next < min(max(limit, 1), items.count) {
                let index = next
                let item = items[index]
                group.addTask { (index, try await transform(item)) }
                next += 1
            }
            while let (index, output) = try await group.next() {
                results[index] = output
                if next < items.count {
                    let nextIndex = next
                    let item = items[nextIndex]
                    group.addTask { (nextIndex, try await transform(item)) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    /// The items in groups of at most `size`, for services that take a limited number per request.
    static func chunked<Item>(_ items: [Item], size: Int) -> [[Item]] {
        let size = max(size, 1)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The strings without repeats, in their first order.
    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// Builds web service URLs, escaping path parts and query values strictly (a "+" or "&" in a search stays itself).
enum WebURL {
    private static let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    private static let segmentAllowed = CharacterSet(charactersIn: unreserved + "!$'()*,;=:@")
    private static let queryAllowed = CharacterSet(charactersIn: unreserved + "!$'()*,:@/")

    /// A URL from a base and path, with query parameters in order (a name may repeat).
    static func make(_ string: String, query: [(String, String)] = []) throws -> URL {
        guard var components = URLComponents(string: string) else { throw PMailError.protocolError("a bad address: \(string)") }
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(escapeQuery($0.0))=\(escapeQuery($0.1))" }.joined(separator: "&")
        }
        guard let url = components.url else { throw PMailError.protocolError("a bad address: \(string)") }
        return url
    }

    /// One path segment (an ID), with "/", "?", "#" and everything unusual escaped.
    static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? ""
    }

    /// A path made of several segments ("people/c123"), each escaped but the slashes kept.
    static func path(_ text: String) -> String {
        text.split(separator: "/", omittingEmptySubsequences: false).map { segment(String($0)) }.joined(separator: "/")
    }

    /// A query parameter's name or value, escaped so a "+", "&" or "=" in it stays itself.
    static func escapeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    /// A web link from a service's answer (a join link, a picture): only a whole http or https address counts, since
    /// `URL(string:)` happily turns any text into a relative URL.
    static func webLink(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url.host?.isEmpty == false ? url : nil
    }
}
