import AppKit
import Observation
import PMailKit

/// One account's mail as the window shows it: its folders, the list showing, which rows are ticked, the conversation
/// open, and actions waiting out their few seconds of Undo. What it loads is kept in the account's cache, so it shows
/// at once next time and while the server can't be reached. Snoozed, Scheduled and Outbox are folders PMail keeps on
/// the Mac.
@Observable
final class MailViewModel {
    @ObservationIgnored let service: any MailService
    @ObservationIgnored let storage: AccountStorage
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored weak var session: AccountSession?
    var account: Account

    // Folders
    private(set) var folders: [MailFolder] = []
    @ObservationIgnored private var serviceFolders: [MailFolder] = []
    private(set) var foldersLoaded = false
    var showsMoreFolders = false
    private(set) var snoozeCount = 0
    private(set) var scheduledCount = 0
    private(set) var outboxCount = 0

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
    /// The server couldn't be reached, so what's showing is what PMail last loaded.
    private(set) var connectionTrouble = false
    var checkedIDs: Set<String> = []
    let pageSize = 50
    @ObservationIgnored private var pageTokens: [Int: String] = [:]
    @ObservationIgnored private var listGeneration = 0
    /// When each snoozed conversation comes back, and the queued message behind each Scheduled or Outbox row.
    private(set) var snoozeTimes: [String: Date] = [:]
    @ObservationIgnored private var queuedItems: [String: QueuedMessage] = [:]
    /// Drafts saved (or thrown away) while the server couldn't be reached, waiting to go to Drafts.
    @ObservationIgnored private(set) var waitingDrafts: [WaitingDraft] = []

    // Reading
    private(set) var openConversation: Conversation?
    private(set) var openMessages: [MailMessage] = []
    var expandedMessageIDs: Set<String> = []
    private(set) var isLoadingConversation = false
    private(set) var conversationError: String?
    @ObservationIgnored private var conversationGeneration = 0
    /// Senders whose pictures the person chose to load ("Always show pictures from …"), by address: the same for
    /// every account, kept with the privacy settings.
    var trustedImageSenders: Set<String> {
        get { PrivacySettings.shared.trustedImageSenders }
        set { PrivacySettings.shared.trustedImageSenders = newValue }
    }
    @ObservationIgnored let defaults: UserDefaults
    /// Messages whose pictures the person chose to load this once.
    var imagesShownFor: Set<String> = []

    // Actions waiting for their Undo to run out, or for the network
    private struct PendingAction {
        let id: UUID
        let action: MailAction
        let messages: [MessageSummary]
        let listKey: String
        let snapshot: [Conversation]
        let total: Int?
        var task: Task<Void, Never>?
        var onUndo: (() -> Void)?
        /// Whether it takes its conversations out of the list it was made in.
        var leaves = false
        /// Drafts thrown away: deleted as drafts rather than moved.
        var discardsDrafts = false
        /// Taken out of the spam folder: the junk filter learns they're good mail.
        var fromSpam = false
    }
    @ObservationIgnored private var pending: [UUID: PendingAction] = [:]
    @ObservationIgnored private var committing: [UUID: PendingAction] = [:]
    @ObservationIgnored private var waitingForNetwork: [PendingAction] = []
    /// Seconds an archive, delete or move waits before reaching the server, so Undo can stop it.
    @ObservationIgnored var undoDelay: TimeInterval = 6

    init(account: Account, service: any MailService, storage: AccountStorage, defaults: UserDefaults = .standard) {
        self.account = account
        self.service = service
        self.storage = storage
        self.defaults = defaults
    }

    /// What the account can do. An account with folders rather than labels archives into its server's Archive folder,
    /// which the server makes when it has none (an iCloud account that only has an inbox).
    var capabilities: MailCapabilities { service.capabilities }

    /// Whether Report spam has somewhere to put mail: labels, a spam folder, or one the server makes when it has none.
    var canReportSpam: Bool {
        service.capabilities.usesLabels || service.capabilities.canMove || !foldersLoaded || serviceFolders.contains { $0.role == .spam }
    }
    /// The inbox's tabs: the server's own (Primary, Promotions… or Focused and Other), or the categories PMail sorts
    /// it into. Turned off (Settings ▸ Mail, or the list's ⋯ menu), every account shows its whole inbox in one list.
    var inboxTabs: [InboxTab] {
        Self.sortsIntoCategories(defaults) ? service.inboxTabs : []
    }

    /// Whether the account's inbox can be shown in categories, whether or not it is.
    var hasInboxCategories: Bool { !service.inboxTabs.isEmpty }

    /// Whether inboxes show their categories now.
    var showsCategories: Bool { Self.sortsIntoCategories(defaults) }

    /// Shows inbox categories (or not) on every account.
    func setShowsCategories(_ on: Bool) {
        // The accounts' defaults: the app's own, or the sample accounts' in sample runs.
        defaults.set(on, forKey: "SortInboxCategories")
        for session in app?.accounts.sessions.values.map({ $0 }) ?? [] { session.mail.categoriesSettingChanged() }
        if app == nil { categoriesSettingChanged() }
    }

    /// Unread messages under each inbox tab, by tab ID, for the counts on the tabs.
    private(set) var tabUnreadCounts: [String: Int] = [:]

    /// Asks the account how many unread messages each tab has, while the inbox shows tabs.
    func refreshTabCounts() {
        let tabs = inboxTabs
        guard !tabs.isEmpty, currentFolder?.role == .inbox else { return }
        let service = self.service
        Task {
            if let counts = try? await service.unreadCounts(inTabs: tabs) { tabUnreadCounts = counts }
        }
    }

