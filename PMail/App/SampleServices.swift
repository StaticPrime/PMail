#if DEBUG
import Foundation
import PMailKit

/// Made-up services for the sample accounts: everything happens in memory, a moment later, as if from a server.
struct SampleServiceFactory: ServiceFactory {
    var today: @Sendable () -> Date = { AppClock.now() }

    func services(for account: Account, secrets: any SecretStore, storage: AccountStorage?) -> AccountServices {
        let now = today()
        let mail = SampleData.mail(for: account, today: now)
        return AccountServices(
            mail: SampleMailService(account: account, folders: mail.folders, messages: mail.messages, sorter: storage?.sorter),
            calendar: SampleCalendarService(account: account, calendars: SampleData.calendars(for: account),
                                            events: SampleData.events(for: account, today: now)),
            contacts: SampleContactsService(contacts: SampleData.contacts(for: account)))
    }
}

/// A short pause, as a real server would take.
private func pause() async { try? await Task.sleep(for: .milliseconds(40)) }

actor SampleMailService: MailService {
    let account: Account
    private var folders: [MailFolder]
    private var messages: [SampleData.Message]
    private var counter = 0
    /// Every message sent, for the self-test.
    private(set) var sent: [OutgoingMessage] = []
    /// Every action asked for, for the self-test.
    private(set) var actions: [(MailAction, [String])] = []

    nonisolated let capabilities: MailCapabilities
    nonisolated let inboxTabs: [InboxTab]
    /// Sorts a folder account's inbox into categories, as the real IMAP and POP services do.
    nonisolated let sorter: InboxSorter?

    init(account: Account, folders: [MailFolder], messages: [SampleData.Message], sorter: InboxSorter? = nil) {
        self.account = account
        self.folders = folders
        self.messages = messages
        switch account.kind {
        case .google:
            capabilities = MailCapabilities(usesLabels: true, canStar: true, canMarkImportant: true, hasInboxTabs: true,
                                            canLabel: true, canEditLabels: true, syncsSignature: true)
            serverSignature = #"<div><b>Jamie Rivera</b> · <a href="https://pugglesoft.example/">PuggleSoft</a></div>"#
            inboxTabs = [InboxTab(id: "CATEGORY_PERSONAL", name: "Primary", symbol: "tray"),
                         InboxTab(id: "CATEGORY_PROMOTIONS", name: "Promotions", symbol: "tag"),
                         InboxTab(id: "CATEGORY_SOCIAL", name: "Social", symbol: "person.2"),
                         InboxTab(id: "CATEGORY_UPDATES", name: "Updates", symbol: "info.circle")]
            self.sorter = nil
        case .microsoft:
            capabilities = MailCapabilities(canMarkImportant: true, hasInboxTabs: true, canLabel: true, canEditLabels: true)
            inboxTabs = [InboxTab(id: "focused", name: "Focused", symbol: "scope"), InboxTab(id: "other", name: "Other", symbol: "tray.full")]
            self.sorter = nil
        default:
            capabilities = MailCapabilities(hasInboxTabs: sorter != nil, canLabel: true, canEditLabels: true)
            inboxTabs = sorter == nil ? [] : InboxCategory.tabs
            self.sorter = sorter
        }
    }

    var sentMessages: [OutgoingMessage] { sent }
    var actionLog: [(MailAction, [String])] { actions }

    private func role(_ id: String?) -> FolderRole? { folders.first { $0.id == id }?.role }

    /// Whether a message is in a folder or label.
    private func isIn(_ message: SampleData.Message, folder id: String?) -> Bool {
        let summary = message.summary
        guard let id else { return !summary.labelIDs.contains("SPAM") && !summary.labelIDs.contains("TRASH") && !summary.isDraft }
        switch role(id) {
        case .starred?: return summary.isStarred && summary.folderID != role(.trash) && !summary.labelIDs.contains("TRASH")
        case .important?: return summary.isImportant
        default:
            // A label lists what has it, wherever it is.
            let isLabel = folders.first { $0.id == id }?.kind == .label
            return capabilities.usesLabels || isLabel ? summary.labelIDs.contains(id) : summary.folderID == id
        }
    }

    private func role(_ role: FolderRole) -> String? { folders.first { $0.role == role }?.id }

    func loadFolders() async throws -> [MailFolder] {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        return folders.map { folder in
            var folder = folder
            let inside = messages.filter { isIn($0, folder: folder.id) }
            folder.unreadCount = inside.filter(\.summary.isUnread).count
            folder.totalCount = inside.count
            return folder
        }
    }

    func listConversations(_ request: ListRequest) async throws -> ConversationPage {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        var matching = messages.filter { isIn($0, folder: request.folderID) }
        if let category = InboxCategory(tabID: request.tabID), let sorter {
            // Sorted on the Mac, as a real IMAP or POP account's inbox is.
            var sorted: [SampleData.Message] = []
            for message in matching {
                if await sorter.category(of: message.summary) == category { sorted.append(message) }
            }
            matching = sorted
        } else if let tab = request.tabID {
            matching = matching.filter { $0.summary.labelIDs.contains(tab) }
        }
        if let query = request.query?.lowercased(), !query.isEmpty {
            let words = query.split(separator: " ").map(String.init)
            matching = matching.filter { message in
                let text = [message.summary.subject, message.summary.snippet, message.summary.from?.displayName ?? "", message.summary.from?.email ?? "",
                            message.text ?? message.html ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        // A conversation shows every message it has (your replies too), apart from Trash and Spam.
        let threads = Set(matching.map(\.summary.threadID))
        let shown = messages.filter { threads.contains($0.summary.threadID) && (isIn($0, folder: request.folderID) || role(request.folderID) == .inbox
            && !$0.summary.labelIDs.contains("TRASH") && $0.summary.folderID != role(.trash)) }
        let conversations = Conversation.group(shown.map(\.summary))
        let start = request.pageIndex * request.pageSize
        let page = Array(conversations.dropFirst(start).prefix(request.pageSize))
        let hasMore = start + request.pageSize < conversations.count
        return ConversationPage(conversations: page, totalCount: conversations.count, nextPageToken: hasMore ? "\(request.pageIndex + 1)" : nil)
    }

    func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        return messages.filter { $0.summary.threadID == id }.sorted { $0.summary.date < $1.summary.date }.map(mailMessage)
    }

    private func mailMessage(_ message: SampleData.Message) -> MailMessage {
        MailMessage(summary: message.summary, htmlBody: message.html, textBody: message.text, attachments: message.attachments,
                    inlineParts: message.inline, rawSource: Data("Subject: \(message.summary.subject)\r\n\r\n\(message.text ?? "")".utf8))
    }

    func loadMessage(_ summary: MessageSummary) async throws -> MailMessage {
        guard let message = messages.first(where: { $0.summary.id == summary.id }) else { throw PMailError.notFound }
        return mailMessage(message)
    }

    func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data {
        guard let data = messages.first(where: { $0.summary.id == message.id })?.attachments.first(where: { $0.id == attachment.id })?.data
        else { throw PMailError.notFound }
        return data
    }

    func perform(_ action: MailAction, on summaries: [MessageSummary]) async throws {
        await pause()
        actions.append((action, summaries.map(\.id)))
        let ids = Set(summaries.map(\.id))
        let labels = capabilities.usesLabels
        for index in messages.indices where ids.contains(messages[index].summary.id) {
            var summary = messages[index].summary
            func move(to role: FolderRole) {
                if labels {
                    summary.labelIDs.removeAll { ["INBOX", "SPAM", "TRASH"].contains($0) }
                    if let id = self.role(role) { summary.labelIDs.append(id) }
                } else {
                    summary.folderID = self.role(role) ?? summary.folderID
                }
            }
            switch action {
            case .markRead: summary.isUnread = false; summary.labelIDs.removeAll { $0 == "UNREAD" }
            case .markUnread: summary.isUnread = true
            case .star: summary.isStarred = true
            case .unstar: summary.isStarred = false
            case .markImportant: summary.isImportant = true
            case .markNotImportant: summary.isImportant = false
            case .archive:
                if labels { summary.labelIDs.removeAll { $0 == "INBOX" } } else { summary.folderID = role(.archive) ?? summary.folderID }
            case .moveToInbox, .notSpam: move(to: .inbox)
            case .trash: move(to: .trash)
            case .markSpam: move(to: .spam)
            case .deleteForever: summary.id = "deleted-" + summary.id
            case let .move(target):
                if labels {
                    summary.labelIDs.removeAll { $0 == "INBOX" }
                    summary.labelIDs.append(target)
                } else {
                    summary.folderID = target
                }
            case let .addLabel(label): if !summary.labelIDs.contains(label) { summary.labelIDs.append(label) }
            case let .removeLabel(label): summary.labelIDs.removeAll { $0 == label }
            }
            messages[index].summary = summary
        }
        messages.removeAll { $0.summary.id.hasPrefix("deleted-") }
    }

    func send(_ message: OutgoingMessage) async throws {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        sent.append(message)
        counter += 1
        let id = "sent-\(counter)"
        let summary = MessageSummary(id: id, threadID: message.threadID ?? id, folderID: role(.sent), labelIDs: capabilities.usesLabels ? ["SENT"] : [],
                                     from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                                     snippet: HTMLText.snippet(from: message.textBody), date: AppClock.now(), messageIDHeader: message.messageID,
                                     inReplyTo: message.inReplyTo, references: message.references)
        messages.append(SampleData.Message(summary: summary, html: nil, text: message.textBody))
    }

    func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? {
        if let draft { messages.removeAll { $0.summary.id == draft.id } }
        counter += 1
        let id = "draft-\(counter)"
        let summary = MessageSummary(id: id, threadID: message.threadID ?? id, folderID: role(.drafts), labelIDs: capabilities.usesLabels ? ["DRAFT"] : [],
                                     from: message.from, to: message.to, subject: message.subject, snippet: HTMLText.snippet(from: message.textBody),
                                     date: AppClock.now(), isDraft: true)
        messages.append(SampleData.Message(summary: summary, html: nil, text: message.textBody))
        return summary
    }

    func deleteDraft(_ draft: MessageSummary) async throws {
        messages.removeAll { $0.summary.id == draft.id }
    }

    func unreadCounts(inTabs tabs: [InboxTab]) async throws -> [String: Int] {
        await pause()
        let unread = messages.filter { isIn($0, folder: role(.inbox)) && $0.summary.isUnread }.map(\.summary)
        var counts: [String: Int] = [:]
        for tab in tabs {
            if let category = InboxCategory(tabID: tab.id), let sorter {
                var count = 0
                for summary in unread {
                    if await sorter.category(of: summary) == category { count += 1 }
                }
                counts[tab.id] = count
            } else {
                counts[tab.id] = unread.filter { $0.labelIDs.contains(tab.id) }.count
            }
        }
        return counts
    }

    // MARK: The signature (a Google account keeps it on its server)

    private var serverSignature: String?

    /// The signature as the server has it, for the self-test.
    var savedSignature: String? { serverSignature }

    func loadSignature() async throws -> String? {
        await pause()
        guard capabilities.syncsSignature else { throw PMailError.notSupported("No signature on this server.") }
        return serverSignature
    }

    func saveSignature(html: String) async throws {
        await pause()
        guard capabilities.syncsSignature else { throw PMailError.notSupported("No signature on this server.") }
        serverSignature = html.isEmpty ? nil : html
    }

    // MARK: Labels

    func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        await pause()
        counter += 1
        let label = MailFolder(id: "Label_new\(counter)", name: name, kind: .label, colorHex: colorHex)
        folders.append(label)
        return label
    }

    func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        await pause()
        guard let index = folders.firstIndex(where: { $0.id == label.id }) else { throw PMailError.notFound }
        folders[index].name = name
        folders[index].colorHex = colorHex
        return folders[index]
    }

    func deleteLabel(_ label: MailFolder) async throws {
        await pause()
        folders.removeAll { $0.id == label.id }
        for index in messages.indices { messages[index].summary.labelIDs.removeAll { $0 == label.id } }
    }

    func close() async {}

    // MARK: Keeping up to date

    /// The state is the newest inbox message's date: anything newer is new.
    func checkForNewMail(since state: MailSyncState?) async throws -> NewMail {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        let inbox = messages.filter { isIn($0, folder: role(.inbox)) }.map(\.summary)
        let newest = inbox.map(\.date).max() ?? .distantPast
        let unread = inbox.filter(\.isUnread).count
        // Seconds since the reference date round-trip exactly, so a message isn't reported twice.
        guard let state, let seconds = Double(state.value) else {
            return NewMail(messages: [], state: MailSyncState(String(newest.timeIntervalSinceReferenceDate)), inboxUnread: unread)
        }
        let since = Date(timeIntervalSinceReferenceDate: seconds)
        let arrived = inbox.filter { $0.date > since }.sorted { $0.date > $1.date }
        return NewMail(messages: arrived, state: MailSyncState(String(max(newest, since).timeIntervalSinceReferenceDate)), inboxUnread: unread)
    }

    /// A message's labels and folder, found by its subject, for the self-test.
    func labels(ofSubject subject: String) -> [String] {
        guard let summary = messages.first(where: { $0.summary.subject == subject })?.summary else { return [] }
        return summary.labelIDs + [summary.folderID].compactMap { $0 }
    }

    func findMessages(withMessageIDs messageIDs: [String]) async throws -> [MessageSummary] {
        await pause()
        if failsLikeOffline { throw PMailError.connectionFailed("the network is off") }
        let wanted = Set(messageIDs)
        return messages.map(\.summary).filter { $0.messageIDHeader.map(wanted.contains) == true && !$0.labelIDs.contains("TRASH") }
    }

    /// While set, every call fails as if the network were down (for the self-test).
    private(set) var failsLikeOffline = false

    func setFailsLikeOffline(_ fails: Bool) { failsLikeOffline = fails }

    /// A new message arriving in the inbox, as if from outside (for the self-test).
    func deliver(from: MailAddress, subject: String, text: String, html: String? = nil, at date: Date) {
        counter += 1
        let id = "arrived-\(counter)"
        let labels = capabilities.usesLabels ? ["INBOX", "CATEGORY_PERSONAL", "UNREAD"] : []
        let summary = MessageSummary(id: id, folderID: capabilities.usesLabels ? nil : role(.inbox), labelIDs: labels, from: from,
                                     to: [account.address], subject: subject, snippet: HTMLText.snippet(from: text), date: date,
                                     isUnread: true, messageIDHeader: "<\(id)@example.com>")
        messages.append(SampleData.Message(summary: summary, html: html, text: text))
    }
}

