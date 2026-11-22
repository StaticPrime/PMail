import AppKit
import Observation
import PMailKit

/// One account's contacts as the window shows them: the list or one person's page, and saving changes.
@Observable
final class ContactsViewModel {
    enum Section: Hashable {
        case contacts
        case other
        case label(String)
    }

    @ObservationIgnored let service: any ContactsService
    @ObservationIgnored let cache: AccountCache?
    @ObservationIgnored weak var app: AppModel?
    var account: Account
    private(set) var contacts: [Contact] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var needsSignIn = false
    var section: Section = .contacts
    /// The person whose page is showing; nil for the list.
    var openContactID: String?

    /// Changes made while the contacts server couldn't be reached, waiting to be sent (kept in the account's folder).
    @ObservationIgnored let pending: PendingChanges<ContactChange>?
    /// What's waiting, as the window shows it.
    private(set) var waiting: [ContactChange] = []
    /// Counts changes made here (and the server's answers to them), so a load that may have missed one is done again.
    @ObservationIgnored private var changeCount = 0

    init(account: Account, service: any ContactsService, cache: AccountCache? = nil, changes: PendingChanges<ContactChange>? = nil) {
        self.account = account
        self.service = service
        self.cache = cache
        pending = changes
    }

    /// Whether what's showing is a copy, because the server couldn't be reached.
    private(set) var isOffline = false

    func start() { reload() }

    func reload() { load(quietly: false) }

    /// Gets the latest contacts without showing it's busy (beside each mail check), keeping what's showing when the
    /// server can't be reached.
    func refreshQuietly() {
        guard loaded else { return }
        load(quietly: true)
    }

