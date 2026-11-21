import AppKit
import Observation
import PMailKit

/// One account's mail as the window shows it: its folders, the list showing, which rows are ticked, the conversation
/// open, and actions waiting out their few seconds of Undo.
@Observable
final class MailViewModel {
    @ObservationIgnored let service: any MailService
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored weak var session: AccountSession?
    var account: Account

    // Folders
    private(set) var folders: [MailFolder] = []
    private(set) var foldersLoaded = false
    var showsMoreFolders = false

    // The list
    /// The folder or label showing; nil for All Mail.
    private(set) var selectedFolderID: String?
    private(set) var selectedTabID: String?
    private(set) var activeSearch: String?
    private(set) var pageIndex = 0
    private(set) var conversations: [Conversation] = []
    private(set) var totalCount: Int?
    private(set) var hasNextPage = false
    private(set) var isLoadingList = false
    private(set) var listError: String?
    private(set) var needsSignIn = false
    var checkedIDs: Set<String> = []
    let pageSize = 50
    @ObservationIgnored private var pageTokens: [Int: String] = [:]
    @ObservationIgnored private var listGeneration = 0

    // Reading
    private(set) var openConversation: Conversation?
    private(set) var openMessages: [MailMessage] = []
    var expandedMessageIDs: Set<String> = []
    private(set) var isLoadingConversation = false
    private(set) var conversationError: String?
    @ObservationIgnored private var conversationGeneration = 0
    /// Senders whose pictures the person chose to load ("Always show images from …"), by address.
    var trustedImageSenders: Set<String> {
        didSet { defaults.set(Array(trustedImageSenders), forKey: "TrustedImageSenders") }
    }
    @ObservationIgnored let defaults: UserDefaults
    /// Messages whose pictures the person chose to load this once.
    var imagesShownFor: Set<String> = []

    // Actions waiting for their Undo to run out
    private struct PendingAction {
        let id: UUID
        let action: MailAction
        let messages: [MessageSummary]
        let listKey: String
        let snapshot: [Conversation]
        let total: Int?
        var task: Task<Void, Never>?
    }
    @ObservationIgnored private var pending: [UUID: PendingAction] = [:]
    /// Seconds an archive, delete or move waits before reaching the server, so Undo can stop it.
    @ObservationIgnored var undoDelay: TimeInterval = 6

    init(account: Account, service: any MailService, defaults: UserDefaults = .standard) {
        self.account = account
        self.service = service
        self.defaults = defaults
        trustedImageSenders = Set(defaults.stringArray(forKey: "TrustedImageSenders") ?? [])
    }

    var capabilities: MailCapabilities { service.capabilities }
    var inboxTabs: [InboxTab] { service.inboxTabs }

    // MARK: Folders

    var inbox: MailFolder? { folders.first { $0.role == .inbox } }
    func folder(_ id: String?) -> MailFolder? { id.flatMap { id in folders.first { $0.id == id } } }
    func folder(role: FolderRole) -> MailFolder? { folders.first { $0.role == role } }
    var currentFolder: MailFolder? { folder(selectedFolderID) }

    /// Folders always in the sidebar, in order: Inbox, Starred, Snoozed, Sent, Drafts.
    var primaryFolders: [MailFolder] {
        let roles: [FolderRole] = [.inbox, .starred, .snoozed, .important, .sent, .drafts]
        let shown = capabilities.usesLabels ? roles.filter { $0 != .important } : roles
        return shown.compactMap { folder(role: $0) }
    }

    /// Special folders behind "More": Important, Scheduled, Outbox, Archive, Spam, Trash.
    var moreFolders: [MailFolder] {
        let roles: [FolderRole] = capabilities.usesLabels ? [.important, .scheduled, .outbox, .archive, .spam, .trash]
            : [.scheduled, .outbox, .archive, .allMail, .spam, .trash]
        return roles.compactMap { folder(role: $0) }
    }

    /// Whether "All Mail" has a row of its own (for labels, it's every message rather than a folder).
    var showsAllMail: Bool { capabilities.usesLabels }

    /// The account's own folders and labels, nested under their parents, in name order.
    var userFolders: [(folder: MailFolder, depth: Int)] {
        let mine = folders.filter { $0.role == nil }
        var result: [(MailFolder, Int)] = []
        func add(parent: String?, depth: Int) {
            for folder in mine.filter({ $0.parentID == parent }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append((folder, depth))
                add(parent: folder.id, depth: depth + 1)
            }
        }
        add(parent: nil, depth: 0)
        // Folders whose parent isn't listed still show, at the top level.
        let placed = Set(result.map(\.0.id))
        for folder in mine where !placed.contains(folder.id) { result.append((folder, 0)) }
        return result
    }

