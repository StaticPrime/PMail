import Foundation

/// Reading and writing vCard files (RFC 2426 and RFC 6350), for contact cards that arrive by mail and for sharing
/// contacts.
public enum VCard {
    /// The contacts in a vCard file. Group cards (as iCloud writes them) aren't listed; their names become labels
    /// on their members instead.
    public static func contacts(in data: Data) -> [Contact] {
        contacts(from: VCardCard.parse(data).map { card in (card, card.uid ?? UUID().uuidString, nil) })
    }

    public static func contacts(in text: String) -> [Contact] {
        contacts(in: Data(text.utf8))
    }

    /// A vCard 3.0 card for a contact, with its labels as categories.
    public static func document(for contact: Contact) -> String {
        let uid = contact.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        return VCardWriter.newCard(for: contact, uid: uid, categories: contact.labels)
    }

    /// One file holding a card for each contact.
    public static func document(for contacts: [Contact]) -> String {
        contacts.map(document(for:)).joined()
    }

    /// Contacts from cards, leaving out group cards and giving each member the names of the groups it's in as labels.
    static func contacts(from cards: [(card: VCardCard, id: String, etag: String?)]) -> [Contact] {
        var groupsByMember: [String: [String]] = [:]
        for entry in cards where entry.card.isGroup {
            let name = entry.card.groupName
            guard !name.isEmpty else { continue }
            for member in entry.card.memberUIDs { groupsByMember[member.lowercased(), default: []].append(name) }
        }
        return cards.filter { !$0.card.isGroup }.map { entry in
            var contact = entry.card.contact(id: entry.id, etag: entry.etag)
            if let uid = entry.card.uid {
                for name in groupsByMember[VCardCard.bareUID(uid).lowercased()] ?? [] where !contact.labels.contains(name) {
                    contact.labels.append(name)
                }
            }
            return contact
        }
    }
}
