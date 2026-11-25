import Foundation
import Testing
@testable import PMailKit

/// A pretend calendar that can be "offline", remembering what it was asked to do.
private actor PretendCalendar: CalendarService {
    var offline = false
    var refusesUpdates = false
    private(set) var events: [String: CalendarEvent] = [:]
    private(set) var calls: [String] = []
    private var counter = 0

    func setOffline(_ value: Bool) { offline = value }
    func setRefusesUpdates(_ value: Bool) { refusesUpdates = value }
    func add(_ event: CalendarEvent) { events[event.id] = event }

    private func reach() throws { if offline { throw PMailError.connectionFailed("The network is down.") } }

    func loadCalendars() async throws -> [CalendarInfo] { [CalendarInfo(id: "cal", name: "Calendar", isPrimary: true)] }

    func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try reach()
        return Array(events.values)
    }

    func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        try reach()
        counter += 1
        var saved = event
        saved.id = "server-\(counter)"
        events[saved.id] = saved
        calls.append("create \(event.title)")
        return saved
    }

    func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        try reach()
        if refusesUpdates { throw PMailError.http(status: 400, message: "Bad request") }
        guard events[event.id] != nil else { throw PMailError.notFound }
        events[event.id] = event
        calls.append("update \(event.title)")
        return event
    }

    func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        try reach()
        guard events.removeValue(forKey: event.id) != nil else { throw PMailError.notFound }
        calls.append("delete \(event.title)")
    }

    func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        try reach()
        events[event.id]?.myResponse = response
        calls.append("respond \(event.title)")
    }
}

/// Pretend contacts that can be "offline".
private actor PretendContacts: ContactsService {
    var offline = false
    private(set) var contacts: [String: Contact] = [:]
    private var counter = 0

    func setOffline(_ value: Bool) { offline = value }
    func add(_ contact: Contact) { contacts[contact.id] = contact }
    private func reach() throws { if offline { throw PMailError.timedOut } }

    func loadContacts() async throws -> [Contact] {
        try reach()
        return Array(contacts.values)
    }

    func create(_ contact: Contact) async throws -> Contact {
        try reach()
        counter += 1
        var saved = contact
        saved.id = "people/\(counter)"
        contacts[saved.id] = saved
        return saved
    }

    func update(_ contact: Contact) async throws -> Contact {
        try reach()
        contacts[contact.id] = contact
        return contact
    }

    func delete(_ contact: Contact) async throws {
        try reach()
        contacts[contact.id] = nil
    }
}

/// A pretend mail server with drafts, which can be "offline".
private actor PretendMail: MailService {
    nonisolated let capabilities = MailCapabilities()
    nonisolated let inboxTabs: [InboxTab] = []
    var offline = false
    private(set) var drafts: [String: OutgoingMessage] = [:]
    private var counter = 0

    func setOffline(_ value: Bool) { offline = value }
    private func reach() throws { if offline { throw PMailError.connectionFailed("The network is down.") } }

    func loadFolders() async throws -> [MailFolder] { [] }
    func listConversations(_ request: ListRequest) async throws -> ConversationPage { ConversationPage(conversations: []) }
    func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] { [] }
    func loadMessage(_ summary: MessageSummary) async throws -> MailMessage { throw PMailError.notFound }
    func loadAttachment(_ attachment: PMailKit.Attachment, in message: MessageSummary) async throws -> Data { Data() }
    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {}
    func send(_ message: OutgoingMessage) async throws {}
    func close() async {}

    func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        try reach()
        if let draft {
            guard drafts.removeValue(forKey: draft.id) != nil else { throw PMailError.notFound }
        }
        counter += 1
        let id = "draft-\(counter)"
        drafts[id] = message
        return MessageSummary(id: id, subject: message.subject, isDraft: true)
    }

    func deleteDraft(_ draft: MessageSummary) async throws {
        try reach()
        guard drafts.removeValue(forKey: draft.id) != nil else { throw PMailError.notFound }
    }
}

