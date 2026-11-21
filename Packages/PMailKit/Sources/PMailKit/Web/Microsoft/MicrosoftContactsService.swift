import Foundation

/// A Microsoft account's contacts (the default contacts folder), through Microsoft Graph. Categories are the labels.
public actor MicrosoftContactsService: ContactsService {
    let client: WebClient

    static let base = Graph.root + "me/"
    /// The year Graph is given for a birthday without one, and that reads back as "no year".
    static let noYear = 1604

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(client: WebClient(tokens: tokens, transport: transport))
    }

    init(client: WebClient) {
        self.client = client
    }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    public func loadContacts() async throws -> [Contact] {
        try await client.graphItems(Self.url("contacts", [("$top", "500")])).compactMap(Self.contact(from:))
    }

    public func create(_ contact: Contact) async throws -> Contact {
        let saved = try await client.post(Self.url("contacts"), .object(Self.body(for: contact, isNew: true)))
        return try Self.saved(saved, from: contact)
    }

    public func update(_ contact: Contact) async throws -> Contact {
        let url = try Self.url("contacts/\(WebURL.segment(contact.id))")
        let saved = try await client.patch(url, .object(Self.body(for: contact, isNew: false)))
        return try Self.saved(saved, from: contact)
    }

    public func delete(_ contact: Contact) async throws {
        do {
            try await client.delete(Self.url("contacts/\(WebURL.segment(contact.id))"))
        } catch PMailError.notFound {
            // Already gone.
        }
    }

    /// The saved contact from the server's answer, keeping the picture the person had.
    private static func saved(_ json: JSONValue, from contact: Contact) throws -> Contact {
        guard var result = Self.contact(from: json) else {
            throw PMailError.protocolError("the saved contact couldn’t be read")
        }
        result.photoData = contact.photoData
        return result
    }

    // MARK: Mapping

    /// A contact from Graph.
    static func contact(from json: JSONValue) -> Contact? {
        guard let id = json["id"].nonEmpty else { return nil }
        var givenName = json["givenName"].string ?? ""
        let middleName = json["middleName"].string ?? "", familyName = json["surname"].string ?? ""
        let company = json["companyName"].string ?? ""
        if givenName.isEmpty, middleName.isEmpty, familyName.isEmpty, let displayName = json["displayName"].nonEmpty,
           displayName != company {
            givenName = displayName  // Only a whole name was given.
        }
        var phones: [LabeledValue] = []
        if let mobile = json["mobilePhone"].nonEmpty { phones.append(LabeledValue(label: "mobile", value: mobile)) }
        phones += json["businessPhones"].strings.filter { !$0.isEmpty }.map { LabeledValue(label: "work", value: $0) }
        phones += json["homePhones"].strings.filter { !$0.isEmpty }.map { LabeledValue(label: "home", value: $0) }
        let slots = [("homeAddress", "home"), ("businessAddress", "work"), ("otherAddress", "other")]
        let addresses = slots.compactMap { key, label in address(from: json[key], label: label) }
        return Contact(id: id, kind: .contact, prefix: json["title"].string ?? "", givenName: givenName, middleName: middleName,
                       familyName: familyName, suffix: json["generation"].string ?? "", nickname: json["nickName"].string ?? "",
                       company: company, jobTitle: json["jobTitle"].string ?? "", department: json["department"].string ?? "",
                       emails: json["emailAddresses"].array.compactMap { $0["address"].nonEmpty.map { LabeledValue(value: $0) } },
                       phones: phones, addresses: addresses,
                       urls: json["businessHomePage"].nonEmpty.map { [LabeledValue(label: "work", value: $0)] } ?? [],
                       birthday: json["birthday"].string.flatMap(birthday(from:)), notes: json["personalNotes"].string ?? "",
                       labels: json["categories"].strings, etag: json["changeKey"].nonEmpty ?? json["@odata.etag"].nonEmpty)
    }

    static func address(from json: JSONValue, label: String) -> PostalAddress? {
        let address = PostalAddress(label: label, street: json["street"].string ?? "", city: json["city"].string ?? "",
                                    region: json["state"].string ?? "", postalCode: json["postalCode"].string ?? "",
                                    country: json["countryOrRegion"].string ?? "")
        return address.isEmpty ? nil : address
    }

    /// A birthday from Graph's date-time ("1990-04-12T11:59:00Z"), read by its date alone.
    static func birthday(from text: String) -> DateComponents? {
        guard var parts = WebDate.dayComponents(text) else { return nil }
        if let year = parts.year, year <= noYear { parts.year = nil }
        return parts
    }

    /// Graph's fields for a contact. A new contact sends only what it has; a change sends every field, so cleared ones
    /// are cleared on the server too. Phones go to mobile, home and business numbers by their labels.
    static func body(for contact: Contact, isNew: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        func set(_ key: String, _ value: String) {
            if !isNew || !value.isEmpty { body[key] = .string(value) }
        }
        set("givenName", contact.givenName)
        set("middleName", contact.middleName)
        set("surname", contact.familyName)
        set("nickName", contact.nickname)
        set("title", contact.prefix)
        set("generation", contact.suffix)
        set("companyName", contact.company)
        set("department", contact.department)
        set("jobTitle", contact.jobTitle)
        set("personalNotes", contact.notes)
        set("businessHomePage", contact.urls.first?.value ?? "")

        var mobile: String?
        var home: [String] = []
        var business: [String] = []
        for phone in contact.phones where !phone.value.isEmpty {
            switch phone.label.lowercased() {
            case "mobile", "cell", "iphone":
                if mobile == nil { mobile = phone.value } else { business.append(phone.value) }
            case "home":
                home.append(phone.value)
            default:
                business.append(phone.value)
            }
        }
        set("mobilePhone", mobile ?? "")
        if !isNew || !home.isEmpty { body["homePhones"] = JSONValue(home) }
        if !isNew || !business.isEmpty { body["businessPhones"] = JSONValue(business) }

        let emails = contact.emails.filter { !$0.value.isEmpty }.prefix(3)
        if !isNew || !emails.isEmpty {
            let name = contact.displayName
            body["emailAddresses"] = .array(emails.map { email in
                var value: [String: JSONValue] = ["address": .string(email.value)]
                if !name.isEmpty, name != email.value { value["name"] = .string(name) }
                return .object(value)
            })
        }
        if !isNew || !contact.labels.isEmpty { body["categories"] = JSONValue(contact.labels) }

        // One address each for home, work and other; extra ones fill whichever of those is free.
        var slots: [String: PostalAddress] = [:]
        var extras: [PostalAddress] = []
        for address in contact.addresses where !address.isEmpty {
            let key = switch address.label.lowercased() {
            case "home": "homeAddress"
            case "work", "business": "businessAddress"
            default: "otherAddress"
            }
            if slots[key] == nil { slots[key] = address } else { extras.append(address) }
        }
        for key in ["homeAddress", "businessAddress", "otherAddress"] where slots[key] == nil && !extras.isEmpty {
            slots[key] = extras.removeFirst()
        }
        for key in ["homeAddress", "businessAddress", "otherAddress"] {
            let address = slots[key] ?? PostalAddress()
            if isNew && address.isEmpty { continue }
            body[key] = ["street": .string(address.street), "city": .string(address.city), "state": .string(address.region),
                         "postalCode": .string(address.postalCode), "countryOrRegion": .string(address.country)]
        }

        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            let year = birthday.year.flatMap { $0 > 0 ? $0 : nil } ?? noYear
            body["birthday"] = .string(String(format: "%04ld-%02ld-%02ldT11:59:00Z", year, month, day))
        } else if !isNew {
            body["birthday"] = .null
        }
        return body
    }
}
