import AppKit
import Observation
import PMailKit

/// One account's services, as the factory made them.
struct AccountServices {
    let mail: any MailService
    let calendar: any CalendarService
    let contacts: any ContactsService
}

/// Makes the services an account uses: the real ones for its kind, or (in debug runs) made-up ones.
protocol ServiceFactory {
    /// The account's services. `storage` is what the account keeps on the Mac; its label book and inbox sorter are
    /// shared with the services, so the window and the services see the same labels and categories.
    func services(for account: Account, secrets: any SecretStore, storage: AccountStorage?) -> AccountServices
}

extension ServiceFactory {
    /// Services for checking an account (signing in, the factory checks), with nothing of the window's to share.
    func services(for account: Account, secrets: any SecretStore) -> AccountServices {
        services(for: account, secrets: secrets, storage: nil)
    }
}

/// What an account keeps on the Mac: a copy of what it last loaded, messages waiting to be sent, and snoozes.
struct AccountStorage {
    let cache: AccountCache
    let queue: MailQueue
    let snoozes: SnoozeBook
    let blockedSenders: BlockedSenders
    /// Its labels' names and colors (and, for a server that can't keep them, which messages have them).
    let labelBook: LabelBook
    /// Sorts its inbox into categories when its server doesn't, remembering the senders put in one by hand.
    let sorter: InboxSorter
    /// Copies of the pictures, style sheets and fonts its mail loads from the internet.
    let remoteContent: RemoteContentCache

    init(folder: URL) {
        cache = AccountCache(folder: folder.appendingPathComponent("Cache", isDirectory: true))
        queue = MailQueue(folder: folder.appendingPathComponent("Outbox", isDirectory: true))
        snoozes = SnoozeBook(file: folder.appendingPathComponent("Snoozes.json"))
        blockedSenders = BlockedSenders(file: folder.appendingPathComponent("BlockedSenders.json"))
        labelBook = LabelBook(file: folder.appendingPathComponent("Labels.json"))
        sorter = InboxSorter(file: folder.appendingPathComponent("Categories.json"))
        remoteContent = RemoteContentCache(folder: folder.appendingPathComponent("Remote Content", isDirectory: true))
    }
}

/// An account with its services and what each part of the window shows for it. Switching accounts swaps the whole
/// session, so mail, calendar and contacts always belong to the same account.
@Observable
final class AccountSession: Identifiable {
    private(set) var account: Account
    @ObservationIgnored let services: AccountServices
    @ObservationIgnored let storage: AccountStorage
    let mail: MailViewModel
    let calendar: CalendarViewModel
    let contacts: ContactsViewModel
    @ObservationIgnored private var activated = false

    var id: UUID { account.id }

    init(account: Account, services: AccountServices, storage: AccountStorage, app: AppModel?, defaults: UserDefaults = .standard) {
        self.account = account
        self.services = services
        self.storage = storage
        mail = MailViewModel(account: account, service: services.mail, storage: storage, defaults: defaults)
        calendar = CalendarViewModel(account: account, service: services.calendar, cache: storage.cache, defaults: defaults,
                                     today: { AppClock.now() })
        contacts = ContactsViewModel(account: account, service: services.contacts, cache: storage.cache)
        attach(app)
    }

    func attach(_ app: AppModel?) {
        mail.app = app
        calendar.app = app
        contacts.app = app
        mail.session = self
    }

    /// Starts loading the account's mail, calendars and contacts the first time it's shown.
    func activate() {
        guard !activated else { return }
        activated = true
        mail.start()
        calendar.start()
        contacts.start()
    }

    var isActivated: Bool { activated }

    /// Bumped when the signature changed on the server, so an open signature editor shows the new one.
    var signatureRevision = 0

    func update(_ account: Account) {
        self.account = account
        mail.account = account
        calendar.account = account
        contacts.account = account
    }

    /// Whether the account's own servers need it signed in again.
    var needsSignIn: Bool { mail.needsSignIn || calendar.needsSignIn || contacts.needsSignIn }
}

