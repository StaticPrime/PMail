import Foundation
import Testing
@testable import PMailKit

/// A pretend proxy connection: gives back its answers in turn, and keeps what PMail sent.
private final class ProxyStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Data]
    private(set) var sent: [Data] = []
    private let failure: PMailError?

    init(answers: [[UInt8]] = [], failure: PMailError? = nil) {
        self.answers = answers.map { Data($0) }
        self.failure = failure
    }

    func read() async throws -> Data {
        if let failure { throw failure }
        return lock.withLock { answers.isEmpty ? Data() : answers.removeFirst() }
    }

    func write(_ data: Data) async throws {
        if let failure { throw failure }
        lock.withLock { sent.append(data) }
    }

    func startTLS() async throws {}
    func close() {}
}

private struct ProxyConnector: ByteStreamConnector {
    let stream: ProxyStream

    func connect(host: String, port: Int, security: ConnectionSecurity) async throws -> any ByteStream { stream }
}

struct ProxyCheckTests {
    private let tor = RemoteContentProxy()

    @Test func socksGreetingsAndPasswords() {
        #expect(ProxyCheck.socksGreeting(offeringPassword: false) == Data([5, 1, 0]))
        #expect(ProxyCheck.socksGreeting(offeringPassword: true) == Data([5, 2, 0, 2]))
        #expect(ProxyCheck.socksPasswordRequest(username: "me", password: "pw") == Data([1, 2, 0x6D, 0x65, 2, 0x70, 0x77]))
        #expect(ProxyCheck.socksPasswordRequest(username: "", password: "pw") == nil)
        #expect(ProxyCheck.socksPasswordRequest(username: String(repeating: "x", count: 256), password: "") == nil)
    }

    @Test func aSocksProxyThatAnswers() async throws {
        let stream = ProxyStream(answers: [[5, 0]])
        try await ProxyCheck.check(tor, password: nil, connector: ProxyConnector(stream: stream))
        #expect(stream.sent == [Data([5, 1, 0])], "a greeting and nothing more: nothing is asked for on the internet")

        let signedIn = ProxyStream(answers: [[5, 2], [1, 0]])
        try await ProxyCheck.check(RemoteContentProxy(username: "me"), password: "pw", connector: ProxyConnector(stream: signedIn))
        #expect(signedIn.sent == [Data([5, 2, 0, 2]), Data([1, 2, 0x6D, 0x65, 2, 0x70, 0x77])])
    }

    @Test func socksTroubleIsExplained() async {
        await #expect(throws: PMailError.server("The proxy didn’t accept the user name and password.")) {
            try await ProxyCheck.check(RemoteContentProxy(username: "me"), password: "wrong", connector: ProxyConnector(stream: ProxyStream(answers: [[5, 2], [1, 1]])))
        }
        await #expect(throws: PMailError.server("The proxy wants a user name and password.")) {
            try await ProxyCheck.check(tor, password: nil, connector: ProxyConnector(stream: ProxyStream(answers: [[5, 0xFF]])))
        }
        await #expect(throws: PMailError.server("That isn’t a SOCKS5 proxy. Is it an HTTP proxy?")) {
            try await ProxyCheck.check(tor, password: nil, connector: ProxyConnector(stream: ProxyStream(answers: [Array("HTTP/1.1 400".utf8)])))
        }
        await #expect(throws: PMailError.server("Nothing answered at 127.0.0.1:9050. Is the proxy running?")) {
            try await ProxyCheck.check(tor, password: nil, connector: ProxyConnector(stream: ProxyStream(failure: .connectionFailed("refused"))))
        }
        await #expect(throws: PMailError.server("Fill in the proxy’s server and port.")) {
            try await ProxyCheck.check(RemoteContentProxy(host: ""), password: nil, connector: ProxyConnector(stream: ProxyStream()))
        }
    }

    @Test func httpProxies() async throws {
        let request = String(decoding: ProxyCheck.httpCheckRequest(username: "me", password: "pw"), as: UTF8.self)
        #expect(request.hasPrefix("CONNECT pmail-check.invalid:443 HTTP/1.1\r\n"), "an address that can't exist")
        #expect(request.contains("Proxy-Authorization: Basic bWU6cHc=\r\n") && request.hasSuffix("\r\n\r\n"))
        #expect(!String(decoding: ProxyCheck.httpCheckRequest(username: "", password: ""), as: UTF8.self).contains("Proxy-Authorization"))

        let proxy = RemoteContentProxy(kind: .http, host: "proxy.example", port: 8080)
        let stream = ProxyStream(answers: [Array("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8)])
        try await ProxyCheck.check(proxy, password: nil, connector: ProxyConnector(stream: stream))
        #expect(stream.sent.count == 1)
        await #expect(throws: PMailError.server("The proxy wants a user name and password.")) {
            try await ProxyCheck.check(proxy, password: nil, connector: ProxyConnector(stream: ProxyStream(answers: [Array("HTTP/1.1 407 Proxy Authentication Required\r\n".utf8)])))
        }
        await #expect(throws: PMailError.server("That isn’t an HTTP proxy. Is it a SOCKS5 proxy?")) {
            try await ProxyCheck.check(proxy, password: nil, connector: ProxyConnector(stream: ProxyStream(answers: [[5, 0]])))
        }
    }
}
