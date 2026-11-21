import Foundation
import Testing
@testable import PMailKit

struct BlockedSendersTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailBlocked-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("BlockedSenders.json")
    }

    @Test func addressesAndDomainsMatch() throws {
        let address = BlockedSender.address(" Deals@Spam.Example ")
        #expect(address.value == "deals@spam.example" && address.id == "address:deals@spam.example")
        #expect(address.matches("DEALS@spam.example"))
        #expect(!address.matches("other@spam.example"))

        let domain = try #require(BlockedSender.domain(of: "news@Spam.Example"))
        #expect(domain.value == "spam.example" && domain.displayName == "everything from spam.example")
        #expect(domain.matches("anyone@spam.example") && domain.matches("bulk@mail.spam.example"), "subdomains too")
        #expect(!domain.matches("someone@notspam.example"), "only whole labels")
        #expect(!domain.matches("spam.example"), "an address needs an @")
        #expect(BlockedSender.domain(of: "no-at-sign") == nil)
    }

    @Test func blockedSendersAreKeptAndCanBeUnblocked() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let blocked = BlockedSenders(file: file)
        #expect(await blocked.all().isEmpty)
        let domain = try #require(BlockedSender.domain(of: "x@spam.example"))
        try await blocked.add([.address("deals@offers.example"), domain, .address("DEALS@offers.example")])
        #expect(await blocked.all().map(\.id) == ["address:deals@offers.example", "domain:spam.example"], "repeats are added once")

        let messages = [
            MessageSummary(id: "1", from: MailAddress(email: "deals@offers.example")),
            MessageSummary(id: "2", from: MailAddress(email: "win@mail.spam.example")),
            MessageSummary(id: "3", from: MailAddress(email: "alex@example.com")),
            MessageSummary(id: "4"),
        ]
        #expect(await blocked.blocked(among: messages).map(\.id) == ["1", "2"])

        // Read back from the file by a fresh store.
        let reopened = BlockedSenders(file: file)
        #expect(await reopened.isBlocked("anyone@spam.example"))
        try await reopened.remove(id: domain.id)
        #expect(await BlockedSenders(file: file).all().map(\.id) == ["address:deals@offers.example"])
    }
}