/// Every account, which one is showing, and adding and removing them. The list is saved in Application Support and
/// the secrets in the keychain.
@Observable
final class AccountsController {
    private(set) var accounts: [Account] = []
    private(set) var sessions: [UUID: AccountSession] = [:]
    private(set) var currentID: UUID?
    @ObservationIgnored let store: AccountStore?
    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let factory: any ServiceFactory
    @ObservationIgnored let defaults: UserDefaults
    /// Where each account keeps what it keeps on the Mac, in a folder named after its ID.
    @ObservationIgnored let storageFolder: URL
    @ObservationIgnored weak var app: AppModel?

    private static let currentKey = "CurrentAccount"

    init(store: AccountStore?, secrets: any SecretStore, factory: any ServiceFactory, storageFolder: URL, defaults: UserDefaults = .standard) {
        self.store = store
        self.secrets = secrets
        self.factory = factory
        self.storageFolder = storageFolder
        self.defaults = defaults
    }

    func storageFolder(for id: UUID) -> URL {
        storageFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var current: AccountSession? { currentID.flatMap { sessions[$0] } }

    /// Reads the saved accounts and makes their sessions, without loading anything yet.
    func load(_ initial: [Account]? = nil) {
        accounts = initial ?? store?.load() ?? []
        for account in accounts where sessions[account.id] == nil { sessions[account.id] = makeSession(account) }
        let saved = defaults.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        currentID = accounts.first { $0.id == saved }?.id ?? accounts.first?.id
    }

    private func makeSession(_ account: Account) -> AccountSession {
        let storage = AccountStorage(folder: storageFolder(for: account.id))
        return AccountSession(account: account, services: factory.services(for: account, secrets: secrets, storage: storage),
                              storage: storage, app: app, defaults: defaults)
    }

    func session(for id: UUID) -> AccountSession? { sessions[id] }

    /// Takes the signature an account keeps on its server when it differs from the one here (it changed there).
    func refreshSignature(of id: UUID) async {
        guard let session = sessions[id], session.services.mail.capabilities.syncsSignature else { return }
        // A failed request changes nothing; a server with no signature clears it here too.
        let loaded: String?
        do { loaded = try await session.services.mail.loadSignature() } catch { return }
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        let html = loaded ?? ""
        guard (account.signatureHTML ?? "") != html else { return }
        account.signatureHTML = html.isEmpty ? nil : html
        account.signature = html.isEmpty ? "" : RichTextHTML.plainText(from: RichTextHTML.attributedString(fromHTML: html))
        update(account, sendingSignature: false)
        session.signatureRevision += 1
    }

    func switchTo(_ id: UUID) {
        guard sessions[id] != nil else { return }
        currentID = id
        defaults.set(id.uuidString, forKey: Self.currentKey)
    }

    /// Adds an account (or, for one already added, signs it in again), saves its secret and switches to it.
    @discardableResult
    func add(_ account: Account, secret: StoredSecret) throws -> AccountSession {
        if let index = accounts.firstIndex(where: { $0.email.lowercased() == account.email.lowercased() && $0.kind == account.kind }) {
            // Signing in again: keep the account's place, color and settings, and start its services over.
            var existing = accounts[index]
            try secrets.setSecret(secret, for: existing.id)
            existing.name = account.name.isEmpty ? existing.name : account.name
            existing.incoming = account.incoming ?? existing.incoming
            existing.outgoing = account.outgoing ?? existing.outgoing
            existing.pictureURL = account.pictureURL ?? existing.pictureURL
            accounts[index] = existing
            sessions[existing.id] = makeSession(existing)
            save()
            switchTo(existing.id)
            return sessions[existing.id]!
        }
        try secrets.setSecret(secret, for: account.id)
        var account = account
        account.colorIndex = nextColorIndex()
        accounts.append(account)
        let session = makeSession(account)
        sessions[account.id] = session
        save()
        switchTo(account.id)
        return session
    }

    /// Saves changes to an account's name, signature or servers.
    /// Saves an account's settings; a changed signature goes to its server too, where it keeps one.
    func update(_ account: Account, sendingSignature: Bool = true) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let signatureChanged = accounts[index].signatureHTML != account.signatureHTML || accounts[index].signature != account.signature
        let serversChanged = accounts[index].incoming != account.incoming || accounts[index].outgoing != account.outgoing
            || accounts[index].calendarServer != account.calendarServer || accounts[index].contactsServer != account.contactsServer
        accounts[index] = account
        if serversChanged {
            sessions[account.id] = makeSession(account)
        } else {
            sessions[account.id]?.update(account)
        }
        save()
        if sendingSignature, signatureChanged, let mail = sessions[account.id]?.services.mail, mail.capabilities.syncsSignature {
            let html = account.signatureHTML ?? ""
            Task { [weak self] in
                do {
                    try await mail.saveSignature(html: html)
                } catch {
                    self?.app?.report(error, doing: "Saving the signature to \(account.email)")
                }
            }
        }
    }

