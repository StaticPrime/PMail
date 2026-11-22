import Foundation
import Testing
@testable import PMailKit

/// The inbox's category tabs on a POP account, sorted from the mail kept on the Mac.
@Suite(.timeLimit(.minutes(1))) struct POPCategoryTests {
    private let account = Account(kind: .other, name: "Jamie Rivera", email: "jamie@example.com")
    private let incoming = ServerSettings(mailProtocol: .pop3, host: "pop.example.com", security: .tls, username: "jamie@example.com")
    private let credential = Credential.password(username: "jamie@example.com", password: "secret")

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-pop-categories-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }

    /// A message as a POP server sends it in RETR.
    private func message(_ number: Int, from: String, subject: String, headers: [String] = []) -> String {
        let lines = ["From: \(from)", "To: Jamie Rivera <jamie@example.com>", "Subject: \(subject)",
                     "Date: \(number) Nov 2026 10:00:00 +0000", "Message-ID: <m\(number)@example.com>"] + headers
        return lines.joined(separator: "\r\n") + "\r\n\r\nBody of message \(number)\r\n"
    }

    /// A POP session that lists `uids` (numbered from 1) and serves RETR for the given message numbers, in order.
    private func session(uids: [String], retrieving: [(number: Int, text: String)] = []) -> ScriptedByteStream {
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

    private static func request(_ category: InboxCategory, pageSize: Int = 50, pageIndex: Int = 0) -> ListRequest {
        ListRequest(folderID: POPMailService.inboxID, tabID: category.tabID, pageSize: pageSize, pageIndex: pageIndex)
    }

    private static func ids(_ page: ConversationPage) -> [String] {
        page.conversations.flatMap(\.messages).map(\.id)
    }

    @Test func theInboxIsSortedIntoCategoriesAndAChosenCategoryWins() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uids = ["a", "b", "c", "d", "e"]
        let unsubscribe = "List-Unsubscribe: <mailto:unsubscribe@lists.example>"
        let first = session(uids: uids, retrieving: [
            (5, message(5, from: "Weekly <newsletter@weekly.example>", subject: "This week in Swift",
                        headers: [unsubscribe, "List-Id: Weekly <weekly.example>", "Precedence: bulk"])),
            (4, message(4, from: "Facebook <notification@facebookmail.com>", subject: "Jamie commented on your photo")),
            (3, message(3, from: "Shop <no-reply@shop.example>", subject: "Your order has shipped")),
            (2, message(2, from: "Shop <deals@shop.example>", subject: "Weekend sale on everything", headers: [unsubscribe])),
            (1, message(1, from: "Alex Kim <alex@example.com>", subject: "Lunch tomorrow?")),
        ])
        // Each first page checks for new mail; there's none after the first.
        let later = (0..<5).map { _ in session(uids: uids) }
        let sorter = InboxSorter(file: folder.appendingPathComponent("InboxCategories.json"))
        let store = LocalMailStore(folder: folder.appendingPathComponent("mail", isDirectory: true))
        let pop = POPMailService(account: account, incoming: incoming, credential: credential, store: store,
                                 sender: IMAPRecordingSender(), connector: ScriptedConnector([first] + later), sorter: sorter)
        #expect(pop.capabilities.hasInboxTabs && pop.inboxTabs.map(\.id) == InboxCategory.allCases.map(\.tabID))

        let primary = try await pop.listConversations(Self.request(.primary))
        #expect(Self.ids(primary) == ["pop:a"] && primary.totalCount == 1 && primary.nextPageToken == nil)
        #expect(first.mismatches.isEmpty && first.isFinished)
        #expect(await store.summary(for: "pop:e")?.senderHints
                == SenderHints(canUnsubscribe: true, listID: "weekly.example", isBulk: true), "kept with the summary")

        #expect(Self.ids(try await pop.listConversations(Self.request(.promotions))) == ["pop:b"])
        #expect(Self.ids(try await pop.listConversations(Self.request(.transactions))) == ["pop:c"])
        #expect(Self.ids(try await pop.listConversations(Self.request(.social))) == ["pop:d"])
        #expect(Self.ids(try await pop.listConversations(Self.request(.updates))) == ["pop:e"])

        // The person puts the shop's deals in Primary.
        try await sorter.setCategory(.primary, forSender: "Deals@Shop.Example")
        let mixed = try await pop.listConversations(Self.request(.primary, pageSize: 1))
        #expect(Self.ids(mixed) == ["pop:b"] && mixed.totalCount == 2 && mixed.nextPageToken == "1")
        let next = try await pop.listConversations(Self.request(.primary, pageSize: 1, pageIndex: 1))
        #expect(Self.ids(next) == ["pop:a"] && next.nextPageToken == nil, "a later page doesn't check for mail")
        #expect(later.allSatisfy { $0.mismatches.isEmpty && $0.isFinished })

        // A search in a tab searches the whole inbox, as usual.
        let search = ListRequest(folderID: POPMailService.inboxID, tabID: InboxCategory.social.tabID, query: "sale")
        #expect(Self.ids(try await pop.listConversations(search)) == ["pop:b"])
    }

    @Test func withoutASorterThereAreNoTabs() {
        let pop = POPMailService(account: account, incoming: incoming, credential: credential,
                                 store: LocalMailStore(folder: temporaryFolder()), sender: IMAPRecordingSender(),
                                 connector: ScriptedConnector([]))
        #expect(!pop.capabilities.hasInboxTabs && pop.inboxTabs.isEmpty)
    }
}
