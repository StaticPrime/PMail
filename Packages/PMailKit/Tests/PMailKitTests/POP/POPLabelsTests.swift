import Foundation
import Testing
@testable import PMailKit

/// Labels on POP accounts, kept with the mail on this Mac.
@Suite struct POPLabelsTests {
    private let account = Account(kind: .other, name: "Jamie Rivera", email: "jamie@example.com")
    private let incoming = ServerSettings(mailProtocol: .pop3, host: "pop.example.com", security: .tls, username: "jamie@example.com")

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-pop-labels-\(UUID().uuidString)", isDirectory: true)
    }

    private func message(_ number: Int, day: Int, subject: String) -> Data {
        Data(("From: Sender \(number) <sender\(number)@example.com>\r\nTo: Jamie Rivera <jamie@example.com>\r\n"
              + "Subject: \(subject)\r\nDate: \(day) Nov 2026 10:00:00 +0000\r\nMessage-ID: <m\(number)@example.com>\r\n\r\n"
              + "Body of message \(number)\r\n").utf8)
    }

    /// A service that never reaches a server: the connector has no sessions to give.
    private func service(_ store: LocalMailStore, book: LabelBook?) -> POPMailService {
        POPMailService(account: account, incoming: incoming, credential: .password(username: "jamie@example.com", password: "secret"),
                       store: store, sender: IMAPRecordingSender(), connector: ScriptedConnector([]), labelBook: book)
    }

    @Test func labelsAreKeptWithTheMailAndListedCountedRenamedAndDeleted() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mail = folder.appendingPathComponent("mail", isDirectory: true)
        let store = LocalMailStore(folder: mail)
        let park = try await store.add(raw: message(1, day: 1, subject: "Park day"), folderID: POPMailService.inboxID, id: "pop:a")
        let lunch = try await store.add(raw: message(2, day: 2, subject: "Lunch plans"), folderID: POPMailService.inboxID, id: "pop:b",
                                        isUnread: false)
        let binned = try await store.add(raw: message(3, day: 3, subject: "Old plans"), folderID: POPMailService.trashID, id: "pop:c")
        let bookFile = folder.appendingPathComponent("labels.json")
        let pop = service(store, book: LabelBook(file: bookFile))
        #expect(pop.capabilities.canLabel && pop.capabilities.canEditLabels)
        #expect(!service(store, book: nil).capabilities.canLabel)

        let work = try await pop.createLabel(named: "Work", colorHex: "#16a766")
        #expect(work == MailFolder(id: "PMail_Work", name: "Work", kind: .label, colorHex: "#16A766"))
        try await pop.perform(.addLabel(work.id), on: [park, lunch, binned])
        try await pop.perform(.removeLabel(work.id), on: [park])
        await #expect(throws: PMailError.notFound) { try await pop.perform(.addLabel("PMail_Nope"), on: [park]) }
        await #expect(throws: PMailError.notFound) { try await pop.perform(.addLabel("Work"), on: [park]) }
        #expect(await store.summary(for: lunch.id)?.labelIDs == [work.id])
        #expect(await store.summary(for: park.id)?.labelIDs == [])

        // Listed and counted outside Trash, and searched within.
        let label = try #require(try await pop.loadFolders().last)
        #expect(label.id == work.id && label.kind == .label && label.totalCount == 1 && label.unreadCount == 0)
        let page = try await pop.listConversations(ListRequest(folderID: work.id))
        #expect(page.conversations.flatMap(\.messages).map(\.id) == [lunch.id] && page.totalCount == 1)
        #expect(try await pop.listConversations(ListRequest(folderID: work.id, query: "park")).conversations.isEmpty)
        #expect(try await pop.listConversations(ListRequest(folderID: work.id, query: "LUNCH")).conversations.count == 1)

        // Renaming moves its messages, and it all lasts until next time.
        let job = try await pop.updateLabel(work, name: "Job", colorHex: "#FF0000")
        #expect(job == MailFolder(id: "PMail_Job", name: "Job", kind: .label, colorHex: "#FF0000"))
        let reopened = service(LocalMailStore(folder: mail), book: LabelBook(file: bookFile))
        #expect(try await reopened.listConversations(ListRequest(folderID: job.id)).conversations.flatMap(\.messages).map(\.id)
                == [lunch.id])
        #expect(try await reopened.loadFolders().filter { $0.kind == .label }.map(\.name) == ["Job"])

        // A lost book finds the labels again on the messages.
        let lost = service(LocalMailStore(folder: mail), book: LabelBook(file: folder.appendingPathComponent("lost.json")))
        #expect(try await lost.loadFolders().filter { $0.kind == .label }.map(\.id) == [job.id])

        // Deleting takes it off every message, the one in Trash too.
        try await reopened.deleteLabel(job)
        #expect(await LocalMailStore(folder: mail).summaries(withLabel: job.id).isEmpty)
        #expect(try await reopened.loadFolders().filter { $0.kind == .label }.isEmpty)
    }
}
