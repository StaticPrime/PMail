import Foundation
import Testing
@testable import PMailKit

/// Keeping a Google account's mail on this Mac in step with Gmail over IMAP: the first sync, later ones that fetch
/// only what changed, and lists that never ask the server.
@Suite(.timeLimit(.minutes(1))) struct IMAPGmailSyncTests {
    private typealias Script = IMAPScript
    private typealias Step = ScriptedByteStream.Step

    private static let capabilities = IMAPGmailTests.capabilities

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailGmailSync-\(UUID().uuidString)", isDirectory: true)
    }

    private func service(_ streams: [ScriptedByteStream], folder: URL) -> IMAPMailService {
        let account = Account(kind: .google, name: "Pug Tester", email: "pug@gmail.com")
        let incoming = ServerSettings(mailProtocol: .imap, host: "imap.gmail.com", security: .tls, username: "pug@gmail.com",
                                      authentication: .oauth2)
        return IMAPMailService(account: account, incoming: incoming,
                               credential: .oauth(username: "pug@gmail.com", tokens: IMAPFakeTokens(["token-1", "token-2"])),
                               sender: IMAPRecordingSender(), connector: ScriptedConnector(streams), gmailStoreFolder: folder)
    }

    /// Commands with their tags numbered in turn.
    private struct Session {
        var steps: [Step] = []
        private var number = 0

        mutating func tag() -> String {
            number += 1
            return "A\(number)"
        }

        mutating func signIn() {
            let tag = tag()
            steps.append(.expect("\(tag) AUTHENTICATE XOAUTH2 \(SASL.xoauth2(username: "pug@gmail.com", accessToken: steps.isEmpty ? "token-1" : "token-1"))",
                                 reply: "\(tag) OK [CAPABILITY \(IMAPGmailSyncTests.capabilities)] authenticated (Success)\r\n"))
        }

        mutating func ok(_ command: String, _ untagged: [String] = []) {
            let tag = tag()
            steps.append(Script.ok(tag, command, untagged: untagged))
        }

        mutating func examine(_ mailbox: String, exists: Int, validity: UInt32, next: UInt32, modSeq: UInt64, condstore: Bool = true) {
            let tag = tag()
            let lines = ["* \(exists) EXISTS", "* 0 RECENT", "* OK [UIDVALIDITY \(validity)] UIDs valid", "* OK [UIDNEXT \(next)] Predicted next UID",
                         "* OK [HIGHESTMODSEQ \(modSeq)] Highest", "\(tag) OK [READ-ONLY] \(mailbox) selected. (Success)"]
            steps.append(.expect("\(tag) EXAMINE \"\(mailbox)\"\(condstore ? " (CONDSTORE)" : "")", reply: lines.map { $0 + "\r\n" }.joined()))
        }

        mutating func select(_ mailbox: String) {
            let tag = tag()
            steps.append(.expect("\(tag) SELECT \"\(mailbox)\"", reply: Script.lines(
                "* 3 EXISTS", "* OK [UIDVALIDITY 11] UIDs valid", "* OK [UIDNEXT 105] Predicted next UID", "\(tag) OK [READ-WRITE] (Success)")))
        }

        mutating func fetch(_ command: String, _ lines: [String]) {
            let tag = tag()
            steps.append(.expect("\(tag) \(command)", reply: (lines + ["\(tag) OK Success"]).map { $0 + "\r\n" }.joined()))
        }

        mutating func list() {
            let tag = tag()
            let mailboxes = [
                #"* LIST (\HasNoChildren) "/" "INBOX""#,
                #"* LIST (\HasChildren \Noselect) "/" "[Gmail]""#,
                #"* LIST (\All \HasNoChildren) "/" "[Gmail]/All Mail""#,
                #"* LIST (\Drafts \HasNoChildren) "/" "[Gmail]/Drafts""#,
                #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#,
                #"* LIST (\HasNoChildren \Junk) "/" "[Gmail]/Spam""#,
                #"* LIST (\Flagged \HasNoChildren) "/" "[Gmail]/Starred""#,
                #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#,
                #"* LIST (\HasNoChildren) "/" "Work""#,
            ]
            steps.append(.expect("\(tag) LIST \"\" \"*\"", reply: (mailboxes + ["\(tag) OK Success"]).map { $0 + "\r\n" }.joined()))
        }
    }

    private static let indexFetch = "(\(IMAPMailService.gmailIndexItems))"
    private static let headerFetch = "(\(IMAPMailService.gmailHeaderItems))"

    private static func index(_ sequence: Int, uid: UInt32, thread: UInt32, labels: String, flags: String = #"\Seen"#, hour: Int) -> String {
        #"* \#(sequence) FETCH (UID \#(uid) X-GM-MSGID 17900000000000\#(uid) X-GM-THRID 17900000000000\#(thread) "#
            + #"X-GM-LABELS (\#(labels)) FLAGS (\#(flags)) INTERNALDATE "20-Nov-2026 \#(hour):00:00 +0000")"#
    }

    private static func headers(_ sequence: Int, uid: UInt32, subject: String) -> String {
        let text = "From: Alex Kim <alex@example.com>\r\nTo: pug@gmail.com\r\nSubject: \(subject)\r\nMessage-ID: <m\(uid)@example.com>\r\n\r\n"
        return "* \(sequence) FETCH (UID \(uid) RFC822.SIZE 1200 BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO "
            + "CONTENT-TYPE LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED X-SPAM-FLAG X-SPAM-STATUS X-SPAM)] \(Script.literal(text)))"
    }

    /// The first sync of an account with three messages in All Mail (an unread inbox message, its reply from the account,
    /// and a promotion in the inbox) and one in Trash; `withDraft` adds a draft of a second reply, in All Mail as 104.
    private func firstSync(_ session: inout Session, withDraft: Bool = false) {
        let count = withDraft ? 4 : 3
        let next: UInt32 = withDraft ? 105 : 104
        session.signIn()
        session.list()
        session.examine("[Gmail]/All Mail", exists: count, validity: 11, next: next, modSeq: 500)
        session.fetch("UID FETCH 1:* \(Self.indexFetch)", [
            Self.index(1, uid: 101, thread: 101, labels: #"\Inbox"#, flags: "", hour: 10),
            Self.index(2, uid: 102, thread: 102, labels: #"\Inbox \Important"#, hour: 11),
            Self.index(3, uid: 103, thread: 101, labels: #"\Sent"#, hour: 12),
        ] + (withDraft ? [Self.index(4, uid: 104, thread: 101, labels: #"\Draft"#, flags: #"\Seen \Draft"#, hour: 13)] : []))
        session.examine("[Gmail]/Spam", exists: 0, validity: 12, next: 1, modSeq: 3)
        session.examine("[Gmail]/Trash", exists: 1, validity: 13, next: 8, modSeq: 4)
        session.fetch("UID FETCH 1:* \(Self.indexFetch)", [Self.index(1, uid: 7, thread: 7, labels: "", hour: 9)])
        // The tabs, the first time for everything.
        session.examine("[Gmail]/All Mail", exists: count, validity: 11, next: next, modSeq: 500, condstore: false)
        session.ok(#"UID SEARCH X-GM-RAW "category:promotions""#, ["* SEARCH 102"])
        session.ok(#"UID SEARCH X-GM-RAW "category:social""#, ["* SEARCH"])
        session.ok(#"UID SEARCH X-GM-RAW "category:updates""#, ["* SEARCH"])
        session.ok(#"UID SEARCH X-GM-RAW "category:forums""#, ["* SEARCH"])
        // Headers: the inbox's first, the newest first, in one batch here.
        session.fetch("UID FETCH 101:\(next - 1) \(Self.headerFetch)", [
            Self.headers(1, uid: 101, subject: "Park day"), Self.headers(2, uid: 102, subject: "50% off kibble"),
            Self.headers(3, uid: 103, subject: "Re: Park day"),
        ] + (withDraft ? [Self.headers(4, uid: 104, subject: "Re: Park day")] : []))
        session.examine("[Gmail]/Trash", exists: 1, validity: 13, next: 8, modSeq: 4, condstore: false)
        session.fetch("UID FETCH 7 \(Self.headerFetch)", [Self.headers(1, uid: 7, subject: "Old news")])
    }

    @Test func theFirstSyncTakesTheIndexThenTabsThenHeadersAndListsComeFromTheStore() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = Session()
        firstSync(&session)
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: session.steps)
        let mail = service([stream], folder: folder)
        #expect(mail.capabilities.listsFromLocalCopy)
        try await mail.syncGmail()
        #expect(stream.mismatches.isEmpty && stream.isFinished)

        let primary = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PERSONAL"))
        #expect(primary.conversations.map(\.id) == ["17900000000000101"])
        #expect(primary.conversations.first?.messages.map(\.subject) == ["Park day", "Re: Park day"], "the reply in Sent too")
        #expect(primary.conversations.first?.messages.first?.isUnread == true)
        let promotions = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PROMOTIONS"))
        #expect(promotions.conversations.map(\.id) == ["17900000000000102"] && promotions.conversations.first?.isImportant == true)
        #expect(try await mail.unreadCounts(inTabs: GoogleMailService.tabs)["CATEGORY_PERSONAL"] == 1)
        // With conversations being filed away, a page lists that many more to fill in, and the next still starts after it.
        let filled = try await mail.listConversations(ListRequest(folderID: "INBOX", pageSize: 1, extra: 1))
        #expect(filled.conversations.count == 2 && filled.nextPageToken == "1")
        // Lists and counts asked the server nothing; only the snippets of what was listed come in the background.
        #expect(stream.linesSoFar.dropFirst(session.steps.count).allSatisfy { $0.contains("EXAMINE") || $0.contains("BODYSTRUCTURE") })
        #expect(await mail.gmailStore?.setting("downloaded") != nil)
    }

    @Test func laterSyncsFetchOnlyWhatChangedAndAnnounceNewMail() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = Session()
        firstSync(&session)
        // Spam and Trash haven't changed; All Mail has a new message, a message read elsewhere and one deleted.
        session.examine("[Gmail]/Spam", exists: 0, validity: 12, next: 1, modSeq: 3)
        session.examine("[Gmail]/Trash", exists: 1, validity: 13, next: 8, modSeq: 4)
        session.examine("[Gmail]/All Mail", exists: 3, validity: 11, next: 105, modSeq: 520)
        session.fetch("UID FETCH 104:* \(Self.indexFetch)", [Self.index(3, uid: 104, thread: 104, labels: #"\Inbox"#, flags: "", hour: 13)])
        session.fetch("UID FETCH 1:103 (UID FLAGS X-GM-LABELS) (CHANGEDSINCE 500)", [#"* 1 FETCH (UID 101 FLAGS (\Seen) X-GM-LABELS (\Inbox))"#])
        session.ok("UID SEARCH ALL", ["* SEARCH 101 103 104"])
        session.ok(#"UID SEARCH UID 104 X-GM-RAW "category:promotions""#, ["* SEARCH"])
        session.ok(#"UID SEARCH UID 104 X-GM-RAW "category:social""#, ["* SEARCH"])
        session.ok(#"UID SEARCH UID 104 X-GM-RAW "category:updates""#, ["* SEARCH"])
        session.ok(#"UID SEARCH UID 104 X-GM-RAW "category:forums""#, ["* SEARCH"])
        session.fetch("UID FETCH 104 \(Self.headerFetch)", [Self.headers(3, uid: 104, subject: "Lunch?")])
        // Then nothing at all has changed: one look per mailbox.
        session.examine("[Gmail]/Spam", exists: 0, validity: 12, next: 1, modSeq: 3)
        session.examine("[Gmail]/Trash", exists: 1, validity: 13, next: 8, modSeq: 4)
        session.examine("[Gmail]/All Mail", exists: 3, validity: 11, next: 105, modSeq: 520)
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: session.steps)
        let mail = service([stream], folder: folder)
        try await mail.syncGmail()
        let news = try await mail.checkForNewMail(since: nil)
        #expect(news.messages.map(\.subject) == ["Lunch?"], "only mail new since the first sync is announced")
        #expect(news.inboxUnread == 1)
        let quiet = try await mail.checkForNewMail(since: news.state)
        #expect(quiet.messages.isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)

        let inbox = try await mail.listConversations(ListRequest(folderID: "INBOX"))
        #expect(inbox.conversations.map(\.id) == ["17900000000000104", "17900000000000101"], "the deleted promotion is gone")
        #expect(inbox.conversations.last?.messages.first?.isUnread == false, "read on another device")
    }

    @Test func actionsGoToGmailAndShowInTheStoreAtOnce() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = Session()
        firstSync(&session)
        let background = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: session.steps)
        var actions = Session()
        actions.signIn()
        actions.select("[Gmail]/All Mail")
        actions.ok(#"UID STORE 101 -X-GM-LABELS (\Inbox)"#)
        actions.ok(#"UID STORE 102 +X-GM-LABELS ("Work")"#)
        actions.ok(#"UID STORE 102 -X-GM-LABELS (\Inbox)"#)
        let main = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: actions.steps)
        let mail = service([background, main], folder: folder)
        try await mail.syncGmail()
        let inbox = try await mail.listConversations(ListRequest(folderID: "INBOX")).conversations
        #expect(inbox.map(\.id) == ["17900000000000101", "17900000000000102"], "the reply makes Park day the newest")
        let park = try #require(inbox.first?.messages.first)
        try await mail.perform(.archive, on: [park])
        #expect(try await mail.listConversations(ListRequest(folderID: "INBOX")).conversations.map(\.id) == ["17900000000000102"])
        let kibble = try #require(try await mail.listConversations(ListRequest(folderID: "INBOX")).conversations.first?.messages.first)
        try await mail.perform(.move(toFolderID: "Work"), on: [kibble])
        #expect(try await mail.listConversations(ListRequest(folderID: "INBOX")).conversations.isEmpty)
        #expect(try await mail.listConversations(ListRequest(folderID: "Work")).conversations.map(\.id) == ["17900000000000102"],
                "Move to: the label on, out of the inbox")
        #expect(main.mismatches.isEmpty && main.isFinished && background.mismatches.isEmpty)
    }

    /// What deleting draft 104 for good says to Gmail: deleting it from All Mail would do nothing there, so it goes to
    /// the trash and is deleted from there (as 8).
    private static func deletingTheDraftForGood(_ session: inout Session) {
        session.select("[Gmail]/All Mail")
        session.fetch("UID FETCH 104 (X-GM-MSGID)", ["* 4 FETCH (UID 104 X-GM-MSGID 17900000000000104)"])
        session.ok(#"UID MOVE 104 "[Gmail]/Trash""#, ["* 4 EXPUNGE"])
        session.select("[Gmail]/Trash")
        session.ok("UID SEARCH X-GM-MSGID 17900000000000104", ["* SEARCH 8"])
        session.ok(#"UID STORE 8 +FLAGS.SILENT (\Deleted)"#)
        session.ok("UID EXPUNGE 8", ["* 2 EXPUNGE"])
    }

    @Test func aDraftThrownAwayIsDeletedForGoodAndLeavesDraftsAtOnce() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = Session()
        firstSync(&session, withDraft: true)
        let background = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: session.steps)
        var actions = Session()
        actions.signIn()
        Self.deletingTheDraftForGood(&actions)
        let main = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: actions.steps)
        let mail = service([background, main], folder: folder)
        try await mail.syncGmail()
        let drafts = try await mail.listConversations(ListRequest(folderID: "[Gmail]/Drafts")).conversations
        #expect(drafts.map(\.id) == ["17900000000000101"])
        #expect(drafts.first?.messages.map(\.isDraft) == [false, false, true], "Gmail lists a reply's draft with its whole conversation")
        let draft = try #require(drafts.first?.messages.last)
        try await mail.deleteDraft(draft)
        #expect(try await mail.listConversations(ListRequest(folderID: "[Gmail]/Drafts")).conversations.isEmpty, "out of Drafts at once")
        let park = try await mail.listConversations(ListRequest(folderID: "INBOX")).conversations.first { $0.id == "17900000000000101" }
        #expect(park?.messages.map(\.subject) == ["Park day", "Re: Park day"], "the rest of the conversation stays")
        #expect(main.mismatches.isEmpty && main.isFinished && background.mismatches.isEmpty)
    }

    @Test func savingADraftAgainDeletesItsOldCopyForGood() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = Session()
        firstSync(&session, withDraft: true)
        let background = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: session.steps)
        let message = OutgoingMessage(from: MailAddress(name: "Pug Tester", email: "pug@gmail.com"), to: [MailAddress(email: "alex@example.com")],
                                      subject: "Re: Park day", textBody: "See you at 3!", messageID: "<draft-2@gmail.com>",
                                      date: Date(timeIntervalSince1970: 1_795_000_000))
        let raw = MIMEBuilder.buildForSaving(message)
        var actions = Session()
        actions.signIn()
        let append = actions.tag()
        actions.steps += [
            .expect(#"\#(append) APPEND "[Gmail]/Drafts" (\Draft \Seen) {\#(raw.count)+}"#, reply: ""),
            .expectBytes(raw.count, reply: ""),
            .expect("", reply: "\(append) OK [APPENDUID 5 9] (Success)\r\n"),
        ]
        Self.deletingTheDraftForGood(&actions)
        let main = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: actions.steps)
        let mail = service([background, main], folder: folder)
        try await mail.syncGmail()
        #expect(background.mismatches.isEmpty && background.isFinished)
        let old = try #require(try await mail.listConversations(ListRequest(folderID: "[Gmail]/Drafts")).conversations.first?.messages.last)
        let saved = try #require(try await mail.saveDraft(message, replacing: old))
        #expect(saved.id == IMAPMessageID(mailbox: "[Gmail]/Drafts", uidValidity: 5, uid: 9).rawValue && saved.isDraft)
        #expect(try await mail.listConversations(ListRequest(folderID: "[Gmail]/Drafts")).conversations.isEmpty,
                "the old copy isn't left behind as a second draft; the new one comes with the next sync")
        #expect(main.mismatches.isEmpty && main.isFinished)
    }
}
