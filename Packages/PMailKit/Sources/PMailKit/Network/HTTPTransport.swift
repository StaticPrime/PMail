import Foundation

/// Sends web requests. Tests give the web service clients a stub instead of the network.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Real requests through URLSession.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    /// Whether URLSession follows redirects itself. Without, a redirect comes back as the answer, for a client that
    /// follows it its own way: WebDAV's re-sends the same method, body and sign-in, where URLSession leaves the
    /// sign-in behind (and the server then refuses it, as if the password were wrong).
    private let followsRedirects: Bool

    public init(session: URLSession = URLSession(configuration: .ephemeral), followsRedirects: Bool = true) {
        self.session = session
        self.followsRedirects = followsRedirects
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = followsRedirects ? try await session.data(for: request)
                : try await session.data(for: request, delegate: RedirectsReturned.shared)
            guard let http = response as? HTTPURLResponse else { throw PMailError.protocolError("not an HTTP response") }
            return (data, http)
        } catch let error as PMailError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                if nsError.code == NSURLErrorTimedOut { throw PMailError.timedOut }
                if nsError.code == NSURLErrorCancelled { throw PMailError.cancelled }
            }
            if error is CancellationError { throw PMailError.cancelled }
            throw PMailError.connectionFailed(nsError.localizedDescription)
        }
    }
}

/// Turns down every redirect, so the redirect itself is the answer.
private final class RedirectsReturned: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectsReturned()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension URLRequest {
    /// A request with a method, headers and optional body, for the web service clients.
    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.init(url: url)
        httpMethod = method
        for (name, value) in headers { setValue(value, forHTTPHeaderField: name) }
        httpBody = body
    }
}

extension HTTPURLResponse {
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Builds a form-encoded body (`application/x-www-form-urlencoded`), as OAuth token requests use.
public enum FormEncoding {
    public static func encode(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    public static func escape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
