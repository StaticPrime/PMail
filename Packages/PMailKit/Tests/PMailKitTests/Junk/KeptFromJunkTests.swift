import Foundation
import Testing
@testable import PMailKit

/// Mail taken out of junk is known again by its Message-ID wherever it turns up (a move gives it another ID on an IMAP
/// server), between launches.
struct KeptFromJunkTests {
    @Test func messagesTakenOutOfJunkAreKnownByTheirMessageID() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-notjunk-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        func message(_ id: String, _ header: String?) -> MessageSummary {
            MessageSummary(id: id, subject: "Board meeting", date: Date(), messageIDHeader: header)
        }
        let inJunk = message("Junk/41", "<Board-1@Example.com>")
        await KeptFromJunk(file: file).keep([inJunk])
        let reopened = KeptFromJunk(file: file)
        let movedBack = message("INBOX/77", "<board-1@example.com>")
        let other = message("INBOX/78", "<other@example.com>")
        #expect(await reopened.kept(among: [movedBack, other]) == ["INBOX/77"])
    }
}
