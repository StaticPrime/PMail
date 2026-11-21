import AppKit
import PMailKit
import ServiceManagement
import SwiftUI

/// PMail ▸ Settings: shortcuts, Undo Send, pictures in messages, and whether sign-in with Google and Microsoft is set
/// up in this copy.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(_ app: AppModel) {
        let controller = shared ?? SettingsWindowController(app: app)
        shared = controller
        if controller.window?.isVisible != true { controller.window?.center() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(app: AppModel) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("PMailSettings")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: SettingsView(app: app))
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct SettingsView: View {
    let app: AppModel
    @AppStorage("SingleKeyShortcuts") private var singleKeys = true
    @AppStorage("UndoSendSeconds") private var undoSeconds = 5
    @AppStorage("AlwaysShowPictures") private var alwaysShowPictures = false
    @AppStorage("NotifyNewMail") private var notifyNewMail = true
    @AppStorage("CheckMinutes") private var checkMinutes = 2
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
            Section("Mail") {
                Picker("Undo Send", selection: $undoSeconds) {
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Show pictures in messages without asking", isOn: $alwaysShowPictures)
                Text("Pictures from the internet can tell senders when you read their mail, so PMail asks first unless this is on.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Single-key shortcuts (C to compose, E to archive, J and K to move…)", isOn: $singleKeys)
                Button("Show All Shortcuts") { app.sheet = .shortcuts }
            }
            Section("Signing in") {
                LabeledContent("Google") { status(app.oauth.google != nil, variable: "PMAIL_GOOGLE_CLIENT_ID") }
                LabeledContent("Microsoft") { status(app.oauth.microsoft != nil, variable: "PMAIL_MICROSOFT_CLIENT_ID") }
                LabeledContent("iCloud") { Text("App-specific password").foregroundStyle(.secondary) }
                LabeledContent("Other mail accounts") { Text("Password").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
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
