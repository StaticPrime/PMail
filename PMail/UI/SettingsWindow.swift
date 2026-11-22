import AppKit
import PMailKit
import ServiceManagement
import SwiftUI

/// PMail ▸ Settings, in panes along a toolbar so none grows taller than the screen: General (new mail, opening at
/// login, the keyboard), Mail (Undo Send, pictures, inbox categories), Accounts (each account's blocked senders and
/// sender categories) and Signing In.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    enum Pane: Int, CaseIterable {
        case general, mail, accounts, signingIn

        var title: String {
            switch self {
            case .general: "General"
            case .mail: "Mail"
            case .accounts: "Accounts"
            case .signingIn: "Signing In"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .mail: "envelope"
            case .accounts: "person.crop.circle"
            case .signingIn: "key"
            }
        }

        @MainActor func view(_ app: AppModel) -> AnyView {
            switch self {
            case .general: AnyView(GeneralSettings(app: app))
            case .mail: AnyView(MailSettings(app: app))
            case .accounts: AnyView(AccountSettings(app: app))
            case .signingIn: AnyView(SigningInSettings(app: app))
            }
        }
    }

    private let tabs = NSTabViewController()

    static func show(_ app: AppModel, pane: Pane? = nil) {
        let controller = shared ?? SettingsWindowController(app: app)
        shared = controller
        if let pane { controller.tabs.selectedTabViewItemIndex = pane.rawValue }
        if controller.window?.isVisible != true { controller.window?.center() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(app: AppModel) {
        tabs.tabStyle = .toolbar
        for pane in Pane.allCases {
            let host = NSHostingController(rootView: pane.view(app))
            // Each pane sizes the window to fit it, and follows it as it grows (someone blocked while it's open).
            host.sizingOptions = .preferredContentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = NSUserInterfaceItemIdentifier("PMailSettings")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension View {
    /// A settings pane: grouped sections at a fixed width, as tall as they need.
    func settingsPane() -> some View {
        formStyle(.grouped).frame(width: 520).fixedSize()
    }
}

/// General: new mail, opening at login, and the keyboard.
private struct GeneralSettings: View {
    let app: AppModel
    @AppStorage("NotifyNewMail") private var notifyNewMail = true
    @AppStorage("CheckMinutes") private var checkMinutes = 2
    @AppStorage("SingleKeyShortcuts") private var singleKeys = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("New mail") {
                Toggle("Show a notification when new mail arrives", isOn: $notifyNewMail)
                Picker("Check for new mail", selection: $checkMinutes) {
                    Text("Every minute").tag(1)
                    Text("Every 2 minutes").tag(2)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                }
                Text("An IMAP account (iCloud included) is watched while it’s showing: new mail appears the moment its server says so, or within a minute.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
                Toggle("Open PMail when I log in", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                if let loginError { Text(loginError).font(.pm(11.5)).foregroundStyle(.red) }
            }
            Section("Keyboard") {
                Toggle("Single-key shortcuts (C to compose, E to archive, J and K to move…)", isOn: $singleKeys)
                Button("Show All Shortcuts") { app.sheet = .shortcuts }
            }
        }
        .settingsPane()
    }

    /// Adds PMail to (or takes it out of) the apps that open at login, so new mail and snoozes keep coming.
    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn’t allow it: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Mail: Undo Send, pictures, and sorting inboxes into categories.
private struct MailSettings: View {
    let app: AppModel
    @AppStorage("UndoSendSeconds") private var undoSeconds = 5
    @AppStorage("AlwaysShowPictures") private var alwaysShowPictures = false
    @AppStorage("SortInboxCategories") private var sortsCategories = true

    var body: some View {
        Form {
            Section("Sending and reading") {
                Picker("Undo Send", selection: $undoSeconds) {
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Show pictures in messages without asking", isOn: $alwaysShowPictures)
                Text("Pictures from the internet can tell senders when you read their mail, so PMail asks first unless this is on.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
            }
            Section("Inbox categories") {
                Toggle("Sort the inbox into categories", isOn: Binding(get: { sortsCategories }, set: { on in
                    sortsCategories = on
                    for session in app.accounts.sessions.values { session.mail.categoriesSettingChanged() }
                }))
                Text("Shows the inbox in tabs, each with its unread count: the server's own on Google and Microsoft accounts, and Primary, Transactions, Updates, Promotions and Social, sorted on this Mac, for the others. Move a conversation to another category (or drag it onto a tab) and that sender's mail goes there from now on; Accounts lists them. Off, every inbox is one list.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

/// Accounts: everything about the account picked — the settings its account menu also offers (the name on sent mail,
/// the signature, its servers, signing in again, removing it), and its own blocked senders and senders put in a
/// category. Every account keeps its own; changing the picker shows another account's.
private struct AccountSettings: View {
    let app: AppModel
    @State private var accountID: UUID?
    /// The picked account as edited here, saved a moment after each change.
    @State private var draft: Account?
    @State private var saving: Task<Void, Never>?

    /// The account showing: the one picked (while it's still there), else the one in the window.
    private var account: UUID? {
        if let accountID, app.accounts.accounts.contains(where: { $0.id == accountID }) { return accountID }
        return app.accounts.currentID ?? app.accounts.accounts.first?.id
    }

    var body: some View {
        let mail = account.flatMap { app.accounts.session(for: $0) }?.mail
        Form {
            if app.accounts.accounts.isEmpty {
                Text("Add an account to see its settings here.").foregroundStyle(.secondary)
            } else {
                Section {
                    Picker("Account", selection: Binding(get: { account }, set: { accountID = $0 })) {
                        ForEach(app.accounts.accounts) { account in Text(account.email).tag(Optional(account.id)) }
                    }
                    if let draft { AccountHeader(account: draft).padding(.vertical, 4) }
                }
                if draft != nil {
                    AccountSettingsSections(app: app, account: Binding(get: { draft ?? Account(kind: .other, name: "", email: "") }, set: save))
                }
                blockedSection(mail)
                categoriesSection(mail)
            }
        }
        .formStyle(.grouped)
        // The pane holds a lot: a fixed height that fits on the screen, scrolling inside.
        .frame(width: 520, height: min(620, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
        .task(id: account) {
            saving?.cancel()
            draft = account.flatMap { id in app.accounts.accounts.first { $0.id == id } }
            await mail?.loadBlockedSenders()
            await mail?.loadSenderCategories()
        }
    }

    /// Keeps an edit and saves it once typing pauses.
    private func save(_ edited: Account) {
        draft = edited
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            app.accounts.update(edited)
        }
    }

    /// Senders blocked from Report spam, each with Unblock.
    private func blockedSection(_ mail: MailViewModel?) -> some View {
        let blocked = mail?.blockedSenders ?? []
        return Section("Blocked senders") {
            if blocked.isEmpty {
                Text("No one is blocked. Report spam offers to block the sender, or everything from their domain, so their mail goes to \(mail?.spamFolderName ?? "Junk") as it arrives.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(blocked) { sender in
                            HStack {
                                Text(sender.kind == .domain ? "Everything from \(sender.value)" : sender.value).textSelection(.enabled)
                                Spacer()
                                Button("Unblock") { mail?.unblock(sender) }
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(blocked.count) * 28, 168))
            }
        }
    }

    /// Senders put in an inbox category by hand, each with its category and Sort Automatically.
    private func categoriesSection(_ mail: MailViewModel?) -> some View {
        let choices = (mail?.senderCategories ?? [:]).sorted { $0.key < $1.key }
        return Section("Senders in categories") {
            if let mail, !choices.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(choices, id: \.key) { sender, category in
                            HStack {
                                Text(sender).textSelection(.enabled).lineLimit(1)
                                Spacer()
                                Picker("", selection: Binding(get: { category }, set: { mail.setCategory($0, forSender: sender) })) {
                                    ForEach(InboxCategory.allCases, id: \.self) { Text($0.name).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                Button("Sort Automatically") { mail.setCategory(nil, forSender: sender) }
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(choices.count) * 30, 180))
            } else {
                Text("Move a conversation to another category and its sender shows here, to change or to sort automatically again.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Signing In: whether this copy can sign in to Google and Microsoft, and what the others use.
private struct SigningInSettings: View {
    let app: AppModel

    var body: some View {
        Form {
            Section("Signing in") {
                LabeledContent("Google") { status(app.oauth.google != nil, variable: "PMAIL_GOOGLE_CLIENT_ID") }
                LabeledContent("Microsoft") { status(app.oauth.microsoft != nil, variable: "PMAIL_MICROSOFT_CLIENT_ID") }
                LabeledContent("iCloud") { Text("App-specific password").foregroundStyle(.secondary) }
                LabeledContent("Other mail accounts") { Text("Password").foregroundStyle(.secondary) }
            }
        }
        .settingsPane()
    }

    private func status(_ ready: Bool, variable: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ready ? .green : .orange)
            Text(ready ? "Set up" : "Not set up (\(variable))").foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Help ▸ Keyboard Shortcuts.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Anywhere", [("⌘N", "New message"), ("⌥⌘N", "New event"), ("⌘1  ⌘2  ⌘3", "Mail, Calendar, Contacts"), ("⌘F or /", "Search"),
                      ("⌃⌘1…9", "Switch account"), ("⌃⌘S", "Hide or show the sidebar"), ("⇧⌘N", "Refresh")]),
        ("Mail", [("C", "Compose"), ("E", "Archive"), ("#", "Delete"), ("!", "Report spam"), ("S", "Star or unstar"), ("R", "Reply"),
                  ("A", "Reply all"), ("F", "Forward"), ("J  K", "Older or newer conversation"), ("U", "Back to the list"),
                  ("⇧I  ⇧U", "Mark read or unread"), ("⌘Return", "Send")]),
        ("Calendar", [("C", "Create an event"), ("D  W  M  A", "Day, week, month or schedule"), ("T", "Today"), ("J  K", "Next or previous")]),
        ("Writing", [("⌘B  ⌘I  ⌘U", "Bold, italic, underline"), ("⌘K", "Insert link")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.pm(20))
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 22) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0).font(.pm(14, .semibold)).foregroundStyle(Theme.accent)
                            ForEach(group.1, id: \.1) { key, action in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(key).font(.system(size: 12.5, weight: .medium, design: .rounded)).frame(width: 110, alignment: .leading)
                                    Text(action).font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                Text("Single-key shortcuts work when you aren’t typing, and can be turned off in Settings.")
                    .font(.pm(11.5)).foregroundStyle(Theme.textTertiary).padding(.bottom, 20)
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.surface)
    }
}
