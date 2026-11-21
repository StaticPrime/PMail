import Foundation
import Testing
@testable import PMailKit

/// Hands out OAuth tokens in order (the last one again once they run out) and counts invalidations.
private final class POPTestTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var invalidated = 0

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    var invalidations: Int { lock.withLock { invalidated } }

    func accessToken() async throws -> String {
        lock.withLock { tokens.count > 1 ? tokens.removeFirst() : tokens[0] }
    }

    func invalidateAccessToken() async {
        lock.withLock { invalidated += 1 }
    }
}

@Suite struct POPClientTests {
    private let password = Credential.password(username: "jamie@example.com", password: "secret")

    private func settings(_ security: ConnectionSecurity) -> ServerSettings {
        ServerSettings(mailProtocol: .pop3, host: "pop.example.com", security: security, username: "jamie@example.com")
    }

    @Test func stlsSignInAndEveryCommand() async throws {
        let stream = ScriptedByteStream(greeting: "+OK POP3 server ready <1896.697170952@pop.example.com>\r\n", script: [
            .expect("CAPA", reply: "+OK Capability list follows\r\nTOP\r\nUSER\r\nUIDL\r\nSTLS\r\n.\r\n"),
            .expect("STLS", reply: "+OK Begin TLS negotiation\r\n"),
            .expect("CAPA", reply: "+OK\r\nTOP\r\nUSER\r\nUIDL\r\nSASL PLAIN\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "+OK Logged in\r\n"),
            .expect("STAT", reply: "+OK 2 320\r\n"),
            .expect("UIDL", reply: "+OK\r\n1 whqtswO00WBw418f9t5JxYwZ\r\n2 QhdPYR:00WBw1Ph7x7\r\n.\r\n"),
            .expect("LIST", reply: "+OK 2 messages (320 octets)\r\n1 120\r\n2 200\r\n.\r\n"),
            .expect("TOP 1 0", reply: "+OK\r\nSubject: First\r\n\r\n.\r\n"),
            .expect("RETR 2", reply: "+OK 200 octets\r\nSubject: Dots\r\n\r\n..leading dot\r\n...\r\nplain\r\n.\r\n"),
            .expect("DELE 2", reply: "+OK message 2 deleted\r\n"),
            .expect("QUIT", reply: "+OK Bye\r\n"),
        ])
        let connector = ScriptedConnector([stream])
        let client = POPClient(settings: settings(.startTLS), credential: password, connector: connector)
        try await client.connect()
        let status = try await client.stat()
        #expect(status.count == 2 && status.size == 320)
        #expect(try await client.uidl() == [POPMessageID(number: 1, uid: "whqtswO00WBw418f9t5JxYwZ"),
                                            POPMessageID(number: 2, uid: "QhdPYR:00WBw1Ph7x7")])
        #expect(try await client.list() == [1: 120, 2: 200])
        #expect(try await client.top(1) == Data("Subject: First\r\n\r\n".utf8))
        #expect(try await client.retrieve(2) == Data("Subject: Dots\r\n\r\n.leading dot\r\n..\r\nplain\r\n".utf8))
        try await client.delete(2)
        await client.quit()
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
        #expect(stream.tlsStarted)
        #expect(stream.closed)
        #expect(await client.capabilities["SASL"] == ["PLAIN"])
        #expect(connector.connections.first?.port == 110)
    }

    @Test func wrongPasswordIsAnAuthenticationFailure() async {
        let stream = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nUSER\r\nUIDL\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "-ERR [AUTH] Invalid credentials.\r\n"),
        ])
        let client = POPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.authenticationFailed("Invalid credentials.")) { try await client.connect() }
        #expect(stream.closed)
    }

    @Test func lockedMailboxSaysTryAgainLater() async {
        let stream = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "-ERR unknown command\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "-ERR [IN-USE] Mailbox locked by another client\r\n"),
        ])
        let client = POPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.server("Mailbox locked by another client — try again later")) { try await client.connect() }
        #expect(stream.mismatches.isEmpty)
    }

    @Test func authPlainWhenUserIsNotOffered() async throws {
        let stream = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nSASL PLAIN LOGIN\r\nUIDL\r\n.\r\n"),
            .expect("AUTH PLAIN " + SASL.plain(username: "jamie@example.com", password: "secret"), reply: "+OK Logged in\r\n"),
            .expect("QUIT", reply: "+OK\r\n"),
        ])
        let client = POPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        try await client.connect()
        await client.quit()
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
    }

    @Test func xoauth2RejectionRefreshesTheTokenAndTriesOnceMore() async throws {
        let tokens = POPTestTokens(["stale", "fresh"])
        let first = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nSASL XOAUTH2 PLAIN\r\nUIDL\r\n.\r\n"),
            .expect("AUTH XOAUTH2 " + SASL.xoauth2(username: "jamie@example.com", accessToken: "stale"),
                    reply: "+ eyJzdGF0dXMiOiI0MDAifQ==\r\n"),
            .expect("", reply: "-ERR [AUTH] Invalid credentials\r\n"),
        ])
        let second = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nSASL XOAUTH2 PLAIN\r\nUIDL\r\n.\r\n"),
            .expect("AUTH XOAUTH2 " + SASL.xoauth2(username: "jamie@example.com", accessToken: "fresh"), reply: "+OK Welcome\r\n"),
        ])
        let connector = ScriptedConnector([first, second])
        let client = POPClient(settings: settings(.tls), credential: .oauth(username: "jamie@example.com", tokens: tokens),
                               connector: connector)
        try await client.connect()
        #expect(first.mismatches.isEmpty && second.mismatches.isEmpty)
        #expect(first.isFinished && second.isFinished)
        #expect(first.closed)
        #expect(tokens.invalidations == 1)
        #expect(connector.connections.count == 2)
    }

    @Test func passwordsNeverGoOverAConnectionThatCannotUpgrade() async {
        let stream = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nUSER\r\nUIDL\r\n.\r\n"),
        ])
        let client = POPClient(settings: settings(.startTLS), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.connectionFailed("the server doesn’t offer a secure connection (STLS)")) {
            try await client.connect()
        }
        #expect(!stream.writtenText.contains("USER"))
        #expect(!stream.writtenText.contains("secret"))
    }

    @Test func refusedCommandsKeepTheConnection() async throws {
        let stream = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nUSER\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "+OK\r\n"),
            .expect("RETR 9", reply: "-ERR no such message\r\n"),
            .expect("UIDL", reply: "-ERR command not supported\r\n"),
            .expect("STAT", reply: "+OK 0 0\r\n"),
        ])
        let client = POPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.server("no such message")) { _ = try await client.retrieve(9) }
        await #expect(throws: PMailError.self) { _ = try await client.uidl() }
        let status = try await client.stat()
        #expect(status.count == 0)
        #expect(stream.mismatches.isEmpty)
    }

    @Test func garbledAnswersAreProtocolErrors() async {
        let stream = ScriptedByteStream(greeting: "* OK this is IMAP\r\n", script: [])
        let client = POPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.protocolError("unexpected answer “* OK this is IMAP”")) { try await client.connect() }
    }
}
