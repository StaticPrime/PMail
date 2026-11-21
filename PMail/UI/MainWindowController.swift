import AppKit
import Observation
import PMailKit
import SwiftUI

/// Where the window's own buttons are, so the top bar lines up with them.
@Observable
final class WindowChrome {
    /// Space to leave on the left for the close, minimize and zoom buttons.
    var leadingInset: CGFloat = 80
    /// The height of the band the window buttons sit in, which the top bar fills.
    var barHeight: CGFloat = 52
}

/// The main window: a top bar sharing the title bar's band, then mail, calendar or contacts. Menu commands come here
/// through the responder chain.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let app: AppModel
    let chrome = WindowChrome()
    nonisolated(unsafe) private var keyMonitor: Any?

    init(app: AppModel) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "PMail"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.canvasNS
        window.minSize = NSSize(width: 980, height: 620)
        window.isRestorable = false
        // An empty toolbar makes the title bar band taller and centers the window buttons in it; the top bar draws
        // into that band itself.
        let toolbar = NSToolbar(identifier: "PMailWindow")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: RootView(app: app, chrome: chrome))
        host.sizingOptions = []
        window.contentView = host
        measureChrome()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Nothing is focused at first (not the search field), so single-key shortcuts work straight away.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: Lining up with the window buttons

    private func measureChrome() {
        guard let window else { return }
        let band = window.frame.height - window.contentLayoutRect.height
        if window.styleMask.contains(.fullScreen) {
            chrome.leadingInset = 12
            chrome.barHeight = max(band, 52)
            return
        }
        chrome.barHeight = max(band, 44)
        if let zoom = window.standardWindowButton(.zoomButton), zoom.superview != nil {
            chrome.leadingInset = zoom.convert(zoom.bounds, to: nil).maxX + 14
        }
    }

    func windowDidResize(_ notification: Notification) { measureChrome() }
    func windowDidEnterFullScreen(_ notification: Notification) { measureChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { measureChrome() }
    func windowDidBecomeKey(_ notification: Notification) { measureChrome() }

    // MARK: Single-key shortcuts

    /// Letters that act without ⌘ while no text is being typed: c compose, / search, e archive, # delete, r reply,
    /// a reply all, f forward, s star, j/k older/newer, u back to the list, ! spam, Shift-I/U read/unread, and in the
    /// calendar d/w/m/a views, t today, j/k next/previous.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, NSApp.keyWindow === window,
                  window.attachedSheet == nil, UserDefaults.standard.bool(forKey: "SingleKeyShortcuts"),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !Self.isEditingText(window), self.app.sheet == nil else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    static func isEditingText(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable || textView.isFieldEditor }
        return responder is NSTextField
    }

    /// Handles a single-key shortcut. Returns whether it was one.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return false }
        let shifted = event.modifierFlags.contains(.shift)
        let typed = event.characters ?? key
        if key == "/" && !shifted { pmFind(nil); return true }
        guard let session = app.current else { return false }
        switch app.module {
        case .mail:
            let mail = session.mail
            switch (typed, shifted) {
            case ("c", false): pmNewMessage(nil)
            case ("e", false): act(.archive)
            case ("#", _): act(.trash)
            case ("!", _): act(.markSpam)
            case ("s", false):
                if let target = mail.targetConversations.first { mail.perform(target.isStarred ? .unstar : .star, on: [target]) }
            case ("I", true): act(.markRead)
            case ("U", true): act(.markUnread)
            case ("r", false): reply(.reply)
            case ("a", false): reply(.replyAll)
            case ("f", false): reply(.forward)
            case ("u", false): if mail.openConversation != nil { mail.closeConversation() }
            case ("j", false): if let next = mail.neighbor(1) { mail.open(next) }
            case ("k", false): if let previous = mail.neighbor(-1) { mail.open(previous) }
            default: return false
            }
            return true
        case .calendar:
            let calendar = session.calendar
            switch typed {
            case "d": calendar.mode = .day
            case "w": calendar.mode = .week
            case "m": calendar.mode = .month
            case "a": calendar.mode = .schedule
            case "t": calendar.goToday()
            case "j", "n": calendar.step(1)
            case "k", "p": calendar.step(-1)
            case "c": pmNewEvent(nil)
            default: return false
            }
            return true
        case .contacts:
            if typed == "c" { pmNewContact(nil); return true }
            if typed == "u", session.contacts.openContactID != nil { session.contacts.openContactID = nil; return true }
            return false
        }
    }

    private func act(_ action: MailAction) {
        guard let mail = app.current?.mail else { return }
        let targets = mail.targetConversations
        guard !targets.isEmpty else { return }
        mail.perform(action, on: targets)
    }

    private func reply(_ kind: ReplyBuilder.Kind) {
        guard let session = app.current, let message = session.mail.openMessages.last else { return }
        app.reply(to: message, kind: kind, in: session)
    }

    // MARK: Menu commands

    @objc func pmNewMessage(_ sender: Any?) { app.compose() }

    @objc func pmNewEvent(_ sender: Any?) {
        guard let calendar = app.current?.calendar else { return }
        app.show(.calendar)
        if let draft = calendar.newDraft() { app.sheet = .eventEditor(draft) } else { app.show("This account has no calendar you can add events to.") }
    }

    @objc func pmNewContact(_ sender: Any?) {
        guard app.current != nil else { return }
        app.show(.contacts)
        app.sheet = .contactEditor(Contact(id: "new-\(UUID().uuidString)"))
    }

    @objc func pmAddAccount(_ sender: Any?) { app.sheet = .addAccount(nil) }

    @objc func pmAccountSettings(_ sender: Any?) {
        guard let id = app.current?.id else { return }
        app.sheet = .accountSettings(id)
    }

    @objc func pmRemoveAccount(_ sender: Any?) {
        guard let session = app.current, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(session.account.email) from PMail?"
        alert.informativeText = "Its mail, calendars and contacts stay on the server; PMail just stops showing them and forgets its password or sign-in."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.app.removeAccount(session.id)
        }
    }

    @objc func pmSwitchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        app.switchAccount(to: id)
    }

    @objc func pmShowModule(_ sender: NSMenuItem) {
        guard let module = AppModel.Module.allCases[safe: sender.tag] else { return }
        app.show(module)
    }

    @objc func pmToggleSidebar(_ sender: Any?) {
        withAnimation(.easeInOut(duration: 0.2)) { app.isSidebarExpanded.toggle() }
    }

    @objc func pmCalendarMode(_ sender: NSMenuItem) {
        guard let mode = CalendarViewModel.Mode.allCases[safe: sender.tag], let calendar = app.current?.calendar else { return }
        app.show(.calendar)
        calendar.mode = mode
    }

    @objc func pmGoToday(_ sender: Any?) {
        app.show(.calendar)
        app.current?.calendar.goToday()
    }

    @objc func pmRefresh(_ sender: Any?) {
        guard let session = app.current else { return }
        switch app.module {
        case .mail: session.mail.refresh()
        case .calendar: session.calendar.reload()
        case .contacts: session.contacts.reload()
        }
    }

    @objc func pmFind(_ sender: Any?) { app.searchFocusRequest += 1 }

    @objc func pmReply(_ sender: Any?) { reply(.reply) }
    @objc func pmReplyAll(_ sender: Any?) { reply(.replyAll) }
    @objc func pmForward(_ sender: Any?) { reply(.forward) }
    @objc func pmArchive(_ sender: Any?) { act(.archive) }
    @objc func pmTrash(_ sender: Any?) { act(.trash) }
    @objc func pmSpam(_ sender: Any?) { act(.markSpam) }

    @objc func pmToggleRead(_ sender: Any?) {
        guard let mail = app.current?.mail else { return }
        let targets = mail.targetConversations
        let anyUnread = targets.contains(where: \.isUnread)
        mail.perform(anyUnread ? .markRead : .markUnread, on: targets)
        if !anyUnread, mail.openConversation != nil { mail.closeConversation() }
    }

    @objc func pmToggleStar(_ sender: Any?) {
        guard let mail = app.current?.mail else { return }
        let targets = mail.targetConversations
        mail.perform(targets.allSatisfy(\.isStarred) ? .unstar : .star, on: targets)
    }

    @objc func pmMoveTo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        act(.move(toFolderID: id))
    }

    @objc func pmSendMessage(_ sender: Any?) {
        app.composers.last(where: { !$0.isMinimized })?.send()
    }

    @objc func pmShowShortcuts(_ sender: Any?) { app.sheet = .shortcuts }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = app.current
        let mail = session?.mail
        let targets = mail?.targetConversations ?? []
        let capabilities = mail?.capabilities
        // While text is being typed, keys like ⌘⌫ belong to the text, not to the conversation behind it.
        let typing = window.map(Self.isEditingText) ?? false
        switch menuItem.action {
        case #selector(pmNewMessage(_:)), #selector(pmNewContact(_:)), #selector(pmRefresh(_:)), #selector(pmFind(_:)),
             #selector(pmAccountSettings(_:)), #selector(pmRemoveAccount(_:)):
            return session != nil
        case #selector(pmNewEvent(_:)), #selector(pmGoToday(_:)):
            return session?.calendar.defaultCalendar != nil || menuItem.action == #selector(pmGoToday(_:)) && session != nil
        case #selector(pmShowModule(_:)):
            menuItem.state = app.module == AppModel.Module.allCases[safe: menuItem.tag] ? .on : .off
            return session != nil
        case #selector(pmCalendarMode(_:)):
            menuItem.state = app.module == .calendar && session?.calendar.mode == CalendarViewModel.Mode.allCases[safe: menuItem.tag] ? .on : .off
            return session != nil
        case #selector(pmToggleSidebar(_:)):
            menuItem.title = app.isSidebarExpanded ? "Hide Sidebar" : "Show Sidebar"
            return session != nil
        case #selector(pmSwitchAccount(_:)):
            menuItem.state = (menuItem.representedObject as? UUID) == app.accounts.currentID ? .on : .off
            return true
        case #selector(pmReply(_:)), #selector(pmReplyAll(_:)), #selector(pmForward(_:)):
            return app.module == .mail && mail?.openMessages.isEmpty == false
        case #selector(pmArchive(_:)):
            return !typing && app.module == .mail && !targets.isEmpty && capabilities?.canArchive == true
        case #selector(pmTrash(_:)), #selector(pmSpam(_:)):
            return !typing && app.module == .mail && !targets.isEmpty
        case #selector(pmToggleRead(_:)):
            menuItem.title = targets.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread"
            return !typing && app.module == .mail && !targets.isEmpty
        case #selector(pmToggleStar(_:)):
            menuItem.title = !targets.isEmpty && targets.allSatisfy(\.isStarred) ? "Remove Star" : "Add Star"
            return !typing && app.module == .mail && !targets.isEmpty && capabilities?.canStar == true
        case #selector(pmMoveTo(_:)):
            return !typing && app.module == .mail && !targets.isEmpty && capabilities?.canMove == true
        case #selector(pmSendMessage(_:)):
            return app.composers.contains { !$0.isMinimized }
        default:
            return true
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
