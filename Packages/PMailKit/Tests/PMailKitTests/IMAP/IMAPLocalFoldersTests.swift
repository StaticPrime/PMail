import Foundation
import Testing
@testable import PMailKit

/// Mail on an IMAP server that has only an inbox: Sent and Drafts kept on this Mac, Archive, Junk and Trash made on the
/// server (nothing leaves the server for the Mac), and mail an earlier PMail kept on the Mac put back on the server.
struct IMAPLocalFoldersTests {
    private typealias Script = IMAPScript

    /// An iCloud account that has only ever had an inbox: no special-use folders, no MOVE.
    private static let capabilities = "IMAP4rev1 SASL-IR AUTH=PLAIN IDLE UIDPLUS LITERAL+"
    private static let pug = MailAddress(name: "Pug Tester", email: "pug@example.com")
    private static let alex = MailAddress(name: "Alex Rivera", email: "alex@example.com")

    private func temporaryStore() -> LocalMailStore {
        LocalMailStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("PMailKitTests-kept-\(UUID().uuidString)", isDirectory: true))
    }

    private static func status(_ tag: String, _ mailbox: String, messages: Int = 1, unseen: Int = 0) -> ScriptedByteStream.Step {
        Script.ok(tag, #"STATUS "\#(mailbox)" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
                  untagged: [#"* STATUS "\#(mailbox)" (MESSAGES \#(messages) UNSEEN \#(unseen) UIDNEXT 100 UIDVALIDITY 7)"#])
    }

    /// A LIST answered with these mailboxes, without special-use marks.
    private static func list(_ tag: String, _ names: [String]) -> ScriptedByteStream.Step {
        .expect(#"\#(tag) LIST "" "*""#, reply: (names.map { #"* LIST (\HasNoChildren) "/" "\#($0)""# } + ["\(tag) OK LIST completed"])
            .map { $0 + "\r\n" }.joined())
    }

    /// An APPEND of `text` with these flags, answered with where it went.
    private static func append(_ tag: String, _ mailbox: String, flags: String?, _ text: String) -> [ScriptedByteStream.Step] {
        let count = text.utf8.count
        return [
            .expect("\(tag) APPEND \"\(mailbox)\"\(flags.map { " (\($0))" } ?? "") {\(count)+}", reply: ""),
            .expectBytes(count, reply: ""),
            .expect("", reply: "\(tag) OK [APPENDUID 9 1] APPEND completed\r\n"),
        ]
    }

    private static func message(_ subject: String, id: String, date: String = "Sat, 21 Nov 2026 09:00:00 +0000") -> String {
        "From: Alex Rivera <alex@example.com>\r\nTo: pug@example.com\r\nSubject: \(subject)\r\nMessage-ID: \(id)\r\nDate: \(date)\r\n\r\nHello\r\n"
    }

    @Test func aServerWithOnlyAnInboxKeepsSentAndDraftsOnTheMac() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            Self.list("A2", ["INBOX"]),
            Self.status("A3", "INBOX", messages: 3, unseen: 1),
        ])
        let harness = IMAPHarness([stream], localStore: store)
        let service = harness.service

        // Sent and Drafts are kept here; there's no Archive, Junk or Trash until one's needed.
        let folders = try await service.loadFolders()
        #expect(folders.map(\.id) == ["INBOX", "pmail:starred", LocalFolders.sentID, LocalFolders.draftsID])
        #expect(folders.map(\.role) == [.inbox, .starred, .sent, .drafts])
        #expect(folders.map(\.name) == ["Inbox", "Starred", "Sent", "Drafts"])

        // Sending keeps the copy, Bcc and all, in the Sent kept here.
        let message = OutgoingMessage(from: Self.pug, to: [Self.alex], bcc: [MailAddress(email: "secret@example.net")],
                                      subject: "Lunch?", textBody: "Noon at the usual place?", messageID: "<lunch@example.com>")
        try await service.send(message)
        #expect(harness.sender.sent.count == 1)
        let sent = await store.summaries(in: LocalFolders.sentID)
        #expect(sent.count == 1 && sent.first?.subject == "Lunch?" && sent.first?.isUnread == false)
        let sentSummary = try #require(sent.first)
        let sentCopy = try #require(await store.raw(for: sentSummary.id))
        #expect(String(decoding: sentCopy, as: UTF8.self).contains("Bcc: secret@example.net"))
        let sentPage = try await service.listConversations(ListRequest(folderID: LocalFolders.sentID, pageSize: 50))
        #expect(sentPage.conversations.count == 1 && sentPage.totalCount == 1)

        // Drafts are kept here too, each save replacing the last.
        let first = try #require(try await service.saveDraft(message, replacing: nil))
        #expect(first.folderID == LocalFolders.draftsID && first.isDraft)
        var edited = message
        edited.textBody = "Noon, or one?"
        let second = try #require(try await service.saveDraft(edited, replacing: first))
        #expect(second.id == first.id)
        #expect(await store.summaries(in: LocalFolders.draftsID).count == 1)
        try await service.deleteDraft(second)
        #expect(await store.summaries(in: LocalFolders.draftsID).isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// Archiving, reporting spam and deleting on an iCloud server with only an inbox make its Archive, Junk and
    /// Deleted Messages, and move the messages there. Nothing is copied to this Mac or deleted from the server.
    @Test func archiveJunkAndDeleteMakeFoldersOnTheServer() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            Self.list("A2", ["INBOX"]),
            Self.status("A3", "INBOX", messages: 3, unseen: 3),
            // Archive: the list is read again in case another program made one, then the server makes it.
            Self.list("A4", ["INBOX"]),
            Script.ok("A5", #"CREATE "Archive""#),
            Script.ok("A6", #"SUBSCRIBE "Archive""#),
            Self.list("A7", ["INBOX", "Archive"]),
            Script.select("A8"),
            Script.ok("A9", #"UID COPY 12 "Archive""#),
            Script.ok("A10", #"UID STORE 12 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A11", "UID EXPUNGE 12", untagged: ["* 1 EXPUNGE"]),
            // Junk.
            Self.list("A12", ["INBOX", "Archive"]),
            Script.ok("A13", #"CREATE "Junk""#),
            Script.ok("A14", #"SUBSCRIBE "Junk""#),
            Self.list("A15", ["INBOX", "Archive", "Junk"]),
            Script.ok("A16", #"UID COPY 13 "Junk""#),
            Script.ok("A17", #"UID STORE 13 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A18", "UID EXPUNGE 13", untagged: ["* 1 EXPUNGE"]),
            // Delete: iCloud's name for the Trash.
            Self.list("A19", ["INBOX", "Archive", "Junk"]),
            Script.ok("A20", #"CREATE "Deleted Messages""#),
            Script.ok("A21", #"SUBSCRIBE "Deleted Messages""#),
            Self.list("A22", ["INBOX", "Archive", "Junk", "Deleted Messages"]),
            Script.ok("A23", #"UID COPY 14 "Deleted Messages""#),
            Script.ok("A24", #"UID STORE 14 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A25", "UID EXPUNGE 14", untagged: ["* 1 EXPUNGE"]),
        ])
        let service = IMAPHarness([stream], kind: .icloud, localStore: store).service
        _ = try await service.loadFolders()
        try await service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(12), folderID: "INBOX")])
        try await service.perform(.markSpam, on: [MessageSummary(id: IMAPMessageID.inbox(13), folderID: "INBOX")])
        try await service.perform(.trash, on: [MessageSummary(id: IMAPMessageID.inbox(14), folderID: "INBOX")])
        #expect(await store.allSummaries().isEmpty, "nothing kept on this Mac")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// A server that won't make an Archive leaves the message where it was, and says why.
    @Test func aServerThatWontMakeAFolderKeepsTheMessage() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            Self.list("A2", ["INBOX"]),
            Self.list("A3", ["INBOX"]),
            .expect(#"A4 CREATE "Archive""#, reply: "A4 NO [CANNOT] Folders can't be made here\r\n"),
        ])
        let service = IMAPHarness([stream], localStore: store).service
        await #expect {
            try await service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(12), folderID: "INBOX")])
        } throws: { error in
            guard case let PMailError.notSupported(reason) = error else { return false }
            return reason.contains("Archive") && reason.contains("nothing was moved")
        }
        #expect(await store.allSummaries().isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished, "no STORE or EXPUNGE")
    }

    @Test func keptFoldersStepAsideWhenTheServerHasItsOwn() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        // Kept from before the server had a Sent folder, and archived by an earlier PMail.
        try await store.add(raw: Data("From: pug@example.com\r\nSubject: Old news\r\n\r\nHi\r\n".utf8),
                            folderID: LocalFolders.sentID, isUnread: false)
        try await store.add(raw: Data(Self.message("Hike", id: "<hike@example.com>").utf8), folderID: LocalFolders.archiveID)
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.list("A2"),
            Self.status("A3", "INBOX"),
            Self.status("A4", "Sent Messages"),
            Self.status("A5", "Drafts"),
            Self.status("A6", "Deleted Messages"),
            Self.status("A7", "Junk"),
            Self.status("A8", "Archive"),
        ])
        let harness = IMAPHarness([stream], localStore: store)
        let folders = try await harness.service.loadFolders()
        #expect(folders.filter { $0.role == .sent }.map(\.id) == ["Sent Messages"])
        #expect(folders.filter { $0.role == .trash }.map(\.id) == ["Deleted Messages"])
        let kept = try #require(folders.first { $0.id == LocalFolders.sentID })
        #expect(kept.name == "Sent on this Mac" && kept.role == nil && kept.totalCount == 1)
        let archived = try #require(folders.first { $0.id == LocalFolders.archiveID })
        #expect(archived.name == "Archive on this Mac" && archived.role == nil && archived.totalCount == 1)
        #expect(!folders.contains { [LocalFolders.trashID, LocalFolders.draftsID, LocalFolders.spamID].contains($0.id) })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    /// Mail an earlier PMail kept on this Mac goes back: archived mail to the server's Archive (one already there just
    /// lets the copy here go), deleted mail to a Deleted Messages made for it, and sent copies to the server's Sent.
    /// Drafts stay.
    @Test func mailKeptOnTheMacGoesBackToTheServer() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let hike = Self.message("Hike", id: "<hike@example.com>")
        let park = Self.message("Park day", id: "<park@example.com>", date: "Fri, 20 Nov 2026 09:00:00 +0000")
        let offer = Self.message("You won!", id: "<prize@spam.example>")
        let old = Self.message("Old news", id: "<old@example.com>")
        try await store.add(raw: Data(hike.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        try await store.add(raw: Data(park.utf8), folderID: LocalFolders.archiveID, isUnread: false)
        try await store.add(raw: Data(offer.utf8), folderID: LocalFolders.trashID, isUnread: true)
        try await store.add(raw: Data(old.utf8), folderID: LocalFolders.sentID, isUnread: false)
        try await store.add(raw: Data(Self.message("Draft", id: "<draft@example.com>").utf8), folderID: LocalFolders.draftsID, isUnread: false)
        let server = ["INBOX", "Sent Messages", "Drafts", "Junk", "Archive"]
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            Self.list("A2", server),
            Script.select("A3", "Archive", readOnly: true),
            .expect(#"A4 UID SEARCH HEADER Message-ID "<hike@example.com>""#, reply: "* SEARCH\r\nA4 OK Done\r\n"),
        ] + Self.append("A5", "Archive", flags: #"\Seen"#, hike) + [
            .expect(#"A6 UID SEARCH HEADER Message-ID "<park@example.com>""#, reply: "* SEARCH 31\r\nA6 OK Done\r\n"),
            Self.list("A7", server),
            Script.ok("A8", #"CREATE "Deleted Messages""#),
            Script.ok("A9", #"SUBSCRIBE "Deleted Messages""#),
            Self.list("A10", server + ["Deleted Messages"]),
            Script.select("A11", "Deleted Messages", readOnly: true),
            .expect(#"A12 UID SEARCH HEADER Message-ID "<prize@spam.example>""#, reply: "* SEARCH\r\nA12 OK Done\r\n"),
        ] + Self.append("A13", "Deleted Messages", flags: nil, offer) + [
            Self.list("A14", server + ["Deleted Messages"]),
            Script.select("A15", "Sent Messages", readOnly: true),
            .expect(#"A16 UID SEARCH HEADER Message-ID "<old@example.com>""#, reply: "* SEARCH\r\nA16 OK Done\r\n"),
        ] + Self.append("A17", "Sent Messages", flags: #"\Seen"#, old))
        let service = IMAPHarness([stream], kind: .icloud, localStore: store).service
        #expect(try await service.putKeptMailBack() == 3)
        for folder in [LocalFolders.archiveID, LocalFolders.trashID, LocalFolders.sentID] {
            #expect(await store.summaries(in: folder).isEmpty, "\(folder) is back on the server")
        }
        #expect(await store.summaries(in: LocalFolders.draftsID).count == 1, "drafts stay")
        #expect(try await service.putKeptMailBack() == 0, "nothing left, and nothing asked")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }
}