    private func load(quietly: Bool) {
        if !quietly { isLoading = true }
        let changes = changeCount
        Task {
            waiting = await pending?.all() ?? []
            if contacts.isEmpty, let cached = await cache?.contacts() {
                contacts = ContactChange.applying(waiting, to: cached)
                loaded = true
            }
            do {
                let fresh = try await service.loadContacts()
                // Something was saved or deleted while this loaded, which it may not include: load again.
                guard changes == changeCount else { return load(quietly: quietly) }
                // What's waiting shows on top of what the server has.
                contacts = ContactChange.applying(waiting, to: fresh)
                loaded = true
                isLoading = false
                isOffline = false
                error = nil
                needsSignIn = false
                await cache?.save(contacts: fresh)
            } catch {
                loaded = true
                isLoading = false
                if MailViewModel.isConnectionProblem(error), !contacts.isEmpty || quietly {
                    isOffline = true
                } else if !quietly {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    var savedContacts: [Contact] { contacts.filter { $0.kind == .contact } }
    var otherContacts: [Contact] { contacts.filter { $0.kind == .other } }

    /// Every group name any contact is in.
    var labels: [String] {
        Array(Set(savedContacts.flatMap(\.labels))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func count(in section: Section) -> Int { contacts(in: section, matching: "").count }

    /// The contacts a section lists, matching the search words, starred first, then by family name.
    func contacts(in section: Section, matching search: String) -> [Contact] {
        let base: [Contact] = switch section {
        case .contacts: savedContacts
        case .other: otherContacts
        case let .label(name): savedContacts.filter { $0.labels.contains(name) }
        }
        let words = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ").map(String.init)
        let matching = words.isEmpty ? base : base.filter { contact in
            let text = ([contact.displayName, contact.company, contact.jobTitle, contact.notes] + contact.emails.map(\.value)
                + contact.phones.map(\.value)).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { text.contains($0) }
        }
        return matching.sorted { first, second in
            let a = first.displayName.isEmpty ? "\u{10FFFF}" : first.displayName
            let b = second.displayName.isEmpty ? "\u{10FFFF}" : second.displayName
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func contact(_ id: String?) -> Contact? { id.flatMap { id in contacts.first { $0.id == id } } }

    /// Addresses to offer while typing in To, Cc or Bcc: saved contacts first, then other contacts.
    func suggestions(for text: String, excluding: [MailAddress] = []) -> [MailAddress] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let taken = Set(excluding.map { $0.email.lowercased() })
        var results: [MailAddress] = []
        var seen = Set<String>()
        for contact in savedContacts + otherContacts {
            for address in contact.mailAddresses where !taken.contains(address.email.lowercased()) {
                let haystack = (address.name ?? "").lowercased() + " " + address.email.lowercased()
                guard haystack.contains(query), seen.insert(address.email.lowercased()).inserted else { continue }
                results.append(address)
            }
            if results.count >= 8 { break }
        }
        return results
    }

    /// Saves a contact (a new one if it has no server ID yet) and returns it as saved. When the server can't be
    /// reached, it's kept on this Mac (and returned as kept) and sent once it can.
    @discardableResult
    func save(_ contact: Contact, isNew: Bool) async -> Contact? {
        var made = contact
        if isNew { made.id = LocalID.make() }
        let later: ContactChange = isNew ? .create(made) : .update(contact)
        if waits(contact.id), await keep(later) {
            app?.show("Saved on this Mac. It’ll go to your contacts when you’re back online.")
            return made
        }
        changeCount += 1
        do {
            let saved = isNew ? try await service.create(contact) : try await service.update(contact)
            changeCount += 1
            if let index = contacts.firstIndex(where: { $0.id == contact.id || $0.id == saved.id }) {
                contacts[index] = saved
            } else {
                contacts.append(saved)
            }
            app?.show(isNew ? "Contact created." : "Changes saved.")
            return saved
        } catch {
            if PMailError.isConnectionProblem(error), await keep(later) {
                app?.show("Saved on this Mac. It’ll go to your contacts when you’re back online.")
                return made
            }
            app?.report(error, doing: isNew ? "Creating the contact" : "Saving the contact")
            return nil
        }
    }

    func delete(_ contact: Contact) {
        let snapshot = contacts
        contacts.removeAll { $0.id == contact.id }
        changeCount += 1
        if openContactID == contact.id { openContactID = nil }
        let service = self.service
        let waitingText = "Deleted on this Mac. It’ll be deleted from your contacts when you’re back online."
        Task {
            if waits(contact.id), await keep(.delete(contact)) {
                app?.show(LocalID.isLocal(contact.id) ? "Contact deleted." : waitingText)
                return
            }
            do {
                try await service.delete(contact)
                changeCount += 1
                app?.show("Contact deleted.")
            } catch {
                if PMailError.isConnectionProblem(error), await keep(.delete(contact)) {
                    app?.show(waitingText)
                    return
                }
                contacts = snapshot
                app?.report(error, doing: "Deleting the contact")
            }
        }
    }

    // MARK: Changes made offline

    /// Whether a change waits instead of going now: the Mac is offline, the contact was made here and hasn't reached
    /// the server, or it has changes waiting already (so they go in order).
    private func waits(_ id: String) -> Bool {
        app?.sync?.isOnline == false || LocalID.isLocal(id) || waiting.contains { $0.contact.id == id }
    }

    /// Keeps a change on this Mac until the server can be reached, and shows it. False when there's nowhere to keep it.
    private func keep(_ change: ContactChange) async -> Bool {
        guard let pending else { return false }
        await pending.add(change, merging: ContactChange.adding)
        waiting = await pending.all()
        contacts = ContactChange.applying([change], to: contacts)
        changeCount += 1
        return true
    }

    /// Whether a contact has changes waiting to be sent.
    func isWaiting(_ contact: Contact) -> Bool { waiting.contains { $0.contact.id == contact.id } }

    /// Sends the changes made offline, oldest first, shows them as the server saved them, and says what it turned down.
    func sendWaitingChanges() async {
        guard let pending, !(await pending.all()).isEmpty else { return }
        let result = await pending.send(using: service)
        waiting = await pending.all()
        guard result.sent > 0 || !result.refused.isEmpty else { return }
        changeCount += 1
        for (id, saved) in result.saved {
            if let index = contacts.firstIndex(where: { $0.id == id }) { contacts[index] = saved }
            if openContactID == id { openContactID = saved.id }
        }
        contacts.removeAll { result.deleted.contains($0.id) }
        for refusal in result.refused {
            app?.show("“\(refusal.title.isEmpty ? "A contact" : refusal.title)” couldn’t be saved to your contacts: \(refusal.reason)")
        }
    }

    func toggleStar(_ contact: Contact) {
        var changed = contact
        changed.isStarred.toggle()
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) { contacts[index] = changed }
        Task { await save(changed, isNew: false) }
    }
}