    /// Folders messages can be moved to, for the Move menu.
    var moveTargets: [MailFolder] {
        folders.filter { $0.isSelectable && $0.id != selectedFolderID && $0.role != .starred && $0.role != .important
            && $0.role != .drafts && $0.role != .snoozed && $0.role != .scheduled && $0.role != .outbox }
    }

    var unreadInbox: Int { inbox?.unreadCount ?? 0 }

    // MARK: Loading

    func start() {
        Task { await loadFolders(thenList: true) }
    }

    /// Loads the folders, and the first list if nothing is showing yet.
    func loadFolders(thenList: Bool) async {
        do {
            let loaded = try await service.loadFolders()
            folders = loaded
            foldersLoaded = true
            needsSignIn = false
            if thenList, selectedFolderID == nil, activeSearch == nil {
                selectedFolderID = inbox?.id ?? loaded.first(where: \.isSelectable)?.id
                selectedTabID = inboxTabs.first?.id
                loadList()
            }
        } catch {
            foldersLoaded = true
            listError = describe(error)
            needsSignIn = (error as? PMailError)?.needsSignIn ?? false
        }
    }

    /// Fetches folders and the current page again.
    func refresh() {
        Task {
            await loadFolders(thenList: false)
            loadList()
        }
    }

    /// Loads the page showing, replacing what's there.
    func loadList() {
        listGeneration += 1
        let generation = listGeneration
        let request = ListRequest(folderID: listFolderID, tabID: selectedTabID, query: activeSearch, pageSize: pageSize,
                                  pageToken: pageIndex == 0 ? nil : pageTokens[pageIndex], pageIndex: pageIndex)
        isLoadingList = true
        listError = nil
        Task {
            do {
                let page = try await service.listConversations(request)
                guard generation == listGeneration else { return }
                conversations = page.conversations
                totalCount = page.totalCount
                hasNextPage = page.nextPageToken != nil
                if let token = page.nextPageToken { pageTokens[pageIndex + 1] = token }
                checkedIDs.formIntersection(Set(conversations.map(\.id)))
                isLoadingList = false
                needsSignIn = false
            } catch {
                guard generation == listGeneration else { return }
                isLoadingList = false
                listError = describe(error)
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    /// The folder to ask the service for: a search in a label account covers all mail.
    private var listFolderID: String? {
        if activeSearch != nil, capabilities.usesLabels { return nil }
        return selectedFolderID
    }

    private var listKey: String { "\(selectedFolderID ?? "*")|\(selectedTabID ?? "")|\(activeSearch ?? "")|\(pageIndex)" }

    // MARK: Choosing what to list

    func select(folderID: String?) {
        flushPendingActions()
        closeConversation()
        selectedFolderID = folderID
        selectedTabID = folder(folderID)?.role == .inbox ? inboxTabs.first?.id : nil
        activeSearch = nil
        resetPaging()
        loadList()
    }

    func select(tabID: String) {
        guard tabID != selectedTabID else { return }
        selectedTabID = tabID
        resetPaging()
        loadList()
    }

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clearSearch() }
        flushPendingActions()
        closeConversation()
        activeSearch = query
        resetPaging()
        loadList()
    }

    func clearSearch() {
        guard activeSearch != nil else { return }
        activeSearch = nil
        resetPaging()
        loadList()
    }

    private func resetPaging() {
        pageIndex = 0
        pageTokens = [:]
        conversations = []
        checkedIDs = []
        totalCount = nil
    }

    var canGoBack: Bool { pageIndex > 0 }
    var canGoForward: Bool { hasNextPage }

    func nextPage() {
        guard hasNextPage else { return }
        pageIndex += 1
        checkedIDs = []
        loadList()
    }

    func previousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        checkedIDs = []
        loadList()
    }

    /// "1–50 of 2,345".
    var rangeText: String {
        guard !conversations.isEmpty else { return "" }
        let first = pageIndex * pageSize + 1
        let last = first + conversations.count - 1
        let number = NumberFormatter()
        number.numberStyle = .decimal
        let range = "\(number.string(from: NSNumber(value: first)) ?? "")–\(number.string(from: NSNumber(value: last)) ?? "")"
        if let totalCount { return "\(range) of \(number.string(from: NSNumber(value: max(totalCount, last))) ?? "")" }
        return hasNextPage ? "\(range) of many" : range
    }

