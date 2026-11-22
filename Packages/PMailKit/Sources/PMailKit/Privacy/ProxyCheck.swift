import Foundation

/// Checks that a proxy is there and takes PMail's requests, without asking it for anything on the internet. A SOCKS5
/// proxy is greeted, and given the user name and password when there is one. An HTTP proxy is asked to connect to
/// `pmail-check.invalid`, an address that can't exist, which any HTTP proxy answers with an error of its own.
public enum ProxyCheck {
    public static func check(_ proxy: RemoteContentProxy, password: String?,
                             connector: any ByteStreamConnector = URLSessionConnector(timeout: 10)) async throws {
        guard proxy.isComplete else { throw PMailError.server("Fill in the proxy’s server and port.") }
        let place = "\(proxy.trimmedHost):\(proxy.port)"
        do {
            let stream = try await connector.connect(host: proxy.trimmedHost, port: proxy.port, security: .none)
            defer { stream.close() }
            switch proxy.kind {
            case .socks5: try await greetSOCKS(stream, username: proxy.username, password: password ?? "")
            case .http: try await askHTTP(stream, username: proxy.username, password: password ?? "")
            }
        } catch PMailError.connectionFailed {
            throw PMailError.server("Nothing answered at \(place). Is the proxy running?")
        } catch PMailError.timedOut {
            throw PMailError.server("The proxy at \(place) didn’t answer.")
        }
    }

    // MARK: SOCKS5 (RFC 1928, with RFC 1929's user name and password)

    /// The greeting: SOCKS version 5 and the ways of signing in offered, none or a user name and password.
    static func socksGreeting(offeringPassword: Bool) -> Data {
        offeringPassword ? Data([5, 2, 0, 2]) : Data([5, 1, 0])
    }

    /// The user name and password, as the proxy asks for them; nil if either is too long to send.
    static func socksPasswordRequest(username: String, password: String) -> Data? {
        let user = Array(username.utf8), secret = Array(password.utf8)
        guard (1...255).contains(user.count), secret.count <= 255 else { return nil }
        return Data([1, UInt8(user.count)] + user + [UInt8(secret.count)] + secret)
    }

    private static func greetSOCKS(_ stream: any ByteStream, username: String, password: String) async throws {
        let offersPassword = !username.isEmpty
        try await stream.write(socksGreeting(offeringPassword: offersPassword))
        let choice = try await read(2, from: stream)
        guard choice[0] == 5 else { throw PMailError.server("That isn’t a SOCKS5 proxy. Is it an HTTP proxy?") }
        switch choice[1] {
        case 0:
            return
        case 2 where offersPassword:
            guard let request = socksPasswordRequest(username: username, password: password) else {
                throw PMailError.server("The user name or password is too long for a SOCKS5 proxy.")
            }
            try await stream.write(request)
            let reply = try await read(2, from: stream)
            guard reply[1] == 0 else { throw PMailError.server("The proxy didn’t accept the user name and password.") }
        case 0xFF where !offersPassword:
            throw PMailError.server("The proxy wants a user name and password.")
        default:
            throw PMailError.server("The proxy wants a way of signing in that PMail doesn’t offer.")
        }
    }

    // MARK: HTTP

    /// A CONNECT to an address that can't exist, with the user name and password when there is one.
    static func httpCheckRequest(username: String, password: String) -> Data {
        var request = "CONNECT pmail-check.invalid:443 HTTP/1.1\r\nHost: pmail-check.invalid:443\r\n"
        if !username.isEmpty { request += "Proxy-Authorization: Basic " + Data("\(username):\(password)".utf8).base64EncodedString() + "\r\n" }
        return Data((request + "\r\n").utf8)
    }

    /// What an HTTP proxy's first line of answer says: any status is a proxy answering, except 407, which asks for (or
    /// turns down) a user name and password.
    static func checkHTTPAnswer(_ statusLine: String, offeredPassword: Bool) throws {
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw PMailError.server("That isn’t an HTTP proxy. Is it a SOCKS5 proxy?")
        }
        if status == 407 {
            throw PMailError.server(offeredPassword ? "The proxy didn’t accept the user name and password." : "The proxy wants a user name and password.")
        }
    }

    private static func askHTTP(_ stream: any ByteStream, username: String, password: String) async throws {
        try await stream.write(httpCheckRequest(username: username, password: password))
        var answer = Data()
        while !answer.contains(UInt8(ascii: "\n")), answer.count < 4096 {
            let more = try await stream.read()
            guard !more.isEmpty else { break }
            answer += more
        }
        let firstLine = String(decoding: answer, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        try checkHTTPAnswer(firstLine, offeredPassword: !username.isEmpty)
    }

    private static func read(_ count: Int, from stream: any ByteStream) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < count {
            let more = try await stream.read()
            guard !more.isEmpty else { throw PMailError.server("The proxy closed the connection without answering.") }
            bytes += more
        }
        return bytes
    }
}
