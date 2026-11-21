import Foundation
import Testing
@testable import PMailKit

@Suite(.timeLimit(.minutes(1))) struct IMAPClientTests {
    private func connectedClient(_ stream: ScriptedByteStream, security: ConnectionSecurity = .tls) async throws -> IMAPClient {
        let client = IMAPClient(connector: ScriptedConnector([stream]))
        try await client.connect(host: "imap.example.com", port: security == .tls ? 993 : 143, security: security)
        return client
    }

    @Test func startTLSComesBeforeThePassword() async throws {
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] Ready\r\n", script: [
            .expect("A1 STARTTLS", reply: "A1 OK [CAPABILITY IMAP4rev1 AUTH=EVIL] Begin TLS negotiation now\r\n"),
            .expect("A2 CAPABILITY", reply: "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\nA2 OK Done\r\n"),
            .expect("A3 AUTHENTICATE PLAIN", reply: "+ \r\n"),
            .expect(SASL.plain(username: "pug", password: "secret"), reply: "A3 OK Signed in\r\n"),
            .expect("A4 CAPABILITY", reply: "* CAPABILITY IMAP4rev1 AUTH=PLAIN MOVE IDLE\r\nA4 OK Done\r\n"),
        ])
        let client = try await connectedClient(stream, security: .startTLS)
        #expect(stream.tlsStarted)
        #expect(stream.lines == ["A1 STARTTLS", "A2 CAPABILITY"])
        let capabilities = await client.capabilities
        #expect(capabilities.contains("AUTH=PLAIN") && !capabilities.contains("AUTH=EVIL"))
        try await client.signIn(.password(username: "pug", password: "secret"))
        #expect(await client.isAuthenticated)
        #expect(await client.hasCapability("move"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func noPasswordWithoutEncryption() async throws {
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Ready\r\n", script: [])
        let client = IMAPClient(connector: ScriptedConnector([stream]))
        await #expect(throws: PMailError.self) {
            try await client.connect(host: "imap.example.com", port: 143, security: .startTLS)
        }
        #expect(stream.lines.isEmpty && !stream.tlsStarted)
        #expect(!(await client.isConnected))
    }

    @Test func plainConnectionsAreAllowedOnlyWhenChosen() async throws {
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1] Ready\r\n", script: [
            .expect(#"A1 LOGIN "pug" "secret""#, reply: "A1 OK [CAPABILITY IMAP4rev1] Hi\r\n"),
        ])
        let client = try await connectedClient(stream, security: .none)
        try await client.signIn(.password(username: "pug", password: "secret"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func xoauth2RetriesOnceWithAFreshToken() async throws {
        let tokens = IMAPFakeTokens(["old-token", "new-token"])
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=XOAUTH2] Ready\r\n", script: [
            .expect("A1 AUTHENTICATE XOAUTH2 \(SASL.xoauth2(username: "pug@example.com", accessToken: "old-token"))",
                    reply: "+ eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiQmVhcmVyIn0=\r\n"),
            .expect("", reply: "A1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"),
            .expect("A2 AUTHENTICATE XOAUTH2 \(SASL.xoauth2(username: "pug@example.com", accessToken: "new-token"))",
                    reply: "A2 OK [CAPABILITY IMAP4rev1 MOVE] Thanks\r\n"),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.oauth(username: "pug@example.com", tokens: tokens))
        #expect(tokens.invalidations == 1)
        #expect(await client.isAuthenticated)
        #expect(await client.hasCapability("MOVE"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func xoauth2WithoutInitialResponseAndGivingUp() async throws {
        let tokens = IMAPFakeTokens(["first", "second"])
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2] Ready\r\n", script: [
            .expect("A1 AUTHENTICATE XOAUTH2", reply: "+ \r\n"),
            .expect(SASL.xoauth2(username: "pug@example.com", accessToken: "first"), reply: "+ eyJzdGF0dXMiOiI0MDEifQ==\r\n"),
            .expect("", reply: "A1 NO Invalid credentials\r\n"),
            .expect("A2 AUTHENTICATE XOAUTH2", reply: "+ \r\n"),
            .expect(SASL.xoauth2(username: "pug@example.com", accessToken: "second"), reply: "A2 NO Still invalid\r\n"),
        ])
        let client = try await connectedClient(stream)
        await #expect(throws: PMailError.authenticationFailed("Still invalid")) {
            try await client.signIn(.oauth(username: "pug@example.com", tokens: tokens))
        }
        #expect(tokens.invalidations == 1)
        #expect(!(await client.isAuthenticated))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func loginQuotesArgumentsAndUsesLiteralsForNonASCII() async throws {
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1] Ready\r\n", script: [
            .expect(#"A1 LOGIN "pug@example.com" "pa\"ss\\word""#, reply: "A1 NO [AUTHENTICATIONFAILED] Nope\r\n"),
            .expect(#"A2 LOGIN "pug" {10}"#, reply: "+ Ready for literal data\r\n"),
            .expect("pässwörd", reply: "A2 OK [CAPABILITY IMAP4rev1 IDLE] Welcome\r\n"),
        ])
        let client = try await connectedClient(stream)
        await #expect(throws: PMailError.authenticationFailed("Nope")) {
            try await client.signIn(.password(username: "pug@example.com", password: #"pa"ss\word"#))
        }
        try await client.signIn(.password(username: "pug", password: "pässwörd"))
        #expect(await client.hasCapability("IDLE"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func loginDisabledWithoutPlainIsRefused() async throws {
        let stream = ScriptedByteStream(greeting: "* OK [CAPABILITY IMAP4rev1 LOGINDISABLED AUTH=GSSAPI] Ready\r\n", script: [])
        let client = try await connectedClient(stream)
        await #expect(throws: PMailError.self) { try await client.signIn(.password(username: "pug", password: "secret")) }
        #expect(stream.lines.isEmpty)
    }

    @Test func greetingsThatSignInOrSayGoodbye() async throws {
        let welcome = ScriptedByteStream(greeting: "* PREAUTH [CAPABILITY IMAP4rev1] Welcome back\r\n", script: [])
        let client = try await connectedClient(welcome)
        try await client.signIn(.password(username: "pug", password: "secret"))
        #expect(await client.isAuthenticated)
        #expect(welcome.lines.isEmpty)

        let busy = ScriptedByteStream(greeting: "* BYE Too many connections\r\n", script: [])
        let refused = IMAPClient(connector: ScriptedConnector([busy]))
        await #expect(throws: PMailError.connectionFailed("Too many connections")) {
            try await refused.connect(host: "imap.example.com", port: 993, security: .tls)
        }
        #expect(!(await refused.isConnected))

        let capabilityLater = ScriptedByteStream(greeting: "* OK Ready\r\n", script: [
            .expect("A1 CAPABILITY", reply: "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR\r\nA1 OK Done\r\n"),
        ])
        let asked = try await connectedClient(capabilityLater)
        #expect(await asked.hasCapability("SASL-IR"))
    }

    @Test func unsolicitedResponsesNeverDerailACommand() async throws {
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(), script: [
            IMAPScript.signIn("A1"),
            IMAPScript.select("A2"),
            .expect("A3 UID FETCH 12 (UID FLAGS)", reply: IMAPScript.lines(
                "* 5 EXISTS",
                #"* 4 FETCH (FLAGS (\Seen))"#,
                #"* 3 FETCH (UID 12 FLAGS (\Flagged))"#,
                "* 2 FETCH (UID 99 FLAGS ())",
                "* OK [ALERT] Your mailbox is almost full",
                "* 4 EXPUNGE",
                "* 3 FETCH (UID 12 RFC822.SIZE 2048)",
                "A3 OK Fetch completed")),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        let selected = try await client.select("INBOX")
        #expect(selected.exists == 3 && selected.uidValidity == 7 && selected.uidNext == 100 && !selected.isReadOnly)
        let fetched = try await client.uidFetch([12], items: "UID FLAGS")
        #expect(fetched.count == 1)
        #expect(fetched.first?.flags == ["\\Flagged"] && fetched.first?.size == 2048)
        #expect(await client.selectedMailbox?.exists == 4)
        #expect(await client.alerts == ["Your mailbox is almost full"])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func listStatusSelectAndExamine() async throws {
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(), script: [
            IMAPScript.signIn("A1"),
            .expect(#"A2 LIST "" "*" RETURN (SPECIAL-USE)"#, reply: "A2 BAD Unknown argument RETURN\r\n"),
            .expect(#"A3 LIST "" "*""#, reply: IMAPScript.lines(
                #"* LIST (\HasChildren) "/" "INBOX""#,
                #"* LIST (\HasNoChildren \Sent) "/" "Sent""#,
                #"* LIST (\HasNoChildren) "/" "Projects/Caf&AOk-""#,
                #"* LIST (\HasChildren) "/" "INBOX""#,
                "A3 OK Done")),
            .expect(#"A4 STATUS "Projects/Caf&AOk-" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#, reply: IMAPScript.lines(
                #"* STATUS "Projects/Caf&AOk-" (MESSAGES 231 UNSEEN 4 UIDNEXT 44292 UIDVALIDITY 1)"#, "A4 OK Done")),
            .expect(#"A5 SELECT "INBOX""#, reply: IMAPScript.lines(
                #"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)"#,
                #"* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited"#,
                "* 172 EXISTS",
                "* 1 RECENT",
                "* OK [UNSEEN 12] Message 12 is first unseen",
                "* OK [UIDVALIDITY 3857529045] UIDs valid",
                "* OK [UIDNEXT 4392] Predicted next UID",
                "A5 OK [READ-WRITE] SELECT completed")),
            .expect(#"A6 EXAMINE "Projects/Caf&AOk-""#, reply: IMAPScript.lines("* 231 EXISTS", "* OK [UIDVALIDITY 1] Ok",
                                                                               "A6 OK [READ-ONLY] Done")),
            .expect(#"A7 SELECT "Nowhere""#, reply: "A7 NO Mailbox doesn't exist\r\n"),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        let mailboxes = try await client.listMailboxes()
        #expect(mailboxes.map(\.name) == ["INBOX", "Sent", "Projects/Café"])
        let status = try await client.status("Projects/Café")
        #expect(status == IMAPMailboxStatus(mailbox: "Projects/Café", messages: 231, unseen: 4, uidNext: 44292, uidValidity: 1))
        let inbox = try await client.select("INBOX")
        #expect(inbox.exists == 172 && inbox.recent == 1 && inbox.uidValidity == 3_857_529_045 && inbox.uidNext == 4392)
        #expect(inbox.flags.count == 5 && inbox.permanentFlags == ["\\Deleted", "\\Seen", "\\*"])
        let cafe = try await client.select("Projects/Café", readOnly: true)
        #expect(cafe.isReadOnly && cafe.exists == 231)
        await #expect(throws: PMailError.server("Mailbox doesn't exist")) { try await client.select("Nowhere") }
        #expect(await client.selectedMailbox == nil)
        #expect(await client.isConnected)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func appendWaitsForTheGoAheadWithoutLiteralPlus() async throws {
        let message = "Subject: Hi\r\n\r\nHello there\r\n"
        let capabilities = "IMAP4rev1 AUTH=PLAIN SASL-IR UIDPLUS"
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(capabilities), script: [
            IMAPScript.signIn("A1", capabilities: capabilities),
            .expect(#"A2 APPEND "Sent Messages" (\Seen) {\#(message.utf8.count)}"#, reply: "+ Ready for literal data\r\n"),
            .expectBytes(message.utf8.count, reply: ""),
            .expect("", reply: "A2 OK [APPENDUID 38505 3955] APPEND completed\r\n"),
            .expect(#"A3 APPEND "Nowhere" {\#(message.utf8.count)}"#, reply: "A3 NO [TRYCREATE] No such mailbox\r\n"),
            .expect("A4 NOOP", reply: "* 4 EXISTS\r\nA4 OK Done\r\n"),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        let appended = try await client.append(Data(message.utf8), to: "Sent Messages", flags: ["\\Seen"])
        #expect(appended == IMAPAppendResult(uidValidity: 38505, uid: 3955))
        await #expect(throws: PMailError.server("No such mailbox")) { try await client.append(Data(message.utf8), to: "Nowhere") }
        try await client.noop()
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func searchSendsNonASCIITextAsLiterals() async throws {
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(), script: [
            IMAPScript.signIn("A1"),
            IMAPScript.select("A2"),
            .expect("A3 UID SEARCH CHARSET UTF-8 UNSEEN OR OR FROM {5+}", reply: ""),
            .expect("café SUBJECT {5+}", reply: ""),
            .expect("café TEXT {5+}", reply: ""),
            .expect("café", reply: "* SEARCH 3 9\r\nA3 OK Search completed\r\n"),
            .expect(#"A4 UID SEARCH OR HEADER References "<root@example.com>" FLAGGED"#, reply: "* SEARCH\r\nA4 OK Done\r\n"),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        try await client.select("INBOX")
        #expect(try await client.uidSearch([.unseen] + IMAPSearchKey.matching(query: "café")) == [3, 9])
        #expect(try await client.uidSearch([.or(.header("References", "<root@example.com>"), .flagged)]) == [])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func movingFallsBackToCopyAndExpunge() async throws {
        let capabilities = "IMAP4rev1 AUTH=PLAIN SASL-IR"
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(capabilities), script: [
            IMAPScript.signIn("A1", capabilities: capabilities),
            IMAPScript.select("A2"),
            IMAPScript.ok("A3", #"UID COPY 4:5 "Archive""#),
            IMAPScript.ok("A4", #"UID STORE 4:5 +FLAGS.SILENT (\Deleted)"#),
            IMAPScript.ok("A5", "EXPUNGE", untagged: ["* 2 EXPUNGE", "* 2 EXPUNGE"]),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        try await client.select("INBOX")
        try await client.uidMove([5, 4], to: "Archive")
        #expect(await client.selectedMailbox?.exists == 1)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aGoodbyeMidCommandReportsTheServersReason() async throws {
        let stream = ScriptedByteStream(greeting: IMAPScript.greeting(), script: [
            IMAPScript.signIn("A1"),
            .expect("A2 NOOP", reply: "* BYE Server shutting down\r\n"),
        ])
        let client = try await connectedClient(stream)
        try await client.signIn(.password(username: "pug@example.com", password: "secret"))
        stream.close()  // The server hangs up right after saying goodbye.
        await #expect(throws: PMailError.connectionFailed("Server shutting down")) { try await client.noop() }
        #expect(!(await client.isConnected))
        await #expect(throws: PMailError.self) { try await client.noop() }
    }
}
