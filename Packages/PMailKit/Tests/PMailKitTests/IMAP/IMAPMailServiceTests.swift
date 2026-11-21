import Foundation
import Testing
@testable import PMailKit

@Suite(.timeLimit(.minutes(1))) struct IMAPMailServiceTests {
    private typealias Script = IMAPScript

    private static func status(_ tag: String, _ mailbox: String, messages: Int, unseen: Int) -> ScriptedByteStream.Step {
        let name = IMAPMailboxName.encode(mailbox)
        return .expect("\(tag) STATUS \"\(name)\" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)", reply: Script.lines(
            "* STATUS \"\(name)\" (MESSAGES \(messages) UNSEEN \(unseen) UIDNEXT 100 UIDVALIDITY 7)", "\(tag) OK STATUS completed"))
    }

    private static let summaryFetch = "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE "
        + "BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)])"

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private static let pug = MailAddress(name: "Pug Tester", email: "pug@example.com")
    private static let alex = MailAddress(name: "Alex Kim", email: "alex@example.com")

    @Test func capabilitiesOfAnIMAPAccount() {
        let harness = IMAPHarness([])
        let capabilities = harness.service.capabilities
        #expect(!capabilities.usesLabels && capabilities.canStar && !capabilities.canMarkImportant && !capabilities.hasInboxTabs)
        #expect(capabilities.searchesOnServer && capabilities.canArchive && capabilities.supportsDrafts && capabilities.canMove)
        #expect(harness.service.inboxTabs.isEmpty)
    }

    @Test func foldersWithRolesAndCounts() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2", extra: [#"* LIST (\HasChildren) "/" "Projects""#, #"* LIST (\HasNoChildren) "/" "Projects/Caf&AOk-""#,
                                      #"* LIST (\Noselect \HasChildren) "/" "Old""#]),
            Self.status("A3", "INBOX", messages: 12, unseen: 3),
            Self.status("A4", "Sent Messages", messages: 40, unseen: 0),
            Self.status("A5", "Drafts", messages: 2, unseen: 0),
            Self.status("A6", "Deleted Messages", messages: 5, unseen: 1),
            Self.status("A7", "Junk", messages: 9, unseen: 9),
            Self.status("A8", "Archive", messages: 300, unseen: 0),
            Self.status("A9", "Projects", messages: 1, unseen: 0),
            .expect(#"A10 STATUS "Projects/Caf&AOk-" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
                    reply: "A10 NO Mailbox is locked\r\n"),
        ])
        let harness = IMAPHarness([stream])
        let folders = try await harness.service.loadFolders()
        #expect(folders.map(\.id) == ["INBOX", "pmail:starred", "Sent Messages", "Drafts", "Deleted Messages", "Junk", "Archive",
                                      "Projects", "Projects/Café", "Old"])
        #expect(folders.map(\.role) == [.inbox, .starred, .sent, .drafts, .trash, .spam, .archive, nil, nil, nil])
        #expect(folders[0].name == "Inbox" && folders[0].unreadCount == 3 && folders[0].totalCount == 12)
        #expect(folders[1].name == "Starred" && folders[1].isSelectable)
        #expect(folders[5].unreadCount == 9 && folders[6].totalCount == 300)
        #expect(folders[8].name == "Café" && folders[8].parentID == "Projects")
        #expect(folders[8].unreadCount == 0 && folders[8].totalCount == nil)
        #expect(!folders[9].isSelectable && folders[9].parentID == nil)
        #expect(folders.allSatisfy { $0.kind == .folder })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func rolesByTheirUsualNames() {
        let boxes = [
            IMAPMailbox(name: "INBOX", delimiter: "."),
            IMAPMailbox(name: "INBOX.Sent Items", delimiter: "."),
            IMAPMailbox(name: "INBOX.Drafts", delimiter: "."),
            IMAPMailbox(name: "Trash", delimiter: "."),
            IMAPMailbox(name: "Spam", delimiter: "."),
            IMAPMailbox(name: "Work.Archive", delimiter: "."),
            IMAPMailbox(name: "Archives", delimiter: "."),
            IMAPMailbox(name: "Bin", delimiter: ".", attributes: ["\\Noselect"]),
        ]
        #expect(IMAPFolderRoles.assign(boxes) == ["INBOX": .inbox, "INBOX.Sent Items": .sent, "INBOX.Drafts": .drafts,
                                                  "Trash": .trash, "Spam": .spam, "Archives": .archive])
        let flagged = [IMAPMailbox(name: "Sent"), IMAPMailbox(name: "Outbox Copies", attributes: ["\\Sent"]),
                       IMAPMailbox(name: "All Mail", attributes: ["\\All"])]
        #expect(IMAPFolderRoles.assign(flagged) == ["Outbox Copies": .sent, "All Mail": .allMail])
    }

    @Test func aPageOfConversationsWithSnippets() async throws {
        let replyHeaders = "References: <root@example.com>\r\nIn-Reply-To: <root@example.com>\r\n\r\n"
        let first = #"* 2 FETCH (UID 11 FLAGS (\Seen) INTERNALDATE "21-Nov-2026 18:45:05 +0000" RFC822.SIZE 1200 "#
            + #"ENVELOPE ("Sat, 21 Nov 2026 13:45:00 -0500" "Park day" (("Alex Kim" NIL "alex" "example.com")) "#
            + #"(("Alex Kim" NIL "alex" "example.com")) (("Alex Kim" NIL "alex" "example.com")) ((NIL NIL "pug" "example.com")) "#
            + #"NIL NIL NIL "<root@example.com>") "#
            + #"BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 60 2 NIL NIL NIL NIL) "#
            + #"BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] {2}"# + "\r\n\r\n)"
        let second = #"* 3 FETCH (UID 12 FLAGS (\Flagged) INTERNALDATE "21-Nov-2026 19:00:09 +0000" RFC822.SIZE 3400 "#
            + #"ENVELOPE ("Sat, 21 Nov 2026 14:00:00 -0500" "Re: Park day" (("Sam" NIL "sam" "example.org")) "#
            + #"(("Sam" NIL "sam" "example.org")) (("Sam" NIL "sam" "example.org")) ((NIL NIL "pug" "example.com")) "#
            + #"(("Alex Kim" NIL "alex" "example.com")) NIL "<root@example.com>" "<reply@example.org>") "#
            + #"BODYSTRUCTURE ((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "BASE64" 80 2 NIL NIL NIL NIL)"#
            + #"("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "BASE64" 200 4 NIL NIL NIL NIL) "#
            + #""ALTERNATIVE" ("BOUNDARY" "a") NIL NIL NIL)"#
            + #"("IMAGE" "JPEG" ("NAME" "pug.jpg") NIL NIL "BASE64" 9000 NIL ("ATTACHMENT" ("FILENAME" "pug.jpg")) NIL NIL) "#
            + #""MIXED" ("BOUNDARY" "m") NIL NIL NIL) BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] "#
            + Script.literal(replyHeaders) + ")"
        let quoted = "See you at the park =\r\nat noon! =F0=9F=90=B6\r\n"
        let base64 = Data("Count me in, I’ll bring the frisbee.".utf8).base64EncodedString()
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 10 11 12"]),
            .expect("A4 UID FETCH 11:12 \(Self.summaryFetch)",
                    reply: Script.lines("* 5 EXISTS", first, second, "A4 OK Fetch completed")),
            .expect("A5 UID FETCH 11 (UID BODY.PEEK[1]<0.2048>)", reply: Script.lines(
                "* 2 FETCH (UID 11 BODY[1]<0> \(Script.literal(quoted)))", "A5 OK Done")),
            .expect("A6 UID FETCH 12 (UID BODY.PEEK[1.1]<0.2048>)", reply: Script.lines(
                "* 3 FETCH (UID 12 BODY[1.1]<0> \(Script.literal(base64 + "\r\n")))", "A6 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        let page = try await harness.service.listConversations(ListRequest(folderID: "INBOX", pageSize: 2))
        #expect(page.totalCount == 3 && page.nextPageToken == "1")
        #expect(page.conversations.count == 1)
        let conversation = try #require(page.conversations.first)
        #expect(conversation.id == "<root@example.com>")
        #expect(conversation.messages.map(\.id) == [IMAPMessageID.inbox(11), IMAPMessageID.inbox(12)])
        #expect(conversation.subject == "Park day" && conversation.snippet == "Count me in, I’ll bring the frisbee.")
        let original = conversation.messages[0]
        #expect(original.snippet == "See you at the park at noon! 🐶")
        #expect(!original.isUnread && !original.isStarred && !original.hasAttachments && original.size == 1200)
        #expect(original.from == Self.alex && original.folderID == "INBOX")
        #expect(original.date == (try Self.date("2026-11-21T18:45:00Z")))
        let reply = conversation.messages[1]
        #expect(reply.isUnread && reply.isStarred && reply.hasAttachments)
        #expect(reply.references == ["<root@example.com>"] && reply.inReplyTo == "<root@example.com>")
        #expect(reply.messageIDHeader == "<reply@example.org>" && reply.cc.map(\.email) == ["alex@example.com"])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func searchingTheStarredFolderPageByPage() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", #"UID SEARCH FLAGGED OR OR FROM "frisbee" SUBJECT "frisbee" TEXT "frisbee""#,
                      untagged: ["* SEARCH 12 4 9"]),
            .expect("A4 UID FETCH 4 \(Self.summaryFetch)", reply: Script.lines(
                #"* 1 FETCH (UID 4 FLAGS (\Seen \Flagged) ENVELOPE (NIL "Old news" NIL NIL NIL NIL NIL NIL NIL NIL) "#
                    + #"BODYSTRUCTURE ("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1) "#
                    + #"BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] NIL)"#,
                "A4 OK Done")),
            .expect("A5 UID FETCH 4 (UID BODY.PEEK[1]<0.2048>)",
                    reply: Script.lines(#"* 1 FETCH (UID 4 BODY[1]<0> "hello")"#, "A5 OK Done")),
            Script.select("A6", "Archive", exists: 0, uidValidity: 3, readOnly: true),
        ])
        let harness = IMAPHarness([stream])
        let request = ListRequest(folderID: IMAPMailService.starredFolderID, query: "frisbee", pageSize: 2, pageToken: "1")
        let page = try await harness.service.listConversations(request)
        #expect(page.totalCount == 3 && page.nextPageToken == nil)
        let message = try #require(page.conversations.first?.messages.first)
        #expect(message.id == IMAPMessageID.inbox(4) && message.threadID == IMAPMessageID.inbox(4))
        #expect(message.subject == "Old news" && message.snippet == "hello" && message.isStarred)
        let empty = try await harness.service.listConversations(ListRequest(folderID: "Archive"))
        #expect(empty.conversations.isEmpty && empty.totalCount == 0 && empty.nextPageToken == nil)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func conversationsIncludeRepliesFromSent() async throws {
        let original = "From: Alex Kim <alex@example.com>\r\nSubject: Park day\r\nMessage-ID: <root@example.com>\r\n"
            + "\r\nSee you at the park!\r\n"
        let mine = "From: Pug Tester <pug@example.com>\r\nSubject: Re: Park day\r\nMessage-ID: <mine@example.com>\r\n"
            + "In-Reply-To: <root@example.com>\r\nReferences: <root@example.com>\r\n\r\nWouldn't miss it.\r\n"
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", readOnly: true),
            .expect("A3 UID FETCH 11 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                #"* 2 FETCH (UID 11 FLAGS (\Seen) BODY[] "# + Script.literal(original) + ")", "A3 OK Done")),
            Script.list("A4"),
            Script.select("A5", "Sent Messages", exists: 2, uidValidity: 9, readOnly: true),
            Script.ok("A6", #"UID SEARCH OR OR HEADER References "<root@example.com>" HEADER In-Reply-To "<root@example.com>" "#
                + #"HEADER Message-ID "<root@example.com>""#, untagged: ["* SEARCH 5"]),
            .expect("A7 UID FETCH 5 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE "
                + "BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] BODY.PEEK[])", reply: Script.lines(
                #"* 1 FETCH (UID 5 FLAGS (\Seen) ENVELOPE ("Sat, 21 Nov 2026 15:00:00 -0500" "Re: Park day" "#
                    + #"(("Pug Tester" NIL "pug" "example.com")) NIL NIL (("Alex Kim" NIL "alex" "example.com")) NIL NIL "#
                    + #""<root@example.com>" "<mine@example.com>") "#
                    + #"BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1) "#
                    + "BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)] "
                    + Script.literal("References: <root@example.com>\r\n\r\n") + " BODY[] " + Script.literal(mine) + ")",
                "A7 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        let summary = MessageSummary(id: IMAPMessageID.inbox(11), threadID: "<root@example.com>", folderID: "INBOX",
                                     from: Self.alex, subject: "Park day", date: try Self.date("2026-11-21T18:45:00Z"),
                                     isUnread: true, messageIDHeader: "<root@example.com>")
        let hint = Conversation(id: "<root@example.com>", messages: [summary])
        let messages = try await harness.service.loadConversation(id: "<root@example.com>", hint: hint)
        #expect(messages.count == 2)
        #expect(messages[0].id == IMAPMessageID.inbox(11) && !messages[0].summary.isUnread)
        #expect(messages[0].textBody?.contains("See you at the park!") == true)
        #expect(messages[0].rawSource == Data(original.utf8))
        #expect(messages[1].id == IMAPMessageID(mailbox: "Sent Messages", uidValidity: 9, uid: 5).rawValue)
        #expect(messages[1].summary.threadID == "<root@example.com>" && messages[1].summary.folderID == "Sent Messages")
        #expect(messages[1].summary.from?.email == "pug@example.com")
        #expect(messages[1].textBody?.contains("Wouldn't miss it.") == true)
        #expect(!stream.lines.contains { $0.contains("STORE") || $0.contains("SELECT") })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func readAndStarFlags() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2"),
            Script.ok("A3", #"UID STORE 11:12 +FLAGS.SILENT (\Seen)"#),
            Script.ok("A4", #"UID STORE 12 +FLAGS.SILENT (\Flagged)"#),
            Script.ok("A5", #"UID STORE 11 -FLAGS.SILENT (\Seen)"#),
            Script.ok("A6", #"UID STORE 12 -FLAGS.SILENT (\Flagged)"#),
            Script.select("A7", "Junk", exists: 4, uidValidity: 2),
            Script.ok("A8", #"UID STORE 3 +FLAGS.SILENT (\Seen)"#),
        ])
        let harness = IMAPHarness([stream])
        let eleven = MessageSummary(id: IMAPMessageID.inbox(11))
        let twelve = MessageSummary(id: IMAPMessageID.inbox(12))
        try await harness.service.perform(.markRead, on: [eleven, twelve])
        try await harness.service.perform(.star, on: [twelve])
        try await harness.service.perform(.markUnread, on: [eleven])
        try await harness.service.perform(.unstar, on: [twelve])
        let junk = MessageSummary(id: IMAPMessageID(mailbox: "Junk", uidValidity: 2, uid: 3).rawValue)
        try await harness.service.perform(.markRead, on: [junk, MessageSummary(id: "not an imap id")])
        await #expect(throws: PMailError.self) { try await harness.service.perform(.markImportant, on: [eleven]) }
        await #expect(throws: PMailError.self) { try await harness.service.perform(.addLabel("Work"), on: [eleven]) }
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func archivingMovesToTheArchiveFolder() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2"),
            Script.select("A3"),
            Script.ok("A4", #"UID MOVE 11 "Archive""#, untagged: ["* OK [COPYUID 3 11 1] Moved", "* 2 EXPUNGE"]),
            Script.ok("A5", #"UID MOVE 12 "Junk""#),
            Script.select("A6", "Junk", exists: 1, uidValidity: 2),
            Script.ok("A7", #"UID MOVE 3 "INBOX""#),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        try await harness.service.perform(.markSpam, on: [MessageSummary(id: IMAPMessageID.inbox(12))])
        let junk = MessageSummary(id: IMAPMessageID(mailbox: "Junk", uidValidity: 2, uid: 3).rawValue)
        try await harness.service.perform(.notSpam, on: [junk])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func archivingWithoutMoveCopiesThenExpunges() async throws {
        let capabilities = "IMAP4rev1 SASL-IR AUTH=PLAIN SPECIAL-USE UIDPLUS LITERAL+"
        let stream = ScriptedByteStream(greeting: Script.greeting(capabilities), script: [
            Script.signIn("A1", capabilities: capabilities),
            Script.list("A2"),
            Script.select("A3"),
            .expect(#"A4 UID COPY 11 "Archive""#, reply: "A4 OK [COPYUID 3 11 1] Copied\r\n"),
            Script.ok("A5", #"UID STORE 11 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A6", "UID EXPUNGE 11", untagged: ["* 2 EXPUNGE"]),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func archivingNeedsAnArchiveFolder() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            .expect(#"A2 LIST "" "*" RETURN (SPECIAL-USE)"#, reply: Script.lines(#"* LIST () "/" "INBOX""#, "A2 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        await #expect(throws: PMailError.notSupported("This account has no Archive folder.")) {
            try await harness.service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        }
        await #expect(throws: PMailError.notSupported("This account has no Trash folder.")) {
            try await harness.service.perform(.trash, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        }
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func trashingAndDeletingForever() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2"),
            Script.select("A3"),
            Script.ok("A4", #"UID MOVE 11 "Deleted Messages""#),
            Script.select("A5", "Deleted Messages", exists: 2, uidValidity: 5),
            Script.ok("A6", #"UID STORE 1 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A7", "UID EXPUNGE 1"),
            Script.select("A8"),
            Script.ok("A9", #"UID STORE 12 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A10", "UID EXPUNGE 12"),
            Script.select("A11", "Junk", exists: 1, uidValidity: 2),
            Script.ok("A12", #"UID STORE 3 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A13", "UID EXPUNGE 3"),
            Script.select("A14", exists: 2, uidValidity: 8),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.perform(.trash, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        let trashed = MessageSummary(id: IMAPMessageID(mailbox: "Deleted Messages", uidValidity: 5, uid: 1).rawValue)
        try await harness.service.perform(.trash, on: [trashed])
        let junk = MessageSummary(id: IMAPMessageID(mailbox: "Junk", uidValidity: 2, uid: 3).rawValue)
        try await harness.service.perform(.deleteForever, on: [MessageSummary(id: IMAPMessageID.inbox(12)), junk])
        // UIDs from before the mailbox's UIDVALIDITY changed are never acted on.
        await #expect(throws: PMailError.notFound) {
            try await harness.service.perform(.markRead, on: [MessageSummary(id: IMAPMessageID.inbox(13))])
        }
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func sendingFilesACopyInSent() async throws {
        let message = OutgoingMessage(from: Self.pug, to: [Self.alex], cc: [MailAddress(email: "sam@example.org")],
                                      bcc: [MailAddress(email: "secret@example.net")], subject: "Park day",
                                      textBody: "See you there!", messageID: "<sent-1@example.com>",
                                      date: try Self.date("2026-11-21T20:00:00Z"))
        let raw = MIMEBuilder.build(message)
        let copy = MIMEBuilder.buildForSaving(message)
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2"),
            .expect(#"A3 APPEND "Sent Messages" (\Seen) {\#(copy.count)+}"#, reply: ""),
            .expectBytes(copy.count, reply: ""),
            .expect("", reply: "A3 OK [APPENDUID 9 6] APPEND completed\r\n"),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.send(message)
        let sent = try #require(harness.sender.sent.first)
        #expect(harness.sender.sent.count == 1)
        #expect(sent.from == "pug@example.com" && sent.to == ["alex@example.com", "sam@example.org", "secret@example.net"])
        #expect(sent.raw == raw)
        // What goes out never names the Bcc recipients; the copy in Sent does.
        #expect(!String(decoding: raw, as: UTF8.self).contains("Bcc:"))
        #expect(String(decoding: copy, as: UTF8.self).contains("Bcc: secret@example.net"))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func sendingWithoutASentFolderStillSends() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            .expect(#"A2 LIST "" "*" RETURN (SPECIAL-USE)"#, reply: Script.lines(#"* LIST () "/" "INBOX""#, "A2 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        try await harness.service.send(OutgoingMessage(from: Self.pug, to: [Self.alex]))
        #expect(harness.sender.sent.count == 1)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func savingADraftReplacesTheOldOne() async throws {
        let message = OutgoingMessage(from: Self.pug, to: [Self.alex], bcc: [MailAddress(email: "secret@example.net")],
                                      subject: "Draft plans", textBody: "Thinking about\nSaturday",
                                      references: ["<root@example.com>"], messageID: "<draft-2@example.com>",
                                      date: try Self.date("2026-11-21T21:00:00Z"))
        let raw = MIMEBuilder.buildForSaving(message)
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2"),
            .expect(#"A3 APPEND "Drafts" (\Draft \Seen) {\#(raw.count)+}"#, reply: ""),
            .expectBytes(raw.count, reply: ""),
            .expect("", reply: "A3 OK [APPENDUID 4 21] APPEND completed\r\n"),
            Script.select("A4", "Drafts", exists: 2, uidValidity: 4),
            Script.ok("A5", #"UID STORE 20 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A6", "UID EXPUNGE 20", untagged: ["* 1 EXPUNGE"]),
            Script.ok("A7", #"UID STORE 21 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A8", "UID EXPUNGE 21", untagged: ["* 1 EXPUNGE"]),
        ])
        let harness = IMAPHarness([stream])
        let old = MessageSummary(id: IMAPMessageID(mailbox: "Drafts", uidValidity: 4, uid: 20).rawValue, isDraft: true)
        let saved = try #require(try await harness.service.saveDraft(message, replacing: old))
        #expect(saved.id == IMAPMessageID(mailbox: "Drafts", uidValidity: 4, uid: 21).rawValue)
        #expect(saved.isDraft && !saved.isUnread && saved.folderID == "Drafts" && saved.threadID == "<root@example.com>")
        #expect(saved.subject == "Draft plans" && saved.snippet == "Thinking about Saturday")
        #expect(saved.messageIDHeader == "<draft-2@example.com>")
        try await harness.service.deleteDraft(saved)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func iCloudTriesTheOtherUserNameAndRemembersIt() async throws {
        let first = ScriptedByteStream(greeting: Script.greeting(), script: [
            .expect("A1 AUTHENTICATE PLAIN \(SASL.plain(username: "pug@icloud.com", password: "app-password"))",
                    reply: "A1 NO [AUTHENTICATIONFAILED] Authentication failed\r\n"),
            Script.signIn("A2", username: "pug", password: "app-password"),
            Script.select("A3"),
            Script.ok("A4", #"UID STORE 11 +FLAGS.SILENT (\Seen)"#),
            .expect("A5 LOGOUT", reply: "* BYE See you\r\nA5 OK Logged out\r\n"),
        ])
        let second = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1", username: "pug", password: "app-password"),
            Script.select("A2"),
            Script.ok("A3", #"UID STORE 11 -FLAGS.SILENT (\Seen)"#),
        ])
        let harness = IMAPHarness([first, second], kind: .icloud, email: "pug@icloud.com", username: "pug@icloud.com",
                                  host: "imap.mail.me.com", password: "app-password")
        let message = MessageSummary(id: IMAPMessageID.inbox(11))
        try await harness.service.perform(.markRead, on: [message])
        await harness.service.close()
        try await harness.service.perform(.markUnread, on: [message])
        #expect(first.mismatches.isEmpty && first.isFinished && first.closed)
        #expect(second.mismatches.isEmpty && second.isFinished)
        #expect(harness.connector.connections.count == 2)
    }

    @Test func otherServersDoNotGetASecondGuess() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            .expect("A1 AUTHENTICATE PLAIN \(SASL.plain(username: "pug@example.com", password: "secret"))",
                    reply: "A1 NO [AUTHENTICATIONFAILED] Authentication failed\r\n"),
        ])
        let harness = IMAPHarness([stream])
        await #expect(throws: PMailError.authenticationFailed("Authentication failed")) {
            try await harness.service.perform(.markRead, on: [MessageSummary(id: IMAPMessageID.inbox(11))])
        }
        #expect(stream.mismatches.isEmpty && stream.isFinished && stream.closed)
    }

    @Test func reconnectsOnceWhenTheConnectionHasDropped() async throws {
        let first = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2"),
            Script.ok("A3", #"UID STORE 11 +FLAGS.SILENT (\Seen)"#),
        ])
        let second = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2"),
            Script.ok("A3", #"UID STORE 11 +FLAGS.SILENT (\Flagged)"#),
        ])
        let harness = IMAPHarness([first, second])
        let message = MessageSummary(id: IMAPMessageID.inbox(11))
        try await harness.service.perform(.markRead, on: [message])
        first.close()  // The server hangs up while PMail is idle.
        try await harness.service.perform(.star, on: [message])
        #expect(first.lines.last == #"A4 UID STORE 11 +FLAGS.SILENT (\Flagged)"#)
        #expect(second.mismatches.isEmpty && second.isFinished)
        #expect(harness.connector.connections.count == 2)
    }

    @Test func messagesAndAttachmentsAreLoadedWithoutMarkingThemRead() async throws {
        let pdf = Data("%PDF-1.4 pretend document".utf8)
        let base64 = pdf.base64EncodedString()
        let raw = "From: Sam <sam@example.org>\r\nSubject: Report\r\nMessage-ID: <report@example.org>\r\n\r\nHere it is.\r\n"
        let structure = #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 12 1)("APPLICATION" "PDF" ("NAME" "a.pdf") NIL NIL "BASE64" 40 NIL "#
            + #"("ATTACHMENT" ("FILENAME" "a.pdf")) NIL NIL) "MIXED" ("BOUNDARY" "b") NIL NIL NIL)"#
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", readOnly: true),
            .expect("A3 UID FETCH 12 (UID BODYSTRUCTURE BODY.PEEK[2])", reply: Script.lines(
                "* 3 FETCH (UID 12 BODYSTRUCTURE \(structure) BODY[2] \(Script.literal(base64 + "\r\n")))", "A3 OK Done")),
            .expect("A4 UID FETCH 12 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                "* 3 FETCH (UID 12 FLAGS () BODY[] \(Script.literal(raw)))", "A4 OK Done")),
        ])
        let harness = IMAPHarness([stream])
        let summary = MessageSummary(id: IMAPMessageID.inbox(12), subject: "Report")
        let attachment = Attachment(id: "2", filename: "a.pdf", mimeType: "application/pdf", size: 40)
        #expect(try await harness.service.loadAttachment(attachment, in: summary) == pdf)
        let message = try await harness.service.loadMessage(summary)
        #expect(message.summary.isUnread && message.rawSource == Data(raw.utf8))
        #expect(message.textBody?.contains("Here it is.") == true)
        await #expect(throws: PMailError.notFound) {
            try await harness.service.loadMessage(MessageSummary(id: IMAPMessageID.inbox(12, uidValidity: 6)))
        }
        let given = Data("already here".utf8)
        let loaded = Attachment(id: "9", filename: "x", mimeType: "text/plain", size: 1, data: given)
        #expect(try await harness.service.loadAttachment(loaded, in: summary) == given)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func messageIDsRoundTrip() {
        let id = IMAPMessageID(mailbox: "Projects/Café: notes", uidValidity: 3_857_529_045, uid: 42)
        #expect(id.rawValue == "imap:3857529045:42:Projects/Café: notes")
        #expect(IMAPMessageID(rawValue: id.rawValue) == id)
        #expect(IMAPMessageID(rawValue: "imap:1:2:") == nil)
        #expect(IMAPMessageID(rawValue: "imap:x:2:INBOX") == nil)
        #expect(IMAPMessageID(rawValue: "pop:1:2:INBOX") == nil)
        let messages = [MessageSummary(id: "a", references: ["<r@x>", "<s@x>"]), MessageSummary(id: "b", inReplyTo: "<r@x>"),
                        MessageSummary(id: "c", messageIDHeader: "<c@x>")]
        #expect(IMAPMailService.threadRoots(of: messages, conversationID: "t") == ["<r@x>", "<c@x>"])
        #expect(IMAPMailService.threadRoots(of: [], conversationID: "<t@x>") == ["<t@x>"])
    }
}