    /// The heading for what's listed: the folder's name, "All Mail" or the search.
    var listTitle: String {
        if let activeSearch { return "Results for “\(activeSearch)”" }
        return currentFolder.map(displayName(for:)) ?? "All Mail"
    }

    func displayName(for folder: MailFolder) -> String {
        switch folder.role {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .important: "Important"
        case .snoozed: "Snoozed"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .scheduled: "Scheduled"
        case .outbox: "Outbox"
        case .archive: "Archive"
        case .allMail: "All Mail"
        case .spam: capabilities.usesLabels ? "Spam" : (folder.name.isEmpty ? "Junk" : folder.name)
        case .trash: "Trash"
        case nil: folder.name
        }
    }

    func symbol(for folder: MailFolder) -> String {
        switch folder.role {
        case .inbox: "tray"
        case .starred: "star"
        case .important: "bookmark"
        case .snoozed: "clock"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .scheduled: "calendar.badge.clock"
        case .outbox: "tray.and.arrow.up"
        case .archive: "archivebox"
        case .allMail: "tray.2"
        case .spam: "exclamationmark.octagon"
        case .trash: "trash"
        case nil: folder.kind == .label ? "tag" : "folder"
        }
    }

    /// Whether the list is the sent mail (rows then show who messages went to).
    var listShowsRecipients: Bool { currentFolder?.role == .sent || currentFolder?.role == .drafts }

    // MARK: Ticking rows

    func toggleChecked(_ id: String) {
        if checkedIDs.contains(id) { checkedIDs.remove(id) } else { checkedIDs.insert(id) }
    }

    enum CheckFilter { case all, none, read, unread, starred, unstarred }

    func check(_ filter: CheckFilter) {
        let ids: [String] = switch filter {
        case .all: conversations.map(\.id)
        case .none: []
        case .read: conversations.filter { !$0.isUnread }.map(\.id)
        case .unread: conversations.filter(\.isUnread).map(\.id)
        case .starred: conversations.filter(\.isStarred).map(\.id)
        case .unstarred: conversations.filter { !$0.isStarred }.map(\.id)
        }
        checkedIDs = Set(ids)
    }

    var checkedConversations: [Conversation] { conversations.filter { checkedIDs.contains($0.id) } }

    /// The conversations an action from the toolbar works on: the open one, or the ticked ones.
    var targetConversations: [Conversation] {
        if let openConversation { return [openConversation] }
        return checkedConversations
    }

    // MARK: Reading

    func open(_ conversation: Conversation) {
        openConversation = conversation
        openMessages = []
        conversationError = nil
        isLoadingConversation = true
        conversationGeneration += 1
        let generation = conversationGeneration
        Task {
            do {
                let messages = try await service.loadConversation(id: conversation.id, hint: conversation)
                guard generation == conversationGeneration else { return }
                openMessages = messages
                // The newest message and every unread one start open; the rest are one line each.
                var expanded = Set(conversation.messages.filter(\.isUnread).map(\.id))
                if let last = messages.last { expanded.insert(last.id) }
                expandedMessageIDs = expanded
                isLoadingConversation = false
                let unread = conversation.messages.filter(\.isUnread)
                if !unread.isEmpty { setFlags(.markRead, on: unread) }
            } catch {
                guard generation == conversationGeneration else { return }
                isLoadingConversation = false
                conversationError = describe(error)
            }
        }
    }

    func closeConversation() {
        openConversation = nil
        openMessages = []
        expandedMessageIDs = []
        conversationError = nil
        conversationGeneration += 1
    }

    /// The conversation after (newer: -1) or before (older: +1) the open one in the list.
    func neighbor(_ offset: Int) -> Conversation? {
        guard let openConversation, let index = conversations.firstIndex(where: { $0.id == openConversation.id }) else { return nil }
        let target = index + offset
        return conversations.indices.contains(target) ? conversations[target] : nil
    }

    /// "3 of 2,345" for the reading toolbar.
    var positionText: String {
        guard let openConversation, let index = conversations.firstIndex(where: { $0.id == openConversation.id }) else { return "" }
        let position = pageIndex * pageSize + index + 1
        if let totalCount { return "\(position) of \(max(totalCount, position).formatted())" }
        return "\(position)"
    }