    /// Whether inboxes PMail sorts itself show their categories (Settings ▸ Inbox categories; on unless turned off).
    static func sortsIntoCategories(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "SortInboxCategories") as? Bool ?? true
    }

    /// Whether the window should say it's offline: no network, or the server didn't answer.
    var isOffline: Bool { connectionTrouble || app?.sync?.isOnline == false }

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

    /// Whether messages here can carry labels: an account whose folders are labels, or one with labels beside its
    /// folders (categories, IMAP keywords, or labels kept on the Mac).
    var hasLabels: Bool { capabilities.usesLabels || capabilities.canLabel }

    /// The account's own folders (not labels), nested under their parents, in name order.
    var userFolders: [(folder: MailFolder, depth: Int)] {
        nested(folders.filter { $0.role == nil && $0.kind != .label && !capabilities.usesLabels })
    }

    /// The account's labels, nested under their parents, in name order.
    var labels: [(folder: MailFolder, depth: Int)] {
        nested(folders.filter { $0.role == nil && ($0.kind == .label || capabilities.usesLabels) })
    }

    private func nested(_ mine: [MailFolder]) -> [(folder: MailFolder, depth: Int)] {
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
            && $0.role != .sent && $0.role != .drafts && $0.role != .snoozed && $0.role != .scheduled && $0.role != .outbox
            // Labels are put on, not moved into (apart from accounts whose folders are labels).
            && ($0.kind != .label || capabilities.usesLabels) }
    }

    var unreadInbox: Int { inbox?.unreadCount ?? 0 }

    /// Whether a folder is one PMail keeps on the Mac (Snoozed, Scheduled, Outbox).
    static func isLocal(_ id: String?) -> Bool {
        id == Snooze.folderID || id == QueuedMessage.scheduledFolderID || id == QueuedMessage.outboxFolderID
    }

    var showsLocalFolder: Bool { Self.isLocal(selectedFolderID) && activeSearch == nil }

    /// The service's folders, with PMail's own: Snoozed (where snoozing works), and Scheduled and Outbox when
    /// anything is waiting in them.
    private func rebuildFolders() {
        var all = serviceFolders.filter { $0.role != .snoozed && $0.role != .scheduled && $0.role != .outbox }
        if capabilities.canArchive {
            all.append(MailFolder(id: Snooze.folderID, name: "Snoozed", role: .snoozed, totalCount: snoozeCount))
        }
        if scheduledCount > 0 || selectedFolderID == QueuedMessage.scheduledFolderID {
            all.append(MailFolder(id: QueuedMessage.scheduledFolderID, name: "Scheduled", role: .scheduled, totalCount: scheduledCount))
        }
        if outboxCount > 0 || selectedFolderID == QueuedMessage.outboxFolderID {
            all.append(MailFolder(id: QueuedMessage.outboxFolderID, name: "Outbox", role: .outbox, unreadCount: outboxCount,
                                  totalCount: outboxCount))
        }
        folders = all
    }

    /// Counts what's snoozed and waiting to be sent, and lists them again if they're showing.
    func refreshLocalFolders() async {
        let snoozes = await storage.snoozes.all()
        let queued = await storage.queue.all()
        snoozeCount = snoozes.count
        scheduledCount = queued.filter(\.isScheduled).count
        outboxCount = queued.filter { !$0.isScheduled }.count
        rebuildFolders()
        if showsLocalFolder { await loadLocalList() }
    }

    func queueChanged() { Task { await refreshLocalFolders() } }
    func snoozesChanged() { Task { await refreshLocalFolders() } }

    // MARK: Loading

    func start() {
        Task {
            waitingDrafts = await storage.waitingDrafts.all()
            // What was loaded last time shows at once, while the server is asked.
            if serviceFolders.isEmpty, let cached = await storage.cache.folders() {
                serviceFolders = cached
                rebuildFolders()
                if selectedFolderID == nil, activeSearch == nil {
                    selectedFolderID = inbox?.id
                    selectedTabID = inboxTabs.first?.id
                    if let page = await storage.cache.page(for: listKey), conversations.isEmpty { show(page) }
                }
            }
            await refreshLocalFolders()
            await loadBlockedSenders()
            await loadFolders(thenList: true)
            // A signature kept on the server may have changed there.
            await app?.accounts.refreshSignature(of: account.id)
        }
    }

    /// Loads the folders, and the first list if nothing has been loaded from the server yet.
    func loadFolders(thenList: Bool) async {
        do {
            let loaded = try await service.loadFolders()
            serviceFolders = loaded
            rebuildFolders()
            foldersLoaded = true
            needsSignIn = false
            await storage.cache.save(folders: loaded)
            if thenList {
                if selectedFolderID == nil, activeSearch == nil {
                    selectedFolderID = inbox?.id ?? loaded.first(where: \.isSelectable)?.id
                    selectedTabID = inboxTabs.first?.id
                }
                loadList()
            }
        } catch {
            foldersLoaded = true
            if Self.isConnectionProblem(error), !serviceFolders.isEmpty {
                connectionTrouble = true
            } else {
                listError = describe(error)
            }
            needsSignIn = (error as? PMailError)?.needsSignIn ?? false
        }
    }

    /// Fetches folders and the current page again.
    /// Loads the folders and the list again; the account's calendars and contacts come along, on their own.
    func refresh() {
        Task {
            await loadFolders(thenList: false)
            await refreshLocalFolders()
            loadList()
        }
        if let session { app?.sync?.refreshCalendarAndContacts(of: session) }
    }

    /// New mail came in, or the server said something changed: counts and the list showing are fetched again
    /// (without clearing what's there).
    func serverChanged() {
        Task {
            await loadFolders(thenList: false)
            if activeSearch == nil, pageIndex == 0, !showsLocalFolder { loadList() }
        }
    }

    /// The network is back: waiting changes go to the server, and everything is fetched again.
    func networkCameBack() {
        connectionTrouble = false
        let waiting = waitingForNetwork
        waitingForNetwork = []
        let service = self.service
        Task {
            for item in waiting {
                do {
                    try await Self.apply(item, with: service)
                    learn(from: item)
                } catch {
                    app?.report(error, doing: "That change")
                }
            }
            await loadFolders(thenList: false)
            loadList()
        }
    }

    /// Loads the page showing, replacing what's there (a copy from the cache shows first if the list is empty).
    func loadList() {
        // Whatever was loading before is stale now, a server list arriving after Snoozed or Scheduled was chosen too.
        listGeneration += 1
        let generation = listGeneration
        if showsLocalFolder {
            Task { await loadLocalList(generation: generation) }
            return
        }
        let key = listKey
        let request = ListRequest(folderID: listFolderID, tabID: selectedTabID, query: activeSearch, pageSize: pageSize,
                                  pageToken: pageIndex == 0 ? nil : pageTokens[pageIndex], pageIndex: pageIndex)
        isLoadingList = true
        listError = nil
        let cacheable = activeSearch == nil
        Task {
            if conversations.isEmpty, cacheable, let cached = await storage.cache.page(for: key), generation == listGeneration {
                show(cached)
            }
            do {
                let page = try await service.listConversations(request)
                guard generation == listGeneration else { return }
                show(page)
                isLoadingList = false
                needsSignIn = false
                connectionTrouble = false
                if currentFolder?.role == .inbox { refreshTabCounts() }
                if cacheable { await storage.cache.save(page: page, for: key) }
            } catch {
                guard generation == listGeneration else { return }
                isLoadingList = false
                if Self.isConnectionProblem(error), !conversations.isEmpty || (showsDrafts && !waitingDrafts.isEmpty) {
                    // Drafts kept on this Mac show even when the server's copy of the list can't be had.
                    if conversations.isEmpty { show(ConversationPage(conversations: [])) }
                    connectionTrouble = true
                } else {
                    listError = describe(error)
                }
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    private func show(_ page: ConversationPage) {
        // What was filed away here but hasn't reached the server yet (waiting out Undo, on its way, or waiting for
        // the network) stays out of the list when it's loaded again.
        let key = listKey
        let leaving = Set((Array(pending.values) + Array(committing.values) + waitingForNetwork)
            .filter { $0.leaves && $0.listKey == key }.flatMap { $0.messages.map(\.id) })
        var shown = page.conversations
        if !leaving.isEmpty {
            shown = shown.compactMap { conversation in
                var conversation = conversation
                conversation.messages.removeAll { leaving.contains($0.id) }
                return conversation.messages.isEmpty ? nil : conversation
            }
        }
        // Drafts kept on this Mac go at the top of Drafts, in place of the server's copies they replace (or delete).
        if showsDrafts, pageIndex == 0, !waitingDrafts.isEmpty {
            let replaced = Set(waitingDrafts.compactMap { $0.replaces?.id })
            shown.removeAll { conversation in conversation.messages.contains { replaced.contains($0.id) } }
            shown = waitingDrafts.reversed().compactMap { draft in draft.summary.map { Conversation(id: draft.summaryID, messages: [$0]) } } + shown
        }
        conversations = shown
        totalCount = page.totalCount.map { max(0, $0 - (page.conversations.count - shown.count)) }
        hasNextPage = page.nextPageToken != nil
        if let token = page.nextPageToken { pageTokens[pageIndex + 1] = token }
        checkedIDs.formIntersection(Set(conversations.map(\.id)))
        refreshJunkMarks()
    }

    /// Lists Snoozed, Scheduled or Outbox from the Mac.
    private func loadLocalList(generation: Int? = nil) async {
        if let generation, generation != listGeneration { return }
        listError = nil
        isLoadingList = false
        switch selectedFolderID {
        case Snooze.folderID?:
            let snoozes = await storage.snoozes.all()
            snoozeTimes = Dictionary(snoozes.map { ($0.conversation.id, $0.wakeAt) }, uniquingKeysWith: { first, _ in first })
            conversations = snoozes.map(\.conversation)
        default:
            let scheduled = selectedFolderID == QueuedMessage.scheduledFolderID
            let items = await storage.queue.all().filter { $0.isScheduled == scheduled }
            queuedItems = Dictionary(items.map { ($0.summaryID, $0) }, uniquingKeysWith: { first, _ in first })
            conversations = items.map { Conversation(id: $0.summaryID, messages: [$0.summary]) }
        }
        totalCount = conversations.count
        hasNextPage = false
        checkedIDs.formIntersection(Set(conversations.map(\.id)))
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
        if Self.isLocal(selectedFolderID) { selectedFolderID = inbox?.id }
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

    /// What the spam folder is called: Spam or Junk, as the server words it, and Junk when it says neither (or PMail
    /// keeps the folder itself).
    static func spamName(_ serverName: String) -> String {
        serverName.range(of: "spam", options: .caseInsensitive) != nil ? "Spam" : "Junk"
    }

    /// This account's spam folder's name, for messages that mention it.
    var spamFolderName: String { folder(role: .spam).map(displayName(for:)) ?? "Junk" }

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
        case .spam: Self.spamName(folder.name)
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
    var listShowsRecipients: Bool {
        [.sent, .drafts, .scheduled, .outbox].contains(currentFolder?.role)
    }

    /// The date a row shows: when a snoozed conversation comes back, when a scheduled message goes, else its date.
    func rowDate(for conversation: Conversation) -> String {
        let formatting = AppClock.formatting
        if let wake = snoozeTimes[conversation.id], selectedFolderID == Snooze.folderID { return formatting.laterDate(wake) }
        if let queued = queuedItems[conversation.id], let sendAt = queued.sendAt { return formatting.laterDate(sendAt) }
        return formatting.listDate(conversation.date)
    }

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

    /// The queued message behind the open Scheduled or Outbox row.
    var openQueuedItem: QueuedMessage? { openConversation.flatMap { queuedItems[$0.id] } }

    /// When the open conversation comes back from snooze, if it's snoozed.
    var openSnoozeTime: Date? { openConversation.flatMap { snoozeTimes[$0.id] } }

    func open(_ conversation: Conversation) {
        if let waiting = waitingDrafts.first(where: { $0.summaryID == conversation.id }) {
            editWaitingDraft(waiting)
            return
        }
        // A draft opens in a window to carry on writing, not to be read.
        if queuedItems[conversation.id] == nil, let draft = draftToEdit(in: conversation) {
            editDraft(draft)
            return
        }
        openConversation = conversation
        openMessages = []
        conversationError = nil
        conversationGeneration += 1
        let generation = conversationGeneration
        if let queued = queuedItems[conversation.id] {
            // A message waiting to be sent: shown as it will go.
            let message = queued.message
            let attachments = message.attachments.enumerated().map { index, file in
                Attachment(id: "\(index + 1)", filename: file.filename, mimeType: file.mimeType, size: file.data.count,
                           contentID: file.contentID, isInline: file.contentID != nil, data: file.data)
            }
            openMessages = [MailMessage(summary: queued.summary, bcc: message.bcc, htmlBody: message.htmlBody, textBody: message.textBody,
                                        attachments: attachments.filter { !$0.isInline }, inlineParts: attachments.filter(\.isInline))]
            expandedMessageIDs = [queued.summaryID]
            isLoadingConversation = false
            return
        }
        isLoadingConversation = true
        let snoozed = selectedFolderID == Snooze.folderID
        Task {
            var showedCopy = false
            if let cached = await storage.cache.conversation(conversation.id), !cached.isEmpty, generation == conversationGeneration {
                show(cached, for: conversation)
                showedCopy = true
            }
            do {
                var hint = conversation
                if snoozed {
                    // A snoozed conversation was archived, which can give its messages new IDs.
                    let found = try await service.findMessages(withMessageIDs: conversation.messages.compactMap(\.messageIDHeader))
                    if !found.isEmpty { hint = Conversation(id: found.first?.threadID ?? conversation.id, messages: found) }
                }
                let messages = try await service.loadConversation(id: hint.id, hint: hint)
                guard generation == conversationGeneration else { return }
                show(messages, for: conversation)
                connectionTrouble = false
                await storage.cache.save(conversation: conversation.id, messages: messages)
                let unread = conversation.messages.filter(\.isUnread)
                if !unread.isEmpty, !snoozed { setFlags(.markRead, on: unread) }
            } catch {
                guard generation == conversationGeneration else { return }
                isLoadingConversation = false
                if showedCopy, Self.isConnectionProblem(error) {
                    connectionTrouble = true
                } else if !showedCopy {
                    conversationError = Self.isConnectionProblem(error)
                        ? "This conversation hasn’t been opened on this Mac before, so it can’t be shown while you’re offline."
                        : describe(error)
                }
            }
        }
    }

    private func show(_ messages: [MailMessage], for conversation: Conversation) {
        let firstShow = openMessages.isEmpty
        openMessages = messages
        refreshJunkMarks()
        if firstShow {
            // The newest message and every unread one start open; the rest are one line each.
            var expanded = Set(conversation.messages.filter(\.isUnread).map(\.id))
            if let last = messages.last { expanded.insert(last.id) }
            expandedMessageIDs = expanded
        }
        isLoadingConversation = false
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

    /// Whether a message's pictures from the internet load as it's shown (through PMail's private loader, from its
    /// copy when it has one), as Settings ▸ Privacy says: always while mail activity is protected; otherwise, while
    /// remote content is blocked, only when asked for this message or its sender.
    func showsImages(for message: MailMessage) -> Bool {
        let shownByHand = imagesShownFor.contains(message.id)
        // Junk never loads its pictures by itself.
        if junkMarks[message.id] != nil || currentFolder?.role == .spam { return shownByHand }
        return PrivacySettings.shared.loadsRemoteContent(from: message.summary.from?.email, shownByHand: shownByHand)
    }

    /// The account's copies of what its mail loads from the internet.
    var remoteContentCache: RemoteContentCache { storage.remoteContent }

    // MARK: Actions

    /// Stars, marks or files conversations. Archiving, deleting, spam and moves leave the list at once and reach
    /// the server after a few seconds, unless Undo is clicked first.
    func perform(_ action: MailAction, on conversations: [Conversation]) {
        guard allows(action) else { return }
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
        guard allows(action) else { return }
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
        let change: (inout MessageSummary) -> Void = { summary in
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
        updateMessages(ids, change)
        if action == .markRead { adjustUnreadCounts(by: -unreadBefore.count, for: unreadBefore) }
        if action == .markUnread { adjustUnreadCounts(by: messages.filter { !$0.isUnread }.count, for: messages) }
        let changed = messages.map { summary -> MessageSummary in
            var summary = summary
            change(&summary)
            return summary
        }
        let service = self.service
        let cache = storage.cache
        Task {
            await cache.update(summaries: changed)
            do {
                try await service.perform(action, on: messages)
                if action == .markRead || action == .markUnread { refreshTabCounts() }
            } catch where Self.isConnectionProblem(error) {
                waitingForNetwork.append(PendingAction(id: UUID(), action: action, messages: messages, listKey: listKey, snapshot: [], total: nil))
                connectionTrouble = true
            } catch {
                app?.report(error, doing: "That change")
                loadList()
            }
        }
    }

    private func adjustUnreadCounts(by delta: Int, for messages: [MessageSummary]) {
        guard delta != 0 else { return }
        let inFolders = Set(messages.compactMap(\.folderID) + messages.flatMap(\.labelIDs) + [selectedFolderID].compactMap { $0 })
        for index in serviceFolders.indices where inFolders.contains(serviceFolders[index].id) {
            serviceFolders[index].unreadCount = max(0, serviceFolders[index].unreadCount + delta)
        }
        rebuildFolders()
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

    private func fileAway(_ action: MailAction, messages: [MessageSummary], count: Int, note: String? = nil, onUndo: (() -> Void)? = nil,
                          alwaysLeaves: Bool = false, discardsDrafts: Bool = false, staysOpen: Bool = false) {
        let ids = Set(messages.map(\.id))
        let snapshot = conversations
        let total = totalCount
        let wasOpen = openConversation
        let leaves = alwaysLeaves || leavesList(action)
        if leaves {
            conversations = conversations.compactMap { conversation in
                var conversation = conversation
                conversation.messages.removeAll { ids.contains($0.id) }
                return conversation.messages.isEmpty ? nil : conversation
            }
            if let totalCount { self.totalCount = max(0, totalCount - (snapshot.count - conversations.count)) }
            checkedIDs.subtract(snapshot.map(\.id).filter { id in !conversations.contains { $0.id == id } })
        }
        // Leaving a conversation that was filed away goes on to the next one, or back to the list.
        if !staysOpen, let open = wasOpen, open.messages.allSatisfy({ ids.contains($0.id) }) || leaves {
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
        var item = PendingAction(id: id, action: action, messages: messages, listKey: listKey, snapshot: snapshot, total: total, onUndo: onUndo)
        item.leaves = leaves
        item.discardsDrafts = discardsDrafts
        item.fromSpam = currentFolder?.role == .spam
        let delay = undoable ? undoDelay : 0
        item.task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.commit(id)
        }
        pending[id] = item
        app?.show(note ?? text, actionTitle: undoable ? "Undo" : nil, duration: undoable ? undoDelay : 4,
                  action: undoable ? { [weak self] in self?.undo(id) } : nil)
    }

    /// Sends a waiting action to the server; offline, it waits for the network.
    private func commit(_ id: UUID) async {
        guard let item = pending.removeValue(forKey: id) else { return }
        committing[id] = item
        defer { committing[id] = nil }
        do {
            try await Self.apply(item, with: service)
            learn(from: item)
            if item.discardsDrafts { draftsChanged() }
            await loadFolders(thenList: false)
            refreshTabCounts()
        } catch where Self.isConnectionProblem(error) {
            waitingForNetwork.append(item)
            connectionTrouble = true
            app?.show("You’re offline. That change will be made when PMail can reach the server again.")
        } catch {
            app?.report(error, doing: "That change")
            loadList()
        }
    }

    /// Takes back an action whose few seconds haven't run out.
    func undo(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.task?.cancel()
        item.onUndo?()
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
                do {
                    try await Self.apply(item, with: service)
                    self?.learn(from: item)
                } catch where Self.isConnectionProblem(error) {
                    self?.waitingForNetwork.append(item)
                } catch {
                    self?.app?.report(error, doing: "That change")
                }
            }
        }
    }

    /// Waits for every waiting action to reach the server, for quitting.
    func flushAndWait() async {
        let items = Array(pending.values) + waitingForNetwork
        pending.removeAll()
        waitingForNetwork.removeAll()
        for item in items {
            item.task?.cancel()
            if (try? await Self.apply(item, with: service)) != nil { learn(from: item) }
        }
    }

    var hasPendingActions: Bool { !pending.isEmpty || !waitingForNetwork.isEmpty }

    /// Puts a sent message's conversation at the top if the list showing is where it belongs.
    func didSend() {
        if currentFolder?.role == .sent || openConversation != nil { refresh() }
    }

    // MARK: Drafts

    /// Whether the list showing is Drafts.
    var showsDrafts: Bool { currentFolder?.role == .drafts && activeSearch == nil }

    /// The draft a conversation opens to carry on writing: in Drafts its newest draft (or newest message), elsewhere
    /// its newest message when every message in it is a draft. A conversation with real mail in it opens to read.
    func draftToEdit(in conversation: Conversation) -> MessageSummary? {
        let drafts = conversation.messages.filter(\.isDraft)
        if currentFolder?.role == .drafts {
            return drafts.max { $0.date < $1.date } ?? conversation.latest
        }
        guard !drafts.isEmpty, drafts.count == conversation.messages.count else { return nil }
        return drafts.max { $0.date < $1.date }
    }

    /// Opens a saved draft in a window, ready to carry on writing (or brings forward the window already editing it).
    func editDraft(_ draft: MessageSummary) {
        guard let app, let session else { return }
        if let open = app.composers.first(where: { $0.editingDraftID == draft.id }) {
            app.open(open)
            return
        }
        let service = self.service
        Task {
            do {
                let message = try await service.loadMessage(draft)
                var files: [OutgoingAttachment] = []
                for attachment in message.attachments {
                    let data: Data
                    if let loaded = attachment.data { data = loaded } else { data = try await service.loadAttachment(attachment, in: draft) }
                    files.append(OutgoingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
                }
                let compose = ComposeModel(app: app, session: session)
                compose.load(draft: message, files: files)
                app.open(compose)
            } catch {
                app.report(error, doing: "Opening the draft")
            }
        }
    }

    /// Throws drafts away, with Undo: out of the list at once, deleted a few seconds later.
    func discardDrafts(_ conversations: [Conversation]) {
        var drafts: [MessageSummary] = []
        for conversation in conversations {
            let marked = conversation.messages.filter(\.isDraft)
            drafts += marked.isEmpty && currentFolder?.role == .drafts ? conversation.messages : marked
        }
        guard !drafts.isEmpty else { return }
        fileAway(.trash, messages: drafts, count: conversations.count,
                 note: drafts.count == 1 ? "Draft discarded." : "\(drafts.count) drafts discarded.", alwaysLeaves: true, discardsDrafts: true)
    }

    /// Throws away one draft in the conversation showing (a reply not sent yet), leaving the rest of it open.
    func discardDraft(_ draft: MessageSummary) {
        let before = openMessages
        let conversationID = openConversation?.id
        fileAway(.trash, messages: [draft], count: 1, note: "Draft discarded.", onUndo: { [weak self] in
            guard let self, self.openConversation?.id == conversationID else { return }
            self.openMessages = before
        }, discardsDrafts: true, staysOpen: true)
    }

    /// A draft was saved, sent or thrown away: Drafts lists it again if it's showing, and the counts follow.
    func draftsChanged() {
        Task {
            waitingDrafts = await storage.waitingDrafts.all()
            if showsDrafts { loadList() }
            await loadFolders(thenList: false)
        }
    }

    // MARK: Drafts kept on the Mac

    /// Opens a draft kept on this Mac in a window to carry on writing (or brings forward the window already editing it).
    func editWaitingDraft(_ draft: WaitingDraft) {
        guard let app, let session, draft.message != nil else { return }
        if let open = app.composers.first(where: { $0.waitingDraftID == draft.id }) {
            app.open(open)
            return
        }
        let compose = ComposeModel(app: app, session: session)
        compose.load(waiting: draft)
        app.open(compose)
    }

    /// Saves the drafts kept on this Mac to the server's Drafts (and deletes the ones thrown away offline), once it
    /// can be reached. A window still open on one carries on with the server's copy.
    func sendWaitingDrafts() async {
        guard !(await storage.waitingDrafts.all()).isEmpty else { return }
        let result = await storage.waitingDrafts.send(using: service)
        waitingDrafts = await storage.waitingDrafts.all()
        guard result.sent > 0 || !result.refused.isEmpty else { return }
        for (summaryID, saved) in result.saved {
            app?.composers.first { $0.waitingDraftSummaryID == summaryID }?.draftReachedServer(saved)
        }
        for refusal in result.refused {
            app?.show("“\(refusal.title.isEmpty ? "A draft" : refusal.title)” couldn’t be saved to Drafts: \(refusal.reason)")
        }
        draftsChanged()
    }

    /// Sends a waiting action to the server: thrown-away drafts are deleted as drafts, anything else is the action.
    private static func apply(_ item: PendingAction, with service: any MailService) async throws {
        if item.discardsDrafts {
            for draft in item.messages { try await service.deleteDraft(draft) }
        } else {
            try await service.perform(item.action, on: item.messages)
        }
    }

    // MARK: Labels

    /// A label being made or changed, for the label sheet.
    struct LabelEditing: Identifiable {
        let id = UUID()
        /// The label to change; nil makes a new one.
        let label: MailFolder?
        /// Conversations to put a new label on once it's made.
        let applyTo: [Conversation]
    }

    var labelEditor: LabelEditing?

    func newLabel(applyingTo conversations: [Conversation] = []) {
        labelEditor = LabelEditing(label: nil, applyTo: conversations)
    }

    func editLabel(_ label: MailFolder) {
        labelEditor = LabelEditing(label: label, applyTo: [])
    }

    /// Makes or changes a label from the sheet; a new one goes on the conversations it was made for.
    func saveLabel(_ editing: LabelEditing, name: String, colorHex: String?) {
        let service = self.service
        Task {
            do {
                if let label = editing.label {
                    let updated = try await service.updateLabel(label, name: name, colorHex: colorHex)
                    await loadFolders(thenList: false)
                    // Listing a label whose ID changed with its name: keep listing it.
                    if selectedFolderID == label.id, updated.id != label.id {
                        selectedFolderID = updated.id
                        loadList()
                    }
                    app?.show("Label saved.")
                } else {
                    let label = try await service.createLabel(named: name, colorHex: colorHex)
                    await loadFolders(thenList: false)
                    if !editing.applyTo.isEmpty { perform(.addLabel(label.id), on: editing.applyTo) }
                    app?.show("Label “\(label.name)” made.")
                }
            } catch {
                app?.report(error, doing: editing.label == nil ? "Making the label" : "Changing the label")
            }
        }
    }

    /// Deletes a label; its conversations keep everything else.
    func deleteLabel(_ label: MailFolder) {
        let service = self.service
        Task {
            do {
                try await service.deleteLabel(label)
                if selectedFolderID == label.id { select(folderID: inbox?.id) }
                await loadFolders(thenList: false)
                loadList()
                app?.show("Label “\(label.name)” deleted.")
            } catch {
                app?.report(error, doing: "Deleting the label")
            }
        }
    }

    /// Puts a label on conversations, or takes it off when every one of them has it.
    func toggleLabel(_ labelID: String, on conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        let all = conversations.allSatisfy { $0.labelIDs.contains(labelID) }
        perform(all ? .removeLabel(labelID) : .addLabel(labelID), on: conversations)
    }

    // MARK: Inbox categories

    /// Whether the inbox's tabs are categories PMail sorts mail into on the Mac, so conversations can be moved
    /// between them.
    var sortsInboxOnMac: Bool { inboxTabs.first.flatMap { InboxCategory(tabID: $0.id) } != nil }

    /// The category tab showing, when the inbox shows one.
    var currentCategory: InboxCategory? { currentFolder?.role == .inbox ? InboxCategory(tabID: selectedTabID) : nil }

    /// Senders put in a category by hand, for Settings.
    private(set) var senderCategories: [String: InboxCategory] = [:]

    func loadSenderCategories() async {
        senderCategories = await storage.sorter.senderCategories()
    }

    /// Puts conversations' senders in a category from now on, which moves these conversations there too (with Undo).
    func moveToCategory(_ conversations: [Conversation], _ category: InboxCategory) {
        let own = account.email.lowercased()
        var senders: [String] = []
        for message in conversations.flatMap(\.messages) {
            guard let email = message.from?.email.lowercased(), email != own, !senders.contains(email) else { continue }
            senders.append(email)
        }
        guard !senders.isEmpty else { return }
        // Out of the tab showing at once, when that's another category.
        if let current = currentCategory, current != category {
            let ids = Set(conversations.map(\.id))
            let before = self.conversations.count
            self.conversations.removeAll { ids.contains($0.id) }
            if let total = totalCount { totalCount = max(0, total - (before - self.conversations.count)) }
            checkedIDs.subtract(ids)
            if let open = openConversation, ids.contains(open.id) { closeConversation() }
        }
        let sorter = storage.sorter
        Task {
            let earlier = await sorter.senderCategories()
            for sender in senders { try? await sorter.setCategory(category, forSender: sender) }
            await loadSenderCategories()
            let who = senders.count == 1 ? senders[0] : "\(senders.count) senders"
            app?.show("Mail from \(who) goes to \(category.name) from now on.", actionTitle: "Undo") {
                Task {
                    for sender in senders { try? await sorter.setCategory(earlier[sender], forSender: sender) }
                    await self.loadSenderCategories()
                    self.loadList()
                }
            }
            loadList()
        }
    }

    /// Changes or clears a sender's category (Settings ▸ Inbox categories); nil sorts their mail automatically again.
    func setCategory(_ category: InboxCategory?, forSender sender: String) {
        let sorter = storage.sorter
        Task {
            try? await sorter.setCategory(category, forSender: sender)
            await loadSenderCategories()
            if currentFolder?.role == .inbox { loadList() }
        }
    }

    /// Sorting into categories was turned on or off: the inbox shows its tabs (or not) and lists again.
    func categoriesSettingChanged() {
        guard currentFolder?.role == .inbox else { return }
        tabUnreadCounts = [:]
        selectedTabID = inboxTabs.first?.id
        resetPaging()
        loadList()
    }

    // MARK: Spam and blocked senders

    /// Who's blocked on this account, for Settings.
    private(set) var blockedSenders: [BlockedSender] = []
    /// A Report spam waiting for the person to say whether to block the senders too.
    var spamReport: SpamReport?

    /// Conversations being reported, with the addresses and domains blocking could cover.
    struct SpamReport: Identifiable {
        let id = UUID()
        let conversations: [Conversation]
        let addresses: [String]
        let domains: [String]
    }

    enum SpamBlock {
        case nobody, senders, domains
    }

    func loadBlockedSenders() async {
        blockedSenders = await storage.blockedSenders.all()
    }

    /// Report spam, which first asks whether to block the senders as well: their addresses, or everything from their
    /// domains.
    func reportSpam(_ conversations: [Conversation]) {
        guard canReportSpam, !conversations.isEmpty else { return }
        let own = account.email.lowercased()
        var addresses: [String] = []
        for message in conversations.flatMap(\.messages) {
            guard let email = message.from?.email.lowercased(), email != own, !addresses.contains(email) else { continue }
            addresses.append(email)
        }
        guard !addresses.isEmpty else { return perform(.markSpam, on: conversations) }
        // The account's own domain isn't offered: blocking it would send its own mail to the spam folder.
        let ownDomain = BlockedSender.domain(ofAddress: own)
        var domains: [String] = []
        for domain in addresses.compactMap(BlockedSender.domain(ofAddress:)) where domain != ownDomain && !domains.contains(domain) {
            domains.append(domain)
        }
        spamReport = SpamReport(conversations: conversations, addresses: addresses, domains: domains)
    }

    /// Moves reported conversations to the spam folder, blocking their senders first if asked. Blocking also takes the inbox's
    /// other conversations from them along; Undo puts everything back and unblocks them.
    func finishSpamReport(_ report: SpamReport, block: SpamBlock) {
        spamReport = nil
        let now = AppClock.now()
        let rules: [BlockedSender]
        switch block {
        case .nobody: rules = []
        case .senders: rules = report.addresses.map { BlockedSender.address($0, at: now) }
        case .domains: rules = report.domains.map { BlockedSender(kind: .domain, value: $0, blockedAt: now) }
        }
        guard !rules.isEmpty else { return perform(.markSpam, on: report.conversations) }
        var targets = report.conversations
        if currentFolder?.role == .inbox {
            let reported = Set(targets.map(\.id))
            targets += conversations.filter { conversation in
                !reported.contains(conversation.id) && conversation.messages.contains { message in
                    guard let sender = message.from?.email else { return false }
                    return rules.contains { $0.matches(sender) }
                }
            }
        }
        let book = storage.blockedSenders
        Task {
            try? await book.add(rules)
            await loadBlockedSenders()
        }
        let who = rules.count == 1 ? rules[0].displayName : block == .domains ? "\(rules.count) domains" : "\(rules.count) senders"
        fileAway(.markSpam, messages: targets.flatMap(\.messages), count: targets.count,
                 note: "Blocked \(who). Their mail goes to \(spamFolderName) from now on.", onUndo: { [weak self] in
                     Task {
                         for rule in rules { try? await book.remove(id: rule.id) }
                         await self?.loadBlockedSenders()
                     }
                 })
    }

    // MARK: Junk

    /// Messages showing that were left in the inbox marked as junk or as from a blocked sender, by message ID.
    private(set) var junkMarks: [String: JunkMarks.Mark] = [:]

    func refreshJunkMarks() {
        let summaries = conversations.flatMap(\.messages) + openMessages.map(\.summary)
        let marks = storage.junkMarks
        Task { junkMarks = await marks.marks(for: summaries) }
    }

    /// A conversation's mark: junk if any of its messages is, else blocked if one is.
    func junkMark(for conversation: Conversation) -> JunkMarks.Mark? {
        let marks = conversation.messages.compactMap { junkMarks[$0.id] }
        return marks.contains(.junk) ? .junk : marks.first
    }

    /// A message marked as junk isn't: the mark goes, and the junk filter learns from it.
    func notJunk(_ message: MessageSummary) {
        junkMarks[message.id] = nil
        let marks = storage.junkMarks
        let filter = JunkSettings.shared.filter
        Task {
            await marks.clear([message])
            await filter.learn([message], asJunk: false)
        }
        app?.show("Marked as not junk. PMail will learn from it.")
    }

    /// A message marked as from a blocked sender: its sender is unblocked (every rule that covers them) and the mark goes.
    func unblockSender(of message: MessageSummary) {
        guard let email = message.from?.email else { return }
        junkMarks[message.id] = nil
        let book = storage.blockedSenders
        let marks = storage.junkMarks
        Task {
            for rule in await book.all() where rule.matches(email) { try? await book.remove(id: rule.id) }
            await marks.clear([message])
            await loadBlockedSenders()
        }
        app?.show("Unblocked \(email).")
    }

    /// What the junk filter learns from a change that reached the server: spam reported is junk, and mail taken out of
    /// the spam folder isn't.
    private func learn(from item: PendingAction) {
        let filter = JunkSettings.shared.filter
        let marks = storage.junkMarks
        let messages = item.messages
        switch item.action {
        case .markSpam:
            Task {
                await filter.learn(messages, asJunk: true)
                await marks.clear(messages)
            }
        case .notSpam:
            Task {
                await filter.learn(messages, asJunk: false)
                await marks.clear(messages)
            }
        case .moveToInbox, .move:
            guard item.fromSpam else { return }
            Task { await filter.learn(messages, asJunk: false) }
        default:
            break
        }
    }

    /// Unblocks a sender (Settings ▸ Blocked senders).
    func unblock(_ sender: BlockedSender) {
        let book = storage.blockedSenders
        Task {
            try? await book.remove(id: sender.id)
            await loadBlockedSenders()
        }
    }

    // MARK: Snoozing

    /// Whether conversations here can be snoozed (it needs archiving, they're not PMail's own, and they're not in
    /// the Trash).
    var canSnooze: Bool { capabilities.canArchive && !Self.isLocal(selectedFolderID) && !showsTrash }

    /// Whether the list showing is the Trash, where conversations are only put back, moved out, marked read or unread,
    /// or deleted for good: not archived, snoozed, starred or labeled.
    var showsTrash: Bool { currentFolder?.role == .trash && activeSearch == nil }

    /// Whether an action makes sense on the conversations showing (the Trash refuses archiving, stars, importance and
    /// labels).
    func allows(_ action: MailAction) -> Bool {
        // Sent holds what was sent, and Drafts, Scheduled, Outbox and Snoozed fill themselves: nothing is moved into them.
        if case let .move(target) = action, let role = folder(target)?.role,
           [.sent, .drafts, .scheduled, .outbox, .snoozed].contains(role) {
            return false
        }
        guard showsTrash else { return true }
        switch action {
        case .archive, .star, .unstar, .addLabel, .removeLabel, .markImportant, .markNotImportant: return false
        default: return true
        }
    }

    /// Puts conversations away until `date`: out of the inbox now, back (unread, with a notification) then.
    func snooze(_ conversations: [Conversation], until date: Date) {
        guard canSnooze, !conversations.isEmpty else { return }
        let snoozes = conversations.map { Snooze(conversation: $0, wakeAt: date) }
        let book = storage.snoozes
        Task {
            for snooze in snoozes { try? await book.add(snooze) }
            await refreshLocalFolders()
        }
        let noun = conversations.count == 1 ? "Conversation" : "\(conversations.count) conversations"
        fileAway(.archive, messages: conversations.flatMap(\.messages), count: conversations.count,
                 note: "\(noun) snoozed until \(AppClock.formatting.laterDate(date)).", onUndo: { [weak self] in
                     Task {
                         for snooze in snoozes { await book.remove(snooze.id) }
                         await self?.refreshLocalFolders()
                     }
                 }, alwaysLeaves: true)
    }

    /// Brings a snoozed conversation back to the inbox now.
    func unsnooze(_ conversation: Conversation) {
        let book = storage.snoozes
        let service = self.service
        if openConversation?.id == conversation.id { closeConversation() }
        conversations.removeAll { $0.id == conversation.id }
        Task {
            if let snooze = await book.snooze(forConversation: conversation.id) {
                await book.remove(snooze.id)
                do {
                    let found = try await service.findMessages(withMessageIDs: snooze.messageIDs)
                    if !found.isEmpty { try await service.perform(.moveToInbox, on: found) }
                    app?.show("Conversation moved back to the inbox.")
                } catch {
                    app?.report(error, doing: "Unsnoozing")
                }
            }
            await refreshLocalFolders()
            await loadFolders(thenList: false)
        }
    }

    // MARK: Waiting messages

    /// Takes a message out of Scheduled or the Outbox and opens it to edit (it becomes a message being written).
    func editQueued(_ item: QueuedMessage) {
        Task {
            await storage.queue.remove(item.id)
            await refreshLocalFolders()
            closeConversation()
            guard let app, let session else { return }
            let compose = ComposeModel(app: app, session: session)
            compose.load(item.message)
            app.open(compose)
            app.show(item.isScheduled ? "Scheduled send canceled. Edit the message and send it again, or close it to keep a draft."
                                      : "The message was taken out of the Outbox.")
        }
    }

    /// Sends a scheduled or Outbox message as soon as possible.
    func sendQueuedNow(_ item: QueuedMessage) {
        Task {
            var now = item
            now.sendAt = nil
            now.attempts = 0
            now.lastAttempt = nil
            now.queuedAt = AppClock.now()
            try? await storage.queue.save(now)
            closeConversation()
            await refreshLocalFolders()
            if let session, let sync = app?.sync { await sync.sendDue(session, at: AppClock.now()) }
        }
    }

    func deleteQueued(_ item: QueuedMessage) {
        Task {
            await storage.queue.remove(item.id)
            closeConversation()
            await refreshLocalFolders()
            app?.show("Message deleted.")
        }
    }

    // MARK: Errors

    func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Whether an error means the server couldn't be reached (as opposed to refusing).
    static func isConnectionProblem(_ error: Error) -> Bool {
        switch error as? PMailError {
        case .connectionFailed?, .timedOut?: true
        default: false
        }
    }
}
