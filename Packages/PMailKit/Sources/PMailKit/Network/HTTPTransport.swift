import Foundation

/// Sends web requests. Tests give the web service clients a stub instead of the network.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Real requests through URLSession.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
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
