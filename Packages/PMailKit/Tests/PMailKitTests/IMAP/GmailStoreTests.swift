import Foundation
import Testing
@testable import PMailKit

/// A Google account's mail kept on this Mac: every list, count and conversation from one row per message.
@Suite struct GmailStoreTests {
    private static let start = Date(timeIntervalSince1970: 1_795_000_000)

    private func entry(_ uid: UInt32, thread: String, labels: [String], flags: [String] = ["\\Seen"], minutes: Double) -> GmailIndexEntry {
        GmailIndexEntry(id: "m\(uid)", thread: thread, uid: uid, date: Self.start.addingTimeInterval(minutes * 60), flags: flags, labels: labels)
    }

    private func summary(_ subject: String) -> MessageSummary {
        MessageSummary(id: "", from: MailAddress(name: "Alex", email: "alex@example.com"), subject: subject)
    }

    /// A store with places named as Gmail names them, and a few messages:
    /// t1: an unread inbox message in Social (101), with the account's reply (102, Sent).
    /// t2: a Primary inbox message (103), starred, labeled Work.
    /// t3: an archived draft (104).
    /// t4: a message in the trash (7 in Trash).
    private func store() async throws -> GmailStore {
        let store = try GmailStore(file: nil)
        await store.setState(GmailPlaceState(mailbox: "[Gmail]/All Mail", uidValidity: 11, highestUID: 104, modSeq: 500, count: 4), of: .allMail)
        await store.setState(GmailPlaceState(mailbox: "[Gmail]/Trash", uidValidity: 12, highestUID: 7, modSeq: 9, count: 1), of: .trash)
        await store.keep([
            entry(101, thread: "t1", labels: ["\\Inbox"], flags: [], minutes: 1),
            entry(102, thread: "t1", labels: ["\\Sent"], minutes: 5),
            entry(103, thread: "t2", labels: ["\\Inbox", "Work"], flags: ["\\Seen", "\\Flagged"], minutes: 3),
            entry(104, thread: "t3", labels: ["\\Draft"], minutes: 4),
        ], in: .allMail)
        await store.keep([entry(7, thread: "t4", labels: [], minutes: 6)], in: .trash)
        await store.keepHeaders(["m101": summary("Park day"), "m102": summary("Re: Park day"), "m103": summary("Invoice"),
                                 "m104": summary("Draft"), "m7": summary("Old news")])
        await store.setCategory("CATEGORY_SOCIAL", forUIDs: [101], replacing: true)
        return store
    }

    private func ids(_ store: GmailStore, _ view: GmailView) async -> [String] {
        await store.page(view, offset: 0, limit: 50).conversations.map(\.id)
    }

    @Test func listsComeFromLabelsTabsAndPlaces() async throws {
        let store = try await store()
        #expect(await ids(store, .label("\\Inbox")) == ["t1", "t2"], "newest message first, the reply counting")
        #expect(await ids(store, .inboxTab("CATEGORY_SOCIAL")) == ["t1"])
        #expect(await ids(store, .inboxTab("CATEGORY_PERSONAL")) == ["t2"], "Primary: what's in no other category")
        #expect(await ids(store, .label("\\Sent")) == ["t1"])
        #expect(await ids(store, .label("\\Draft")) == ["t3"])
        #expect(await ids(store, .label("Work")) == ["t2"])
        #expect(await ids(store, .starred) == ["t2"])
        #expect(await ids(store, .allMail) == ["t1", "t3", "t2"])
        #expect(await ids(store, .trash) == ["t4"])
        let social = await store.page(.inboxTab("CATEGORY_SOCIAL"), offset: 0, limit: 50).conversations
        #expect(social.first?.messages.map(\.subject) == ["Park day", "Re: Park day"], "the whole conversation, the reply too")
        let park = try #require(social.first?.messages.first)
        #expect(park.id == IMAPMessageID(mailbox: "[Gmail]/All Mail", uidValidity: 11, uid: 101).rawValue)
        #expect(park.isUnread && park.labelIDs == ["INBOX"] && park.threadID == "t1" && park.folderID == "[Gmail]/All Mail")
        let invoice = try #require(await store.page(.label("Work"), offset: 0, limit: 50).conversations.first?.messages.first)
        #expect(invoice.isStarred && !invoice.isUnread && Set(invoice.labelIDs) == ["INBOX", "Work"])
    }

