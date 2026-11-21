import Foundation
import Testing
@testable import PMailKit

@Suite struct SyncStoreTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailSync-\(UUID().uuidString)", isDirectory: true)
    }

    private func message(_ id: String, thread: String, unread: Bool = true, attachment: Int = 0) -> MailMessage {
        var attachments: [PMailKit.Attachment] = []
        if attachment > 0 {
            attachments = [PMailKit.Attachment(id: "2", filename: "big.bin", mimeType: "application/octet-stream", size: attachment,
                                      data: Data(count: attachment))]
        }
        return MailMessage(summary: MessageSummary(id: id, threadID: thread, subject: "Hi", isUnread: unread), textBody: "Hello",
                           attachments: attachments, rawSource: Data("raw".utf8))
    }

    @Test func cacheKeepsFoldersPagesConversationsAndCalendars() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AccountCache(folder: folder, attachmentLimit: 10)
        #expect(await cache.folders() == nil)
        await cache.save(folders: [MailFolder(id: "INBOX", name: "INBOX", role: .inbox, unreadCount: 3)])
        #expect(await cache.folders()?.first?.unreadCount == 3)

        let page = ConversationPage(conversations: [Conversation(id: "t1", messages: [message("m1", thread: "t1").summary])], totalCount: 9,
                                    nextPageToken: "2")
        await cache.save(page: page, for: "INBOX|primary|0")
        let read = try #require(await cache.page(for: "INBOX|primary|0"))
        #expect(read.conversations.map(\.id) == ["t1"] && read.totalCount == 9 && read.nextPageToken == "2")
        #expect(await cache.page(for: "INBOX|social|0") == nil)

        await cache.save(conversation: "t1", messages: [message("m1", thread: "t1", attachment: 100), message("m2", thread: "t1")])
        let messages = try #require(await cache.conversation("t1"))
        #expect(messages.count == 2)
        #expect(messages[0].rawSource == nil, "the raw source isn't kept")
        #expect(messages[0].attachments.first?.data == nil && messages[0].attachments.first?.size == 100, "big attachments keep only their details")

        var read2 = messages[1].summary
        read2.isUnread = false
        await cache.update(summaries: [read2])
        #expect(await cache.conversation("t1")?[1].summary.isUnread == false, "flags follow what was done")

        await cache.save(syncState: MailSyncState("7:42"))
        #expect(await cache.syncState() == MailSyncState("7:42"))

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEvent(id: "e1", calendarID: "c", title: "Lunch", start: start, end: start.addingTimeInterval(3600))
        await cache.save(events: [event], covering: DateInterval(start: start, duration: 86_400))
        let events = try #require(await cache.events())
        #expect(events.events.map(\.title) == ["Lunch"] && events.interval.duration == 86_400)
        await cache.save(contacts: [Contact(id: "p1", givenName: "Alex")])
        #expect(await cache.contacts()?.first?.givenName == "Alex")

        await cache.clear()
        #expect(await cache.folders() == nil)
    }

    @Test func cacheLetsTheOldestConversationsGo() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AccountCache(folder: folder, conversationLimit: 10)
        for index in 0..<30 {
            await cache.save(conversation: "t\(index)", messages: [message("m\(index)", thread: "t\(index)")])
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Conversations").path)
        #expect(files.count <= 15, "\(files.count) kept")
        #expect(await cache.conversation("t29") != nil, "the newest stays")
    }

    @Test func queueKeepsScheduledAndOutboxMessages() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = MailQueue(folder: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let from = MailAddress(email: "jamie@example.com")
        let outgoing = QueuedMessage(message: OutgoingMessage(from: from, to: [MailAddress(email: "a@example.com")], subject: "Now",
                                                              textBody: "Sent when online"), queuedAt: now)
        let later = QueuedMessage(message: OutgoingMessage(from: from, subject: "Later",
                                                           attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))]),
                                  sendAt: now.addingTimeInterval(3600), queuedAt: now)
        try await queue.save(later)
        try await queue.save(outgoing)
        #expect(await queue.all().map(\.message.subject) == ["Now", "Later"], "the Outbox comes first")
        let scheduled = await queue.scheduled
        let outbox = await queue.outbox
        #expect(scheduled.map(\.message.subject) == ["Later"] && outbox.count == 1)
        #expect(await queue.due(at: now).map(\.message.subject) == ["Now"])
        #expect(await queue.due(at: now.addingTimeInterval(3601)).count == 2)
        #expect(await queue.item(later.id)?.message.attachments.first?.data == Data("x".utf8), "attachments are kept")

        var failed = outgoing
        failed.attempts = 2
        try await queue.save(failed)
        #expect(await queue.due(at: now.addingTimeInterval(30)).isEmpty, "a failed message waits before trying again")
        #expect(await queue.due(at: now.addingTimeInterval(61)).map(\.message.subject) == ["Now"])
        failed.lastAttempt = now.addingTimeInterval(600)
        try await queue.save(failed)
        #expect(await queue.due(at: now.addingTimeInterval(630)).isEmpty, "the wait counts from the last try, not from queuing")
        #expect(await queue.due(at: now.addingTimeInterval(661)).count == 1)
        #expect(QueuedMessage.retryDelay(afterAttempts: 1) == 30 && QueuedMessage.retryDelay(afterAttempts: 20) == 3600)

        let summary = later.summary
        #expect(summary.folderID == QueuedMessage.scheduledFolderID && summary.date == later.sendAt && summary.hasAttachments)
        #expect(QueuedMessage.id(fromSummaryID: summary.id) == later.id)
        await queue.remove(later.id)
        #expect(await queue.all().count == 1)
    }

    @Test func snoozesComeDueInOrder() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = SnoozeBook(file: folder.appendingPathComponent("Snoozes.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Conversation(id: "t1", messages: [MessageSummary(id: "m1", threadID: "t1", messageIDHeader: "<m1@example.com>")])
        let second = Conversation(id: "t2", messages: [MessageSummary(id: "m2", threadID: "t2", messageIDHeader: "<m2@example.com>")])
        try await book.add(Snooze(conversation: second, wakeAt: now.addingTimeInterval(7200)))
        try await book.add(Snooze(conversation: first, wakeAt: now.addingTimeInterval(3600)))
        #expect(await book.all().map(\.conversation.id) == ["t1", "t2"])
        #expect(await book.all().first?.messageIDs == ["<m1@example.com>"])
        #expect(await book.due(at: now.addingTimeInterval(3600)).map(\.conversation.id) == ["t1"])
        try await book.add(Snooze(conversation: first, wakeAt: now.addingTimeInterval(9000)))
        #expect(await book.all().count == 2, "snoozing again replaces the earlier snooze")
        #expect(await book.snooze(forConversation: "t1")?.wakeAt == now.addingTimeInterval(9000))
        if let id = await book.snooze(forConversation: "t2")?.id { await book.remove(id) }
        #expect(await book.all().map(\.conversation.id) == ["t1"])
    }

    @Test func laterTimesFollowTheClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        // Wednesday morning: later today, tomorrow, this weekend, next week.
        let wednesday = LaterTimes.snooze(now: date("2026-11-18T09:00:00Z"), calendar: calendar)
        #expect(wednesday.map(\.title) == ["Later today", "Tomorrow", "This weekend", "Next week"])
        #expect(wednesday.map(\.date) == [date("2026-11-18T18:00:00Z"), date("2026-11-19T08:00:00Z"), date("2026-11-21T08:00:00Z"),
                                          date("2026-11-23T08:00:00Z")])
        // Saturday evening: no "later today" or "this weekend".
        let saturday = LaterTimes.snooze(now: date("2026-11-21T19:00:00Z"), calendar: calendar)
        #expect(saturday.map(\.title) == ["Tomorrow", "Next week"])
        let schedule = LaterTimes.scheduleSend(now: date("2026-11-21T19:00:00Z"), calendar: calendar)
        #expect(schedule.map(\.date) == [date("2026-11-22T08:00:00Z"), date("2026-11-22T13:00:00Z"), date("2026-11-23T08:00:00Z")])
    }
}
