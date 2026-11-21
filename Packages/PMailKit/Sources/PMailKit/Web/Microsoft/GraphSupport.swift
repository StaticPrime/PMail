import Foundation

/// One request inside a Microsoft Graph JSON batch.
struct GraphBatchRequest: Sendable, Hashable {
    var method: String
    /// The address from the API version on ("/me/messages/AAMk…/move").
    var url: String
    var body: JSONValue?
    var headers: [String: String]

    init(method: String, url: String, body: JSONValue? = nil, headers: [String: String] = [:]) {
        self.method = method
        self.url = url
        self.body = body
        self.headers = headers
    }
}

/// Helpers the Microsoft mail, calendar and contacts services share for talking to Microsoft Graph.
enum Graph {
    static let root = "https://graph.microsoft.com/v1.0/"
    /// The most requests Graph takes in one JSON batch.
    static let batchLimit = 20

    /// A link from the server (a next page), only when it really points at Graph, so the token never goes elsewhere.
    static func url(fromLink text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return url.host?.lowercased() == "graph.microsoft.com" ? url : nil
    }

    /// An address from Graph's `{"emailAddress": {"name": …, "address": …}}`. A name that only repeats the address is
    /// left out.
    static func address(_ json: JSONValue) -> MailAddress? {
        let value = json["emailAddress"]
        guard let email = value["address"].nonEmpty else { return nil }
        let name = value["name"].nonEmpty.flatMap { $0.caseInsensitiveCompare(email) == .orderedSame ? nil : $0 }
        return MailAddress(name: name, email: email)
    }

    /// Graph's form of an address.
    static func addressJSON(_ address: MailAddress) -> JSONValue {
        var value: [String: JSONValue] = ["address": .string(address.email)]
        if let name = address.name { value["name"] = .string(name) }
        return ["emailAddress": .object(value)]
    }

    /// Text as an OData string literal, single quotes doubled.
    static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A header's value in a batch answer's headers, whatever case its name is in.
    static func header(_ name: String, in headers: JSONValue) -> String? {
        headers.object?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.string
    }

    static func batchJSON(id: String, _ request: GraphBatchRequest) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "method": .string(request.method), "url": .string(request.url)]
        var headers = request.headers
        if let body = request.body {
            object["body"] = body
            headers["Content-Type"] = "application/json"
        }
        if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
        return .object(object)
    }
}

extension WebClient {
    /// Every item of a Graph collection, following `@odata.nextLink` (at most `maxPages` pages).
    func graphItems(_ first: URL, headers: [String: String] = [:], maxPages: Int = 50) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var next: URL? = first
        var pages = 0
        while let url = next, pages < maxPages {
            let page = try await get(url, headers: headers)
            items += page["value"].array
            pages += 1
            next = page["@odata.nextLink"].string.flatMap(Graph.url(fromLink:))
        }
        return items
    }

    /// Sends requests as Graph JSON batches of 20, tries the ones Graph throttled again (after the wait it asks for,
    /// up to `busyRetries` times), and throws the first failure once everything has been tried. With
    /// `ignoringMissing`, requests for things that are already gone (404) count as done.
    func graphBatch(_ requests: [GraphBatchRequest], ignoringMissing: Bool = true) async throws {
        guard !requests.isEmpty else { return }
        let batchURL = try WebURL.make(Graph.root + "$batch")
        var pending = requests.enumerated().map { (id: String($0.offset + 1), request: $0.element) }
        var attempts = 0
        var failure: PMailError?
        while !pending.isEmpty {
            var throttled: [(id: String, request: GraphBatchRequest)] = []
            var throttleError: PMailError?
            var wait = 0.0
            for chunk in Self.chunked(pending, size: Graph.batchLimit) {
                let body: JSONValue = ["requests": .array(chunk.map { Graph.batchJSON(id: $0.id, $0.request) })]
                let answer = try await post(batchURL, body)
                var responses: [String: JSONValue] = [:]
                for response in answer["responses"].array {
                    if let id = response["id"].string ?? response["id"].int.map(String.init) { responses[id] = response }
                }
                for item in chunk {
                    guard let response = responses[item.id] else {
                        failure = failure ?? .protocolError("an answer was missing from a batch")
                        continue
                    }
                    let status = response["status"].int ?? 0
                    if (200..<300).contains(status) || (ignoringMissing && (status == 404 || status == 410)) { continue }
                    if status == 429 || status == 503 || status == 504 {
                        throttled.append(item)
                        throttleError = throttleError ?? Self.error(status: status, data: response["body"].encoded())
                        let asked = Graph.header("Retry-After", in: response["headers"])
                        wait = max(wait, Self.retryDelay(asked, attempt: attempts + 1, cap: maxRetryDelay))
                        continue
                    }
                    failure = failure ?? Self.error(status: status, data: response["body"].encoded())
                }
            }
            guard !throttled.isEmpty else { break }
            guard attempts < busyRetries else {
                failure = failure ?? throttleError
                break
            }
            attempts += 1
            try await Self.mappingErrors { try await pause(wait) }
            pending = throttled
        }
        if let failure { throw failure }
    }
}