    func toggleExpanded(_ id: String) {
        if expandedMessageIDs.contains(id) { expandedMessageIDs.remove(id) } else { expandedMessageIDs.insert(id) }
    }

    /// Whether a message's remote pictures load: never by default, so senders can't see when it's read.
    func showsImages(for message: MailMessage) -> Bool {
        if imagesShownFor.contains(message.id) || UserDefaults.standard.bool(forKey: "AlwaysShowPictures") { return true }
        guard let sender = message.summary.from?.email.lowercased() else { return false }
        return trustedImageSenders.contains(sender)
    }

    // MARK: Actions

    /// Stars, marks or files conversations. Archiving, deleting, spam and moves leave the list at once and reach
    /// the server after a few seconds, unless Undo is clicked first.
    func perform(_ action: MailAction, on conversations: [Conversation]) {
        let messages: [MessageSummary]
        switch action {
        case .star:
            // A conversation's star goes on its newest message.
            messages = conversations.compactMap(\.latest)
        case .unstar:
            messages = conversations.flatMap { $0.messages.filter(\.isStarred) }
        case .markRead:
            messages = conversations.flatMap { $0.messages.filter(\.isUnread) }
        case .markUnread:
            messages = conversations.compactMap(\.latest)
        default:
            messages = conversations.flatMap(\.messages)
        }
        guard !messages.isEmpty else { return }
        switch action {
        case .markRead, .markUnread, .star, .unstar, .markImportant, .markNotImportant, .addLabel:
            setFlags(action, on: messages)
        default:
            fileAway(action, messages: messages, count: conversations.count)
        }
    }

    /// Acts on one message from the conversation (its star, or Delete this message).
    func perform(_ action: MailAction, onMessage message: MessageSummary) {
        switch action {
        case .markRead, .markUnread, .star, .unstar, .markImportant, .markNotImportant:
            setFlags(action, on: [message])
        default:
            fileAway(action, messages: [message], count: 1)
        }
    }

    private func setFlags(_ action: MailAction, on messages: [MessageSummary]) {
        let ids = Set(messages.map(\.id))
        let unreadBefore = messages.filter(\.isUnread)
        updateMessages(ids) { summary in
            switch action {
            case .markRead: summary.isUnread = false
            case .markUnread: summary.isUnread = true
            case .star: summary.isStarred = true
            case .unstar: summary.isStarred = false
            case .markImportant: summary.isImportant = true
            case .markNotImportant: summary.isImportant = false
            case let .addLabel(label): if !summary.labelIDs.contains(label) { summary.labelIDs.append(label) }
            default: break
            }
        }
        if action == .markRead { adjustUnreadCounts(by: -unreadBefore.count, for: unreadBefore) }
        if action == .markUnread { adjustUnreadCounts(by: messages.filter { !$0.isUnread }.count, for: messages) }
        let service = self.service
        Task {
            do {
                try await service.perform(action, on: messages)
            } catch {
                app?.report(error, doing: "That change")
                loadList()
            }
        }
    }

    private func adjustUnreadCounts(by delta: Int, for messages: [MessageSummary]) {
        guard delta != 0 else { return }
        let inFolders = Set(messages.compactMap(\.folderID) + messages.flatMap(\.labelIDs) + [selectedFolderID].compactMap { $0 })
        for index in folders.indices where inFolders.contains(folders[index].id) {
            folders[index].unreadCount = max(0, folders[index].unreadCount + delta)
        }
    }

    private func updateMessages(_ ids: Set<String>, _ change: (inout MessageSummary) -> Void) {
        for index in conversations.indices {
            for messageIndex in conversations[index].messages.indices where ids.contains(conversations[index].messages[messageIndex].id) {
                change(&conversations[index].messages[messageIndex])
            }
        }
        if var open = openConversation {
            for messageIndex in open.messages.indices where ids.contains(open.messages[messageIndex].id) {
                change(&open.messages[messageIndex])
            }
            openConversation = open
        }
        for index in openMessages.indices where ids.contains(openMessages[index].id) {
            change(&openMessages[index].summary)
        }
    }

