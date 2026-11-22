import Foundation
import Testing
@testable import PMailKit

/// The inbox's category tabs on an IMAP account: sorted on the Mac from headers fetched once per message.
@Suite(.timeLimit(.minutes(1))) struct IMAPCategoryTests {
    private typealias Script = IMAPScript

    /// A message in the pretend inbox: who sent it, its subject, and header lines that say what kind of sender it is.
    private struct Mail {
        var uid: UInt32
        var from: String
        var subject: String
        var headers = ""
    }

    /// A service with an inbox sorter whose choices are kept in a folder of its own.
    private struct Harness {
        let service: IMAPMailService
        let sorter: InboxSorter
        let folder: URL

        init(_ streams: [ScriptedByteStream]) {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-categories-\(UUID().uuidString)",
                                                                                  isDirectory: true)
            sorter = InboxSorter(file: folder.appendingPathComponent("InboxCategories.json"))
            let account = Account(kind: .other, name: "Pug Tester", email: "pug@example.com")
            let incoming = ServerSettings(mailProtocol: .imap, host: "imap.example.com", port: 993, security: .tls,
                                          username: "pug@example.com")
            service = IMAPMailService(account: account, incoming: incoming,
                                      credential: .password(username: "pug@example.com", password: "secret"),
                                      sender: IMAPRecordingSender(), connector: ScriptedConnector(streams), sorter: sorter)
        }
    }

    private static let indexFetch = "(UID ENVELOPE BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED)])"
    private static let summaryFetch = "(\(IMAPClient.summaryItems))"
    private static let unsubscribe = "List-Unsubscribe: <mailto:unsubscribe@lists.example>\r\n"

    private static let lunch = Mail(uid: 5, from: "alex@example.com", subject: "Lunch tomorrow?")
    private static let sale = Mail(uid: 4, from: "deals@shop.example", subject: "Weekend sale on everything", headers: unsubscribe)
    private static let shipped = Mail(uid: 3, from: "no-reply@shop.example", subject: "Your order has shipped")
    private static let comment = Mail(uid: 2, from: "notification@facebookmail.com", subject: "Jamie commented on your photo")
    private static let newsletter = Mail(uid: 1, from: "newsletter@weekly.example", subject: "This week in Swift",
                                         headers: unsubscribe + "List-Id: Weekly <weekly.example>\r\n")

    private static func envelope(_ mail: Mail) -> String {
        let address = mail.from.split(separator: "@")
        let minute = String(format: "%02d", mail.uid % 60)
        return #"ENVELOPE ("Sat, 21 Nov 2026 13:\#(minute):00 -0500" "\#(mail.subject)" ((NIL NIL "\#(address[0])" "\#(address[1])")) "#
            + #"NIL NIL ((NIL NIL "pug" "example.com")) NIL NIL NIL "<m\#(mail.uid)@example.com>")"#
    }

    /// What the server answers sorting's FETCH with for a message.
    private static func indexLine(_ mail: Mail) -> String {
        "* \(mail.uid) FETCH (UID \(mail.uid) \(envelope(mail)) "
            + "BODY[HEADER.FIELDS (LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED)] \(Script.literal(mail.headers + "\r\n")))"
    }

    /// What the server answers a list's FETCH with for a message (no structure, so no snippet is fetched).
    private static func summaryLine(_ mail: Mail) -> String {
        #"* \#(mail.uid) FETCH (UID \#(mail.uid) FLAGS (\Seen) INTERNALDATE "21-Nov-2026 18:45:05 +0000" RFC822.SIZE 900 "#
            + "\(envelope(mail)) BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED)] "
            + "\(Script.literal(mail.headers + "\r\n")))"
    }

    private static func fetch(_ tag: String, _ uids: String, _ items: String, _ lines: [String]) -> ScriptedByteStream.Step {
        .expect("\(tag) UID FETCH \(uids) \(items)", reply: (lines + ["\(tag) OK Fetch completed"]).map { $0 + "\r\n" }.joined())
    }

    private static func request(_ category: InboxCategory, pageSize: Int = 50, pageToken: String? = nil) -> ListRequest {
        ListRequest(folderID: "INBOX", tabID: category.tabID, pageSize: pageSize, pageToken: pageToken)
    }

    private static func uids(_ page: ConversationPage) -> [UInt32] {
        page.conversations.flatMap(\.messages).map { IMAPMailService.uid(of: $0) }
    }

    @Test func theInboxIsSortedInBatchesOnceAndAChosenCategoryAppliesWithoutFetchingAgain() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", exists: 5, readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4 5"]),
            // Newest first, two to a FETCH, envelopes and a few header fields only.
            Self.fetch("A4", "4:5", Self.indexFetch, [Self.indexLine(Self.sale), Self.indexLine(Self.lunch)]),
            Self.fetch("A5", "2:3", Self.indexFetch, [Self.indexLine(Self.comment), Self.indexLine(Self.shipped)]),
            Self.fetch("A6", "1", Self.indexFetch, [Self.indexLine(Self.newsletter)]),
            Self.fetch("A7", "5", Self.summaryFetch, [Self.summaryLine(Self.lunch)]),
            // Promotions: already sorted, so only the page is fetched.
            Script.select("A8", exists: 5, readOnly: true),
            Script.ok("A9", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4 5"]),
            Self.fetch("A10", "4", Self.summaryFetch, [Self.summaryLine(Self.sale)]),
            // After the person puts the shop's deals in Primary.
            Script.select("A11", exists: 5, readOnly: true),
            Script.ok("A12", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4 5"]),
            Self.fetch("A13", "4:5", Self.summaryFetch, [Self.summaryLine(Self.sale), Self.summaryLine(Self.lunch)]),
            Script.select("A14", exists: 5, readOnly: true),
            Script.ok("A15", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4 5"]),
        ])
        let harness = Harness([stream])
        defer { try? FileManager.default.removeItem(at: harness.folder) }
        let service = harness.service
        await service.setCategorySorting(limit: 2000, batchSize: 2)

        let primary = try await service.listConversations(Self.request(.primary))
        #expect(Self.uids(primary) == [5] && primary.totalCount == 1 && primary.nextPageToken == nil)
        #expect(primary.conversations.first?.subject == "Lunch tomorrow?")
        let index = await service.categoryIndex
        #expect(index.uidValidity == 7)
        #expect(index.entries.mapValues(\.category) == [5: .primary, 4: .promotions, 3: .transactions, 2: .social, 1: .updates])
        #expect(index.entries[4]?.sender == "deals@shop.example")

        let promotions = try await service.listConversations(Self.request(.promotions))
        #expect(Self.uids(promotions) == [4] && promotions.totalCount == 1)
        let deal = try #require(promotions.conversations.first?.latest)
        #expect(deal.senderHints == SenderHints(canUnsubscribe: true), "the list's summaries carry what the headers say")
        #expect(deal.id == IMAPMessageID.inbox(4) && deal.from?.email == "deals@shop.example")

        try await harness.sorter.setCategory(.primary, forSender: "Deals@Shop.Example")
        let mixed = try await service.listConversations(Self.request(.primary))
        #expect(Self.uids(mixed) == [5, 4] && mixed.totalCount == 2)
        let noPromotions = try await service.listConversations(Self.request(.promotions))
        #expect(noPromotions.conversations.isEmpty && noPromotions.totalCount == 0 && noPromotions.nextPageToken == nil)

        #expect(stream.lines.filter { $0.contains("ENVELOPE BODY.PEEK") }.count == 3, "each message was sorted once")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func newMailIsSortedAloneAndMessagesThatLeftAreForgotten() async throws {
        let promos = (1...4).map { Mail(uid: UInt32($0), from: "offers@shop.example", subject: "Offer number \($0)") }
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", exists: 3, readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3"]),
            Self.fetch("A4", "1:3", Self.indexFetch, promos[0..<3].map(Self.indexLine)),
            Self.fetch("A5", "2:3", Self.summaryFetch, [Self.summaryLine(promos[1]), Self.summaryLine(promos[2])]),
            // Later: the first one was archived elsewhere and a fourth arrived.
            Script.select("A6", exists: 3, readOnly: true),
            Script.ok("A7", "UID SEARCH ALL", untagged: ["* SEARCH 2 3 4"]),
            Self.fetch("A8", "4", Self.indexFetch, [Self.indexLine(promos[3])]),
            Self.fetch("A9", "2", Self.summaryFetch, [Self.summaryLine(promos[1])]),
        ])
        let harness = Harness([stream])
        defer { try? FileManager.default.removeItem(at: harness.folder) }
        let service = harness.service

        let first = try await service.listConversations(Self.request(.promotions, pageSize: 2))
        #expect(Self.uids(first) == [3, 2] && first.totalCount == 3 && first.nextPageToken == "1")
        let second = try await service.listConversations(Self.request(.promotions, pageSize: 2, pageToken: "1"))
        #expect(Self.uids(second) == [2] && second.totalCount == 3 && second.nextPageToken == nil)
        #expect(Set(await service.categoryIndex.entries.keys) == [2, 3, 4])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func messagesPastTheNewestAreListedUnderPrimaryUnsorted() async throws {
        let old = [Mail(uid: 1, from: "deals@shop.example", subject: "An old sale"),
                   Mail(uid: 2, from: "sam@example.com", subject: "Old news")]
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", exists: 4, readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4"]),
            Self.fetch("A4", "3:4", Self.indexFetch, [Self.indexLine(Mail(uid: 3, from: "alex@example.com", subject: "Hi")),
                                                       Self.indexLine(Mail(uid: 4, from: "deals@shop.example", subject: "Sale"))]),
            Self.fetch("A5", "2:3", Self.summaryFetch, [Self.summaryLine(old[1]),
                                                         Self.summaryLine(Mail(uid: 3, from: "alex@example.com", subject: "Hi"))]),
            Script.select("A6", exists: 4, readOnly: true),
            Script.ok("A7", "UID SEARCH ALL", untagged: ["* SEARCH 1 2 3 4"]),
            Self.fetch("A8", "1", Self.summaryFetch, [Self.summaryLine(old[0])]),
        ])
        let harness = Harness([stream])
        defer { try? FileManager.default.removeItem(at: harness.folder) }
        let service = harness.service
        await service.setCategorySorting(limit: 2, batchSize: 10)

        let first = try await service.listConversations(Self.request(.primary, pageSize: 2))
        #expect(Self.uids(first) == [3, 2] && first.totalCount == 3 && first.nextPageToken == "1")
        let rest = try await service.listConversations(Self.request(.primary, pageSize: 2, pageToken: "1"))
        #expect(Self.uids(rest) == [1] && rest.nextPageToken == nil, "even an old sale: it was never sorted")
        #expect(Set(await service.categoryIndex.entries.keys) == [3, 4])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aNewUIDValiditySortsTheInboxAgain() async throws {
        let before = Mail(uid: 1, from: "deals@shop.example", subject: "Sale")
        let after = Mail(uid: 1, from: "alex@example.com", subject: "Hello again")
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            Script.select("A2", exists: 1, uidValidity: 7, readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH 1"]),
            Self.fetch("A4", "1", Self.indexFetch, [Self.indexLine(before)]),
            Script.select("A5", exists: 1, uidValidity: 8, readOnly: true),
            Script.ok("A6", "UID SEARCH ALL", untagged: ["* SEARCH 1"]),
            Self.fetch("A7", "1", Self.indexFetch, [Self.indexLine(after)]),
            Self.fetch("A8", "1", Self.summaryFetch, [Self.summaryLine(after)]),
        ])
        let harness = Harness([stream])
        defer { try? FileManager.default.removeItem(at: harness.folder) }
        let service = harness.service

        let first = try await service.listConversations(Self.request(.primary))
        #expect(first.conversations.isEmpty && first.totalCount == 0)
        let again = try await service.listConversations(Self.request(.primary))
        #expect(again.conversations.first?.latest?.id == IMAPMessageID.inbox(1, uidValidity: 8) && again.totalCount == 1)
        #expect(await service.categoryIndex.uidValidity == 8)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func searchesOtherFoldersAndAnEmptyInbox() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(), script: [
            Script.signIn("A1"),
            // A search in a tab searches the whole inbox, as usual.
            Script.select("A2", exists: 3, readOnly: true),
            Script.ok("A3", #"UID SEARCH OR OR FROM "frisbee" SUBJECT "frisbee" TEXT "frisbee""#, untagged: ["* SEARCH"]),
            // Another folder lists as usual.
            Script.select("A4", "Archive", exists: 0, readOnly: true),
            // An empty inbox has nothing to sort.
            Script.select("A5", exists: 0, readOnly: true),
        ])
        let harness = Harness([stream])
        defer { try? FileManager.default.removeItem(at: harness.folder) }
        let service = harness.service
        #expect(service.capabilities.hasInboxTabs && service.inboxTabs == InboxCategory.tabs)

        let search = ListRequest(folderID: "INBOX", tabID: InboxCategory.promotions.tabID, query: "frisbee")
        #expect(try await service.listConversations(search).conversations.isEmpty)
        let archive = ListRequest(folderID: "Archive", tabID: InboxCategory.promotions.tabID)
        #expect(try await service.listConversations(archive).totalCount == 0)
        let empty = try await service.listConversations(Self.request(.updates))
        #expect(empty.conversations.isEmpty && empty.totalCount == 0 && empty.nextPageToken == nil)
        #expect(await service.categoryIndex.entries.isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }
}
