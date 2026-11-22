import AppKit
import PMailKit
import SwiftUI

/// Everything in the main window: the top bar, the rail of Mail, Calendar and Contacts, the part showing, compose
/// windows docked at the bottom right and notes at the bottom left.
struct RootView: View {
    @Bindable var app: AppModel
    let chrome: WindowChrome

    var body: some View {
        VStack(spacing: 0) {
            TopBar(app: app, chrome: chrome)
            if let session = app.current {
                HStack(spacing: 0) {
                    AppRail(app: app, session: session)
                    module(for: session)
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
                .id(session.id)
            } else {
                WelcomeView(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottomTrailing) { ComposeDock(app: app) }
        .overlay(alignment: .bottomLeading) { ToastView(app: app) }
        .sheet(item: $app.sheet) { sheet in sheetContent(sheet) }
        .onChange(of: app.accounts.currentID) { app.current?.activate() }
    }

    @ViewBuilder
    private func module(for session: AccountSession) -> some View {
        switch app.module {
        case .mail: MailScreen(app: app, session: session, mail: session.mail)
        case .calendar: CalendarScreen(app: app, session: session, model: session.calendar)
        case .contacts: ContactsScreen(app: app, session: session, model: session.contacts)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case let .addAccount(kind):
            AddAccountView(app: app, initialKind: kind)
        case let .accountSettings(id):
            if let session = app.accounts.session(for: id) { AccountSettingsView(app: app, account: session.account) }
        case let .eventEditor(draft):
            if let session = app.current { EventEditor(app: app, model: session.calendar, contacts: session.contacts, draft: draft) }
        case let .contactEditor(contact):
            if let session = app.current { ContactEditor(app: app, model: session.contacts, contact: contact) }
        case let .addPeople(account, people):
            // One person in the contact editor, filled in; several in a list.
            if let session = app.accounts.sessions[account] {
                if people.count == 1, let person = people.first {
                    ContactEditor(app: app, model: session.contacts, contact: ContactsViewModel.newContact(for: person))
                } else {
                    AddPeopleSheet(model: session.contacts, people: people)
                }
            }
        case .shortcuts:
            ShortcutsView()
        }
    }
}

/// The bar across the top: the menu button and logo, search, settings and the account's picture.
struct TopBar: View {
    @Bindable var app: AppModel
    let chrome: WindowChrome

    var body: some View {
        HStack(spacing: 4) {
            if app.current != nil {
                IconButton(symbol: "line.3.horizontal", help: app.isSidebarExpanded ? "Hide the sidebar" : "Show the sidebar", size: 40,
                           iconSize: 17) {
                    withAnimation(.easeInOut(duration: 0.2)) { app.isSidebarExpanded.toggle() }
                }
            }
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text("PMail")
                    .font(.system(size: 21, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.trailing, 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PMail")
            if app.current != nil {
                SearchField(app: app)
                    .frame(maxWidth: 720)
            }
            Spacer(minLength: 12)
            IconButton(symbol: "questionmark.circle", help: "Keyboard shortcuts", size: 40, iconSize: 18) { app.sheet = .shortcuts }
            IconButton(symbol: "gearshape", help: "Settings", size: 40, iconSize: 18) {
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
            }
            if app.current != nil {
                AccountButton(app: app)
                    .padding(.leading, 6)
            }
        }
        .padding(.leading, chrome.leadingInset)
        .padding(.trailing, 14)
        .frame(height: max(chrome.barHeight, 56))
        .background(WindowDragArea())
    }
}

/// The big rounded search field.
struct SearchField: View {
    @Bindable var app: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "magnifyingglass", help: "Search", size: 40, iconSize: 16) { submit() }
            TextField(app.module.searchPrompt, text: $app.searchText)
                .textFieldStyle(.plain)
                .font(.pm(15))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    clear()
                    focused = false
                    return .handled
                }
            if !app.searchText.isEmpty {
                IconButton(symbol: "xmark", help: "Clear search", size: 36, iconSize: 13) { clear() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(Capsule().fill(focused ? Theme.searchFieldFocused : Theme.searchField))
        .shadow(color: .black.opacity(focused ? 0.18 : 0), radius: focused ? 3 : 0, y: 1)
        .onChange(of: app.searchFocusRequest) { focused = true }
        .onChange(of: app.searchText) { _, text in
            // Calendars and contacts filter as you type; mail searches the server when you press Return.
            if text.isEmpty, app.module == .mail { app.current?.mail.clearSearch() }
        }
    }

    private func submit() {
        if app.module == .mail { app.current?.mail.search(app.searchText) }
        if app.module == .calendar, !app.searchText.isEmpty { app.current?.calendar.mode = .schedule }
    }

    private func clear() {
        app.searchText = ""
        if app.module == .mail { app.current?.mail.clearSearch() }
    }
}

/// The narrow rail on the left for moving between Mail, Calendar and Contacts.
struct AppRail: View {
    let app: AppModel
    let session: AccountSession

    var body: some View {
        VStack(spacing: 12) {
            ForEach(AppModel.Module.allCases) { module in
                RailItem(module: module, isSelected: app.module == module,
                         badge: module == .mail ? session.mail.unreadInbox : 0) {
                    app.show(module)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
        .frame(width: 72)
        .onChange(of: app.sync?.totalUnread ?? session.mail.unreadInbox, initial: true) { _, unread in
            // Unread mail in every account's inbox.
            NSApp.dockTile.badgeLabel = unread > 0 ? (unread > 999 ? "999+" : "\(unread)") : nil
        }
    }
}

private struct RailItem: View {
    let module: AppModel.Module
    let isSelected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isSelected ? module.selectedSymbol : module.symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isSelected ? Theme.onSelection : Theme.icon)
                        .frame(width: 56, height: 32)
                        .background(Capsule().fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
                    if badge > 0 {
                        Text(badge > 999 ? "999+" : "\(badge)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Theme.danger))
                            .offset(x: 2, y: -4)
                    }
                }
                Text(module.title)
                    .font(.pm(11.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(badge > 0 ? "\(module.title), \(badge) unread" : module.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The account's picture at the top right, which opens the account switcher.
struct AccountButton: View {
    @Bindable var app: AppModel
    @State private var showsMenu = false
    @State private var hovering = false

    var body: some View {
        if let account = app.current?.account {
            Button { showsMenu.toggle() } label: {
                AccountAvatar(account: account, size: 32)
                    .padding(4)
                    .background(Circle().fill(hovering ? Theme.hover : .clear))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(account.name)\n\(account.email)")
            .accessibilityLabel("Account: \(account.email)")
            .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
                AccountMenu(app: app) { showsMenu = false }
            }
            .onChange(of: app.accountMenuRequest) { showsMenu = true }
        }
    }
}

/// The first thing someone sees with no accounts: the logo and the ways to add one.
struct WelcomeView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("AboutLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 220, height: 220)
                    .accessibilityHidden(true)
                Text("Welcome to PMail")
                    .font(.system(size: 30, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your mail, calendar and contacts together. Add an account to get started.")
                    .font(.pm(15))
                    .foregroundStyle(Theme.textSecondary)
                ProviderGrid(app: app) { kind in app.sheet = .addAccount(kind) }
                    .frame(maxWidth: 560)
                    .padding(.top, 8)
                Text("PMail talks only to your mail provider. It has no account of its own, shows no ads and never tracks you.")
                    .font(.pm(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The note along the bottom left ("Conversation archived. Undo").
struct ToastView: View {
    let app: AppModel

    var body: some View {
        if let toast = app.toast {
            HStack(spacing: 24) {
                Text(toast.text)
                    .font(.pm(13))
                    .foregroundStyle(Theme.onToast)
                    .lineLimit(3)
                if let title = toast.actionTitle, let action = toast.action {
                    Button(title) {
                        action()
                        if app.toast?.id == toast.id { app.dismissToast() }
                    }
                    .buttonStyle(.plain)
                    .font(.pm(13, .semibold))
                    .foregroundStyle(Theme.dynamic(light: 0xA8C7FA, dark: 0x0B57D0))
                }
                Button { app.dismissToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onToast.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.toast))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(.leading, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Empty space in the top bar that moves the window, and double-clicks the way the title bar does.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
                return
            }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
