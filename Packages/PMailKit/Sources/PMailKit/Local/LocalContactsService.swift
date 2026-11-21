import Foundation

/// The contacts of an account with no contacts server, kept in a folder as a vCard file per contact. Labels are
/// saved as each card's categories, and each contact's ID is its file's name.
public actor LocalContactsService: ContactsService {
    private let store: LocalFileStore

    public init(folder: URL) {
        store = LocalFileStore(folder: folder, fileExtension: "vcf")
    }

    public func loadContacts() async throws -> [Contact] {
        var contacts: [Contact] = []
        for name in try store.names() {
            guard let (data, etag) = try? store.read(name), let card = VCardCard.parse(data).first, !card.isGroup else { continue }
            contacts.append(card.contact(id: name, etag: etag))
        }
        return contacts.sorted { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }
    }

    public func create(_ contact: Contact) async throws -> Contact {
        let uid = contact.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let name = LocalFileStore.fileName(for: uid, fileExtension: "vcf")
        guard !store.exists(name) else { throw PMailError.conflict }
        let etag = try store.write(Data(VCardWriter.newCard(for: contact, uid: uid, categories: contact.labels).utf8), to: name)
        var saved = contact
        saved.id = name
        saved.kind = .contact
        saved.uid = uid
        saved.etag = etag
        return saved
    }

    public func update(_ contact: Contact) async throws -> Contact {
        let (data, etag) = try store.read(contact.id)
        if let expected = contact.etag, expected != etag { throw PMailError.conflict }
        let card = VCardCard.parse(data).first ?? VCardCard(lines: [])
        let uid = card.uid ?? contact.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let text = VCardWriter.card(updating: card, with: contact, uid: uid, categories: contact.labels)
        var saved = contact
        saved.etag = try store.write(Data(text.utf8), to: contact.id)
        saved.uid = uid
        return saved
    }

    public func delete(_ contact: Contact) async throws {
        let (_, etag) = try store.read(contact.id)
        if let expected = contact.etag, expected != etag { throw PMailError.conflict }
        try store.delete(contact.id)
    }
}
