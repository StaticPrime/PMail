import Foundation
import Testing
@testable import PMailKit

/// Records what it was asked to send instead of sending it.
private final class RecordingSender: MailSending, @unchecked Sendable {
    struct Sent {
        var raw: Data
        var sender: String
        var recipients: [String]
    }

    private let lock = NSLock()
    private var recorded: [Sent] = []

    var sent: [Sent] { lock.withLock { recorded } }

    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {
        lock.withLock { recorded.append(Sent(raw: raw, sender: sender, recipients: recipients)) }
    }
}

@Suite struct POPMailServiceTests {
    private let account = Account(kind: .other, name: "Jamie Rivera", email: "jamie@example.com")
    private let incoming = ServerSettings(mailProtocol: .pop3, host: "pop.example.com", security: .tls, username: "jamie@example.com")
    private let credential = Credential.password(username: "jamie@example.com", password: "secret")

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-pop-\(UUID().uuidString)", isDirectory: true)
    }

    /// A message as a POP server sends it in RETR (CRLF, nothing to dot-stuff).
    private func message(_ number: Int, day: Int, subject: String? = nil, inReplyTo: String? = nil) -> String {
        var lines = [
            "From: Sender \(number) <sender\(number)@example.com>",
            "To: Jamie Rivera <jamie@example.com>",
            "Subject: \(subject ?? "Message \(number)")",
            "Date: \(day) Nov 2026 10:00:00 +0000",
            "Message-ID: <m\(number)@example.com>",
        ]
        if let inReplyTo { lines += ["In-Reply-To: \(inReplyTo)", "References: \(inReplyTo)"] }
        return lines.joined(separator: "\r\n") + "\r\n\r\nBody of message \(number)\r\n"
    }

    /// A POP session that lists `uids` (numbered from 1) and serves RETR for the given message numbers, in order.
    private func session(uids: [String], retrieving: [(number: Int, text: String)]) -> ScriptedByteStream {
        var steps: [ScriptedByteStream.Step] = [
            .expect("CAPA", reply: "+OK\r\nUSER\r\nUIDL\r\nTOP\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "+OK\r\n"),
            .expect("UIDL", reply: "+OK\r\n" + uids.enumerated().map { "\($0.offset + 1) \($0.element)\r\n" }.joined() + ".\r\n"),
        ]
        for item in retrieving {
            steps.append(.expect("RETR \(item.number)", reply: "+OK\r\n" + item.text + ".\r\n"))
        }
        steps.append(.expect("QUIT", reply: "+OK bye\r\n"))
        return ScriptedByteStream(greeting: "+OK POP3 ready\r\n", script: steps)
    }

    private func service(_ folder: URL, _ streams: [ScriptedByteStream], sender: any MailSending = RecordingSender()) -> POPMailService {
        POPMailService(account: account, incoming: incoming, credential: credential, store: LocalMailStore(folder: folder),
                       sender: sender, connector: ScriptedConnector(streams))
    }

    @Test func firstSyncDownloadsNewestFirstAndLaterSyncsOnlyNewMail() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = session(uids: ["uid-a", "uid-b", "uid-c"], retrieving: [
            (3, message(3, day: 3)), (2, message(2, day: 2)), (1, message(1, day: 1)),
        ])
        let page = try await service(folder, [first]).listConversations(ListRequest(folderID: POPMailService.inboxID))
        #expect(first.mismatches.isEmpty && first.isFinished)
        #expect(page.conversations.map { $0.latest?.id } == ["pop:uid-c", "pop:uid-b", "pop:uid-a"])
        #expect(page.conversations.first?.subject == "Message 3")
        #expect(page.conversations.allSatisfy { $0.isUnread })
        #expect(page.totalCount == 3)
        #expect(page.nextPageToken == nil)

        // A new instance, as after relaunching: only the new message is downloaded.
        let second = session(uids: ["uid-a", "uid-b", "uid-c", "uid-d"], retrieving: [(4, message(4, day: 4))])
        let later = try await service(folder, [second]).listConversations(ListRequest(folderID: POPMailService.inboxID))
        #expect(second.mismatches.isEmpty && second.isFinished)
        #expect(later.conversations.count == 4)
        #expect(later.conversations.first?.latest?.id == "pop:uid-d")
        #expect(!second.lines.contains("RETR 1"))
        #expect(!second.lines.contains { $0.hasPrefix("DELE") })  // mail stays on the server
    }

    @Test func firstSyncTakesOnlyTheNewestAndNeverTheRest() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b", "c", "d"], retrieving: [(4, message(4, day: 4)), (3, message(3, day: 3))])
        let pop = service(folder, [first])
        await pop.setFirstSyncLimit(2)
        #expect(try await pop.syncInbox() == 2)
        #expect(first.mismatches.isEmpty && first.isFinished)

        let second = session(uids: ["a", "b", "c", "d", "e"], retrieving: [(5, message(5, day: 5))])
        let next = service(folder, [second])
        #expect(try await next.syncInbox() == 1)
        #expect(second.mismatches.isEmpty && second.isFinished)
        let inbox = try await next.listConversations(ListRequest(folderID: POPMailService.inboxID, pageIndex: 1))
        #expect(inbox.totalCount == 3)
    }

    @Test func flagsPersistAcrossInstancesAndDeletedMailStaysDeleted() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b", "c"], retrieving: [
            (3, message(3, day: 3)), (2, message(2, day: 2)), (1, message(1, day: 1)),
        ])
        let pop = service(folder, [first])
        try await pop.syncInbox()
        let inbox = try await pop.listConversations(ListRequest(folderID: POPMailService.inboxID, pageIndex: 1))
        #expect(inbox.totalCount == 3)
        let summaries = await LocalMailStore(folder: folder).summaries(in: POPMailService.inboxID)
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let a = try #require(byID["pop:a"]), b = try #require(byID["pop:b"]), c = try #require(byID["pop:c"])
        try await pop.perform(.star, on: [b])
        try await pop.perform(.markRead, on: [a, b])
        try await pop.perform(.trash, on: [c])

        // Relaunch: the flags and the move are still there.
        let second = session(uids: ["a", "b", "c"], retrieving: [])
        let reopened = service(folder, [second])
        let folders = try await reopened.loadFolders()
        #expect(folders.map(\.id) == ["INBOX", "pmail:starred", "Sent", "Drafts", "Archive", "Spam", "Trash"])
        #expect(folders.map(\.role) == [.inbox, .starred, .sent, .drafts, .archive, .spam, .trash])
        #expect(folders[0].unreadCount == 0 && folders[0].totalCount == 2)
        #expect(folders[1].totalCount == 1)
        #expect(folders[6].totalCount == 1, "the trashed message")
        let starred = try await reopened.listConversations(ListRequest(folderID: POPMailService.starredID))
        #expect(starred.conversations.map(\.id) == ["<m2@example.com>"])
        #expect(starred.conversations.first?.isStarred == true)
        let reloadedInbox = try await reopened.listConversations(ListRequest(folderID: POPMailService.inboxID))
        #expect(second.mismatches.isEmpty && second.isFinished)
        #expect(reloadedInbox.conversations.allSatisfy { !$0.isUnread })
        let trash = try await reopened.listConversations(ListRequest(folderID: POPMailService.trashID))
        #expect(trash.conversations.flatMap(\.messages).map(\.id) == ["pop:c"])

        // Deleted for good: still on the server, but never downloaded again.
        try await reopened.perform(.deleteForever, on: [c])
        let third = session(uids: ["a", "b", "c"], retrieving: [])
        try await service(folder, [third]).syncInbox()
        #expect(third.mismatches.isEmpty && third.isFinished)
        #expect(await LocalMailStore(folder: folder).contains(id: "pop:c") == false)
    }

    @Test func sendingFilesACopyInSent() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sender = RecordingSender()
        let pop = service(folder, [], sender: sender)
        let outgoing = OutgoingMessage(from: account.address, to: [MailAddress(name: "Sam", email: "sam@example.com")],
                                       cc: [MailAddress(email: "alex@example.com")], bcc: [MailAddress(email: "secret@example.com")],
                                       subject: "Grüße", textBody: "Hallo Sam")
        try await pop.send(outgoing)

        let sent = try #require(sender.sent.first)
        #expect(sender.sent.count == 1)
        #expect(sent.sender == "jamie@example.com")
        #expect(sent.recipients == ["sam@example.com", "alex@example.com", "secret@example.com"])
        #expect(!sent.raw.mimeText.contains("secret@example.com"))
        #expect(MIMEParser.parse(sent.raw).subject == "Grüße")

        let page = try await pop.listConversations(ListRequest(folderID: POPMailService.sentID))
        let copy = try #require(page.conversations.first?.latest)
        #expect(copy.subject == "Grüße")
        #expect(!copy.isUnread)
        #expect(copy.folderID == "Sent")
        let full = try await pop.loadMessage(copy)
        #expect(full.textBody == "Hallo Sam")
        #expect(full.bcc == [MailAddress(email: "secret@example.com")])  // the saved copy remembers the blind copy

        await #expect(throws: PMailError.server("The message has no recipients.")) {
            try await pop.send(OutgoingMessage(from: account.address, subject: "Nobody"))
        }
    }

    @Test func draftsAreSavedReplacedAndDeleted() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pop = service(folder, [])
        let draft = try #require(try await pop.saveDraft(OutgoingMessage(from: account.address, bcc: [MailAddress(email: "b@example.com")],
                                                                         subject: "First try", textBody: "x"), replacing: nil))
        #expect(draft.isDraft && draft.folderID == "Drafts")
        let replaced = try #require(try await pop.saveDraft(OutgoingMessage(from: account.address, subject: "Second try", textBody: "y"),
                                                            replacing: draft))
        #expect(replaced.id == draft.id)
        let drafts = try await pop.listConversations(ListRequest(folderID: POPMailService.draftsID))
        #expect(drafts.conversations.flatMap(\.messages).map(\.subject) == ["Second try"])
        try await pop.deleteDraft(replaced)
        #expect(try await pop.listConversations(ListRequest(folderID: POPMailService.draftsID)).conversations.isEmpty)
    }

    @Test func pagingSearchingReadingAndUnsupportedActions() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        for number in 1...5 {
            try await store.add(raw: Data(message(number, day: number, subject: number == 3 ? "Café plans" : nil).utf8),
                                folderID: "Sent", id: "local:\(number)")
        }
        let attachmentMessage = mimeWire("""
            From: sam@example.com
            Subject: With a file
            Date: 6 Nov 2026 10:00:00 +0000
            Content-Type: multipart/mixed; boundary="b"

            --b
            Content-Type: text/plain

            See attached
            --b
            Content-Type: application/pdf; name="plan.pdf"
            Content-Transfer-Encoding: base64

            JVBERi0xLjQgcHJldGVuZA==
            --b--
            """)
        try await store.add(raw: attachmentMessage, folderID: "INBOX", id: "local:file")
        let pop = POPMailService(account: account, incoming: incoming, credential: credential, store: store,
                                 sender: RecordingSender(), connector: ScriptedConnector([]))

        let page0 = try await pop.listConversations(ListRequest(folderID: "Sent", pageSize: 2))
        let page1 = try await pop.listConversations(ListRequest(folderID: "Sent", pageSize: 2, pageToken: page0.nextPageToken))
        let page2 = try await pop.listConversations(ListRequest(folderID: "Sent", pageSize: 2, pageIndex: 2))
        #expect(page0.conversations.compactMap { $0.latest?.id } == ["local:5", "local:4"])
        #expect(page1.conversations.compactMap { $0.latest?.id } == ["local:3", "local:2"])
        #expect(page2.conversations.compactMap { $0.latest?.id } == ["local:1"])
        #expect(page0.nextPageToken == "1" && page1.nextPageToken == "2" && page2.nextPageToken == nil)
        #expect(page0.totalCount == 5)

        // Search is local, ignores accents, and never connects (the connector has no scripted sessions).
        let found = try await pop.listConversations(ListRequest(folderID: POPMailService.inboxID, query: "cafe"))
        #expect(found.conversations.isEmpty)
        let everywhere = try await pop.listConversations(ListRequest(folderID: nil, query: "CAFE"))
        #expect(everywhere.conversations.compactMap { $0.latest?.id } == ["local:3"])

        let summary = try #require(await store.summary(for: "local:file"))
        #expect(summary.hasAttachments)
        let full = try await pop.loadMessage(summary)
        let attachment = try #require(full.attachments.first)
        #expect(full.rawSource == attachmentMessage)
        #expect(try await pop.loadAttachment(attachment, in: summary) == Data("%PDF-1.4 pretend".utf8))
        let conversation = try await pop.loadConversation(id: summary.threadID, hint: nil)
        #expect(conversation.map(\.id) == ["local:file"])
        await #expect(throws: PMailError.notFound) {
            try await pop.loadMessage(MessageSummary(id: "local:missing"))
        }

        let unsupported: [MailAction] = [.addLabel("x"), .removeLabel("x"), .markImportant, .move(toFolderID: "Elsewhere")]
        for action in unsupported {
            await #expect(throws: PMailError.self) { try await pop.perform(action, on: [summary]) }
        }
        try await pop.perform(.move(toFolderID: "Sent"), on: [summary])
        #expect(await store.summary(for: "local:file")?.folderID == "Sent")
        try await pop.perform(.moveToInbox, on: [summary])
        #expect(await store.summary(for: "local:file")?.folderID == "INBOX")
        // Archive and Spam are kept here too; Not spam brings a message back to the inbox.
        try await pop.perform(.archive, on: [summary])
        #expect(await store.summary(for: "local:file")?.folderID == "Archive")
        try await pop.perform(.markSpam, on: [summary])
        #expect(await store.summary(for: "local:file")?.folderID == "Spam")
        let allMail = try await pop.listConversations(ListRequest(folderID: nil, pageSize: 50))
        #expect(!allMail.conversations.contains { $0.messages.contains { $0.id == "local:file" } }, "spam stays out of All Mail")
        try await pop.perform(.notSpam, on: [summary])
        #expect(await store.summary(for: "local:file")?.folderID == "INBOX")

        #expect(pop.capabilities == MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: false, hasInboxTabs: false,
                                                     searchesOnServer: false, canArchive: true, supportsDrafts: true, canMove: true))
        #expect(pop.inboxTabs.isEmpty)
    }

    @Test func repliesJoinTheirConversation() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b"], retrieving: [
            (2, message(2, day: 2, subject: "Re: Lunch", inReplyTo: "<m1@example.com>")), (1, message(1, day: 1, subject: "Lunch")),
        ])
        let pop = service(folder, [first])
        let page = try await pop.listConversations(ListRequest(folderID: POPMailService.inboxID))
        #expect(page.conversations.count == 1)
        let conversation = try #require(page.conversations.first)
        #expect(conversation.messages.map(\.id) == ["pop:a", "pop:b"])
        let messages = try await pop.loadConversation(id: conversation.id, hint: conversation)
        #expect(messages.map(\.textBody) == ["Body of message 1", "Body of message 2"])
    }

    @Test func checkingForNewMailStartsSilentlyThenReportsWhatArrived() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b"], retrieving: [(2, message(2, day: 2)), (1, message(1, day: 1))])
        let second = session(uids: ["a", "b", "c", "d"], retrieving: [(4, message(4, day: 4)), (3, message(3, day: 3))])
        let third = session(uids: ["a", "b", "c", "d"], retrieving: [])
        let pop = service(folder, [first, second, third])
        let start = try await pop.checkForNewMail(since: nil)
        #expect(start.messages.isEmpty && start.inboxUnread == 2)
        #expect(await LocalMailStore(folder: folder).summaries(in: POPMailService.inboxID).count == 2)
        let later = try await pop.checkForNewMail(since: start.state)
        #expect(later.messages.map(\.id) == ["pop:d", "pop:c"])
        #expect(later.messages.map(\.subject) == ["Message 4", "Message 3"] && later.messages.allSatisfy(\.isUnread))
        #expect(later.inboxUnread == 4)
        let quiet = try await pop.checkForNewMail(since: later.state)
        #expect(quiet.messages.isEmpty && quiet.inboxUnread == 4)
        for stream in [first, second, third] { #expect(stream.mismatches.isEmpty && stream.isFinished) }

        // POP servers can't say when mail arrives.
        #expect(!pop.pushesChanges)
        #expect(try await pop.waitForChange(timeout: 30) == false)

        // On a Mac that never downloaded this account's mail, a check starts silently even with a state.
        let elsewhere = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let fresh = session(uids: ["a"], retrieving: [(1, message(1, day: 1))])
        let news = try await service(elsewhere, [fresh]).checkForNewMail(since: later.state)
        #expect(news.messages.isEmpty && news.inboxUnread == 1)
        #expect(fresh.mismatches.isEmpty && fresh.isFinished)
    }

    @Test func findingMessagesByMessageIDLooksOnThisMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        try await store.add(raw: Data(message(1, day: 1).utf8), folderID: POPMailService.inboxID, id: "pop:a")
        try await store.add(raw: Data(message(2, day: 2).utf8), folderID: POPMailService.sentID, id: "local:2")
        try await store.add(raw: Data(message(3, day: 3).utf8), folderID: POPMailService.trashID, id: "pop:c")
        let pop = POPMailService(account: account, incoming: incoming, credential: credential, store: store,
                                 sender: RecordingSender(), connector: ScriptedConnector([]))
        let found = try await pop.findMessages(withMessageIDs: ["<m1@example.com>", "<M2@EXAMPLE.COM>", "<m3@example.com>",
                                                                "<unknown@example.com>"])
        #expect(found.map(\.id) == ["local:2", "pop:a"])
        #expect(try await pop.findMessages(withMessageIDs: ["", "<>"]).isEmpty)
    }

    @Test func syncFailuresReachTheCaller() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let refused = ScriptedByteStream(greeting: "+OK ready\r\n", script: [
            .expect("CAPA", reply: "+OK\r\nUSER\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "-ERR [AUTH] Wrong password\r\n"),
        ])
        await #expect(throws: PMailError.authenticationFailed("Wrong password")) {
            _ = try await service(folder, [refused]).listConversations(ListRequest(folderID: POPMailService.inboxID))
        }
    }
}
