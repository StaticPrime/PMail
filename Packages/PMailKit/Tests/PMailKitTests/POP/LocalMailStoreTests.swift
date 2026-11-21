import Foundation
import Testing
@testable import PMailKit

@Suite struct LocalMailStoreTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func raw(subject: String, from: String = "Sam Lee <sam@example.com>", day: Int, body: String = "Hello") -> Data {
        mimeWire("""
            From: \(from)
            To: Jamie Rivera <jamie@example.com>
            Subject: \(subject)
            Date: \(day) Nov 2026 10:00:00 +0000
            Message-ID: <\(subject.filter(\.isLetter))-\(day)@example.com>

            \(body)
            """)
    }

    @Test func addListAndReadBack() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        let older = try await store.add(raw: raw(subject: "Older", day: 1), folderID: "INBOX", id: "pop:1")
        let newer = try await store.add(raw: raw(subject: "Newer", day: 2), folderID: "INBOX", id: "pop:2", isUnread: false, isStarred: true)
        let sent = try await store.add(raw: raw(subject: "Mine", day: 3), folderID: "Sent")
        #expect(older.subject == "Older" && older.isUnread && !older.isStarred && older.folderID == "INBOX")
        #expect(newer.isStarred && !newer.isUnread)
        #expect(sent.id.hasPrefix("local:"))
        #expect(older.size == raw(subject: "Older", day: 1).count)
        #expect(await store.summaries(in: "INBOX").map(\.id) == ["pop:2", "pop:1"])
        #expect(await store.allSummaries().count == 3)
        #expect(await store.raw(for: "pop:1") == raw(subject: "Older", day: 1))
        #expect(await store.contains(id: "pop:2"))
        #expect(await !store.contains(id: "pop:9"))
        #expect(await store.raw(for: "pop:9") == nil)
        let counts = await store.counts(in: "INBOX")
        #expect(counts.total == 2 && counts.unread == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))
    }

    @Test func flagsMovesAndDeletionsPersistAcrossInstances() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let store = LocalMailStore(folder: folder)
            try await store.add(raw: raw(subject: "One", day: 1), folderID: "INBOX", id: "pop:1")
            try await store.add(raw: raw(subject: "Two", day: 2), folderID: "INBOX", id: "pop:2")
            try await store.add(raw: raw(subject: "Three", day: 3), folderID: "INBOX", id: "pop:3")
            try await store.setStarred(true, for: ["pop:1"])
            try await store.setUnread(false, for: ["pop:1", "pop:2"])
            try await store.move(ids: ["pop:2"], to: "Trash")
            try await store.delete(ids: ["pop:3"])
            try await store.setValue("yes", forKey: "synced")
        }
        let reopened = LocalMailStore(folder: folder)
        let one = try #require(await reopened.summary(for: "pop:1"))
        #expect(one.isStarred && !one.isUnread)
        #expect(await reopened.summary(for: "pop:2")?.folderID == "Trash")
        #expect(await reopened.summary(for: "pop:3") == nil)
        #expect(await reopened.knownIDs(among: ["pop:1", "pop:2", "pop:3", "pop:4"]) == ["pop:1", "pop:2", "pop:3"])
        #expect(await reopened.starredSummaries().map(\.id) == ["pop:1"])
        #expect(await reopened.value(forKey: "synced") == "yes")
        // Deleted IDs for messages gone from the server are forgotten.
        try await reopened.forgetDeletedIDs(withPrefix: "pop:", notIn: ["pop:1"])
        #expect(await reopened.knownIDs(among: ["pop:3"]).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("messages").path)
        #expect(files.count == 2)
    }

    @Test func searchIgnoresCaseAndAccentsAndNeedsEveryWord() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        try await store.add(raw: raw(subject: "Café crème on Friday", day: 1), folderID: "INBOX", id: "a")
        try await store.add(raw: raw(subject: "Budget", from: "Zoë Ñúñez <zoe@example.es>", day: 2), folderID: "INBOX", id: "b")
        try await store.add(raw: raw(subject: "Walks", day: 3, body: "Waffles wants a long walk"), folderID: "Sent", id: "c")
        #expect(await store.search("CAFE creme").map(\.id) == ["a"])
        #expect(await store.search("zoe nunez").map(\.id) == ["b"])
        #expect(await store.search("zoe@example.es").map(\.id) == ["b"])
        #expect(await store.search("waffles").map(\.id) == ["c"])
        #expect(await store.search("jamie").map(\.id) == ["c", "b", "a"])
        #expect(await store.search("jamie", in: "Sent").map(\.id) == ["c"])
        #expect(await store.search("cafe budget").isEmpty)
        #expect(await store.search("   ").isEmpty)
    }

    @Test func addingTheSameIDReplacesTheMessage() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalMailStore(folder: folder)
        try await store.add(raw: raw(subject: "First draft", day: 1), folderID: "Drafts", id: "draft:1", isUnread: false)
        let replaced = try await store.add(raw: raw(subject: "Second draft", day: 1), folderID: "Drafts", id: "draft:1", isUnread: false)
        #expect(replaced.isDraft)
        #expect(await store.summaries(in: "Drafts").map(\.subject) == ["Second draft"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("messages").path)
        #expect(files.count == 1)
    }

    @Test func aDamagedIndexStartsOverInsteadOfCrashing() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        let store = LocalMailStore(folder: folder)
        #expect(await store.allSummaries().isEmpty)
        try await store.add(raw: raw(subject: "Fresh", day: 1), folderID: "INBOX", id: "x")
        #expect(await LocalMailStore(folder: folder).summaries(in: "INBOX").map(\.subject) == ["Fresh"])
    }
}