    /// Whether an action takes conversations out of the list showing.
    private func leavesList(_ action: MailAction) -> Bool {
        let role = currentFolder?.role
        switch action {
        case .archive: return role != .archive && (role == .inbox || !capabilities.usesLabels)
        case .trash: return role != .trash
        case .markSpam: return role != .spam
        case .deleteForever: return true
        case .notSpam, .moveToInbox: return role != .inbox
        case let .move(target): return target != selectedFolderID
        case let .removeLabel(label): return label == selectedFolderID
        default: return false
        }
    }

    private func fileAway(_ action: MailAction, messages: [MessageSummary], count: Int) {
        let ids = Set(messages.map(\.id))
        let snapshot = conversations
        let total = totalCount
        let wasOpen = openConversation
        if leavesList(action) {
            conversations = conversations.compactMap { conversation in
                var conversation = conversation
                conversation.messages.removeAll { ids.contains($0.id) }
                return conversation.messages.isEmpty ? nil : conversation
            }
            if let totalCount { self.totalCount = max(0, totalCount - (snapshot.count - conversations.count)) }
            checkedIDs.subtract(snapshot.map(\.id).filter { id in !conversations.contains { $0.id == id } })
        }
        // Leaving a conversation that was filed away goes on to the next one, or back to the list.
        if let open = wasOpen, open.messages.allSatisfy({ ids.contains($0.id) }) || leavesList(action) {
            if let next = snapshot.firstIndex(where: { $0.id == open.id }).flatMap({ index in
                conversations.first { candidate in !ids.isSuperset(of: candidate.messages.map(\.id)) && snapshot.firstIndex(of: candidate).map { $0 > index } == true }
            }) {
                self.open(next)
            } else {
                closeConversation()
            }
        } else if wasOpen != nil, case .deleteForever = action {
            closeConversation()
        } else if wasOpen != nil {
            // One message out of a longer conversation: take it out of the reading pane.
            openMessages.removeAll { ids.contains($0.id) }
            if openMessages.isEmpty { closeConversation() }
        }

        let id = UUID()
        let noun = count == 1 ? "Conversation" : "\(count) conversations"
        let text: String
        switch action {
        case .archive: text = "\(noun) archived."
        case .trash: text = "\(noun) moved to Trash."
        case .markSpam: text = "\(noun) marked as spam."
        case .notSpam, .moveToInbox: text = "\(noun) moved to Inbox."
        case let .move(target): text = "\(noun) moved to “\(folder(target).map(displayName(for:)) ?? "the folder")”."
        case let .removeLabel(label): text = "\(noun) removed from “\(folder(label)?.name ?? "the label")”."
        case .deleteForever: text = "\(noun) deleted forever."
        default: text = "Done."
        }
        let undoable = action != .deleteForever
        var item = PendingAction(id: id, action: action, messages: messages, listKey: listKey, snapshot: snapshot, total: total)
        let delay = undoable ? undoDelay : 0
        item.task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.commit(id)
        }
        pending[id] = item
        app?.show(text, actionTitle: undoable ? "Undo" : nil, duration: undoable ? undoDelay : 4,
                  action: undoable ? { [weak self] in self?.undo(id) } : nil)
    }

    /// Sends a waiting action to the server.
    private func commit(_ id: UUID) async {
        guard let item = pending.removeValue(forKey: id) else { return }
        do {
            try await service.perform(item.action, on: item.messages)
            await loadFolders(thenList: false)
        } catch {
            app?.report(error, doing: "That change")
            loadList()
        }
    }

    /// Takes back an action whose few seconds haven't run out.
    func undo(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.task?.cancel()
        if item.listKey == listKey {
            conversations = item.snapshot
            totalCount = item.total
        }
        app?.show("Action undone.")
    }

    /// Sends every waiting action now (before quitting, switching accounts or changing folders).
    func flushPendingActions() {
        let items = Array(pending.values)
        pending.removeAll()
        let service = self.service
        for item in items {
            item.task?.cancel()
            Task { [weak self] in
                do { try await service.perform(item.action, on: item.messages) } catch { self?.app?.report(error, doing: "That change") }
            }
        }
    }

    /// Waits for every waiting action to reach the server, for quitting.
    func flushAndWait() async {
        let items = Array(pending.values)
        pending.removeAll()
        for item in items {
            item.task?.cancel()
            try? await service.perform(item.action, on: item.messages)
        }
    }

    var hasPendingActions: Bool { !pending.isEmpty }

    /// Puts a sent message's conversation at the top if the list showing is where it belongs.
    func didSend() {
        if currentFolder?.role == .sent || openConversation != nil { refresh() }
    }

    // MARK: Errors

    func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
