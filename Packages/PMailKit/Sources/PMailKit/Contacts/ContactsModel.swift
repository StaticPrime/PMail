import Foundation

/// A value with a label: an email address, a phone number or a web address ("work", "home", "mobile").
public struct LabeledValue: Codable, Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String = "", value: String) {
        self.label = label
        self.value = value
    }
}

/// A postal address.
public struct PostalAddress: Codable, Sendable, Hashable {
    public var label: String
    public var street: String
    public var city: String
    public var region: String
    public var postalCode: String
    public var country: String

    public init(label: String = "", street: String = "", city: String = "", region: String = "", postalCode: String = "",
                country: String = "") {
        self.label = label
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
    }

    public var isEmpty: Bool { [street, city, region, postalCode, country].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The address on lines, as it goes on an envelope.
    public var formatted: String {
        let cityLine = [city, [region, postalCode].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: ", ")
        return [street, cityLine, country].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Whether a contact is one the person saved, or someone they've emailed whom the provider remembers.
public enum ContactKind: String, Codable, Sendable, Hashable {
    case contact
    /// "Other contacts": people the provider saw in the person's mail, offered when addressing messages.
    case other
}

/// A person (or company) in the account's contacts.
public struct Contact: Codable, Sendable, Identifiable, Hashable {
    /// The provider's ID for it (a resource name, a contact ID, a CardDAV resource's URL path).
    public var id: String
    public var kind: ContactKind
    public var prefix: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var suffix: String
    public var nickname: String
    public var company: String
    public var jobTitle: String
    public var department: String
    public var emails: [LabeledValue]
    public var phones: [LabeledValue]
    public var addresses: [PostalAddress]
    public var urls: [LabeledValue]
    public var birthday: DateComponents?
    public var notes: String
    /// The contact's picture, as image data (JPEG or PNG).
    public var photoData: Data?
    /// Names of the groups (labels) the contact is in.
    public var labels: [String]
    public var isStarred: Bool
    /// For checking nobody else changed it first.
    public var etag: String?
    /// vCard UID, for CardDAV.
    public var uid: String?

    public init(id: String = UUID().uuidString, kind: ContactKind = .contact, prefix: String = "", givenName: String = "",
                middleName: String = "", familyName: String = "", suffix: String = "", nickname: String = "", company: String = "",
                jobTitle: String = "", department: String = "", emails: [LabeledValue] = [], phones: [LabeledValue] = [],
                addresses: [PostalAddress] = [], urls: [LabeledValue] = [], birthday: DateComponents? = nil, notes: String = "",
                photoData: Data? = nil, labels: [String] = [], isStarred: Bool = false, etag: String? = nil, uid: String? = nil) {
        self.id = id
        self.kind = kind
        self.prefix = prefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.suffix = suffix
        self.nickname = nickname
        self.company = company
        self.jobTitle = jobTitle
        self.department = department
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.urls = urls
        self.birthday = birthday
        self.notes = notes
        self.photoData = photoData
        self.labels = labels
        self.isStarred = isStarred
        self.etag = etag
        self.uid = uid
    }

    /// "Jamie Rivera", or the company, or the first email address.
    public var displayName: String {
        let name = [prefix, givenName, middleName, familyName, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        if !nickname.isEmpty { return nickname }
        if !company.isEmpty { return company }
        return emails.first?.value ?? phones.first?.value ?? ""
    }

    /// The name sorted by: family name first, so "Rivera" sorts under R.
    public var sortKey: String {
        let key = familyName.isEmpty ? displayName : "\(familyName) \(givenName)"
        return key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public var initials: String { Account.initials(name: displayName, email: emails.first?.value ?? "") }

    /// "Designer, Puggle & Co." for the list's job title and company column.
    public var jobAndCompany: String { [jobTitle, company].filter { !$0.isEmpty }.joined(separator: ", ") }

    public var primaryEmail: String? { emails.first?.value }

    /// The addresses to offer when someone types in To, Cc or Bcc.
    public var mailAddresses: [MailAddress] {
        emails.map { MailAddress(name: displayName == $0.value ? nil : displayName, email: $0.value) }
    }

    /// Whether the contact has nothing in it worth saving.
    public var isEmpty: Bool {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty && phones.isEmpty && addresses.allSatisfy(\.isEmpty) && notes.isEmpty
    }
}

/// One account's contacts, however they're reached.
///
/// Implementations are thread-safe and throw `PMailError`.
public protocol ContactsService: AnyObject, Sendable {
    /// Every contact, and (where the provider has them) "other contacts".
    func loadContacts() async throws -> [Contact]
    /// Adds a contact and returns it as saved, with its new ID.
    func create(_ contact: Contact) async throws -> Contact
    func update(_ contact: Contact) async throws -> Contact
    func delete(_ contact: Contact) async throws

    /// What the provider can tell about someone from their email address, for filling in a new contact: someone in
    /// the account's organization directory, or someone it has written to before. Nil when it knows nothing (or has
    /// no way to look people up).
    func lookUp(email: String) async throws -> Contact?
}

extension ContactsService {
    public func lookUp(email: String) async throws -> Contact? { nil }
}

/// A name written in one piece ("Sam Rivera", "Rivera, Sam") as a given name and a family name.
public enum PersonName {
    public static func split(_ name: String) -> (given: String, family: String) {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        // What's in brackets ("Sam Rivera (Work)") isn't part of the name.
        text = text.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("@") else { return ("", "") }
        if let comma = text.firstIndex(of: ",") {
            return (text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces), text[..<comma].trimmingCharacters(in: .whitespaces))
        }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count > 1, let family = parts.last else { return (text, "") }
        return (parts.dropLast().joined(separator: " "), family)
    }
}
