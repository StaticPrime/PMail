import AppKit
import PMailKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var app: AppModel!
    private(set) var windowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false, "SingleKeyShortcuts": true,
                                                  UndoSend.key: UndoSend.standard, "NotifyNewMail": true, "CheckMinutes": 2])
        UndoSend.settleChoice()
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts {
            // Sample runs keep their own privacy settings and never load anything from the internet.
            let privacy = PrivacySettings(store: DebugLaunchOptions.sampleDefaults, passwords: MemoryProxyPassword())
            privacy.sampleFetcher = SampleRemoteFetcher.shared
            PrivacySettings.shared = privacy
            JunkSettings.shared = JunkSettings(store: DebugLaunchOptions.sampleDefaults,
                                               filterFile: DebugLaunchOptions.sampleStorage.appendingPathComponent("Junk Filter.json"))
            BuiltInTor.shared.makeRunner = { _, onEvent in SampleTor(onEvent: onEvent) }
            BuiltInTor.shared.connectedFetcher = { _ in SampleRemoteFetcher.shared }
        }
        #endif
        let oauth = OAuthConfiguration.load()
        let accounts = makeAccounts(oauth: oauth)
        app = AppModel(accounts: accounts, oauth: oauth)
        accounts.app = app
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts {
            accounts.load(DebugLaunchOptions.sampleAccounts)
        } else {
            accounts.load()
        }
        #else
        accounts.load()
        #endif
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PMDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if UserDefaults.standard.bool(forKey: "PMLight") { NSApp.appearance = NSAppearance(named: .aqua) }
        #endif
        // Made now, so a notification clicked to open PMail reaches it; it's put to work once PMail has opened.
        let notifier = makeNotifier()
        // The splash screen and the update check come first. The window and everything else opening does wait for them
        // (see UpdateController), so an update that restarts PMail as it opens doesn't cut them off as they start.
        let updates = UpdateController.shared
        updates.onLaunch = { [weak self] in self?.finishOpening(notifier: notifier) }
        updates.onHandoff = { [weak self] handoff in
            if let handoff = LaunchHandoff(handoff) { self?.perform(handoff) }
        }
        updates.settleBeforeRestart = { [weak self] ready in
            guard let self else { return ready(true) }
            settleBeforeRestart(ready)
        }
        updates.start()
        stopOpeningAtLogin()
    }

    /// PMail never opens by itself when you log in. Earlier versions could, from Settings, so a Mac where that was
    /// turned on has PMail taken back out of the apps that open at login. (Sample runs leave the Mac's login items alone.)
    private func stopOpeningAtLogin() {
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts { return }
        #endif
        Task.detached(priority: .utility) {
            let service = SMAppService.mainApp
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try? await service.unregister()
        }
    }

    /// What opening PMail does, once the splash screen is gone: remote content gets its route (starting the built-in Tor
    /// when Hide IP address uses it), the window opens, the account showing loads, and the background sync starts.
    private func finishOpening(notifier: any MailNotifier) {
        PrivacySettings.shared.routeChanged()
        showMainWindow(nil)
        app.current?.activate()
        let sync = SyncController(app: app, notifier: notifier)
        app.sync = sync
        sync.start()
        #if DEBUG
        DebugLaunchOptions.runIfRequested(self)
        SelfTest.runIfRequested(self)
        #endif
    }

    /// The system's notifications, or (in sample runs) a list of them.
    private func makeNotifier() -> any MailNotifier {
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts { return RecordingNotifier() }
        #endif
        return SystemNotifier()
    }

    /// The saved accounts with their real services, or (in debug runs that ask for them) the sample accounts.
    private func makeAccounts(oauth: OAuthConfiguration) -> AccountsController {
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts {
            return AccountsController(store: nil, secrets: MemorySecretStore(), factory: SampleServiceFactory(),
                                      storageFolder: DebugLaunchOptions.sampleStorage, defaults: DebugLaunchOptions.sampleDefaults)
        }
        #endif
        return AccountsController(store: AccountStore(fileURL: Self.supportFolder.appendingPathComponent("Accounts.json")),
                                  secrets: KeychainSecretStore(), factory: LiveServiceFactory(oauth: oauth, folder: Self.supportFolder),
                                  storageFolder: Self.accountsFolder(in: Self.supportFolder))
    }

    /// Application Support/PMail/Accounts: a folder for each account's cache, Outbox, snoozes and anything kept only
    /// on the Mac.
    static func accountsFolder(in support: URL) -> URL {
        support.appendingPathComponent("Accounts", isDirectory: true)
    }

    /// Application Support/PMail in the app's container.
    static var supportFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PMail", isDirectory: true)
    }

    // MARK: Windows

    @objc func showMainWindow(_ sender: Any?) {
        // Not while PMail is still opening (or updating as it opens): the window opens once it has.
        guard UpdateController.shared.hasLaunched else { return }
        if windowController == nil {
            windowController = MainWindowController(app: app)
            windowController?.window?.center()
            windowController?.window?.setFrameAutosaveName("PMailMainWindow")
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Archives, deletes and moves still waiting out their Undo reach the server before PMail quits.
    func applicationWillTerminate(_ notification: Notification) {
        app.sync?.stop()
        BuiltInTor.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never while macOS's installer is changing PMail (see UpdateController).
        if UpdateController.shared.isInstalling { return .terminateCancel }
        let sessions = app.accounts.sessions.values.filter { $0.mail.hasPendingActions }
        guard !sessions.isEmpty else { return .terminateNow }
        Task {
            for session in sessions { await session.mail.flushAndWait() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Gets PMail ready to quit for a new version it has just installed (see UpdateController). Messages still waiting
    /// out Undo Send go first, open compose windows are kept as drafts (as their Save & Close button does), and archives,
    /// deletes and moves waiting out Undo reach the server, as when PMail quits; then the background sync stops, so the
    /// new version starts on its own. It can't go ahead only if a message is still on its way after two minutes.
    private func settleBeforeRestart(_ ready: @escaping @MainActor (Bool) -> Void) {
        Task {
            let deadline = Date().addingTimeInterval(120)
            while ComposeModel.messagesOnTheirWay > 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard ComposeModel.messagesOnTheirWay == 0 else { return ready(false) }
            for draft in app.composers.compactMap({ $0.closeKeepingDraft() }) { await draft.value }
            for session in app.accounts.sessions.values where session.mail.hasPendingActions { await session.mail.flushAndWait() }
            app.sync?.stop()
            ready(true)
        }
    }

    // MARK: Links and notifications

    /// `mailto:` links from other apps open a new message, once PMail has opened (in the new version, should PMail
    /// restart to finish updating first).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            UpdateController.shared.whenLaunched(handoff: LaunchHandoff.mailto(url).encoded) { [weak self] in
                self?.perform(.mailto(url))
            }
        }
    }

    /// Opens what a link or a notification asked for, here or in the copy before this one, which handed it over.
    private func perform(_ handoff: LaunchHandoff) {
        switch handoff {
        case let .mailto(url):
            showMainWindow(nil)
            app.handleMailto(url)
        case let .conversation(account, message):
            app.openConversation(message, in: account)
        }
    }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(app) }
}

/// Something PMail was asked to open as it started, kept for the new version should PMail restart to finish updating
/// first (see UpdateController): a `mailto:` link to write to, or the conversation of a notification that was clicked.
enum LaunchHandoff: Codable {
    case mailto(URL)
    case conversation(account: UUID, message: MessageSummary)

    var encoded: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    init?(_ encoded: String) {
        guard let handoff = try? JSONDecoder().decode(LaunchHandoff.self, from: Data(encoded.utf8)) else { return nil }
        self = handoff
    }
}
