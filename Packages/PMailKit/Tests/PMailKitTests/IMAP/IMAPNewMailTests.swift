import Foundation
import Testing
@testable import PMailKit

/// Checking for new mail, finding messages by Message-ID, and waiting for changes (IDLE, or NOOP without it).
@Suite(.timeLimit(.minutes(1))) struct IMAPNewMailTests {
    private typealias Script = IMAPScript

    private static let idleCapabilities = IMAPScript.capabilities + " IDLE"

    private static let summaryFetch = "(\(IMAPClient.summaryItems))"

    private static func inboxStatus(_ tag: String, uidNext: Int, uidValidity: Int = 7, unseen: Int) -> ScriptedByteStream.Step {
        .expect(#"\#(tag) STATUS "INBOX" (UIDNEXT UIDVALIDITY UNSEEN)"#, reply: Script.lines(
            #"* STATUS "INBOX" (UIDNEXT \#(uidNext) UIDVALIDITY \#(uidValidity) UNSEEN \#(unseen))"#, "\(tag) OK STATUS completed"))
    }

    /// A FETCH answer with what a message list needs, for a plain text message. `messageID` goes in a quoted string
    /// as it is, so a quote in it needs its backslash.
    private static func summaryLine(_ sequence: Int, uid: UInt32, subject: String, messageID: String,
                                    flags: String = "") -> String {
        #"* \#(sequence) FETCH (UID \#(uid) FLAGS (\#(flags)) INTERNALDATE "21-Nov-2026 18:45:05 +0000" RFC822.SIZE 900 "#
            + #"ENVELOPE ("Sat, 21 Nov 2026 13:45:00 -0500" "\#(subject)" (("Alex Kim" NIL "alex" "example.com")) "#
            + #"(("Alex Kim" NIL "alex" "example.com")) NIL ((NIL NIL "pug" "example.com")) NIL NIL NIL "\#(messageID)") "#
            + #"BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1) "#
            + #"BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] NIL)"#
    }

    /// Waits, briefly, until `condition` holds.
    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The condition never held.")
    }

    // MARK: Checking for new mail

    @Test func theFirstCheckOnlyAsksForTheInboxStatus() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.inboxStatus("A2", uidNext: 105, unseen: 4),
            // Nothing new since: STATUS again, and nothing more.
            Self.inboxStatus("A3", uidNext: 105, unseen: 3),
        ])
        let harness = IMAPHarness([stream])
        let first = try await harness.service.checkForNewMail(since: nil)
        #expect(first.messages.isEmpty && first.state == MailSyncState("7:105") && first.inboxUnread == 4)
        let again = try await harness.service.checkForNewMail(since: first.state)
        #expect(again.messages.isEmpty && again.state == MailSyncState("7:105") && again.inboxUnread == 3)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aLaterCheckFetchesWhatArrivedNewestFirst() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.inboxStatus("A2", uidNext: 107, unseen: 5),
            Script.select("A3", exists: 12, readOnly: true),
            Script.ok("A4", "UID SEARCH UID 105:*", untagged: ["* SEARCH 105 106"]),
            .expect("A5 UID FETCH 105:106 \(Self.summaryFetch)", reply: Script.lines(
                Self.summaryLine(11, uid: 105, subject: "Park day", messageID: "<park@example.com>"),
                Self.summaryLine(12, uid: 106, subject: "Frisbee", messageID: "<frisbee@example.com>", flags: #"\Seen"#),
                "A5 OK Fetch completed")),
            .expect("A6 UID FETCH 105:106 (UID BODY.PEEK[1]<0.2048>)", reply: Script.lines(
                #"* 11 FETCH (UID 105 BODY[1]<0> "See you at noon")"#, #"* 12 FETCH (UID 106 BODY[1]<0> "Bring the frisbee")"#,
                "A6 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        let news = try await harness.service.checkForNewMail(since: MailSyncState("7:105"))
        #expect(news.messages.map(\.id) == [IMAPMessageID.inbox(106), IMAPMessageID.inbox(105)])
        #expect(news.messages.map(\.subject) == ["Frisbee", "Park day"])
        #expect(news.messages.map(\.snippet) == ["Bring the frisbee", "See you at noon"])
        #expect(!news.messages[0].isUnread && news.messages[1].isUnread)
        #expect(news.messages.allSatisfy { $0.folderID == "INBOX" })
        #expect(news.state == MailSyncState("7:107") && news.inboxUnread == 5)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aCheckReturnsAtMostTheNewestFifty() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.inboxStatus("A2", uidNext: 161, unseen: 60),
            Script.select("A3", exists: 70, readOnly: true),
            Script.ok("A4", "UID SEARCH UID 101:*", untagged: ["* SEARCH " + (101...160).map(String.init).joined(separator: " ")]),
            .expect("A5 UID FETCH 111:160 \(Self.summaryFetch)", reply: Script.lines(
                #"* 69 FETCH (UID 159 FLAGS () ENVELOPE (NIL "Older" NIL NIL NIL NIL NIL NIL NIL "<159@example.com>"))"#,
                #"* 70 FETCH (UID 160 FLAGS () ENVELOPE (NIL "Newest" NIL NIL NIL NIL NIL NIL NIL "<160@example.com>"))"#,
                "A5 OK Fetch completed")),
        ])
        let harness = IMAPHarness([stream])
        let news = try await harness.service.checkForNewMail(since: MailSyncState("7:101"))
        #expect(news.messages.map(\.subject) == ["Newest", "Older"])
        #expect(news.state == MailSyncState("7:161") && news.inboxUnread == 60)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aNewUIDValidityStartsOverWithoutMessages() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.inboxStatus("A2", uidNext: 40, uidValidity: 9, unseen: 2),
            // A state some other service made is no state at all.
            Self.inboxStatus("A3", uidNext: 41, uidValidity: 9, unseen: 2),
        ])
        let harness = IMAPHarness([stream])
        let news = try await harness.service.checkForNewMail(since: MailSyncState("7:105"))
        #expect(news.messages.isEmpty && news.state == MailSyncState("9:40") && news.inboxUnread == 2)
        let unknown = try await harness.service.checkForNewMail(since: MailSyncState("history:abc"))
        #expect(unknown.messages.isEmpty && unknown.state == MailSyncState("9:41"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func theSelectedInboxIsSearchedRatherThanAskedForItsStatus() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2"),
            Script.ok("A3", #"UID STORE 11 +FLAGS.SILENT (\Seen)"#),
            Script.ok("A4", "UID SEARCH UID 100:*", untagged: ["* 5 EXISTS", "* SEARCH 100 101"]),
            .expect("A5 UID FETCH 100:101 \(Self.summaryFetch)", reply: Script.lines(
                Self.summaryLine(4, uid: 100, subject: "Lunch?", messageID: "<lunch@example.com>"),
                Self.summaryLine(5, uid: 101, subject: "Re: Lunch?", messageID: "<re-lunch@example.com>"),
                "A5 OK Fetch completed")),
            .expect("A6 UID FETCH 100:101 (UID BODY.PEEK[1]<0.2048>)", reply: Script.lines(
                #"* 4 FETCH (UID 100 BODY[1]<0> "Noon?")"#, #"* 5 FETCH (UID 101 BODY[1]<0> "Sounds good")"#, "A6 OK Done")),
            // Nothing new: `UID 102:*` still answers with the newest message, which isn't new.
            Script.ok("A7", "UID SEARCH UID 102:*", untagged: ["* SEARCH 101"]),
            // No state yet: it starts from the UIDNEXT SELECT gave, past whatever has arrived since.
            Script.ok("A8", "UID SEARCH UID 100:*", untagged: ["* SEARCH 100 101"]),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.perform(.markRead, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        let news = try await harness.service.checkForNewMail(since: MailSyncState("7:100"))
        #expect(news.messages.map(\.id) == [IMAPMessageID.inbox(101), IMAPMessageID.inbox(100)])
        #expect(news.messages.map(\.snippet) == ["Sounds good", "Noon?"])
        #expect(news.state == MailSyncState("7:102") && news.inboxUnread == nil)
        let later = try await harness.service.checkForNewMail(since: news.state)
        #expect(later.messages.isEmpty && later.state == MailSyncState("7:102"))
        let fresh = try await harness.service.checkForNewMail(since: nil)
        #expect(fresh.messages.isEmpty && fresh.state == MailSyncState("7:102"))
        #expect(!stream.lines.contains { $0.split(separator: " ").dropFirst().first == "STATUS" }, "no STATUS command")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    // MARK: Finding messages

    @Test func findingMessagesByMessageIDStopsOnceAllAreFound() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2", extra: [#"* LIST (\HasNoChildren) "/" "Projects""#]),
            Script.select("A3", exists: 3, readOnly: true),
            Script.ok("A4", #"UID SEARCH OR HEADER Message-ID "<park@example.com>" HEADER Message-ID "<odd\"one@example.com>""#,
                      untagged: ["* SEARCH 11"]),
            .expect("A5 UID FETCH 11 \(Self.summaryFetch)", reply: Script.lines(
                Self.summaryLine(2, uid: 11, subject: "Park day", messageID: "<park@example.com>"), "A5 OK Done")),
            .expect("A6 UID FETCH 11 (UID BODY.PEEK[1]<0.2048>)",
                    reply: Script.lines(#"* 2 FETCH (UID 11 BODY[1]<0> "See you there")"#, "A6 OK Done")),
            Script.select("A7", "Archive", exists: 40, uidValidity: 3, readOnly: true),
            Script.ok("A8", #"UID SEARCH HEADER Message-ID "<odd\"one@example.com>""#, untagged: ["* SEARCH 31"]),
            .expect("A9 UID FETCH 31 \(Self.summaryFetch)", reply: Script.lines(
                Self.summaryLine(9, uid: 31, subject: "Odd one", messageID: #"<odd\"one@example.com>"#), "A9 OK Done")),
            .expect("A10 UID FETCH 31 (UID BODY.PEEK[1]<0.2048>)",
                    reply: Script.lines(#"* 9 FETCH (UID 31 BODY[1]<0> "Filed away")"#, "A10 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        let found = try await harness.service.findMessages(withMessageIDs: ["<park@example.com>", #"<odd"one@example.com>"#,
                                                                            " <park@example.com>"])
        #expect(found.map(\.id) == [IMAPMessageID.inbox(11), IMAPMessageID(mailbox: "Archive", uidValidity: 3, uid: 31).rawValue])
        #expect(found.map(\.messageIDHeader) == ["<park@example.com>", #"<odd"one@example.com>"#])
        #expect(found.map(\.snippet) == ["See you there", "Filed away"])
        // Both turned up, so Sent, Drafts and Projects were never opened.
        #expect(stream.mismatches.isEmpty && stream.isFinished && stream.lines.count == 10)
    }

    @Test func lookingMessagesUpSkipsTrashAndJunk() async throws {
        let search = #"UID SEARCH HEADER Message-ID "<gone@example.com>""#
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2", extra: [#"* LIST (\HasNoChildren) "/" "Projects""#,
                                      #"* LIST (\HasNoChildren) "/" "Deleted Messages/Old""#,
                                      #"* LIST (\Noselect \HasChildren) "/" "Shared""#]),
            Script.select("A3", exists: 3, readOnly: true),
            Script.ok("A4", search),
            Script.select("A5", "Archive", exists: 0, uidValidity: 3, readOnly: true),
            Script.select("A6", "Sent Messages", exists: 2, uidValidity: 9, readOnly: true),
            Script.ok("A7", search),
            .expect(#"A8 EXAMINE "Drafts""#, reply: "A8 NO Mailbox is locked\r\n"),
            Script.select("A9", "Projects", exists: 1, uidValidity: 4, readOnly: true),
            Script.ok("A10", search),
        ])
        let harness = IMAPHarness([stream])
        #expect(try await harness.service.findMessages(withMessageIDs: ["", "  "]).isEmpty)
        #expect(try await harness.service.findMessages(withMessageIDs: ["<gone@example.com>"]).isEmpty)
        #expect(!stream.lines.contains { $0.contains("Deleted Messages") || $0.contains("Junk") || $0.contains("Shared") })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
        #expect(harness.connector.connections.count == 1)
    }

    @Test func theLookupOrder() {
        let boxes = [
            IMAPMailbox(name: "Work"),
            IMAPMailbox(name: "Sent"),
            IMAPMailbox(name: "INBOX"),
            IMAPMailbox(name: "Trash"),
            IMAPMailbox(name: "Trash/2019"),
            IMAPMailbox(name: "Flagged", attributes: ["\\Flagged"]),
            IMAPMailbox(name: "All Mail", attributes: ["\\All"]),
            IMAPMailbox(name: "Archive"),
            IMAPMailbox(name: "Spam"),
        ] + (1...50).map { IMAPMailbox(name: "Folder \($0)") }
        let order = IMAPMailService.lookupOrder(boxes, limit: 40)
        #expect(Array(order.prefix(5)) == ["INBOX", "Archive", "All Mail", "Sent", "Work"])
        #expect(order.count == 40 && order.last == "Folder 35")
        #expect(!order.contains("Trash") && !order.contains("Trash/2019") && !order.contains("Spam") && !order.contains("Flagged"))
    }

    // MARK: Waiting for changes

    @Test func waitingWithIDLEEndsWhenNewMailArrives() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: Script.lines("+ idling", "* 4 EXISTS", "* 1 RECENT")),
            .expect("DONE", reply: "A3 OK IDLE terminated\r\n"),
        ])
        let harness = IMAPHarness([stream])
        #expect(harness.service.pushesChanges)
        #expect(try await harness.service.waitForChange(timeout: 30))
        #expect(stream.mismatches.isEmpty && stream.isFinished && !stream.closed)
    }

    @Test func waitingWithIDLEEndsWithDONEWhenTheTimeIsUp() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A3 OK IDLE terminated\r\n"),
            // The next wait carries on with the same connection.
            .expect("A4 IDLE", reply: Script.lines("+ idling", "* 2 EXPUNGE")),
            .expect("DONE", reply: "A4 OK IDLE terminated\r\n"),
            .expect("A5 LOGOUT", reply: "* BYE See you\r\nA5 OK Logged out\r\n"),
        ])
        let harness = IMAPHarness([stream])
        let start = ContinuousClock.now
        #expect(try await harness.service.waitForChange(timeout: 0.2) == false)
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        #expect(try await harness.service.waitForChange(timeout: 30))
        #expect(try await harness.service.waitForChange(timeout: 0) == false)
        await harness.service.close()
        #expect(stream.mismatches.isEmpty && stream.isFinished && stream.closed)
        #expect(harness.connector.connections.count == 1)
    }

    @Test func withoutIDLEItAsksWithNOOP() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", exists: 3, readOnly: true),
            // The time is up before the next poll would be due: one NOOP at the end, and nothing changed.
            Script.ok("A3", "NOOP"),
            // The same count is no change; new flags are.
            Script.ok("A4", "NOOP", untagged: ["* 3 EXISTS"]),
            Script.ok("A5", "NOOP", untagged: [#"* 2 FETCH (FLAGS (\Seen))"#]),
            Script.ok("A6", "NOOP", untagged: ["* 4 EXISTS", "* 1 RECENT"]),
        ])
        let harness = IMAPHarness([stream])
        await harness.service.setPollInterval(10)
        #expect(try await harness.service.waitForChange(timeout: 0.05) == false)
        await harness.service.setPollInterval(0.01)
        #expect(try await harness.service.waitForChange(timeout: 30))
        #expect(try await harness.service.waitForChange(timeout: 30))
        #expect(!stream.lines.contains { $0.hasSuffix("IDLE") })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func cancellingAWaitEndsIDLEWhileOtherCallsCarryOn() async throws {
        let waiting = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A3 OK IDLE terminated\r\n"),
        ])
        let main = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.inboxStatus("A2", uidNext: 105, unseen: 1),
        ])
        let harness = IMAPHarness([waiting, main])
        let wait = Task { try await harness.service.waitForChange(timeout: 50) }
        try await Self.eventually { waiting.linesSoFar.contains("A3 IDLE") }
        // The wait has a connection of its own, so the service still answers meanwhile.
        let news = try await harness.service.checkForNewMail(since: nil)
        #expect(news.state == MailSyncState("7:105"))
        wait.cancel()
        await #expect(throws: PMailError.cancelled) { try await wait.value }
        #expect(waiting.lines.last == "DONE" && !waiting.closed)
        #expect(waiting.mismatches.isEmpty && waiting.isFinished)
        #expect(main.mismatches.isEmpty && main.isFinished)
    }

    @Test func aBrokenWaitingConnectionIsMadeAgainOnTheNextCall() async throws {
        let first = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: Script.lines("+ idling", "* BYE Server shutting down")),
        ])
        let second = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: Script.lines("+ idling", #"* 1 FETCH (FLAGS (\Flagged))"#)),
            .expect("DONE", reply: "A3 OK IDLE terminated\r\n"),
        ])
        let harness = IMAPHarness([first, second])
        let wait = Task { try await harness.service.waitForChange(timeout: 50) }
        try await Self.eventually { first.linesSoFar.contains("A3 IDLE") }
        first.close()  // The server hangs up after saying goodbye.
        await #expect(throws: PMailError.connectionFailed("Server shutting down")) { try await wait.value }
        #expect(try await harness.service.waitForChange(timeout: 50))
        #expect(harness.connector.connections.count == 2)
        #expect(second.mismatches.isEmpty && second.isFinished)
    }

    @Test func closingTheServiceEndsAWaitInProgress() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.idleCapabilities), script: [
            Script.signIn("A1", capabilities: Self.idleCapabilities),
            Script.select("A2", exists: 3, readOnly: true),
            .expect("A3 IDLE", reply: "+ idling\r\n"),
        ])
        let harness = IMAPHarness([stream])
        let wait = Task { try await harness.service.waitForChange(timeout: 50) }
        try await Self.eventually { stream.linesSoFar.contains("A3 IDLE") }
        await harness.service.close()
        await #expect(throws: PMailError.cancelled) { try await wait.value }
        #expect(stream.closed && stream.mismatches.isEmpty && stream.isFinished)
    }
}