struct PendingChangesTests {
    private let start = WebFixtures.date("2026-11-24T15:00:00Z")

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailPending-\(UUID().uuidString)/Pending.json")
    }

    private func event(_ id: String, _ title: String) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: "cal", title: title, start: start, end: start.addingTimeInterval(3_600))
    }

    @Test func changesToTheSameEventMerge() {
        let made = event(LocalID.make(), "Lunch")
        var queue = CalendarChange.adding(.create(made, addingConference: false), to: [])
        var renamed = made
        renamed.title = "Team lunch"
        queue = CalendarChange.adding(.update(renamed, scope: .thisEvent, addingConference: true), to: queue)
        queue = CalendarChange.adding(.respond(renamed, response: .accepted), to: queue)
        #expect(queue.count == 1, "changes to something made here go into making it")
        if case let .create(event, adding) = queue.first {
            #expect(event.title == "Team lunch" && event.myResponse == .accepted && adding, "with the video meeting asked for later")
        } else {
            Issue.record("not a create: \(queue)")
        }
        #expect(CalendarChange.adding(.delete(renamed, scope: .thisEvent), to: queue).isEmpty, "made and deleted here: nothing to send")

        let existing = event("evt-1", "Standup")
        var first = existing
        first.title = "Standup (moved)"
        var second = existing
        second.title = "Standup (moved again)"
        queue = CalendarChange.adding(.update(first, scope: .thisEvent, addingConference: false), to: [])
        queue = CalendarChange.adding(.update(second, scope: .thisEvent, addingConference: false), to: queue)
        #expect(queue.map(\.event.title) == ["Standup (moved again)"], "the last change wins")
        queue = CalendarChange.adding(.update(second, scope: .allEvents, addingConference: false), to: queue)
        #expect(queue.count == 2, "a change to the whole series is its own")
        queue = CalendarChange.adding(.delete(existing, scope: .thisEvent), to: queue)
        #expect(queue.count == 1 && { if case .delete = queue[0] { true } else { false } }(), "deleting it is all that's left to send")
    }

    @Test func waitingChangesShowOnWhatsLoaded() {
        let kept = event("evt-1", "Standup")
        let gone = event("evt-2", "Lunch")
        var edited = kept
        edited.title = "Standup, earlier"
        let made = event(LocalID.make(), "Dentist")
        let queue: [CalendarChange] = [.update(edited, scope: .thisEvent, addingConference: false), .delete(gone, scope: .thisEvent),
                                       .create(made, addingConference: false), .respond(edited, response: .declined)]
        let shown = CalendarChange.applying(queue, to: [kept, gone])
        #expect(shown.map(\.title) == ["Standup, earlier", "Dentist"])
        #expect(shown.first?.myResponse == .declined)
    }

    @Test func aChangeIsToTheEventInItsOwnCalendarNotTheSameMeetingInAnother() {
        // The same meeting in someone's calendar the person follows has the same ID as theirs.
        var theirs = event("evt-1", "Planning")
        theirs.calendarID = "colleague"
        let mine = event("evt-1", "Planning")
        var moved = mine
        moved.start = start.addingTimeInterval(7_200)
        let shown = CalendarChange.applying([.update(moved, scope: .thisEvent, addingConference: false)], to: [theirs, mine])
        #expect(shown.map(\.calendarID) == ["colleague", "cal"], "both still show")
        #expect(shown.first { $0.calendarID == "colleague" }?.start == start, "theirs stays put")
        #expect(shown.first { $0.calendarID == "cal" }?.start == moved.start)
        #expect(CalendarChange.applying([.delete(mine, scope: .thisEvent)], to: [theirs, mine]).map(\.calendarID) == ["colleague"])
        #expect(CalendarChange.applying([.create(mine, addingConference: false)], to: [theirs]).count == 2, "mine is added beside theirs")
        #expect(mine.key != theirs.key)

        var elsewhere = mine
        elsewhere.calendarID = "home"
        #expect(CalendarChange.applying([.update(elsewhere, scope: .thisEvent, addingConference: false)], to: [mine]).map(\.calendarID) == ["home"],
                "moved to another calendar, it's still found")
    }

    @Test func changesWaitWhileOfflineAndGoOnceTheServerAnswers() async throws {
        let queueFile = file()
        defer { try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent()) }
        let server = PretendCalendar()
        await server.add(event("evt-1", "Standup"))
        await server.add(event("evt-2", "Lunch"))
        let pending = PendingChanges<CalendarChange>(file: queueFile)
        let made = event(LocalID.make(), "Dentist")
        var moved = event("evt-1", "Standup, earlier")
        moved.title = "Standup, earlier"
        await pending.add(.create(made, addingConference: false), merging: CalendarChange.adding)
        await pending.add(.update(moved, scope: .thisEvent, addingConference: false), merging: CalendarChange.adding)
        await pending.add(.delete(event("evt-2", "Lunch"), scope: .thisEvent), merging: CalendarChange.adding)
        await pending.add(.delete(event("evt-gone", "Old"), scope: .thisEvent), merging: CalendarChange.adding)

        await server.setOffline(true)
        let offline = await pending.send(using: server)
        let waiting = await pending.all().count
        #expect(offline.stoppedOffline && offline.sent == 0 && waiting == 4, "nothing goes while offline")
        #expect(FileManager.default.fileExists(atPath: queueFile.path), "kept in the account's folder")
        #expect(await PendingChanges<CalendarChange>(file: queueFile).all().count == 4, "and still there after quitting")

        await server.setOffline(false)
        let sent = await pending.send(using: server)
        #expect(!sent.stoppedOffline && sent.sent == 4 && sent.refused.isEmpty)
        #expect(sent.saved[made.id]?.id == "server-1", "the new event has its server ID")
        #expect(sent.deleted == ["evt-2", "evt-gone"], "deleting something already gone counts as done")
        #expect(await server.calls == ["create Dentist", "update Standup, earlier", "delete Lunch"], "in the order they were made")
        let left = await pending.all()
        #expect(left.isEmpty && !FileManager.default.fileExists(atPath: queueFile.path), "nothing left waiting")
    }

    @Test func aChangeTheServerTurnsDownIsDropped() async {
        let queueFile = file()
        defer { try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent()) }
        let server = PretendCalendar()
        await server.add(event("evt-1", "Standup"))
        await server.setRefusesUpdates(true)
        let pending = PendingChanges<CalendarChange>(file: queueFile)
        await pending.add(.update(event("evt-1", "Standup, later"), scope: .thisEvent, addingConference: false), merging: CalendarChange.adding)
        await pending.add(.create(event(LocalID.make(), "Dentist"), addingConference: false), merging: CalendarChange.adding)
        let result = await pending.send(using: server)
        #expect(result.refused == [PendingRefusal(title: "Standup, later", reason: "Bad request (error 400)")], "said why")
        let left = await pending.all()
        #expect(result.sent == 1 && left.isEmpty, "and the rest still goes")
    }

    @Test func draftsWaitAndGoToTheServer() async throws {
        let queueFile = file()
        defer { try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent()) }
        let server = PretendMail()
        let me = MailAddress(name: "Jamie", email: "jamie@example.com")
        let onServer = try #require(try await server.saveDraft(OutgoingMessage(from: me, subject: "Old plan", textBody: "v1"), replacing: nil))
        let pending = PendingChanges<WaitingDraft>(file: queueFile)
        var fresh = WaitingDraft(message: OutgoingMessage(from: me, subject: "Party", textBody: "Saturday?"), replaces: nil)
        #expect(fresh.summary?.isDraft == true && fresh.summary?.id == fresh.summaryID && fresh.summary?.subject == "Party", "a row for Drafts")
        await pending.add(fresh, merging: WaitingDraft.adding)
        fresh.message?.textBody = "Saturday at 7?"
        await pending.add(fresh, merging: WaitingDraft.adding)
        await pending.add(WaitingDraft(message: OutgoingMessage(from: me, subject: "New plan", textBody: "v2"), replaces: onServer), merging: WaitingDraft.adding)
        await pending.add(WaitingDraft(message: OutgoingMessage(from: me, subject: "Gone", textBody: ""), replaces: MessageSummary(id: "draft-missing")),
                          merging: WaitingDraft.adding)
        #expect(await pending.all().count == 3, "saving the same draft again replaces it")

        await server.setOffline(true)
        #expect(await pending.send(using: server).stoppedOffline)
        await server.setOffline(false)
        let sent = await pending.send(using: server)
        #expect(sent.sent == 3 && sent.refused.isEmpty)
        let saved = await server.drafts
        #expect(saved.values.map(\.subject).sorted() == ["Gone", "New plan", "Party"], "the old copy replaced, a vanished one saved anew")
        #expect(saved.values.first { $0.subject == "Party" }?.textBody == "Saturday at 7?", "the latest version")
        #expect(sent.saved[fresh.summaryID]?.subject == "Party")

        let doomed = try #require(sent.saved[fresh.summaryID])
        await pending.add(WaitingDraft(message: nil, replaces: doomed), merging: WaitingDraft.adding)
        #expect(await pending.send(using: server).deleted.count == 1, "a draft thrown away offline is deleted")
        #expect(await server.drafts[doomed.id] == nil)
        await pending.add(fresh, merging: WaitingDraft.adding)
        let freshID = fresh.id
        await pending.remove { $0.id == freshID }
        #expect(await pending.all().isEmpty, "one sent from its window is taken out")
    }

    @Test func aWaitingDraftThrownAwayGoesWithTheServerCopyItWasToReplace() async throws {
        let queueFile = file()
        defer { try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent()) }
        let server = PretendMail()
        let me = MailAddress(name: "Jamie", email: "jamie@example.com")
        let onServer = try #require(try await server.saveDraft(OutgoingMessage(from: me, subject: "Plan", textBody: "v1"), replacing: nil))
        let pending = PendingChanges<WaitingDraft>(file: queueFile)
        let fresh = WaitingDraft(message: OutgoingMessage(from: me, subject: "Party", textBody: "Saturday?"), replaces: nil)
        let edited = WaitingDraft(message: OutgoingMessage(from: me, subject: "Plan", textBody: "v2"), replaces: onServer)
        await pending.add(fresh, merging: WaitingDraft.adding)
        await pending.add(edited, merging: WaitingDraft.adding)
        await pending.discard(summaryID: fresh.summaryID)
        await pending.discard(summaryID: edited.summaryID)
        await pending.discard(summaryID: WaitingDraft.summaryPrefix + UUID().uuidString)
        let left = await pending.all()
        #expect(left.compactMap(\.summary).isEmpty, "nothing left to list in Drafts")
        #expect(left.count == 1 && left.first?.message == nil && left.first?.replaces?.id == onServer.id, "the server copy waits to be deleted")
        #expect(await pending.send(using: server).deleted.count == 1)
        #expect(await server.drafts.isEmpty)
        #expect(await pending.all().isEmpty)
    }

    @Test func contactsWaitAndGoTheSameWay() async throws {
        let queueFile = file()
        defer { try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent()) }
        let server = PretendContacts()
        await server.add(Contact(id: "people/existing", givenName: "Alex", familyName: "Kim"))
        let pending = PendingChanges<ContactChange>(file: queueFile)
        var made = Contact(id: LocalID.make(), givenName: "Biscuit", familyName: "Pug")
        await pending.add(.create(made), merging: ContactChange.adding)
        made.isStarred = true
        await pending.add(.update(made), merging: ContactChange.adding)
        await pending.add(.update(Contact(id: "people/existing", givenName: "Alex", familyName: "Kimura")), merging: ContactChange.adding)
        #expect(await pending.all().count == 2, "the star went into making the contact")
        let shown = ContactChange.applying(await pending.all(), to: [Contact(id: "people/existing", givenName: "Alex", familyName: "Kim")])
        #expect(shown.map(\.familyName) == ["Kimura", "Pug"] && shown.last?.isStarred == true)

        await server.setOffline(true)
        #expect(await pending.send(using: server).stoppedOffline)
        await server.setOffline(false)
        let sent = await pending.send(using: server)
        #expect(sent.saved[made.id]?.id == "people/1" && sent.saved[made.id]?.isStarred == true)
        #expect(await server.contacts["people/existing"]?.familyName == "Kimura")
        await pending.add(.delete(Contact(id: "people/1", givenName: "Biscuit")), merging: ContactChange.adding)
        #expect(await pending.send(using: server).deleted == ["people/1"])
        #expect(await server.contacts["people/1"] == nil)
    }
}
