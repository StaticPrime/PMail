import Foundation
@testable import PMailKit

/// A pretend web server for web service tests: answers requests from a list of handlers, and records every
/// request it was sent.
///
///     let transport = StubTransport()
///     transport.on("GET", "/gmail/v1/users/me/labels") { _ in .json(#"{"labels": []}"#) }
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
        }

        static func text(_ text: String, status: Int = 200, contentType: String = "text/plain") -> Response {
            Response(status: status, body: Data(text.utf8), headers: ["Content-Type": contentType])
        }

        static func status(_ status: Int) -> Response {
            Response(status: status, body: Data(), headers: [:])
        }
    }

    private struct Handler {
        var method: String
        var pathPrefix: String
        var respond: (URLRequest) -> Response
    }

    private let lock = NSLock()
    private var handlers: [Handler] = []
    private(set) var requests: [URLRequest] = []

    /// Answers requests with this method whose URL path starts with `pathPrefix`. Later handlers win over earlier
    /// ones, so a test can override a default.
    func on(_ method: String, _ pathPrefix: String, _ respond: @escaping (URLRequest) -> Response) {
        lock.withLock { handlers.append(Handler(method: method, pathPrefix: pathPrefix, respond: respond)) }
    }

    /// The requests sent with this method to paths starting with `pathPrefix`.
    func sent(_ method: String, _ pathPrefix: String) -> [URLRequest] {
        lock.withLock { requests.filter { $0.httpMethod == method && ($0.url?.path ?? "").hasPrefix(pathPrefix) } }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: Handler? = lock.withLock {
            requests.append(request)
            let path = request.url?.path ?? ""
            return handlers.last { $0.method == (request.httpMethod ?? "GET") && path.hasPrefix($0.pathPrefix) }
        }
        let response = handler?.respond(request) ?? .text("no stub for \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")", status: 404)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}

extension URLRequest {
    /// The body as text, for checking what a client sent.
    var bodyText: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// The body as a JSON object.
    var bodyJSON: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A query parameter of the URL.
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }
}
