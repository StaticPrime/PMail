import Foundation
import Testing
@testable import PMailKit

@Suite struct LabelBookTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-labels-\(UUID().uuidString)", isDirectory: true)
    }

    private static let day = ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z") ?? .distantPast

    @Test func labelNamesMakeKeywordsAndReadBackFromThem() {
        #expect(LabelKeyword.keyword(for: "Work") == "PMail_Work")
        #expect(LabelKeyword.keyword(for: "Trips 2026") == "PMail_Trips_2026")
        #expect(LabelKeyword.keyword(for: "Café") == "PMail_Caf&C3&A9")
        #expect(LabelKeyword.keyword(for: "to_do & (later)") == "PMail_to&5Fdo_&26_&28later&29")
        #expect(LabelKeyword.keyword(for: "v1.2-final") == "PMail_v1.2-final")
        let names = ["Work", "Trips 2026", "Café crème", "to_do & (later)", "日本", "🐶 Pugs", #""quoted" \ back]slash*%{"#, "a\tb",
                     "  spaced  ", "100% & more_"]
        for name in names {
            let keyword = LabelKeyword.keyword(for: name)
            #expect(IMAPArgument.isAtom(keyword) && LabelKeyword.isLabel(keyword), "\(keyword) can go to a server")
            #expect(LabelKeyword.name(from: keyword) == name)
        }
        // Read without regard to case, since a server may change it; "&" without two hex digits after it stays itself.
        #expect(LabelKeyword.name(from: "pmail_caf&c3&a9") == "café")
        #expect(LabelKeyword.name(from: "PMail_R&D") == "R&D")
        #expect(LabelKeyword.name(from: "PMail_100&") == "100&")
        #expect(LabelKeyword.name(from: "PMail_&FF&FE") == "&FF&FE", "bytes that aren't UTF-8 read as they're spelled")
        for flag in ["\\Seen", "$Forwarded", "PMail_", "PMail", "Work", "PMail_a b", "PMail_(x)", "PMail_é", "PMail_a\"b"] {
            #expect(!LabelKeyword.isLabel(flag) && LabelKeyword.name(from: flag) == nil, "\(flag) isn't a label keyword")
        }
    }

    @Test func aKeywordSearchSendsOnlyKeywords() {
        var good = IMAPCommandBuilder()
        IMAPSearchKey.keyword("PMail_Caf&C3&A9").write(into: &good)
        #expect(good.parts == [.text("KEYWORD PMail_Caf&C3&A9")])
        // Anything that would break out of the command matches nothing instead.
        for bad in ["two words", "x) UID 1:*", "", "\\Seen"] {
            var builder = IMAPCommandBuilder()
            IMAPSearchKey.keyword(bad).write(into: &builder)
            #expect(builder.parts == [.text("NOT ALL")])
        }
    }

    @Test func labelsColorsAndWhatsKeptForMessagesLastAcrossLaunches() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("labels.json")
        let book = LabelBook(file: file)
        #expect(await book.labels().isEmpty)
        #expect(await book.keywordsAllowed() == nil)
        let work = try await book.create(named: "  Work ", colorHex: "16a766")
        #expect(work == LabelDefinition(id: "PMail_Work", name: "Work", colorHex: "#16A766"))
        #expect(try await book.create(named: "Trips 2026", colorHex: "not a color").colorHex == nil)
        await #expect(throws: PMailError.server("There’s already a label called “Work”.")) {
            try await book.create(named: "WORK", colorHex: nil)
        }
        await #expect(throws: PMailError.server("A label needs a name.")) { try await book.create(named: " \n", colorHex: nil) }
        let walk = MessageSummary(id: "imap:7:5:INBOX", date: Self.day, messageIDHeader: "<Walk@Example.com>")
        #expect(try await book.assign("PMail_Work", to: [walk, MessageSummary(id: "no-message-id")]) == 1)
        try await book.noteKeywords(allowed: false)

        let reopened = LabelBook(file: file)
        #expect(await reopened.labels().map(\.name) == ["Trips 2026", "Work"])
        #expect(await reopened.label(withID: "pmail_work")?.colorHex == "#16A766")
        #expect(await reopened.messages(withLabel: "PMail_Work") == [LabelBook.Labeled(key: "walk@example.com", date: Self.day)])
        #expect(await reopened.labels(forKeywords: [], messageID: "<WALK@example.com>") == ["PMail_Work"])
        #expect(await reopened.keywordsAllowed() == false)
        // Once any mailbox takes keywords, the server keeps labels.
        try await reopened.noteKeywords(allowed: true)
        try await reopened.noteKeywords(allowed: false)
        #expect(await LabelBook(file: file).keywordsAllowed() == true)

        // Renaming moves what's kept for messages to the new keyword and forgets the old one.
        let job = try await reopened.update("PMail_Work", name: "Job", colorHex: nil)
        #expect(job == LabelDefinition(id: "PMail_Job", name: "Job", colorHex: "#16A766"))
        #expect(await reopened.messages(withLabel: "PMail_Job").map(\.key) == ["walk@example.com"])
        #expect(await reopened.messages(withLabel: "PMail_Work").isEmpty)
        #expect(await reopened.discover(["PMail_Work"]) == false)
        // Changing only the case keeps the keyword.
        #expect(try await reopened.update("PMail_Job", name: "JOB", colorHex: "#000000")
                == LabelDefinition(id: "PMail_Job", name: "JOB", colorHex: "#000000"))
        await #expect(throws: PMailError.server("There’s already a label called “Trips 2026”.")) {
            try await reopened.update("PMail_Job", name: "trips 2026", colorHex: nil)
        }
        await #expect(throws: PMailError.notFound) { try await reopened.update("PMail_Nowhere", name: "X", colorHex: nil) }
        try await reopened.remove("PMail_Job")
        #expect(await reopened.messages(withLabel: "PMail_Job").isEmpty)

        let last = LabelBook(file: file)
        #expect(await last.labels().map(\.id) == ["PMail_Trips_2026"])
        #expect(await last.discover(["PMail_Job", "PMail_Work"]) == false)
        // Making a forgotten label again brings its keyword back.
        _ = try await last.create(named: "Work", colorHex: nil)
        try await last.remove("PMail_Work")
        _ = try await last.create(named: "Work", colorHex: nil)
        #expect(await LabelBook(file: file).labels(forKeywords: ["PMAIL_WORK"], messageID: nil) == ["PMail_Work"])
    }

    @Test func aMissingOrDamagedFileReadsAsAnEmptyBook() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("labels.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        let damaged = LabelBook(file: file)
        #expect(await damaged.labels().isEmpty)
        _ = try await damaged.create(named: "Fresh", colorHex: nil)
        #expect(await LabelBook(file: file).labels().map(\.name) == ["Fresh"])

        // Parts in the wrong shape are left out, and the rest kept.
        try Data(#"""
        {"version": 1, "labels": [{"id": "PMail_Kept", "name": "Kept", "colorHex": "#FF0000"}, {"id": "not a keyword", "name": "Odd"}],
         "assignments": 7, "forgotten": "x", "keywordsAllowed": "yes"}
        """#.utf8).write(to: file)
        let partial = LabelBook(file: file)
        #expect(await partial.labels() == [LabelDefinition(id: "PMail_Kept", name: "Kept", colorHex: "#FF0000")])
        #expect(await partial.keywordsAllowed() == nil)
        #expect(await partial.messages(withLabel: "PMail_Kept").isEmpty)
    }

    @Test func messagesGetTheirLabelsAsTheBookSpellsThem() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = LabelBook(file: folder.appendingPathComponent("labels.json"))
        _ = try await book.create(named: "Work", colorHex: "#FF0000")
        _ = try await book.create(named: "Gone", colorHex: nil)
        try await book.remove("PMail_Gone")
        try await book.assign("PMail_Work", to: [MessageSummary(id: "a", messageIDHeader: "<local@example.com>")])
        let summaries = [
            MessageSummary(id: "a", messageIDHeader: "<LOCAL@example.com>"),
            MessageSummary(id: "b", labelIDs: ["pmail_work", "PMail_Gone", "PMail_Trip"]),
            MessageSummary(id: "c"),
        ]
        let labeled = await book.labeling(summaries, mailboxFlags: ["\\Seen", "PMail_Old_Stuff", "$Junk"])
        #expect(labeled.map(\.labelIDs) == [["PMail_Work"], ["PMail_Work", "PMail_Trip"], []])
        // Keywords from another Mac joined the book, named from the keyword; the deleted one didn't come back.
        #expect(await book.labels().map(\.name) == ["Old Stuff", "Trip", "Work"])
        #expect(await book.folders().map(\.kind) == [.label, .label, .label])
    }
}