    /// Removes an account from PMail and its secret from the keychain. Nothing is deleted on the server.
    func remove(_ id: UUID) {
        if let session = sessions[id] {
            session.mail.flushPendingActions()
            let mail = session.services.mail
            Task { await mail.close() }
        }
        try? secrets.setSecret(nil, for: id)
        // The copies and waiting messages go; calendars, contacts and mail kept only on this Mac stay in its folder.
        let folder = storageFolder(for: id)
        for name in ["Cache", "Outbox", "Snoozes.json", "BlockedSenders.json", "Labels.json", "Categories.json", "Remote Content"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        accounts.removeAll { $0.id == id }
        sessions[id] = nil
        save()
        if currentID == id {
            currentID = accounts.first?.id
            if let currentID { defaults.set(currentID.uuidString, forKey: Self.currentKey) } else { defaults.removeObject(forKey: Self.currentKey) }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func nextColorIndex() -> Int {
        let used = Set(accounts.map(\.colorIndex))
        return (0..<Theme.avatarColors.count).first { !used.contains($0) } ?? accounts.count
    }

    private func save() {
        do {
            try store?.save(accounts)
        } catch {
            app?.report(error, doing: "Saving your accounts")
        }
    }
}

/// Services that only explain why they can't work: for an account whose secret is missing, or a provider this copy
/// of PMail can't sign in to.
actor UnavailableService: MailService, CalendarService, ContactsService {
    let reason: PMailError

    init(_ reason: PMailError) {
        self.reason = reason
    }

    nonisolated var capabilities: MailCapabilities { MailCapabilities() }
    nonisolated var inboxTabs: [InboxTab] { [] }
    func loadFolders() async throws -> [MailFolder] { throw reason }
    func listConversations(_ request: ListRequest) async throws -> ConversationPage { throw reason }
    func loadConversation(id: String, hint: Conversation?) async throws -> [MailMessage] { throw reason }
    func loadMessage(_ summary: MessageSummary) async throws -> MailMessage { throw reason }
    func loadAttachment(_ attachment: Attachment, in message: MessageSummary) async throws -> Data { throw reason }
    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws { throw reason }
    func send(_ message: OutgoingMessage) async throws { throw reason }
    func saveDraft(_ message: OutgoingMessage, replacing draft: MessageSummary?) async throws -> MessageSummary? { throw reason }
    func deleteDraft(_ draft: MessageSummary) async throws { throw reason }
    func close() async {}
    func loadCalendars() async throws -> [CalendarInfo] { throw reason }
    func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] { throw reason }
    func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent { throw reason }
    func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent { throw reason }
    func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws { throw reason }
    func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws { throw reason }
    func loadContacts() async throws -> [Contact] { throw reason }
    func create(_ contact: Contact) async throws -> Contact { throw reason }
    func update(_ contact: Contact) async throws -> Contact { throw reason }
    func delete(_ contact: Contact) async throws { throw reason }
}
