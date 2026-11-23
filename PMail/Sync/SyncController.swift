import AppKit
import Network
import Observation
import PMailKit

/// Keeps every account up to date while PMail runs: checks each inbox for new mail every few minutes (or the moment
/// the server says so, where it can), and beside each check, on its own, sends calendar and contact changes made
/// offline and gets the latest calendars and contacts. It deals with junk and blocked senders' mail as it arrives,
/// loads new mail's pictures privately when mail activity is protected, sends messages whose time has come and the
/// Outbox once the network is back, brings snoozed conversations back, and posts notifications.
@Observable
final class SyncController {
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored let notifier: any MailNotifier
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushAccount: UUID?
    @ObservationIgnored private var lastCheck: [UUID: Date] = [:]
    /// Accounts asked to check again once the check under way is done, and whether the server pushed.
    @ObservationIgnored private var checkAgain: [UUID: Bool] = [:]
    @ObservationIgnored private var lastRefresh: [UUID: Date] = [:]
    @ObservationIgnored private var checking: Set<UUID> = []
    @ObservationIgnored private var sending: Set<UUID> = []
    @ObservationIgnored private var unsupported: Set<UUID> = []
    @ObservationIgnored var now: () -> Date = { AppClock.now() }
    /// What happens to new mail as it arrives (Settings ▸ Junk Mail).
    @ObservationIgnored let mailFilter: NewMailFilter

    /// Whether the Mac has a network connection (as the system sees it).
    private(set) var isOnline = true
    /// Inbox unread counts for every account, from the last check (accounts not open yet included).
    private(set) var unreadCounts: [UUID: Int] = [:]

    init(app: AppModel, notifier: any MailNotifier) {
        self.app = app
        self.notifier = notifier
        mailFilter = NewMailFilter(sessions: { [weak app] in app.map { Array($0.accounts.sessions.values) } ?? [] })
        notifier.onOpen = { [weak app] account, message in app?.openConversation(message, in: account) }
    }

    /// Minutes between checks for the account showing; other accounts are checked half as often.
    var checkInterval: TimeInterval {
        let minutes = UserDefaults.standard.double(forKey: "CheckMinutes")
        return (minutes > 0 ? minutes : 2) * 60
    }