    @Test func countsAreGmails() async throws {
        let store = try await store()
        #expect(await store.unreadConversations(in: .label("\\Inbox")) == 1)
        #expect(await store.unreadMessages(inTab: "CATEGORY_SOCIAL") == 1)
        #expect(await store.unreadMessages(inTab: "CATEGORY_PERSONAL") == 0)
        #expect(await store.messages(withLabel: "\\Draft") == 1)
        #expect(await store.page(.allMail, offset: 0, limit: 2).total == 3)
        #expect(await store.page(.allMail, offset: 2, limit: 2).conversations.map(\.id) == ["t2"], "the second page")
    }

    @Test func messagesWithoutHeadersWaitAndAreFetchedInboxFirstNewestFirst() async throws {
        let store = try GmailStore(file: nil)
        await store.setState(GmailPlaceState(mailbox: "[Gmail]/All Mail", uidValidity: 11, highestUID: 3, modSeq: 1, count: 3), of: .allMail)
        await store.keep([entry(1, thread: "a", labels: ["\\Inbox"], minutes: 1), entry(2, thread: "b", labels: [], minutes: 9),
                          entry(3, thread: "c", labels: ["\\Inbox"], minutes: 5)], in: .allMail)
        #expect(await ids(store, .allMail).isEmpty, "no rows without headers")
        #expect(await store.uidsMissingHeaders(in: .allMail, limit: 10) == [3, 1, 2])
        await store.keepHeaders(["m3": summary("C")])
        #expect(await ids(store, .label("\\Inbox")) == ["c"])
        #expect(await store.progress() == (1, 3))
    }

    @Test func changesHereShowAtOnce() async throws {
        let store = try await store()
        let parkDay = MessageSummary(id: IMAPMessageID(mailbox: "[Gmail]/All Mail", uidValidity: 11, uid: 101).rawValue)
        let ids = await store.ids(for: [parkDay])
        #expect(ids == ["m101"])
        await store.relabel(ids, adding: [], removing: ["\\Inbox"])
        #expect(await self.ids(store, .label("\\Inbox")) == ["t2"], "archived")
        await store.setUnread(false, for: ids)
        #expect(await store.unreadConversations(in: .label("\\Inbox")) == 0)
        await store.move(["m103"], to: .trash)
        #expect(await self.ids(store, .trash).contains("t2"))
        #expect(await !self.ids(store, .label("\\Inbox")).contains("t2"))
        #expect(await store.places(of: ["m103"]) == ["m103": .trash])
        // The trash's next sync brings its new UID; a known message keeps its row (and headers).
        await store.keep([entry(8, thread: "t2", labels: ["Work"], minutes: 3)].map { var moved = $0; moved.id = "m103"; return moved }, in: .trash)
        #expect(await store.id(at: 8, in: .trash) == "m103")
        #expect(await store.conversation("t2", in: .trash).first?.subject == "Invoice")
    }

    @Test func messagesGoneFromTheServerAreLetGo() async throws {
        let store = try await store()
        await store.removeMissing(from: .allMail, keeping: [101, 102, 103])
        #expect(await ids(store, .label("\\Draft")).isEmpty)
        #expect(await store.count(in: .allMail) == 3)
        await store.update([(uid: 103, flags: [], labels: ["\\Inbox"])], in: .allMail)
        let invoice = await store.conversation("t2", in: .allMail).first
        #expect(invoice?.isUnread == true && invoice?.isStarred == false && invoice?.labelIDs == ["INBOX"])
    }

    @Test func theStoreIsKeptBetweenLaunches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailGmail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(GmailStore.fileName)
        do {
            let store = try GmailStore(file: file)
            await store.setState(GmailPlaceState(mailbox: "[Gmail]/All Mail", uidValidity: 11, highestUID: 101, modSeq: 77, count: 1), of: .allMail)
            await store.keep([entry(101, thread: "t1", labels: ["\\Inbox"], minutes: 1)], in: .allMail)
            await store.keepHeaders(["m101": summary("Park day")])
        }
        let reopened = try GmailStore(file: file)
        #expect(await reopened.state(of: .allMail)?.modSeq == 77)
        #expect(await reopened.page(.label("\\Inbox"), offset: 0, limit: 50).conversations.first?.subject == "Park day")
    }
}
