import Foundation
import Testing
@testable import PMailKit

/// Labels on IMAP accounts: keywords on a server that takes them, kept on this Mac otherwise.
@Suite(.timeLimit(.minutes(1))) struct IMAPLabelsTests {
    private typealias Script = IMAPScript
    private typealias Step = ScriptedByteStream.Step

    /// A server without special-use folders or MOVE, like an iCloud account that has only ever had an inbox.
    private static let inboxOnlyCapabilities = "IMAP4rev1 SASL-IR AUTH=PLAIN IDLE UIDPLUS LITERAL+"

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-imap-labels-\(UUID().uuidString)", isDirectory: true)
    }

    private func service(_ streams: [ScriptedByteStream], book: LabelBook?, store: LocalMailStore? = nil) -> IMAPMailService {
        let account = Account(kind: .icloud, name: "Pug Tester", email: "pug@example.com")
        let incoming = ServerSettings(mailProtocol: .imap, host: "imap.example.com", port: 993, security: .tls, username: "pug@example.com")
        return IMAPMailService(account: account, incoming: incoming, credential: .password(username: "pug@example.com", password: "secret"),
                               sender: IMAPRecordingSender(), connector: ScriptedConnector(streams), localStore: store, labelBook: book)
    }

    /// SELECT, with `\*` among the PERMANENTFLAGS when the mailbox takes keywords.
    private static func select(_ tag: String, _ mailbox: String = "INBOX", exists: Int = 3, uidValidity: UInt32 = 7,
                               keywords: Bool) -> Step {
        let permanent = #"\Answered \Flagged \Deleted \Seen \Draft"# + (keywords ? #" \*"# : "")
        return .expect("\(tag) SELECT \"\(mailbox)\"", reply: Script.lines(
            #"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)"#, "* OK [PERMANENTFLAGS (\(permanent))] Flags permitted",
            "* \(exists) EXISTS", "* OK [UIDVALIDITY \(uidValidity)] UIDs valid", "\(tag) OK [READ-WRITE] SELECT completed"))
    }

    /// EXAMINE, with `flags` (each with a space before it) among the mailbox's FLAGS. A read-only mailbox never lets
    /// flags change, so its PERMANENTFLAGS are empty.
    private static func examine(_ tag: String, _ mailbox: String = "INBOX", exists: Int = 3, uidValidity: UInt32 = 7,
                                flags: String = "") -> Step {
        .expect("\(tag) EXAMINE \"\(mailbox)\"", reply: Script.lines(
            #"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft\#(flags))"#, "* OK [PERMANENTFLAGS ()] Read-only mailbox",
            "* \(exists) EXISTS", "* OK [UIDVALIDITY \(uidValidity)] UIDs valid", "\(tag) OK [READ-ONLY] EXAMINE completed"))
    }

    /// A message list row as FETCH gives it: flags, arrival, size and envelope (no structure, so no snippet is fetched).
    private static func row(_ sequence: Int, uid: UInt32, flags: String, subject: String, messageID: String,
                            date: String = "Sat, 21 Nov 2026 13:45:00 -0500") -> String {
        #"* \#(sequence) FETCH (UID \#(uid) FLAGS (\#(flags)) INTERNALDATE "21-Nov-2026 18:45:05 +0000" RFC822.SIZE 1200 "#
            + #"ENVELOPE ("\#(date)" "\#(subject)" (("Alex Kim" NIL "alex" "example.com")) NIL NIL "#
            + #"((NIL NIL "pug" "example.com")) NIL NIL NIL "\#(messageID)"))"#
    }

    private static let summaryFetch = "(\(IMAPClient.summaryItems))"

    private static func status(_ tag: String, _ mailbox: String) -> Step {
        Script.ok(tag, #"STATUS "\#(mailbox)" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
                  untagged: [#"* STATUS "\#(mailbox)" (MESSAGES 1 UNSEEN 0 UIDNEXT 100 UIDVALIDITY 7)"#])
    }

    private static let hike = "From: Alex Kim <alex@example.com>\r\nTo: pug@example.com\r\nSubject: Hike\r\n"
        + "Date: Sat, 21 Nov 2026 09:00:00 +0000\r\nMessage-ID: <hike@example.com>\r\n\r\nSaturday?\r\n"

    @Test func anAccountWithALabelBookCanLabel() {
        let folder = temporaryFolder()
        let labeled = service([], book: LabelBook(file: folder.appendingPathComponent("labels.json"))).capabilities
        #expect(labeled.canLabel && labeled.canEditLabels && !labeled.usesLabels)
        let plain = service([], book: nil).capabilities
        #expect(!plain.canLabel && !plain.canEditLabels)
    }

    /// A server that takes keywords keeps labels on the messages, and listing a label finds them in every mailbox.
    @Test func keywordLabelsGoOnMessagesAndListFromEveryMailbox() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.select("A2", keywords: true),
            // Adding asks for the flags back, to see that the keyword stayed.
            Script.ok("A3", "UID STORE 11:12 +FLAGS (PMail_Work)",
                      untagged: [#"* 2 FETCH (UID 11 FLAGS (\Seen PMail_Work))"#, "* 3 FETCH (UID 12 FLAGS (PMail_Work))"]),
            Script.ok("A4", "UID STORE 12 -FLAGS.SILENT (PMail_Work)"),
            // Listing the label: the message PMail put it on is fetched where it is, and still has it.
            Script.ok("A5", "UID FETCH 11 \(Self.summaryFetch)", untagged: [
                Self.row(2, uid: 11, flags: "PMail_Work", subject: "Park day", messageID: "<park@example.com>"),
            ]),
            // Then every mailbox but Trash and Junk is searched for its keyword (the inbox's find is already in hand).
            Script.list("A6"),
            Self.examine("A7", flags: " PMail_Work PMail_Trip"),
            Script.ok("A8", "UID SEARCH KEYWORD PMail_Work", untagged: ["* SEARCH 11"]),
            Script.ok("A9", "UID FETCH 11 (UID INTERNALDATE)",
                      untagged: [#"* 2 FETCH (UID 11 INTERNALDATE "21-Nov-2026 18:45:05 +0000")"#]),
            Self.examine("A10", "Archive", exists: 2, uidValidity: 3),
            Script.ok("A11", "UID SEARCH KEYWORD PMail_Work", untagged: ["* SEARCH 4"]),
            Script.ok("A12", "UID FETCH 4 (UID INTERNALDATE)", untagged: [#"* 1 FETCH (UID 4 INTERNALDATE "22-Nov-2026 09:00:00 +0000")"#]),
            Self.examine("A13", "Sent Messages", exists: 0, uidValidity: 9),
            .expect(#"A14 EXAMINE "Drafts""#, reply: "A14 NO [NONEXISTENT] No such mailbox\r\n"),
            // The newest first: the archived message (fetched now), then the one in the inbox.
            Self.examine("A15", "Archive", exists: 2, uidValidity: 3),
            Script.ok("A16", "UID FETCH 4 \(Self.summaryFetch)", untagged: [
                Self.row(1, uid: 4, flags: #"\Seen PMail_Work"#, subject: "Trip plans", messageID: "<trip@example.com>",
                         date: "Sun, 22 Nov 2026 04:00:00 -0500"),
            ]),
        ])
        let imap = service([stream], book: book)
        let work = try await imap.createLabel(named: "Work", colorHex: "#16a766")
        #expect(work == MailFolder(id: "PMail_Work", name: "Work", kind: .label, colorHex: "#16A766"))
        let park = MessageSummary(id: IMAPMessageID.inbox(11), messageIDHeader: "<park@example.com>")
        let lunch = MessageSummary(id: IMAPMessageID.inbox(12), messageIDHeader: "<lunch@example.com>")
        try await imap.perform(.addLabel(work.id), on: [park, lunch])
        try await imap.perform(.removeLabel(work.id), on: [lunch])
        #expect(await book.keywordsAllowed() == true)
        #expect(await book.messages(withLabel: work.id).isEmpty, "the server keeps them")

        let page = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(page.totalCount == 2 && page.nextPageToken == nil)
        let messages = page.conversations.flatMap(\.messages)
        #expect(messages.map(\.id) == [IMAPMessageID(mailbox: "Archive", uidValidity: 3, uid: 4).rawValue, IMAPMessageID.inbox(11)])
        #expect(messages.map(\.labelIDs) == [["PMail_Work"], ["PMail_Work"]])
        // The inbox's FLAGS named a label made on another Mac.
        #expect(await book.labels().map(\.name) == ["Trip", "Work"])
        // Something that isn't a label's ID is never sent to the server.
        await #expect(throws: PMailError.notFound) { try await imap.perform(.addLabel("Work"), on: [park]) }
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// Renaming gives the label's messages the new keyword everywhere (Trash too), and deleting takes it off; messages
    /// kept on this Mac and in the book follow.
    @Test func renamingAndDeletingAKeywordLabelChangeItsMessagesEverywhere() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let store = LocalMailStore(folder: folder.appendingPathComponent("kept", isDirectory: true))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            .expect(#"A2 LIST "" "*""#, reply: Script.lines(#"* LIST (\HasNoChildren) "/" "INBOX""#,
                                                           #"* LIST (\HasNoChildren \Archive) "/" "Archive""#,
                                                           #"* LIST (\HasNoChildren \Trash) "/" "Trash""#, "A2 OK LIST completed")),
            Self.examine("A3", exists: 2),
            Script.ok("A4", "UID SEARCH KEYWORD PMail_Work", untagged: ["* SEARCH 11 12"]),
            Self.select("A5", exists: 2, keywords: true),
            Script.ok("A6", "UID STORE 11:12 +FLAGS.SILENT (PMail_Job)"),
            Script.ok("A7", "UID STORE 11:12 -FLAGS.SILENT (PMail_Work)"),
            Self.examine("A8", "Archive", exists: 0, uidValidity: 3),
            Self.examine("A9", "Trash", exists: 1, uidValidity: 5),
            Script.ok("A10", "UID SEARCH KEYWORD PMail_Work", untagged: ["* SEARCH 3"]),
            Self.select("A11", "Trash", exists: 1, uidValidity: 5, keywords: true),
            Script.ok("A12", "UID STORE 3 +FLAGS.SILENT (PMail_Job)"),
            Script.ok("A13", "UID STORE 3 -FLAGS.SILENT (PMail_Work)"),
            // Deleting it.
            Self.examine("A14", exists: 2),
            Script.ok("A15", "UID SEARCH KEYWORD PMail_Job", untagged: ["* SEARCH 11 12"]),
            Self.select("A16", exists: 2, keywords: true),
            Script.ok("A17", "UID STORE 11:12 -FLAGS.SILENT (PMail_Job)"),
            Self.examine("A18", "Archive", exists: 0, uidValidity: 3),
            Self.examine("A19", "Trash", exists: 1, uidValidity: 5),
            Script.ok("A20", "UID SEARCH KEYWORD PMail_Job", untagged: ["* SEARCH 3"]),
            Self.select("A21", "Trash", exists: 1, uidValidity: 5, keywords: true),
            Script.ok("A22", "UID STORE 3 -FLAGS.SILENT (PMail_Job)"),
        ])
        let imap = service([stream], book: book, store: store)
        let work = try await imap.createLabel(named: "Work", colorHex: "#16A766")
        try await book.noteKeywords(allowed: true)
        let kept = try await store.add(raw: Data(Self.hike.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        try await imap.perform(.addLabel(work.id), on: [kept])
        try await book.assign(work.id, to: [MessageSummary(id: "elsewhere", messageIDHeader: "<booked@example.com>")])

        // Only the case changing keeps the keyword, so the server isn't needed.
        let shouting = try await imap.updateLabel(work, name: "WORK", colorHex: "#FF0000")
        #expect(shouting == MailFolder(id: "PMail_Work", name: "WORK", kind: .label, colorHex: "#FF0000"))
        #expect(stream.linesSoFar.isEmpty)

        let job = try await imap.updateLabel(shouting, name: "Job", colorHex: nil)
        #expect(job == MailFolder(id: "PMail_Job", name: "Job", kind: .label, colorHex: "#FF0000"))
        #expect(await store.summary(for: kept.id)?.labelIDs == ["PMail_Job"])
        #expect(await book.messages(withLabel: "PMail_Job").map(\.key) == ["booked@example.com"])
        await #expect(throws: PMailError.server("There’s already a label called “Job”.")) {
            try await imap.createLabel(named: "job", colorHex: nil)
        }

        try await imap.deleteLabel(job)
        #expect(await store.summary(for: kept.id)?.labelIDs == [])
        #expect(await book.labels().isEmpty)
        #expect(await book.messages(withLabel: "PMail_Job").isEmpty)
        // A server still listing the old keywords in a mailbox's FLAGS doesn't bring them back.
        #expect(await book.discover(["PMail_Work", "PMail_Job"]) == false)
        await #expect(throws: PMailError.notFound) { try await imap.perform(.addLabel("PMail_Job"), on: [kept]) }
        try await imap.deleteLabel(job)  // Already gone.
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// A server that doesn't take keywords: labels are kept on this Mac by Message-ID, show on the server's messages,
    /// and listing a label finds its messages wherever they are.
    @Test func withoutKeywordsLabelsAreKeptOnThisMacByMessageID() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let park = Self.row(1, uid: 11, flags: #"\Seen"#, subject: "Park day", messageID: "<park@example.com>")
        let lunch = Self.row(2, uid: 12, flags: "", subject: "Lunch", messageID: "<lunch@example.com>",
                             date: "Sun, 22 Nov 2026 12:00:00 +0000")
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.select("A2", keywords: false),
            // The list's row for message 12 came without its Message-ID, so it's asked for.
            Script.ok("A3", "UID FETCH 12 (UID ENVELOPE)", untagged: [
                #"* 2 FETCH (UID 12 ENVELOPE ("Sun, 22 Nov 2026 12:00:00 +0000" "Lunch" NIL NIL NIL NIL NIL NIL NIL "#
                    + #""<lunch@example.com>"))"#,
            ]),
            // The inbox lists with the labels the book keeps.
            Self.examine("A4"),
            Script.ok("A5", "UID SEARCH ALL", untagged: ["* SEARCH 11 12 13"]),
            Script.ok("A6", "UID FETCH 11:13 \(Self.summaryFetch)", untagged: [
                park, lunch, Self.row(3, uid: 13, flags: "", subject: "Other", messageID: "<other@example.com>"),
            ]),
            // Listing the label fetches its messages where PMail labeled them, without searching the server (whose
            // searches may not find them).
            Script.ok("A7", "UID FETCH 11:12 \(Self.summaryFetch)", untagged: [park, lunch]),
            // Taking it off one; a message without a Message-ID can't have one.
            Self.select("A8", keywords: false),
            Script.ok("A9", "UID FETCH 13 (UID ENVELOPE)", untagged: [
                #"* 3 FETCH (UID 13 ENVELOPE ("Sun, 22 Nov 2026 12:00:00 +0000" "Other" NIL NIL NIL NIL NIL NIL NIL NIL))"#,
            ]),
        ])
        let imap = service([stream], book: book)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        let parkSummary = MessageSummary(id: IMAPMessageID.inbox(11), date: Self.date("2026-11-21T10:00:00Z"),
                                         messageIDHeader: "<park@example.com>")
        let lunchSummary = MessageSummary(id: IMAPMessageID.inbox(12), date: Self.date("2026-11-22T12:00:00Z"))
        try await imap.perform(.addLabel(work.id), on: [parkSummary, lunchSummary])
        #expect(await book.keywordsAllowed() == false)
        #expect(Set(await book.messages(withLabel: work.id).map(\.key)) == ["park@example.com", "lunch@example.com"])

        let inbox = try await imap.listConversations(ListRequest(folderID: "INBOX"))
        let rows = Dictionary(uniqueKeysWithValues: inbox.conversations.flatMap(\.messages).map { ($0.messageIDHeader ?? "", $0.labelIDs) })
        #expect(rows == ["<park@example.com>": ["PMail_Work"], "<lunch@example.com>": ["PMail_Work"], "<other@example.com>": []])

        let labeled = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(labeled.totalCount == 2)
        #expect(labeled.conversations.flatMap(\.messages).map(\.id) == [IMAPMessageID.inbox(12), IMAPMessageID.inbox(11)])
        #expect(labeled.conversations.allSatisfy { $0.labelIDs == ["PMail_Work"] })

        try await imap.perform(.removeLabel(work.id), on: [parkSummary])
        #expect(await book.messages(withLabel: work.id).map(\.key) == ["lunch@example.com"])
        await #expect(throws: PMailError.notSupported("A message without a Message-ID can’t be labeled on this server.")) {
            try await imap.perform(.addLabel(work.id), on: [MessageSummary(id: IMAPMessageID.inbox(13))])
        }
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// A label kept on this Mac from before PMail noted where its messages are, on a server whose searches find
    /// nothing (as an iCloud account's may not): once the inbox has shown the message, the label lists it, fetched
    /// where it is with no search, and forgets that place once the message no longer has the label.
    @Test func aLabelListsItsMessagesWithoutTheServersSearches() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let work = try await book.create(named: "Work", colorHex: nil)
        let kept = MessageSummary(id: "earlier", messageIDHeader: "<park@example.com>")
        _ = try await book.assign(work.id, to: [kept])
        try await book.noteKeywords(allowed: false)
        let park = Self.row(1, uid: 11, flags: #"\Seen"#, subject: "Park day", messageID: "<park@example.com>")
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            // The inbox lists with the label the book keeps, and where that message is gets noted.
            Self.examine("A2"),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 11 12"]),
            Script.ok("A4", "UID FETCH 11:12 \(Self.summaryFetch)", untagged: [
                park, Self.row(2, uid: 12, flags: "", subject: "Other", messageID: "<other@example.com>"),
            ]),
            // The label lists it from there, without searching.
            Script.ok("A5", "UID FETCH 11 \(Self.summaryFetch)", untagged: [park]),
            // Once the label is off it, the place is forgotten.
            Script.ok("A6", "UID FETCH 11 \(Self.summaryFetch)", untagged: [park]),
        ])
        let imap = service([stream], book: book)
        _ = try await imap.listConversations(ListRequest(folderID: "INBOX"))
        #expect(await book.places(withLabel: work.id) == [IMAPMessageID.inbox(11)], "only the labeled message's place")

        let page = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(page.conversations.flatMap(\.messages).map(\.subject) == ["Park day"] && page.totalCount == 1)
        #expect(page.conversations.first?.labelIDs == [work.id])

        try await book.unassign(work.id, from: [kept])
        let after = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(after.conversations.isEmpty && after.totalCount == 0)
        #expect(await book.places(withLabel: work.id).isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// A server that says it takes keywords but doesn't keep them: the label is kept on this Mac instead (and every
    /// label after it), and listing the label still finds its conversation on the server.
    @Test func keywordsAServerDropsAreKeptOnThisMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.select("A2", keywords: true),
            // The server answers without the keyword, and doesn't report the second message at all.
            Script.ok("A3", "UID STORE 11:12 +FLAGS (PMail_Work)", untagged: [#"* 2 FETCH (UID 11 FLAGS (\Seen))"#]),
            Script.ok("A4", "UID FETCH 12 (UID FLAGS)", untagged: ["* 3 FETCH (UID 12 FLAGS (PMail_Work))"]),
            // Later labels go straight to the book. Listing fetches both messages where PMail labeled them: one has the
            // label in the book, the other kept its keyword.
            Script.ok("A5", "UID FETCH 11:12 \(Self.summaryFetch)", untagged: [
                Self.row(2, uid: 11, flags: #"\Seen"#, subject: "Park day", messageID: "<park@example.com>"),
                Self.row(3, uid: 12, flags: "PMail_Work", subject: "Lunch", messageID: "<lunch@example.com>"),
            ]),
        ])
        let imap = service([stream], book: book)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        let park = MessageSummary(id: IMAPMessageID.inbox(11), messageIDHeader: "<park@example.com>")
        let lunch = MessageSummary(id: IMAPMessageID.inbox(12), messageIDHeader: "<lunch@example.com>")
        try await imap.perform(.addLabel(work.id), on: [park, lunch])
        #expect(await book.keywordsIgnored(), "the server is known to drop them")
        #expect(await book.keywordsAllowed() == false)
        #expect(await book.messages(withLabel: work.id).map(\.key) == ["park@example.com"], "the dropped one is kept here")

        let page = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(page.conversations.flatMap(\.messages).map(\.subject) == ["Park day", "Lunch"], "the label lists its conversations")
        #expect(page.conversations.flatMap(\.messages).allSatisfy { $0.labelIDs == [work.id] })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// A mailbox the server only opens read-only can't take keywords, so its labels are kept on this Mac, without
    /// deciding anything about the rest of the server.
    @Test func aReadOnlyMailboxKeepsItsLabelsOnThisMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            .expect(#"A2 SELECT "Shared""#, reply: Script.lines(
                #"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)"#, "* OK [PERMANENTFLAGS ()] No changes here",
                "* 2 EXISTS", "* OK [UIDVALIDITY 4] UIDs valid", "A2 OK [READ-ONLY] Opened read-only")),
        ])
        let imap = service([stream], book: book)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        let shared = MessageSummary(id: IMAPMessageID(mailbox: "Shared", uidValidity: 4, uid: 9).rawValue,
                                    messageIDHeader: "<shared@example.com>")
        try await imap.perform(.addLabel(work.id), on: [shared])
        #expect(await book.messages(withLabel: work.id).map(\.key) == ["shared@example.com"])
        #expect(await book.keywordsAllowed() == nil)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// Mail an earlier PMail kept on this Mac keeps its labels (its keywords and those the book keeps), lists under
    /// them without asking the server, and moving it back to the inbox leaves its labels in the book.
    @Test func labelsStayWithMessagesKeptOnThisMacAndBack() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let store = LocalMailStore(folder: folder.appendingPathComponent("kept", isDirectory: true))
        let hike = Self.hike
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.inboxOnlyCapabilities), script: [
            Script.signIn("A1", capabilities: Self.inboxOnlyCapabilities),
            .expect("A2 APPEND \"INBOX\" (\\Seen) {\(hike.utf8.count)+}", reply: ""),
            .expectBytes(hike.utf8.count, reply: ""),
            .expect("", reply: "A2 OK [APPENDUID 7 101] APPEND completed\r\n"),
        ])
        let imap = service([stream], book: book, store: store)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        try await book.noteKeywords(allowed: false)
        let kept = try await store.add(raw: Data(hike.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        try await store.setLabelIDs(["PMail_Trip", work.id], for: [kept.id])
        let archived = try #require(await store.summary(for: kept.id))
        #expect(archived.labelIDs == ["PMail_Trip", "PMail_Work"])

        // The label lists it from this Mac, without asking the server.
        let page = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(page.conversations.flatMap(\.messages).map(\.id) == [archived.id] && page.totalCount == 1)

        try await imap.perform(.removeLabel("PMail_Trip"), on: [archived])
        let current = try #require(await store.summary(for: archived.id))
        #expect(current.labelIDs == ["PMail_Work"])
        try await imap.perform(.moveToInbox, on: [current])
        #expect(await store.summaries(in: LocalFolders.archiveID).isEmpty)
        #expect(await book.messages(withLabel: work.id).map(\.key) == ["hike@example.com"])
        #expect(await book.messages(withLabel: "PMail_Trip").isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// On a server without keywords, a label whose messages are all kept on this Mac lists (and searches) without
    /// connecting: the connector here has no connections to give.
    @Test func keptLabeledMessagesListWithoutTheServer() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let store = LocalMailStore(folder: folder.appendingPathComponent("kept", isDirectory: true))
        let imap = service([], book: book, store: store)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        try await book.noteKeywords(allowed: false)
        let kept = try await store.add(raw: Data(Self.hike.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        let binned = try await store.add(raw: Data(Self.hike.utf8), folderID: LocalFolders.trashID, isUnread: false)
        try await imap.perform(.addLabel(work.id), on: [kept, binned])
        let page = try await imap.listConversations(ListRequest(folderID: work.id))
        #expect(page.conversations.flatMap(\.messages).map(\.id) == [kept.id] && page.totalCount == 1)
        #expect(try await imap.listConversations(ListRequest(folderID: work.id, query: "saturday")).totalCount == 1)
        #expect(try await imap.listConversations(ListRequest(folderID: work.id, query: "sunday")).totalCount == 0)
    }

    /// On a server that takes keywords, a message moved back from this Mac goes up with its label keywords.
    @Test func keptMessagesGoBackWithTheirKeywords() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let store = LocalMailStore(folder: folder.appendingPathComponent("kept", isDirectory: true))
        let hike = Self.hike
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.inboxOnlyCapabilities), script: [
            Script.signIn("A1", capabilities: Self.inboxOnlyCapabilities),
            .expect("A2 APPEND \"INBOX\" (\\Seen PMail_Work) {\(hike.utf8.count)+}", reply: ""),
            .expectBytes(hike.utf8.count, reply: ""),
            .expect("", reply: "A2 OK [APPENDUID 7 101] APPEND completed\r\n"),
        ])
        let imap = service([stream], book: book, store: store)
        _ = try await imap.createLabel(named: "Work", colorHex: nil)
        try await book.noteKeywords(allowed: true)
        let kept = try await store.add(raw: Data(hike.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        try await store.setLabelIDs(["PMail_Work"], for: [kept.id])
        let archived = try #require(await store.summary(for: kept.id))
        try await imap.perform(.moveToInbox, on: [archived])
        #expect(await store.summaries(in: LocalFolders.archiveID).isEmpty)
        #expect(await book.messages(withLabel: "PMail_Work").isEmpty, "the server keeps it")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// Labels made on another Mac show up: from a mailbox's FLAGS and from the messages listed, whatever case the
    /// server spells them in.
    @Test func labelsMadeOnAnotherMacShowUp() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Self.examine("A2", exists: 1, flags: " PMail_Old_Plans PMail_Trip"),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 5"]),
            Script.ok("A4", "UID FETCH 5 \(Self.summaryFetch)", untagged: [
                Self.row(1, uid: 5, flags: #"\Seen pmail_trip PMail_Caf&C3&A9 $Forwarded"#, subject: "Coffee",
                         messageID: "<coffee@example.com>"),
            ]),
            Script.list("A5"),
            Self.status("A6", "INBOX"),
            Self.status("A7", "Sent Messages"),
            Self.status("A8", "Drafts"),
            Self.status("A9", "Deleted Messages"),
            Self.status("A10", "Junk"),
            Self.status("A11", "Archive"),
        ])
        let imap = service([stream], book: book)
        let page = try await imap.listConversations(ListRequest(folderID: "INBOX"))
        #expect(page.conversations.first?.messages.first?.labelIDs == ["PMail_Trip", "PMail_Caf&C3&A9"])
        let folders = try await imap.loadFolders()
        let labels = folders.filter { $0.kind == .label }
        #expect(labels.map(\.name) == ["Café", "Old Plans", "Trip"])
        #expect(labels.map(\.id) == ["PMail_Caf&C3&A9", "PMail_Old_Plans", "PMail_Trip"])
        #expect(folders.prefix(2).map(\.id) == ["INBOX", IMAPMailService.starredFolderID])
        #expect(folders.suffix(3).map(\.kind) == [.label, .label, .label], "labels come after the server's folders")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// With an All Mail folder, a label is searched for there alone; a search narrows it, and it pages by arrival.
    @Test func aLabelIsSearchedForInAllMailAndPaged() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            .expect(#"A2 LIST "" "*""#, reply: Script.lines(#"* LIST (\HasNoChildren) "/" "INBOX""#,
                                                           #"* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail""#,
                                                           #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#, "A2 OK LIST completed")),
            Self.examine("A3", "[Gmail]/All Mail", exists: 50, uidValidity: 11),
            Script.ok("A4", #"UID SEARCH KEYWORD PMail_Work OR OR FROM "frisbee" SUBJECT "frisbee" TEXT "frisbee""#,
                      untagged: ["* SEARCH 30 31"]),
            Script.ok("A5", "UID FETCH 30:31 (UID INTERNALDATE)", untagged: [
                #"* 20 FETCH (UID 30 INTERNALDATE "20-Nov-2026 10:00:00 +0000")"#,
                #"* 21 FETCH (UID 31 INTERNALDATE "21-Nov-2026 10:00:00 +0000")"#,
            ]),
            Script.ok("A6", "UID FETCH 31 \(Self.summaryFetch)", untagged: [
                Self.row(21, uid: 31, flags: "PMail_Work", subject: "Frisbee", messageID: "<frisbee-2@example.com>"),
            ]),
        ])
        let imap = service([stream], book: book)
        let work = try await imap.createLabel(named: "Work", colorHex: nil)
        let page = try await imap.listConversations(ListRequest(folderID: work.id, query: "frisbee", pageSize: 1))
        #expect(page.totalCount == 2 && page.nextPageToken == "1")
        #expect(page.conversations.flatMap(\.messages).map(\.id)
                == [IMAPMessageID(mailbox: "[Gmail]/All Mail", uidValidity: 11, uid: 31).rawValue])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }
}