    func start() {
        #if DEBUG
        // Sample runs don't follow the Mac's own network: the self-test says when it's offline.
        let watchesNetwork = !DebugLaunchOptions.usesSampleAccounts
        #else
        let watchesNetwork = true
        #endif
        if watchesNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                DispatchQueue.main.async { self?.networkChanged(online: online) }
            }
            monitor.start(queue: DispatchQueue(label: "com.pugglesoft.PMail.network"))
            self.monitor = monitor
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tick() }
        // The junk filter starts off on each account it hasn't yet, once things have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let app = self.app else { return }
            Task { for session in app.accounts.sessions.values { await self.startLearning(session) } }
        }
        // Copies of remote content go after half a year, or the oldest once an account's pass half a gigabyte.
        let caches = app?.accounts.sessions.values.map(\.storage.remoteContent) ?? []
        Task.detached(priority: .background) {
            let cutoff = Date().addingTimeInterval(-182 * 86_400)
            for cache in caches { await cache.prune(savedBefore: cutoff, maxBytes: 512 * 1024 * 1024) }
        }
    }

    func stop() {
        timer?.invalidate()
        monitor?.cancel()
        pushTask?.cancel()
    }

    #if DEBUG
    /// Pretends the network went away or came back (for the self-test).
    func pretendNetwork(online: Bool) { networkChanged(online: online) }
    #endif

    private func networkChanged(online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack {
            // Back online: send what waited, catch up, and let the open views know. The push loop may be sleeping off
            // its failures, so it starts over.
            lastCheck = [:]
            lastRefresh = [:]
            pushTask?.cancel()
            pushTask = nil
            tick()
            app?.current?.mail.networkCameBack()
            app?.show("You’re back online.")
        }
    }

    /// Every 20 seconds: whatever is due.
    func tick() {
        guard let app else { return }
        restartPushIfNeeded()
        let date = now()
        for session in app.accounts.sessions.values {
            let id = session.id
            Task { await self.sendDue(session, at: date) }
            Task { await self.wakeSnoozes(session, at: date) }
            let interval = id == app.accounts.currentID ? checkInterval : checkInterval * 2
            if isOnline, !unsupported.contains(id), date.timeIntervalSince(lastCheck[id] ?? .distantPast) >= interval {
                Task { await self.check(session) }
            }
        }
    }

    // MARK: New mail

    /// Asks an account's server what's new since the last check, refreshes the window if it shows that inbox, and
    /// announces the new messages.
    ///
    /// `pushed` says the server spoke up, which can also mean mail was read, moved or deleted somewhere else.
    func check(_ session: AccountSession, pushed: Bool = false) async {
        let id = session.id
        // Asked for while a check is under way (the server pushed, or mail was just sent), it checks once more after,
        // since the one under way may have asked the server before the news.
        guard !checking.contains(id) else {
            checkAgain[id] = (checkAgain[id] ?? false) || pushed
            return
        }
        checking.insert(id)
        lastCheck[id] = now()
        defer {
            checking.remove(id)
            if let again = checkAgain.removeValue(forKey: id) { Task { await check(session, pushed: again) } }
        }
        refreshCalendarAndContacts(of: session, unlessRecent: pushed)
        // Drafts kept on this Mac go to the server's Drafts, on their own.
        Task { await session.mail.sendWaitingDrafts() }
        let storage = session.storage
        let state = await storage.cache.syncState()
        do {
            let result = try await session.services.mail.checkForNewMail(since: state)
            await storage.cache.save(syncState: result.state)
            // Blocked senders' mail and junk are dealt with first, unannounced (junk not on the first check, which finds
            // the whole inbox).
            let sorted = await mailFilter.sort(result.messages, in: session, judgesJunk: state != nil)
            if let unread = result.inboxUnread {
                unreadCounts[id] = max(0, unread - result.messages.filter { $0.isUnread && sorted.movedOut.contains($0.id) }.count)
            }
            let fresh = result.messages.filter { $0.isUnread && !sorted.quiet.contains($0.id) }
            if session.isActivated, pushed || !result.messages.isEmpty { session.mail.serverChanged() }
            if state != nil { prefetchRemoteContent(of: result.messages.filter { !sorted.quiet.contains($0.id) }, in: session) }
            // The first check only learns where the inbox is; announcing it would announce the whole inbox.
            if state != nil, !fresh.isEmpty, UserDefaults.standard.bool(forKey: "NotifyNewMail"), !isShowingInbox(of: session) {
                notifier.notify(newMail: fresh, in: session.account)
            }
            if !sorted.announce.isEmpty { notifier.notify(newMail: sorted.announce, in: session.account) }
            // Mail an earlier PMail kept on this Mac goes back to the server, on its own.
            Task { await putKeptMailBack(of: session) }
            // Invitations, answers and cancellations that came by email, for a calendar with no server to take them.
            if state != nil, session.services.calendar.takesInEmailedInvitations {
                let arrived = result.messages.filter { ($0.isInvitation == true || $0.hasAttachments) && !sorted.movedOut.contains($0.id) }
                if !arrived.isEmpty { Task { await takeInInvitations(from: arrived, in: session) } }
            }
        } catch PMailError.notSupported {
            unsupported.insert(id)
        } catch {
            // A failed check is tried again next time; the window reports its own errors.
        }
    }

    /// Takes the invitations, answers and cancellations in new mail into an account's calendar when its server doesn't
    /// (or it has none): an invitation for the account shows on the calendar waiting for an answer, an answer goes on
    /// the guest, and a cancellation takes the event off.
    func takeInInvitations(from messages: [MessageSummary], in session: AccountSession) async {
        let mail = session.services.mail
        var changed = false
        for summary in messages {
            guard let message = try? await mail.loadMessage(summary) else { continue }
            for file in message.attachments where Invitation.isCalendarFile(mimeType: file.mimeType, filename: file.filename) {
                let data: Data?
                if let inline = file.data { data = inline } else { data = try? await mail.loadAttachment(file, in: summary) }
                guard let data, let invitation = Invitation.read(data, ownerEmail: session.account.email) else { continue }
                if (try? await session.services.calendar.receive(invitation)) != nil { changed = true }
                break
            }
        }
        if changed {
            session.calendar.refreshQuietly()
            await session.calendar.answerInvitationsAutomatically()
        }
    }

    /// Puts mail an earlier PMail kept on this Mac (rather than on the server) back on the account's server, and shows
    /// the folders as they are then. A failure is tried again on a later check.
    func putKeptMailBack(of session: AccountSession) async {
        guard let count = try? await session.services.mail.putKeptMailBack(), count > 0 else { return }
        if session.isActivated { session.mail.serverChanged() }
    }

    /// Sends an account's calendar and contact changes made offline and gets its latest calendars and contacts, beside
    /// its mail check but on its own, so the mail doesn't wait for them. When the server pushed the check (new mail can
    /// come often), only if the last time was a while ago.
    func refreshCalendarAndContacts(of session: AccountSession, unlessRecent: Bool = false) {
        let id = session.id
        if unlessRecent, now().timeIntervalSince(lastRefresh[id] ?? .distantPast) < checkInterval { return }
        lastRefresh[id] = now()
        Task { await session.refreshCalendarAndContacts() }
    }

    // MARK: Protecting mail activity

    /// With mail activity protected (Settings ▸ Privacy), loads the pictures, style sheets and fonts in new mail as it
    /// arrives, through PMail's private loader into the account's copies, so senders see everyone's mail fetched as
    /// it arrives and can't tell whether or when it's read: opening it later asks the internet for nothing. A big
    /// message (with attachments, most likely) is left to load its pictures when it's opened.
    func prefetchRemoteContent(of messages: [MessageSummary], in session: AccountSession) {
        guard PrivacySettings.shared.protectsMailActivity, isOnline else { return }
        let wanted = messages.filter { ($0.size ?? 0) <= 5_000_000 }.prefix(50)
        guard !wanted.isEmpty else { return }
        let service = session.services.mail
        let cache = session.storage.remoteContent
        Task {
            for summary in wanted {
                guard let html = try? await service.loadMessage(summary).htmlBody, !html.isEmpty else { continue }
                await RemoteContentLoader.shared.prefetch(html: html, into: cache)
            }
        }
    }

    /// Starts the junk filter off on an account it hasn't learned from yet.
    func startLearning(_ session: AccountSession) async {
        await mailFilter.startLearning(session)
    }

    /// Whether the window is in front and showing this account's inbox, where a notification would only repeat it.
    private func isShowingInbox(of session: AccountSession) -> Bool {
        guard let app, NSApp.isActive, app.accounts.currentID == session.id, app.module == .mail else { return false }
        return session.mail.currentFolder?.role == .inbox && session.mail.openConversation == nil
    }

    /// The account showing gets pushed changes when its server can push (IMAP IDLE): a loop waiting on the server,
    /// checking the moment it speaks.
    private func restartPushIfNeeded() {
        guard let app, let session = app.current else {
            pushTask?.cancel()
            pushTask = nil
            pushAccount = nil
            return
        }
        guard session.services.mail.pushesChanges, isOnline else { return }
        if pushAccount == session.id, pushTask != nil { return }
        pushTask?.cancel()
        pushAccount = session.id
        let service = session.services.mail
        pushTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let changed = try await service.waitForChange(timeout: 20 * 60)
                    failures = 0
                    if changed, let self, let current = self.app?.accounts.session(for: session.id) { await self.check(current, pushed: true) }
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(300, 15 * failures)))
                }
            }
        }
    }

    func accountChanged() {
        pushTask?.cancel()
        pushTask = nil
        pushAccount = nil
        restartPushIfNeeded()
    }

    // MARK: Sending later

    /// Sends scheduled messages whose time has come and Outbox messages, while online.
    func sendDue(_ session: AccountSession, at date: Date) async {
        guard isOnline, !sending.contains(session.id) else { return }
        sending.insert(session.id)
        defer { sending.remove(session.id) }
        let queue = session.storage.queue
        let due = await queue.due(at: date)
        guard !due.isEmpty else { return }
        for item in due {
            do {
                var message = item.message
                message.date = now()
                try await session.services.mail.send(message)
                await session.storage.recipients.record((message.to + message.cc + message.bcc).map(\.email))
                await queue.remove(item.id)
                let contacts = session.contacts
                let people = message.to + message.cc + message.bcc
                Task { await contacts.addPeopleWritten(to: people) }
                if let draft = item.draft { try? await session.services.mail.deleteDraft(draft) }
                app?.show(item.isScheduled ? "Your scheduled message was sent." : "A message from your Outbox was sent.")
                session.mail.queueChanged()
                session.mail.didSend()
            } catch {
                var failed = item
                failed.attempts += 1
                failed.lastAttempt = now()
                failed.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if item.isScheduled {
                    // A scheduled message that couldn't go joins the Outbox, to be tried again.
                    failed.sendAt = nil
                    failed.queuedAt = now()
                }
                try? await queue.save(failed)
                session.mail.queueChanged()
                // Say so once: at once when signing in again would fix it, otherwise after the third try.
                let needsSignIn = (error as? PMailError)?.needsSignIn == true
                if (failed.attempts == 1 && needsSignIn) || failed.attempts == 3 {
                    app?.report(error, doing: "Sending “\(item.message.subject)”")
                }
            }
        }
    }

    // MARK: Snoozes

    /// Brings snoozed conversations whose time has come back to the inbox, unread, and says so.
    func wakeSnoozes(_ session: AccountSession, at date: Date) async {
        guard isOnline else { return }
        let book = session.storage.snoozes
        for snooze in await book.due(at: date) {
            do {
                let service = session.services.mail
                let found = try await service.findMessages(withMessageIDs: snooze.messageIDs)
                if !found.isEmpty {
                    // Unread first: a message kept on the Mac is uploaded as it is when it moves back.
                    if let latest = found.max(by: { $0.date < $1.date }) { try await service.perform(.markUnread, on: [latest]) }
                    try await service.perform(.moveToInbox, on: found)
                }
                await book.remove(snooze.id)
                session.mail.snoozesChanged()
                if !found.isEmpty {
                    if session.isActivated { session.mail.serverChanged() }
                    if UserDefaults.standard.bool(forKey: "NotifyNewMail") { notifier.notify(backFromSnooze: snooze.conversation, in: session.account) }
                }
            } catch {
                // Tried again on the next tick.
            }
        }
    }

    /// Unread mail in every account's inbox, for the Dock.
    var totalUnread: Int {
        guard let app else { return 0 }
        return app.accounts.accounts.reduce(0) { total, account in
            let session = app.accounts.session(for: account.id)
            let loaded = session?.mail.foldersLoaded == true ? session?.mail.unreadInbox : nil
            return total + (loaded ?? unreadCounts[account.id] ?? 0)
        }
    }

    func unread(for account: UUID) -> Int {
        let session = app?.accounts.session(for: account)
        if session?.mail.foldersLoaded == true { return session?.mail.unreadInbox ?? 0 }
        return unreadCounts[account] ?? 0
    }
}
