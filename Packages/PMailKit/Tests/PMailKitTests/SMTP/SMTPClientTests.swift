import Foundation
import Testing
@testable import PMailKit

/// Hands out OAuth tokens in order (the last one again once they run out) and counts invalidations.
private final class SMTPTestTokens: AccessTokenProvider, @unchecked Sendable {
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

@Suite struct SMTPClientTests {
    private let raw = Data("From: jamie@example.com\r\nTo: sam@example.com\r\nSubject: Hi\r\n\r\nHello Sam\r\n".utf8)
    private let password = Credential.password(username: "jamie@example.com", password: "secret")

    private func settings(_ security: ConnectionSecurity, port: Int? = nil) -> ServerSettings {
        ServerSettings(mailProtocol: .smtp, host: "smtp.example.com", port: port, security: security, username: "jamie@example.com")
    }

    /// Steps for the part of a session after sign-in: one message to the given recipients, then QUIT.
    private func deliverySteps(mailFrom: String, recipients: [String], data: Data) -> [ScriptedByteStream.Step] {
        [.expect(mailFrom, reply: "250 2.1.0 OK\r\n")]
            + recipients.map { .expect("RCPT TO:<\($0)>", reply: "250 2.1.5 OK\r\n") }
            + [.expect("DATA", reply: "354 Go ahead\r\n"),
               .expectBytes(SMTPClient.dataBlock(data).count, reply: "250 2.0.0 Queued as 12345\r\n"),
               .expect("QUIT", reply: "221 2.0.0 Bye\r\n")]
    }

    @Test func startTLSThenPlain() async throws {
        let stream = ScriptedByteStream(greeting: "220 smtp.example.com ESMTP ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250-STARTTLS\r\n250 8BITMIME\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250-AUTH PLAIN LOGIN\r\n250-SIZE 1000000\r\n250 8BITMIME\r\n"),
            .expect("AUTH PLAIN " + SASL.plain(username: "jamie@example.com", password: "secret"), reply: "235 2.7.0 Accepted\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jamie@example.com> SIZE=\(raw.count)", recipients: ["sam@example.com", "zoe@example.com"],
                          data: raw))
        let connector = ScriptedConnector([stream])
        let sender = SMTPSender(settings: settings(.startTLS), credential: password, connector: connector)
        // The same address twice (in any case) is sent to once.
        try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com", "zoe@example.com", "SAM@example.com"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
        #expect(stream.tlsStarted)
        #expect(connector.connections.count == 1)
        #expect(connector.connections.first?.port == 587)
        #expect(connector.connections.first?.security == .startTLS)
    }