/// The internet for sample runs: every picture is the same small made-up one and every style sheet is empty, so
/// automated runs never reach a real server. It keeps what was asked for, for the self-test.
nonisolated final class SampleRemoteFetcher: RemoteFetcher, @unchecked Sendable {
    static let shared = SampleRemoteFetcher()
    private let lock = NSLock()
    private var asked: [URL] = []

    var requests: [URL] { lock.withLock { asked } }

    func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw PMailError.notFound }
        lock.withLock { asked.append(url) }
        let isStyle = url.pathExtension.lowercased() == "css"
        let body = isStyle ? Data("body {}".utf8) : SampleData.samplePicture
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isStyle ? "text/css" : "image/png"])
        return (body, response!)
    }
}

/// Tor for sample runs: connects in half a second without going anywhere, so automated runs never reach the Tor
/// network.
nonisolated final class SampleTor: TorRunner, @unchecked Sendable {
    private let onEvent: @Sendable (TorEvent) -> Void
    private let lock = NSLock()
    private var stopped = false

    init(onEvent: @escaping @Sendable (TorEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let steps: [(Double, TorEvent)] = [(0.1, .progress(10, "Connecting to a relay")), (0.3, .progress(50, "Loading relay descriptors")),
                                           (0.5, .progress(100, "Done"))]
        for (delay, event) in steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !lock.withLock({ stopped }) else { return }
                onEvent(event)
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        let onEvent = onEvent
        DispatchQueue.global().async { onEvent(.exited(0)) }
    }
}

actor SampleCalendarService: CalendarService {
    let account: Account
    private var calendars: [CalendarInfo]
    private var events: [CalendarEvent]
    private var counter = 0

    init(account: Account, calendars: [CalendarInfo], events: [CalendarEvent]) {
        self.account = account
        self.calendars = calendars
        self.events = events
    }

    func loadCalendars() async throws -> [CalendarInfo] {
        await pause()
        return calendars
    }

    func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        await pause()
        return events.filter { calendarIDs.contains($0.calendarID) && $0.start < end && $0.end > start }
    }

    /// A made-up meeting link of the calendar's own kind.
    private func meeting(for calendarID: String) -> Conference? {
        let letters = "abcdefghijkmnopqrstuvwxyz"
        func code(_ count: Int) -> String { String((0..<count).map { _ in letters.randomElement()! }) }
        switch calendars.first(where: { $0.id == calendarID })?.nativeConference {
        case .meet?:
            let meetingCode = "\(code(3))-\(code(4))-\(code(3))"
            return Conference(kind: .meet, joinURL: URL(string: "https://meet.google.com/\(meetingCode)")!, meetingCode: meetingCode)
        case .teams?:
            return Conference(kind: .teams, joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_\(code(12))%40thread.v2/0")!)
        default:
            return nil
        }
    }

    func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        await pause()
        counter += 1
        var saved = event
        saved.id = "created-\(counter)"
        if addingConference, let meeting = meeting(for: event.calendarID) { saved.conference = meeting }
        events.append(saved)
        return saved
    }

    func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        await pause()
        var saved = event
        if addingConference, saved.conference == nil, let meeting = meeting(for: event.calendarID) { saved.conference = meeting }
        events.removeAll { $0.id == event.id }
        events.append(saved)
        return saved
    }

    func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        await pause()
        if scope == .allEvents, let series = event.seriesID { events.removeAll { $0.seriesID == series } }
        events.removeAll { $0.id == event.id }
    }

    func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        await pause()
        if let index = events.firstIndex(where: { $0.id == event.id }) { events[index].myResponse = response }
    }

    var allEvents: [CalendarEvent] { events }
}

actor SampleContactsService: ContactsService {
    private var contacts: [Contact]
    private var counter = 0

    init(contacts: [Contact]) {
        self.contacts = contacts
    }

    func loadContacts() async throws -> [Contact] {
        await pause()
        return contacts
    }

    func create(_ contact: Contact) async throws -> Contact {
        await pause()
        counter += 1
        var saved = contact
        saved.id = "sample-created-\(counter)"
        contacts.append(saved)
        return saved
    }

    func update(_ contact: Contact) async throws -> Contact {
        await pause()
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { throw PMailError.notFound }
        contacts[index] = contact
        return contact
    }

    func delete(_ contact: Contact) async throws {
        await pause()
        contacts.removeAll { $0.id == contact.id }
    }
}
#endif
