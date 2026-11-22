import Foundation
import Testing
@testable import PMailKit

/// The person's choices of category for senders, kept in a JSON file, and how they come before the rules.
struct InboxSorterTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailSorter-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("InboxCategories.json")
    }

    private static let sale = MessageSummary(id: "1", from: MailAddress(email: "Hello@Brand.Example"),
                                             subject: "Black Friday: 40% off everything",
                                             senderHints: SenderHints(canUnsubscribe: true))
    private static let friend = MessageSummary(id: "2", from: MailAddress(email: "alex@example.com"), subject: "Lunch?")

    @Test func aChosenCategoryComesBeforeTheRulesAndIsKept() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let sorter = InboxSorter(file: file)
        #expect(await sorter.categories(of: [Self.sale, Self.friend]) == [.promotions, .primary])
        #expect(await sorter.senderCategories().isEmpty)

        try await sorter.setCategory(.primary, forSender: " <HELLO@brand.example> ")
        try await sorter.setCategory(.social, forSender: "alex@example.com")
        #expect(await sorter.categories(of: [Self.sale, Self.friend]) == [.primary, .social])
        #expect(await sorter.chosenCategory(forSender: "hello@BRAND.example") == .primary)
        #expect(await sorter.senderCategories() == ["hello@brand.example": .primary, "alex@example.com": .social])

        // A fresh sorter reads them back from the file.
        let reopened = InboxSorter(file: file)
        #expect(await reopened.senderCategories() == ["hello@brand.example": .primary, "alex@example.com": .social])
        #expect(await reopened.category(of: Self.sale) == .primary)

        // Nil goes back to the rules; an empty address is ignored.
        try await reopened.setCategory(nil, forSender: "Hello@Brand.Example")
        try await reopened.setCategory(.updates, forSender: "  ")
        #expect(await reopened.category(of: Self.sale) == .promotions)
        #expect(await InboxSorter(file: file).senderCategories() == ["alex@example.com": .social])
        #expect(await InboxSorter(file: file).chosenCategory(forSender: "hello@brand.example") == nil)
    }

    @Test func aMissingOrDamagedFileMeansNoChoices() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(await InboxSorter(file: file).senderCategories().isEmpty, "no file yet")

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        let damaged = InboxSorter(file: file)
        #expect(await damaged.senderCategories().isEmpty)
        #expect(await damaged.category(of: Self.sale) == .promotions)
        // Choosing again writes a good file over it.
        try await damaged.setCategory(.updates, forSender: "hello@brand.example")
        #expect(await InboxSorter(file: file).senderCategories() == ["hello@brand.example": .updates])

        // Categories this version doesn't know, and odd entries, are skipped rather than losing the rest.
        let stored = #"{"version":2,"senders":{"news@paper.example":"forums","Deals@Shop.Example":"promotions","":"social"}}"#
        try Data(stored.utf8).write(to: file)
        #expect(await InboxSorter(file: file).senderCategories() == ["deals@shop.example": .promotions])
    }

    @Test func aChoiceThatCantBeSavedSaysSo() async throws {
        // The file's folder is a file, so nothing can be written there.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("PMailSorterBlocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let sorter = InboxSorter(file: blocker.appendingPathComponent("InboxCategories.json"))
        await #expect(throws: PMailError.self) { try await sorter.setCategory(.promotions, forSender: "a@example.com") }
        #expect(await sorter.senderCategories().isEmpty, "nothing changes when it couldn't be kept")
    }
}