    @Test func loginWhenPlainIsNotOffered() async throws {
        let login = SASL.login(username: "jamie@example.com", password: "secret")
        let stream = ScriptedByteStream(greeting: "220-mail.example.net ESMTP\r\n220 Welcome\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-mail.example.net Hello\r\n250-AUTH=LOGIN\r\n250 AUTH LOGIN\r\n"),
            .expect("AUTH LOGIN", reply: "334 VXNlcm5hbWU6\r\n"),
            .expect(login.username, reply: "334 UGFzc3dvcmQ6\r\n"),
            .expect(login.password, reply: "235 Authentication successful\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jamie@example.com>", recipients: ["sam@example.com"], data: raw))
        let client = SMTPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        try await client.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
        #expect(!stream.tlsStarted)  // .tls is encrypted by the connector from the start
        let transcript = await client.lastTranscript
        #expect(transcript.contains("C: <password>"))
        #expect(!transcript.joined().contains(login.password))
    }

    @Test func xoauth2Succeeds() async throws {
        let tokens = SMTPTestTokens(["token-1"])
        let stream = ScriptedByteStream(greeting: "220 smtp.example.com ESMTP\r\n", script: [
            .expect("EHLO [127.0.0.1]",
                    reply: "250-smtp.example.com at your service\r\n250-AUTH LOGIN PLAIN XOAUTH2 OAUTHBEARER\r\n250 SMTPUTF8\r\n"),
            .expect("AUTH XOAUTH2 " + SASL.xoauth2(username: "jamie@example.com", accessToken: "token-1"), reply: "235 2.7.0 Accepted\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jamie@example.com>", recipients: ["sam@example.com"], data: raw))
        let sender = SMTPSender(settings: settings(.tls), credential: .oauth(username: "jamie@example.com", tokens: tokens),
                                connector: ScriptedConnector([stream]))
        try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
        #expect(tokens.invalidations == 0)
    }

    @Test func xoauth2RejectionRefreshesTheTokenAndTriesOnceMore() async throws {
        let tokens = SMTPTestTokens(["stale", "fresh"])
        let hello = ScriptedByteStream.Step.expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH XOAUTH2\r\n")
        let first = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            hello,
            .expect("AUTH XOAUTH2 " + SASL.xoauth2(username: "jamie@example.com", accessToken: "stale"),
                    reply: "334 eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiYmVhcmVyIn0=\r\n"),
            .expect("", reply: "535-5.7.8 Username and Password not accepted.\r\n535 5.7.8 Learn more at the help center\r\n"),
        ])
        let second = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            hello,
            .expect("AUTH XOAUTH2 " + SASL.xoauth2(username: "jamie@example.com", accessToken: "fresh"), reply: "235 2.7.0 Accepted\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jamie@example.com>", recipients: ["sam@example.com"], data: raw))
        let connector = ScriptedConnector([first, second])
        let sender = SMTPSender(settings: settings(.tls), credential: .oauth(username: "jamie@example.com", tokens: tokens),
                                connector: connector)
        try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        #expect(first.mismatches.isEmpty && second.mismatches.isEmpty)
        #expect(first.isFinished && second.isFinished)
        #expect(first.closed)
        #expect(tokens.invalidations == 1)
        #expect(connector.connections.count == 2)
    }

    @Test func xoauth2RejectedTwiceIsAnAuthenticationFailure() async {
        let tokens = SMTPTestTokens(["bad"])
        func attempt() -> ScriptedByteStream {
            ScriptedByteStream(greeting: "220 ready\r\n", script: [
                .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH XOAUTH2\r\n"),
                .expectPrefix("AUTH XOAUTH2 ", reply: "535 5.7.3 Authentication unsuccessful\r\n"),
            ])
        }
        let connector = ScriptedConnector([attempt(), attempt(), attempt()])
        let client = SMTPClient(settings: settings(.tls), credential: .oauth(username: "jamie@example.com", tokens: tokens),
                                connector: connector)
        await #expect(throws: PMailError.authenticationFailed("Authentication unsuccessful")) {
            try await client.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        #expect(tokens.invalidations == 1)
        #expect(connector.connections.count == 2)
    }

    @Test func dotStuffingAndLineEnds() async throws {
        let message = Data("Subject: Dots\n\n.leading dot\r\n..two dots\nmiddle . dot\r\n.\rlast".utf8)
        #expect(String(decoding: SMTPClient.dataBlock(message), as: UTF8.self)
            == "Subject: Dots\r\n\r\n..leading dot\r\n...two dots\r\nmiddle . dot\r\n..\r\nlast\r\n.\r\n")
        #expect(SMTPClient.dataBlock(Data("ends\r\n".utf8)) == Data("ends\r\n.\r\n".utf8))
        #expect(SMTPClient.dataBlock(Data()) == Data(".\r\n".utf8))

        // On the wire, line by line.
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN\r\n"),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
            .expect("MAIL FROM:<jamie@example.com>", reply: "250 OK\r\n"),
            .expect("RCPT TO:<sam@example.com>", reply: "250 OK\r\n"),
            .expect("DATA", reply: "354 End data with <CR><LF>.<CR><LF>\r\n"),
            .expect("Subject: Dots", reply: ""),
            .expect("", reply: ""),
            .expect("..leading dot", reply: ""),
            .expect("...two dots", reply: ""),
            .expect("middle . dot", reply: ""),
            .expect("..", reply: ""),
            .expect("last", reply: ""),
            .expect(".", reply: "250 OK\r\n"),
            .expect("QUIT", reply: "221 Bye\r\n"),
        ])
        try await SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
            .send(message, from: "jamie@example.com", to: ["sam@example.com"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
    }

    @Test func multiLineEHLOSetsTheMailFromParameters() async throws {
        let eightBit = Data("Subject: Grüße\r\n\r\nKöln\r\n".utf8)
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: """
                250-smtp.example.com greets [127.0.0.1]\r
                250-PIPELINING\r
                250-SIZE 35882577\r
                250-8BITMIME\r
                250-ENHANCEDSTATUSCODES\r
                250-SMTPUTF8\r
                250 AUTH PLAIN LOGIN\r

                """),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jürgen@example.de> SIZE=\(eightBit.count) BODY=8BITMIME SMTPUTF8",
                          recipients: ["zoë@example.de"], data: eightBit))
        try await SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
            .send(eightBit, from: "jürgen@example.de", to: ["zoë@example.de"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
    }

    @Test func refusedRecipientFailsTheSendAndNamesIt() async {
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN\r\n"),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
            .expect("MAIL FROM:<jamie@example.com>", reply: "250 OK\r\n"),
            .expect("RCPT TO:<sam@example.com>", reply: "250 OK\r\n"),
            .expect("RCPT TO:<nobody@example.com>", reply: "550 5.1.1 <nobody@example.com>: Recipient address rejected: User unknown\r\n"),
        ])
        let sender = SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        let refusal = "The server refused nobody@example.com: <nobody@example.com>: Recipient address rejected: User unknown"
        await #expect(throws: PMailError.server(refusal)) {
            try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com", "nobody@example.com"])
        }
        #expect(stream.mismatches.isEmpty)
        #expect(!stream.lines.contains("DATA"))
        #expect(stream.closed)
    }

    @Test func busyRecipientSaysTryAgainLater() async {
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN\r\n"),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
            .expect("MAIL FROM:<jamie@example.com>", reply: "250 OK\r\n"),
            .expect("RCPT TO:<sam@example.com>", reply: "451 4.7.1 Greylisted, please retry\r\n"),
        ])
        let sender = SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        let delay = "The server couldn’t take mail for sam@example.com right now (Greylisted, please retry) — try again later"
        await #expect(throws: PMailError.server(delay)) {
            try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
    }

    @Test func passwordsNeverGoOverAConnectionThatFailedToUpgrade() async {
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN LOGIN\r\n"),
        ])
        let sender = SMTPSender(settings: settings(.startTLS), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.connectionFailed("the server doesn’t offer a secure connection (STARTTLS)")) {
            try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        #expect(!stream.writtenText.contains("AUTH"))
        #expect(!stream.tlsStarted)
    }

    @Test func serverErrorsMapToPMailErrors() async {
        func failing(_ steps: [ScriptedByteStream.Step], greeting: String = "220 ready\r\n") -> SMTPSender {
            SMTPSender(settings: settings(.tls), credential: password,
                       connector: ScriptedConnector([ScriptedByteStream(greeting: greeting, script: steps)]))
        }
        let hello = ScriptedByteStream.Step.expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN\r\n")
        await #expect(throws: PMailError.authenticationFailed("Username and Password not accepted")) {
            try await failing([hello, .expectPrefix("AUTH PLAIN ", reply: "535 5.7.8 Username and Password not accepted.\r\n")])
                .send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        await #expect(throws: PMailError.server("Too many connections — try again later")) {
            try await failing([hello, .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
                               .expect("MAIL FROM:<jamie@example.com>", reply: "421 4.7.0 Too many connections\r\n")])
                .send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        await #expect(throws: PMailError.server("Message rejected as spam")) {
            try await failing([hello, .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
                               .expect("MAIL FROM:<jamie@example.com>", reply: "250 OK\r\n"),
                               .expect("RCPT TO:<sam@example.com>", reply: "250 OK\r\n"),
                               .expect("DATA", reply: "354 Go\r\n"),
                               .expectBytes(SMTPClient.dataBlock(raw).count, reply: "554 5.7.1 Message rejected as spam\r\n")])
                .send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        await #expect(throws: PMailError.server("No service here")) {
            try await failing([], greeting: "554 No service here\r\n").send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        await #expect(throws: PMailError.protocolError("unexpected reply “HTTP/1.1 400 Bad Request”")) {
            try await failing([], greeting: "HTTP/1.1 400 Bad Request\r\n").send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        await #expect(throws: PMailError.connectionFailed("no more scripted connections")) {
            try await SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([]))
                .send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
    }

    @Test func messagesOverTheSizeLimitAreNotSent() async {
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250-SIZE 10\r\n250 AUTH PLAIN\r\n"),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
        ])
        let sender = SMTPSender(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.self) {
            try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        }
        #expect(!stream.lines.contains { $0.hasPrefix("MAIL FROM") })
    }

    @Test func unsafeAddressesAreRefusedBeforeConnecting() async {
        let connector = ScriptedConnector([])
        let sender = SMTPSender(settings: settings(.tls), credential: password, connector: connector)
        await #expect(throws: PMailError.server("“sam@example.com>\r\nRCPT TO:<evil@example.com” isn’t a valid email address.")) {
            try await sender.send(raw, from: "jamie@example.com", to: ["sam@example.com>\r\nRCPT TO:<evil@example.com"])
        }
        await #expect(throws: PMailError.server("The message has no recipients.")) {
            try await sender.send(raw, from: "jamie@example.com", to: [])
        }
        #expect(connector.connections.isEmpty)
    }

    @Test func oldServersGetHELOAndPlainConnectionsSkipSignInWhenNotOffered() async throws {
        let stream = ScriptedByteStream(greeting: "220 relay.local\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "502 Command not implemented\r\n"),
            .expect("HELO [127.0.0.1]", reply: "250 relay.local\r\n"),
        ] + deliverySteps(mailFrom: "MAIL FROM:<jamie@example.com>", recipients: ["sam@example.com"], data: raw))
        let connector = ScriptedConnector([stream])
        try await SMTPSender(settings: settings(.none), credential: password, connector: connector)
            .send(raw, from: "jamie@example.com", to: ["sam@example.com"])
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
        #expect(connector.connections.first?.port == 25)
    }

    @Test func checkSignInConnectsAndQuits() async throws {
        let stream = ScriptedByteStream(greeting: "220 ready\r\n", script: [
            .expect("EHLO [127.0.0.1]", reply: "250-smtp.example.com\r\n250 AUTH PLAIN\r\n"),
            .expectPrefix("AUTH PLAIN ", reply: "235 OK\r\n"),
            .expect("QUIT", reply: "221 Bye\r\n"),
        ])
        try await SMTPClient(settings: settings(.tls), credential: password, connector: ScriptedConnector([stream])).checkSignIn()
        #expect(stream.mismatches.isEmpty)
        #expect(stream.isFinished)
    }
}
