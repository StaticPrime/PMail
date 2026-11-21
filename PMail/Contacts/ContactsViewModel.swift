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

    init(account: Account, service: any ContactsService) {
        self.account = account
        self.service = service
    }

    func start() { reload() }

    func reload() {
        isLoading = true
        Task {
            do {
                contacts = try await service.loadContacts()
                loaded = true
                isLoading = false
                error = nil
                needsSignIn = false
            } catch {
                loaded = true
                isLoading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    /// Saves a contact (a new one if it has no server ID yet) and returns it as saved.
    @discardableResult
    func save(_ contact: Contact, isNew: Bool) async -> Contact? {
        do {
            let saved = isNew ? try await service.create(contact) : try await service.update(contact)
            if let index = contacts.firstIndex(where: { $0.id == contact.id || $0.id == saved.id }) {
                contacts[index] = saved
            } else {
                contacts.append(saved)
            }
            app?.show(isNew ? "Contact created." : "Changes saved.")
            return saved
        } catch {
            app?.report(error, doing: isNew ? "Creating the contact" : "Saving the contact")
            return nil
        }
    }

    func delete(_ contact: Contact) {
        let snapshot = contacts
        contacts.removeAll { $0.id == contact.id }
        if openContactID == contact.id { openContactID = nil }
        let service = self.service
        Task {
            do {
                try await service.delete(contact)
                app?.show("Contact deleted.")
            } catch {
                contacts = snapshot
                app?.report(error, doing: "Deleting the contact")
            }
        }
    }

    func toggleStar(_ contact: Contact) {
        var changed = contact
        changed.isStarred.toggle()
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) { contacts[index] = changed }
        Task { await save(changed, isNew: false) }
    }
}
