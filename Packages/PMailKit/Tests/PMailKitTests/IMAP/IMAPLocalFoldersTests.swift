import Foundation
import Testing
@testable import PMailKit

/// Sent, Drafts and Trash kept on this Mac for an IMAP server that has no folders for them.
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

    @Test func aServerWithOnlyAnInboxKeepsSentDraftsAndTrashOnTheMac() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let parkDay = "From: Alex Rivera <alex@example.com>\r\nTo: pug@example.com\r\nSubject: Park day\r\n"
            + "Message-ID: <park@example.com>\r\nDate: Sat, 21 Nov 2026 09:00:00 +0000\r\n\r\nSee you at the park!\r\n"
        let restored = Data(parkDay.utf8)
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            .expect(#"A2 LIST "" "*""#, reply: Script.lines(#"* LIST (\Noinferiors) "/" "INBOX""#, "A2 OK LIST completed")),
            Self.status("A3", "INBOX", messages: 3, unseen: 1),
            // Deleting from the inbox: the message is read, kept on the Mac, then deleted from the server.
            Script.select("A4"),
            .expect("A5 UID FETCH 11 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                "* 1 FETCH (UID 11 FLAGS () BODY[] " + Script.literal(parkDay) + ")", "A5 OK Done")),
            Script.ok("A6", #"UID STORE 11 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A7", "UID EXPUNGE 11", untagged: ["* 1 EXPUNGE"]),
            // Moving it back to the inbox uploads it, still unread.
            .expect("A8 APPEND \"INBOX\" {\(restored.count)+}", reply: ""),
            .expectBytes(restored.count, reply: ""),
            .expect("", reply: "A8 OK [APPENDUID 7 101] APPEND completed\r\n"),
        ])
        let harness = IMAPHarness([stream], localStore: store)
        let service = harness.service

        let folders = try await service.loadFolders()
        #expect(folders.map(\.id) == ["INBOX", "pmail:starred", LocalFolders.sentID, LocalFolders.draftsID, LocalFolders.archiveID,
                                      LocalFolders.spamID, LocalFolders.trashID])
        #expect(folders.map(\.role) == [.inbox, .starred, .sent, .drafts, .archive, .spam, .trash])
        #expect(folders.map(\.name) == ["Inbox", "Starred", "Sent", "Drafts", "Archive", "Junk", "Trash"])

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

        // Deleting from the inbox puts the message in the Trash kept here, unread as it was.
        try await service.perform(.trash, on: [MessageSummary(id: IMAPMessageID.inbox(11), folderID: "INBOX")])
        let trashPage = try await service.listConversations(ListRequest(folderID: LocalFolders.trashID, pageSize: 50))
        let trashed = try #require(trashPage.conversations.first)
        #expect(trashPage.totalCount == 1 && trashed.subject == "Park day" && trashed.messages.first?.isUnread == true)
        let opened = try await service.loadConversation(id: trashed.id, hint: trashed)
        #expect(opened.count == 1 && opened.first?.textBody?.contains("See you at the park!") == true)
        let searched = try await service.listConversations(ListRequest(folderID: LocalFolders.trashID, query: "park", pageSize: 50))
        #expect(searched.conversations.count == 1)

        // Move to Inbox puts it back on the server and lets the Mac's copy go.
        try await service.perform(.moveToInbox, on: trashed.messages)
        #expect(await store.summaries(in: LocalFolders.trashID).isEmpty)

        // Deleting a sent copy moves it to the Trash kept here; deleting it there removes it for good.
        try await service.perform(.trash, on: [sentSummary])
        #expect(await store.summaries(in: LocalFolders.sentID).isEmpty)
        #expect(await store.summaries(in: LocalFolders.trashID).map(\.id) == [sentSummary.id])
        try await service.perform(.trash, on: [sentSummary])
        #expect(await store.summaries(in: LocalFolders.trashID).isEmpty)

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

    /// Archiving and reporting spam on a server without those folders keeps the mail here; a snoozed conversation
    /// waiting in the Archive kept here is found again without the server, and Not spam puts it back on it.
    @Test func archiveAndSpamAreKeptOnTheMac() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let offer = "From: Deals <deals@spam.example>\r\nTo: pug@example.com\r\nSubject: You won!\r\n"
            + "Message-ID: <prize@spam.example>\r\n\r\nClaim now.\r\n"
        let hike = "From: Alex Rivera <alex@example.com>\r\nTo: pug@example.com\r\nSubject: Hike\r\n"
            + "Message-ID: <hike@example.com>\r\n\r\nSaturday?\r\n"
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Script.signIn("A1", capabilities: Self.capabilities),
            .expect(#"A2 LIST "" "*""#, reply: Script.lines(#"* LIST (\Noinferiors) "/" "INBOX""#, "A2 OK LIST completed")),
            Self.status("A3", "INBOX", messages: 2, unseen: 2),
            // Archiving message 12 keeps it here, then deletes it from the server.
            Script.select("A4"),
            .expect("A5 UID FETCH 12 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                #"* 1 FETCH (UID 12 FLAGS (\Seen) BODY[] "# + Script.literal(hike) + ")", "A5 OK Done")),
            Script.ok("A6", #"UID STORE 12 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A7", "UID EXPUNGE 12", untagged: ["* 1 EXPUNGE"]),
            // Reporting message 13 as spam keeps it in the Junk here.
            .expect("A8 UID FETCH 13 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                "* 1 FETCH (UID 13 FLAGS () BODY[] " + Script.literal(offer) + ")", "A8 OK Done")),
            Script.ok("A9", #"UID STORE 13 +FLAGS.SILENT (\Deleted)"#),
            Script.ok("A10", "UID EXPUNGE 13", untagged: ["* 1 EXPUNGE"]),
            // Not spam uploads it to the inbox, still unread.
            .expect("A11 APPEND \"INBOX\" {\(offer.utf8.count)+}", reply: ""),
            .expectBytes(offer.utf8.count, reply: ""),
            .expect("", reply: "A11 OK [APPENDUID 7 102] APPEND completed\r\n"),
        ])
        let harness = IMAPHarness([stream], localStore: store)
        let service = harness.service
        _ = try await service.loadFolders()

        try await service.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(12), folderID: "INBOX")])
        let archived = await store.summaries(in: LocalFolders.archiveID)
        #expect(archived.map(\.subject) == ["Hike"] && archived.first?.isUnread == false)
        // Found by its Message-ID with no server command, the way a snooze finds its conversation.
        let found = try await service.findMessages(withMessageIDs: ["<hike@example.com>"])
        #expect(found.map(\.id) == archived.map(\.id))

        try await service.perform(.markSpam, on: [MessageSummary(id: IMAPMessageID.inbox(13), folderID: "INBOX")])
        let junk = await store.summaries(in: LocalFolders.spamID)
        #expect(junk.map(\.subject) == ["You won!"])
        try await service.perform(.notSpam, on: junk)
        #expect(await store.summaries(in: LocalFolders.spamID).isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func keptFoldersStepAsideWhenTheServerHasItsOwn() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        // Kept from before the server had a Sent folder.
        try await store.add(raw: Data("From: pug@example.com\r\nSubject: Old news\r\n\r\nHi\r\n".utf8),
                            folderID: LocalFolders.sentID, isUnread: false)
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
        #expect(!folders.contains { [LocalFolders.trashID, LocalFolders.draftsID, LocalFolders.archiveID, LocalFolders.spamID].contains($0.id) })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }
}
