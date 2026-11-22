import Foundation
import Testing
@testable import PMailKit

/// A POP account's messages stay on the server unless the person chooses otherwise: removed once deleted from PMail,
/// or a while after they arrived. Messages PMail never downloaded are never removed.
struct POPRemoveFromServerTests {
    private let account = Account(kind: .other, name: "Jamie Rivera", email: "jamie@example.com")
    private let credential = Credential.password(username: "jamie@example.com", password: "secret")
    private static let start = Date(timeIntervalSince1970: 1_795_000_000)

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-pop-remove-\(UUID().uuidString)", isDirectory: true)
    }

    private func message(_ number: Int) -> String {
        ["From: Sender \(number) <sender\(number)@example.com>", "To: Jamie Rivera <jamie@example.com>", "Subject: Message \(number)",
         "Date: \(number) Nov 2026 10:00:00 +0000", "Message-ID: <m\(number)@example.com>"].joined(separator: "\r\n")
            + "\r\n\r\nBody of message \(number)\r\n"
    }

    /// A POP session that lists `uids` (numbered from 1), serves RETR for `retrieving`, then expects DELE for `deleting`,
    /// in order, and QUIT.
    private func session(uids: [String], retrieving: [Int] = [], deleting: [Int] = []) -> ScriptedByteStream {
        var steps: [ScriptedByteStream.Step] = [
            .expect("CAPA", reply: "+OK\r\nUSER\r\nUIDL\r\n.\r\n"),
            .expect("USER jamie@example.com", reply: "+OK\r\n"),
            .expect("PASS secret", reply: "+OK\r\n"),
            .expect("UIDL", reply: "+OK\r\n" + uids.enumerated().map { "\($0.offset + 1) \($0.element)\r\n" }.joined() + ".\r\n"),
        ]
        steps += retrieving.map { .expect("RETR \($0)", reply: "+OK\r\n" + message($0) + ".\r\n") }
        steps += deleting.map { .expect("DELE \($0)", reply: "+OK marked\r\n") }
        steps.append(.expect("QUIT", reply: "+OK bye\r\n"))
        return ScriptedByteStream(greeting: "+OK POP3 ready\r\n", script: steps)
    }

    /// A service on the store in `folder`, as after a relaunch, at a fixed time.
    private func service(_ folder: URL, _ stream: ScriptedByteStream, removing: RemoveFromServer?, at time: Date = start,
                         firstSyncLimit: Int? = nil) async -> POPMailService {
        let incoming = ServerSettings(mailProtocol: .pop3, host: "pop.example.com", security: .tls, username: "jamie@example.com",
                                      removeFromServer: removing)
        let service = POPMailService(account: account, incoming: incoming, credential: credential, store: LocalMailStore(folder: folder),
                                     sender: NoSending(), connector: ScriptedConnector([stream]))
        await service.setNow { time }
        if let firstSyncLimit { await service.setFirstSyncLimit(firstSyncLimit) }
        return service
    }

    @Test func mailStaysOnTheServerUnlessChosen() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b"], retrieving: [2, 1])
        let pop = await service(folder, first, removing: nil)
        try await pop.syncInbox()
        try await pop.perform(.deleteForever, on: [MessageSummary(id: "pop:a")])
        let later = session(uids: ["a", "b"])
        try await service(folder, later, removing: .never, at: Self.start.addingTimeInterval(400 * 86_400)).syncInbox()
        for stream in [first, later] { #expect(stream.mismatches.isEmpty && stream.isFinished) }
        #expect(!(first.lines + later.lines).contains { $0.hasPrefix("DELE") })
    }

    @Test func removedOnceDeletedFromPMail() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = session(uids: ["a", "b"], retrieving: [2, 1])
        let pop = await service(folder, first, removing: .whenDeleted)
        try await pop.syncInbox()
        // Moving one to the Trash keeps it on the server; deleting it for good there lets the server's copy go.
        try await pop.perform(.trash, on: [MessageSummary(id: "pop:b")])
        try await pop.perform(.deleteForever, on: [MessageSummary(id: "pop:a")])
        let second = session(uids: ["a", "b"], deleting: [1])
        try await service(folder, second, removing: .whenDeleted).syncInbox()
        // Gone from the server: nothing more to do, and b stays in PMail and on the server.
        let third = session(uids: ["b"])
        let pop3 = await service(folder, third, removing: .whenDeleted)
        try await pop3.syncInbox()
        #expect(try await pop3.listConversations(ListRequest(folderID: POPMailService.trashID)).conversations.map(\.latest?.id) == ["pop:b"])
        for stream in [first, second, third] { #expect(stream.mismatches.isEmpty && stream.isFinished) }
    }

    @Test func removedAWeekAfterArriving() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The first sync downloads the newest two; "a" stays on the server only.
        let first = session(uids: ["a", "b", "c"], retrieving: [3, 2])
        try await service(folder, first, removing: .afterAWeek, firstSyncLimit: 2).syncInbox()
        // Six days on, nothing has been there a week.
        let early = session(uids: ["a", "b", "c"])
        try await service(folder, early, removing: .afterAWeek, at: Self.start.addingTimeInterval(6 * 86_400)).syncInbox()
        // Eight days on, b and c go; a was never downloaded, and d just arrived.
        let late = session(uids: ["a", "b", "c", "d"], retrieving: [4], deleting: [2, 3])
        try await service(folder, late, removing: .afterAWeek, at: Self.start.addingTimeInterval(8 * 86_400)).syncInbox()
        let inbox = await LocalMailStore(folder: folder).summaries(in: POPMailService.inboxID)
        #expect(inbox.map(\.id) == ["pop:d", "pop:c", "pop:b"], "removed from the server, kept in PMail")
        for stream in [first, early, late] { #expect(stream.mismatches.isEmpty && stream.isFinished) }
    }

    /// Messages downloaded before PMail noted when they arrived count from the first sync that notes it.
    @Test func olderDownloadsCountFromWhenTheyWereFirstNoted() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        try await store.add(raw: Data(message(1).utf8), folderID: POPMailService.inboxID, id: "pop:a")
        try await store.setValue("1", forKey: POPMailService.firstSyncKey)
        let noted = session(uids: ["a"])
        try await service(folder, noted, removing: .afterADay).syncInbox()
        let dayLater = session(uids: ["a"], deleting: [1])
        try await service(folder, dayLater, removing: .afterADay, at: Self.start.addingTimeInterval(86_400)).syncInbox()
        for stream in [noted, dayLater] { #expect(stream.mismatches.isEmpty && stream.isFinished) }
    }
}

/// An outgoing server these tests never use.
private struct NoSending: MailSending {
    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {}
}
