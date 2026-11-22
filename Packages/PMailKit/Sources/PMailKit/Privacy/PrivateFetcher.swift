import Foundation
import Network

/// A proxy the person set up for remote content (Tor's, or one from their VPN provider), so the senders of their mail
/// see its address instead of theirs.
public struct RemoteContentProxy: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// SOCKS5, as Tor offers. The proxy looks up names itself, so not even those are looked up on the Mac.
        case socks5
        /// An HTTP proxy, asked to connect (CONNECT) for every request.
        case http

        public var name: String {
            switch self {
            case .socks5: "SOCKS5"
            case .http: "HTTP"
            }
        }

        /// Where such a proxy usually listens: Tor's port for SOCKS5.
        public var usualPort: Int { self == .socks5 ? 9050 : 8080 }
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    /// The user name, when the proxy wants one (the password is kept in the keychain).
    public var username: String

    public init(kind: Kind = .socks5, host: String = "127.0.0.1", port: Int = 9050, username: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    /// Whether it says where the proxy is.
    public var isComplete: Bool { !trimmedHost.isEmpty && (1...65_535).contains(port) }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// How PMail asks for remote content: as an anonymous browser that keeps nothing.
public enum PrivateSession {
    /// The browser name every Mac's WebKit gives, so a request doesn't say which app, Mac or version of macOS asked.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    /// The languages every request says it reads, whatever the Mac's own, so they don't tell people apart either.
    public static let acceptLanguage = "en-US,en;q=0.9"

    /// A session that keeps and sends nothing of its own (no cookies, cache or saved passwords) and, given a proxy,
    /// makes every connection through it, failing rather than going around it when the proxy can't be reached. Nil
    /// when the proxy doesn't say where it is.
    public static func configuration(proxy: RemoteContentProxy?, password: String?) -> URLSessionConfiguration? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": acceptLanguage]
        guard let proxy else { return configuration }
        guard proxy.isComplete, let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.trimmedHost), port: port)
        var settings = proxy.kind == .socks5 ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        settings.allowFailover = false
        if !proxy.username.isEmpty { settings.applyCredential(username: proxy.username, password: password ?? "") }
        configuration.proxyConfigurations = [settings]
        return configuration
    }
}

/// Why remote content wasn't loaded.
public enum RemoteContentError: Error, Sendable, Equatable, LocalizedError {
    /// The address is on the Mac or its network, or isn't on the web at all.
    case refusedAddress
    /// It's bigger than PMail loads.
    case tooLarge
    /// Loading is off for now: the proxy is on but isn't filled in, say.
    case notSetUp(String)

    public var errorDescription: String? {
        switch self {
        case .refusedAddress: "PMail doesn’t load content from the Mac itself or its local network."
        case .tooLarge: "It’s too large to load."
        case let .notSetUp(reason): reason
        }
    }
}

/// Which addresses PMail loads remote content from: http and https on the internet, never the Mac itself or its
/// local network, which mail has no business reaching (a picture mustn't be able to poke a router) and which no proxy
/// would carry. Through a proxy, not names that only mean something nearby (`printer`, `nas.local`) either.
public enum RemoteAddressPolicy {
    public static func allows(_ url: URL, throughProxy: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", var host = url.host?.lowercased() else {
            return false
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host.contains(":") { return ipv6(host).map { isPublic(ipv6: $0) } ?? false }
        if let address = ipv4(host) { return isPublic(ipv4: address) }
        if throughProxy, !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".home.arpa") { return false }
        return true
    }

    /// An IPv4 address in any form the system accepts (`127.1`, `0x7f000001` and `2130706433` among them), as bytes.
    static func ipv4(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        return [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    static func ipv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func isPublic(ipv4 bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _): false
        case (100, 64...127): false  // shared by a provider's own network
        case (169, 254): false
        case (172, 16...31): false
        case (192, 168): false
        case (224..., _): false  // multicast and reserved
        default: true
        }
    }

    static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            // :: and ::1, and IPv4 addresses written as IPv6 (::a.b.c.d and ::ffff:a.b.c.d).
            if bytes[10] == 0, bytes[11] == 0, bytes[12..<15].allSatisfy({ $0 == 0 }) { return false }
            if (bytes[10] == 0 && bytes[11] == 0) || (bytes[10] == 0xff && bytes[11] == 0xff) { return isPublic(ipv4: Array(bytes[12..<16])) }
        }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }  // link-local
        if bytes[0] & 0xfe == 0xfc { return false }  // unique local
        if bytes[0] == 0xff { return false }  // multicast
        return true
    }
}

/// Fetches remote content. Sample runs and tests give the loader a stand-in instead of the internet.
public protocol RemoteFetcher: Sendable {
    /// The body and response for a request, giving up once the body passes `limit` bytes.
    func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

/// The internet, through a private session (see `PrivateSession`): directly, or only through a proxy.
public final class PrivateFetcher: RemoteFetcher {
    private let session: URLSession
    private let throughProxy: Bool

    /// Nil when the proxy doesn't say where it is.
    public init?(proxy: RemoteContentProxy?, password: String?) {
        guard let configuration = PrivateSession.configuration(proxy: proxy, password: password) else { return nil }
        session = URLSession(configuration: configuration)
        throughProxy = proxy != nil
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard(throughProxy: throughProxy))
            guard let http = response as? HTTPURLResponse else { throw PMailError.protocolError("not an HTTP response") }
            if http.expectedContentLength > Int64(limit) {
                bytes.task.cancel()
                throw RemoteContentError.tooLarge
            }
            var body: [UInt8] = []
            body.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(limit))))
            for try await byte in bytes {
                body.append(byte)
                if body.count > limit {
                    bytes.task.cancel()
                    throw RemoteContentError.tooLarge
                }
            }
            return (Data(body), http)
        } catch let error as RemoteContentError {
            throw error
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

/// Follows a few redirects, and none to an address PMail wouldn't load from in the first place.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let throughProxy: Bool
    private let lock = NSLock()
    private var count = 0

    init(throughProxy: Bool) {
        self.throughProxy = throughProxy
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let count = lock.withLock { self.count += 1; return self.count }
        guard count <= 5, let url = request.url, RemoteAddressPolicy.allows(url, throughProxy: throughProxy) else { return nil }
        return request
    }
}

/// Loads nothing, saying why: while the proxy is on but not filled in, say.
public struct RefusingFetcher: RemoteFetcher {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        throw RemoteContentError.notSetUp(reason)
    }
}
