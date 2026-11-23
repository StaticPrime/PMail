import AppKit
import Observation
import PMailKit

/// What the main window shows and everything it shares: the accounts, the part of the app showing (mail, calendar or
/// contacts), the search field, compose windows, sheets and the little notes along the bottom.
@Observable
final class AppModel {
    enum Module: String, CaseIterable, Identifiable {
        case mail, calendar, contacts
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mail: "Mail"
            case .calendar: "Calendar"
            case .contacts: "Contacts"
            }
        }

        var symbol: String {
            switch self {
            case .mail: "envelope"
            case .calendar: "calendar"
            case .contacts: "person.crop.circle"
            }
        }

        /// The symbol when chosen (a filled one where there is one).
        var selectedSymbol: String {
            switch self {
            case .mail: "envelope.fill"
            case .calendar: "calendar"
            case .contacts: "person.crop.circle.fill"
            }
        }

        var searchPrompt: String {
            switch self {
            case .mail: "Search mail"
            case .calendar: "Search events"
            case .contacts: "Search contacts"
            }
        }
    }

    /// A sheet over the main window.
    enum Sheet: Identifiable {
        case addAccount(AccountKind?)
        case accountSettings(UUID)
        case eventEditor(EventDraft)
        case contactEditor(Contact)
        /// "Add to Contacts?" for people written to: the account, and who.
        case addPeople(UUID, [MailAddress])
        /// Subscribing the account showing to a calendar: someone's, or one from a web address.
        case subscribeToCalendar(SubscribeCalendarSheet.Kind)
        /// A file's events, to import into one of the account's calendars.
        case importEvents(ImportedEvents)
        case shortcuts

        var id: String {
            switch self {
            case let .addAccount(kind): "add-\(kind?.rawValue ?? "any")"
            case let .accountSettings(id): "settings-\(id)"
            case let .eventEditor(draft): "event-\(draft.id)"
            case let .contactEditor(contact): "contact-\(contact.id)"
            case let .addPeople(account, people): "add-people-\(account)-\(people.map(\.email).joined(separator: ","))"
            case let .subscribeToCalendar(kind): kind == .person ? "subscribe-person" : "subscribe-address"
            case let .importEvents(file): "import-\(file.id)"
            case .shortcuts: "shortcuts"
            }
        }
    }

    /// A note along the bottom of the window, with an optional Undo.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var actionTitle: String?
        var action: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id && lhs.text == rhs.text }
    }

    let accounts: AccountsController
    let oauth: OAuthConfiguration
    /// The calendar Settings ▸ Calendar shows next, when asked from a calendar's ⋯ menu.
    var calendarSettingsTarget: CalendarSettingsTarget?
    /// Keeps every account up to date in the background (made once the window exists).
    var sync: SyncController?
    var module: Module = .mail
    var searchText = ""
    var isSidebarExpanded = true
    var sheet: Sheet?
    var toast: Toast?
    var composers: [ComposeModel] = []
    /// The focused search field asks for focus through this, for ⌘F and "/".
    var searchFocusRequest = 0
    /// Bumped to open the account switcher from code.
    var accountMenuRequest = 0
    private var toastTask: Task<Void, Never>?

    init(accounts: AccountsController, oauth: OAuthConfiguration) {
        self.accounts = accounts
        self.oauth = oauth
    }

    var current: AccountSession? { accounts.current }

    // MARK: Notes

    /// Shows a note along the bottom for a few seconds (longer with an action).
    func show(_ text: String, actionTitle: String? = nil, duration: TimeInterval? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(text: text, actionTitle: actionTitle, action: action)
        self.toast = toast
        toastTask?.cancel()
        let seconds = duration ?? (action == nil ? 4 : 7)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Reports a failure in a note, with the server's reason.
    func report(_ error: Error, doing what: String) {
        if (error as? PMailError) == .cancelled { return }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        show("\(what) didn’t work. \(reason)", duration: 8)
    }

    // MARK: Compose

    /// Opens a new message, optionally addressed already.
    @discardableResult
    func compose(to: [MailAddress] = [], subject: String = "", body: String = "") -> ComposeModel? {
        guard let session = current else {
            sheet = .addAccount(nil)
            return nil
        }
        let model = ComposeModel(app: self, session: session)
        model.to = to
        model.subject = subject
        if !body.isEmpty { model.setPlainBody(body) }
        open(model)
        return model
    }

    /// Opens a reply, reply-all or forward to a message.
    func reply(to message: MailMessage, kind: ReplyBuilder.Kind, in session: AccountSession) {
        let model = ComposeModel(app: self, session: session)
        model.startReply(to: message, kind: kind)
        open(model)
    }

    func open(_ model: ComposeModel) {
        module = .mail
        // One that's already open comes to the front rather than opening twice.
        if composers.contains(where: { $0 === model }) {
            composers.removeAll { $0 === model }
            model.isMinimized = false
        }
        // At most three stay open side by side; older ones minimize.
        for other in composers where !other.isMinimized && composers.filter({ !$0.isMinimized }).count >= 3 {
            other.isMinimized = true
            break
        }
        composers.append(model)
    }

    func close(_ model: ComposeModel) {
        composers.removeAll { $0 === model }
    }

    /// Opens a compose window for a `mailto:` link.
    func handleMailto(_ url: URL) {
        guard let fields = MailtoLink(url: url) else { return }
        compose(to: fields.to, subject: fields.subject, body: fields.body)?.cc = fields.cc
    }

    // MARK: Switching

    func show(_ module: Module) {
        guard self.module != module else { return }
        self.module = module
        searchText = ""
    }

    /// Removes an account from PMail, closing its compose windows, and shows the next one.
    func removeAccount(_ id: UUID) {
        composers.removeAll { $0.session.id == id }
        accounts.remove(id)
        searchText = ""
        current?.activate()
    }

    func switchAccount(to id: UUID) {
        guard accounts.currentID != id else { return }
        current?.mail.flushPendingActions()
        accounts.switchTo(id)
        searchText = ""
        current?.activate()
        sync?.accountChanged()
    }

    /// Opens a message's conversation in its account's inbox (from a notification).
    func openConversation(_ message: MessageSummary, in accountID: UUID) {
        (NSApp.delegate as? AppDelegate)?.showMainWindow(nil)
        NSApp.activate()
        switchAccount(to: accountID)
        show(.mail)
        guard let mail = current?.mail else { return }
        if mail.currentFolder?.role != .inbox, let inbox = mail.inbox { mail.select(folderID: inbox.id) }
        mail.open(Conversation(id: message.threadID, messages: [message]))
    }
}

/// The fields of a `mailto:` link.
struct MailtoLink {
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var subject = ""
    var body = ""

    init?(url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let text = url.absoluteString.dropFirst("mailto:".count)
        let parts = text.split(separator: "?", maxSplits: 1)
        let addresses = String(parts.first ?? "").removingPercentEncoding ?? ""
        to = addresses.split(separator: ",").map { MailAddress(email: String($0)) }.filter { !$0.email.isEmpty }
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let value = String(kv[1]).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? ""
                switch kv[0].lowercased() {
                case "subject": subject = value
                case "body": body = value
                case "cc": cc = value.split(separator: ",").map { MailAddress(email: String($0)) }
                case "to": to += value.split(separator: ",").map { MailAddress(email: String($0)) }
                default: break
                }
            }
        }
    }
}
