import AppKit
import PMailKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var app: AppModel!
    private(set) var windowController: MainWindowController?
    /// `mailto:` links that arrived before the window was ready.
    private var pendingLinks: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false, "SingleKeyShortcuts": true, "UndoSendSeconds": 5])
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
        showMainWindow(nil)
        app.current?.activate()
        for link in pendingLinks { app.handleMailto(link) }
        pendingLinks = []
        #if DEBUG
        DebugLaunchOptions.runIfRequested(self)
        SelfTest.runIfRequested(self)
        #endif
    }

    /// The saved accounts with their real services, or (in debug runs that ask for them) the sample accounts.
    private func makeAccounts(oauth: OAuthConfiguration) -> AccountsController {
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts {
            return AccountsController(store: nil, secrets: MemorySecretStore(), factory: SampleServiceFactory(),
                                      defaults: DebugLaunchOptions.sampleDefaults)
        }
        #endif
        return AccountsController(store: AccountStore(fileURL: Self.supportFolder.appendingPathComponent("Accounts.json")),
                                  secrets: KeychainSecretStore(), factory: LiveServiceFactory(oauth: oauth, folder: Self.supportFolder))
    }

    /// Application Support/PMail in the app's container.
    static var supportFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PMail", isDirectory: true)
    }

    // MARK: Windows

    @objc func showMainWindow(_ sender: Any?) {
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = app.accounts.sessions.values.filter { $0.mail.hasPendingActions }
        guard !sessions.isEmpty else { return .terminateNow }
        Task {
            for session in sessions { await session.mail.flushAndWait() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Links

    /// `mailto:` links from other apps open a new message.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            if windowController == nil { pendingLinks.append(url) } else {
                showMainWindow(nil)
                app.handleMailto(url)
            }
        }
    }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(app) }
}
