import Foundation

/// A Google account's contacts, through Google's People API: the person's contacts, their "other contacts" (people
/// they've emailed), contact groups as labels, and the Starred group.
public actor GoogleContactsService: ContactsService {
    let client: WebClient
    /// User contact groups' names, by resource name ("contactGroups/1a2b3c" → "Family").
    private var groupNames: [String: String] = [:]
    private var groupsLoaded = false
    /// The contacts as last loaded or saved, so an update sends only the fields the person changed.
    private var loaded: [String: Contact] = [:]

    static let base = "https://people.googleapis.com/v1/"
    static let personFields = "names,nicknames,emailAddresses,phoneNumbers,organizations,addresses,birthdays,biographies,urls,"
        + "photos,memberships,metadata"
    /// The most pictures fetched in one load.
    static let photoLimit = 300
    static let myContacts = "contactGroups/myContacts"
    static let starred = "contactGroups/starred"

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(client: WebClient(tokens: tokens, transport: transport))
    }

    init(client: WebClient) {
        self.client = client
    }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    private static func pageQuery(_ token: String?) -> [(String, String)] {
        token.map { [("pageToken", $0)] } ?? []
    }

    // MARK: Loading

    public func loadContacts() async throws -> [Contact] {
        try await loadGroups()
        let people = try await client.pages { token in
            try Self.url("people/me/connections",
                         [("personFields", Self.personFields), ("pageSize", "1000")] + Self.pageQuery(token))
        }.flatMap { $0["connections"].array }
        var contacts: [Contact] = []
        var photoJobs: [(index: Int, url: URL)] = []
        for person in people {
            guard let contact = Self.contact(from: person, kind: .contact, groups: groupNames) else { continue }
            if photoJobs.count < Self.photoLimit, let url = Self.photoURL(person) { photoJobs.append((contacts.count, url)) }
            contacts.append(contact)
        }
        // Other contacts need a permission of their own; without it they're simply left out.
        let others = (try? await client.pages { token in
            try Self.url("otherContacts",
                         [("readMask", "names,emailAddresses,phoneNumbers"), ("pageSize", "1000")] + Self.pageQuery(token))
        }) ?? []
        contacts += others.flatMap { $0["otherContacts"].array }.compactMap { Self.contact(from: $0, kind: .other, groups: [:]) }

        let client = self.client
        let photos = try await WebClient.concurrentMap(photoJobs) { job -> (Int, Data?) in
            let data = try? await client.download(job.url)
            return (job.index, data.flatMap { $0.isEmpty ? nil : $0 })
        }
        for (index, data) in photos where contacts.indices.contains(index) { contacts[index].photoData = data }
        loaded = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return contacts
    }

    private func loadGroups() async throws {
        let groups = try await client.pages { token in
            try Self.url("contactGroups", [("pageSize", "1000")] + Self.pageQuery(token))
        }.flatMap { $0["contactGroups"].array }
        var names: [String: String] = [:]
        for group in groups where group["groupType"].string == "USER_CONTACT_GROUP" {
            guard let resource = group["resourceName"].nonEmpty else { continue }
            names[resource] = group["formattedName"].nonEmpty ?? group["name"].nonEmpty ?? resource
        }
        groupNames = names
        groupsLoaded = true
    }

    /// The person's own picture (not the generated letter), if they have one.
    static func photoURL(_ person: JSONValue) -> URL? {
        let photos = person["photos"].array.filter { $0["default"].bool != true && $0["url"].nonEmpty != nil }
        let photo = photos.first { $0["metadata"]["primary"].bool == true } ?? photos.first
        return WebURL.webLink(photo?["url"].string)
    }

    /// The entry the person marked primary, else the first.
    static func primary(_ values: JSONValue) -> JSONValue {
        values.array.first { $0["metadata"]["primary"].bool == true } ?? values[0]
    }

    /// A contact from a People API person.
    static func contact(from person: JSONValue, kind: ContactKind, groups: [String: String]) -> Contact? {
        guard let id = person["resourceName"].nonEmpty else { return nil }
        let name = primary(person["names"])
        let organization = primary(person["organizations"])
        var givenName = name["givenName"].string ?? ""
        let middleName = name["middleName"].string ?? ""
        let familyName = name["familyName"].string ?? ""
        if givenName.isEmpty, middleName.isEmpty, familyName.isEmpty, let displayName = name["displayName"].nonEmpty {
            givenName = displayName  // Only a whole name was given.
        }
        let memberships = person["memberships"].array.compactMap { membership -> String? in
            let group = membership["contactGroupMembership"]
            return group["contactGroupResourceName"].nonEmpty ?? group["contactGroupId"].nonEmpty.map { "contactGroups/\($0)" }
        }
        let labels = memberships.compactMap { groups[$0] }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Contact(id: id, kind: kind, prefix: name["honorificPrefix"].string ?? "", givenName: givenName,
                       middleName: middleName, familyName: familyName, suffix: name["honorificSuffix"].string ?? "",
                       nickname: primary(person["nicknames"])["value"].string ?? "", company: organization["name"].string ?? "",
                       jobTitle: organization["title"].string ?? "", department: organization["department"].string ?? "",
                       emails: person["emailAddresses"].array.compactMap(labeled),
                       phones: person["phoneNumbers"].array.compactMap(labeled),
                       addresses: person["addresses"].array.compactMap(address(from:)),
                       urls: person["urls"].array.compactMap(labeled),
                       birthday: birthday(from: primary(person["birthdays"])["date"]),
                       notes: primary(person["biographies"])["value"].string ?? "",
                       labels: labels,
                       isStarred: memberships.contains(starred), etag: person["etag"].nonEmpty)
    }

    static func labeled(_ value: JSONValue) -> LabeledValue? {
        guard let text = value["value"].nonEmpty else { return nil }
        return LabeledValue(label: value["type"].string ?? "", value: text)
    }

    static func address(from value: JSONValue) -> PostalAddress? {
        var street = [value["streetAddress"].nonEmpty, value["extendedAddress"].nonEmpty].compactMap { $0 }
            .joined(separator: "\n")
        let city = value["city"].string ?? "", region = value["region"].string ?? ""
        let postalCode = value["postalCode"].string ?? "", country = value["country"].string ?? ""
        if street.isEmpty, city.isEmpty, region.isEmpty, postalCode.isEmpty, country.isEmpty {
            street = value["formattedValue"].string ?? ""
        }
        let address = PostalAddress(label: value["type"].string ?? "", street: street, city: city, region: region,
                                    postalCode: postalCode, country: country)
        return address.isEmpty ? nil : address
    }

    static func birthday(from date: JSONValue) -> DateComponents? {
        guard let month = date["month"].int, let day = date["day"].int, (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        let year = date["year"].int.flatMap { $0 > 0 ? $0 : nil }
        return DateComponents(year: year, month: month, day: day)
    }

    // MARK: Changes

    public func create(_ contact: Contact) async throws -> Contact {
        let groups = try await groupResources(for: contact.labels)
        let (fields, _) = Self.fields(for: contact, original: nil, groups: groups)
        let url = try Self.url("people:createContact", [("personFields", Self.personFields)])
        let saved = try await client.post(url, .object(fields))
        guard let id = saved["resourceName"].nonEmpty else { throw PMailError.protocolError("the new contact had no ID") }
        guard contact.isStarred else { return finish(saved, from: contact) }
        return finish(try await setStarred(true, id: id), from: contact)
    }

    public func update(_ contact: Contact) async throws -> Contact {
        guard contact.kind == .contact else {
            throw PMailError.notSupported("Other contacts can’t be changed. Add the person to your contacts first.")
        }
        let original = loaded[contact.id]
        var groups: [String: String] = [:]
        if original?.labels != contact.labels { groups = try await groupResources(for: contact.labels) }
        var (fields, changed) = Self.fields(for: contact, original: original, groups: groups)
        var result: JSONValue?
        if !changed.isEmpty {
            fields["resourceName"] = .string(contact.id)
            if let etag = contact.etag ?? original?.etag {
                fields["etag"] = .string(etag)
            } else {
                fields["etag"] = try await client.get(Self.url(WebURL.path(contact.id), [("personFields", "metadata")]))["etag"]
            }
            let url = try Self.url("\(WebURL.path(contact.id)):updateContact",
                                   [("updatePersonFields", changed.joined(separator: ",")), ("personFields", Self.personFields)])
            do {
                result = try await client.patch(url, .object(fields))
            } catch let PMailError.http(status, message) where status == 400 && message.lowercased().contains("etag") {
                throw PMailError.conflict  // Changed somewhere else since it was loaded.
            }
        }
        // Changing memberships can take the star off, so the star is set again whenever they were sent.
        let starChanged = original.map { $0.isStarred != contact.isStarred } ?? contact.isStarred
        if starChanged || (changed.contains("memberships") && contact.isStarred) {
            result = try await setStarred(contact.isStarred, id: contact.id)
        }
        guard let result else { return contact }
        return finish(result, from: contact)
    }

    public func delete(_ contact: Contact) async throws {
        guard contact.kind == .contact else { throw PMailError.notSupported("Other contacts can’t be deleted.") }
        do {
            try await client.delete(Self.url("\(WebURL.path(contact.id)):deleteContact"))
        } catch PMailError.notFound {
            // Already gone.
        }
        loaded[contact.id] = nil
    }

    /// Stars or unstars a contact (by its membership in the Starred group) and returns the person as it is now.
    private func setStarred(_ starred: Bool, id: String) async throws -> JSONValue {
        let key = starred ? "resourceNamesToAdd" : "resourceNamesToRemove"
        _ = try await client.post(Self.url("\(Self.starred)/members:modify"), .object([key: JSONValue([id])]))
        return try await client.get(Self.url(WebURL.path(id), [("personFields", Self.personFields)]))
    }

    /// The saved contact from the server's answer, keeping the picture the person had.
    private func finish(_ saved: JSONValue, from contact: Contact) -> Contact {
        guard var result = Self.contact(from: saved, kind: .contact, groups: groupNames) else { return contact }
        result.photoData = contact.photoData
        loaded[result.id] = result
        return result
    }

    /// The contact group for each label, making groups for labels that don't have one yet.
    private func groupResources(for labels: [String]) async throws -> [String: String] {
        if !groupsLoaded && !labels.isEmpty { try await loadGroups() }
        var resources = Dictionary(groupNames.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for label in labels where resources[label] == nil {
            let group = try await client.post(Self.url("contactGroups"), ["contactGroup": ["name": .string(label)]])
            if let resource = group["resourceName"].nonEmpty {
                groupNames[resource] = group["formattedName"].nonEmpty ?? label
                resources[label] = resource
            }
        }
        return resources
    }

    /// The People API fields for a contact and the names of those that changed since `original` (all of them for a
    /// new contact, or one that wasn't loaded here). Labels become group memberships when `groups` maps them.
    static func fields(for contact: Contact, original: Contact?,
                       groups: [String: String]) -> (fields: [String: JSONValue], changed: [String]) {
        var fields: [String: JSONValue] = [:]
        var changed: [String] = []
        func set(_ name: String, _ value: [JSONValue], if differs: Bool) {
            guard differs else { return }
            if original == nil && value.isEmpty { return }  // A new contact only sends what it has.
            fields[name] = .array(value)
            changed.append(name)
        }
        func differs<Value: Equatable>(_ paths: KeyPath<Contact, Value>...) -> Bool {
            guard let original else { return true }
            return paths.contains { original[keyPath: $0] != contact[keyPath: $0] }
        }
        func labeledJSON(_ values: [LabeledValue]) -> [JSONValue] {
            values.filter { !$0.value.isEmpty }.map { value in
                compact(["value": value.value, "type": value.label])
            }
        }

        let name = compact(["honorificPrefix": contact.prefix, "givenName": contact.givenName, "middleName": contact.middleName,
                            "familyName": contact.familyName, "honorificSuffix": contact.suffix])
        set("names", name == [:] ? [] : [name], if: differs(\.prefix, \.givenName, \.middleName, \.familyName, \.suffix))
        set("nicknames", contact.nickname.isEmpty ? [] : [["value": .string(contact.nickname)]], if: differs(\.nickname))
        set("emailAddresses", labeledJSON(contact.emails), if: differs(\.emails))
        set("phoneNumbers", labeledJSON(contact.phones), if: differs(\.phones))
        let organization = compact(["name": contact.company, "title": contact.jobTitle, "department": contact.department])
        set("organizations", organization == [:] ? [] : [organization], if: differs(\.company, \.jobTitle, \.department))
        let addresses = contact.addresses.filter { !$0.isEmpty }.map { address in
            compact(["type": address.label, "streetAddress": address.street, "city": address.city, "region": address.region,
                     "postalCode": address.postalCode, "country": address.country])
        }
        set("addresses", addresses, if: differs(\.addresses))
        var birthdays: [JSONValue] = []
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            var date: [String: JSONValue] = ["month": JSONValue(month), "day": JSONValue(day)]
            if let year = birthday.year, year > 0 { date["year"] = JSONValue(year) }
            birthdays = [["date": .object(date)]]
        }
        set("birthdays", birthdays, if: differs(\.birthday))
        set("biographies", contact.notes.isEmpty ? [] : [["value": .string(contact.notes), "contentType": "TEXT_PLAIN"]],
            if: differs(\.notes))
        set("urls", labeledJSON(contact.urls), if: differs(\.urls))
        if differs(\.labels), original != nil || !contact.labels.isEmpty, !groups.isEmpty || contact.labels.isEmpty {
            let resources = [myContacts] + contact.labels.compactMap { groups[$0] }
            set("memberships", resources.map { ["contactGroupMembership": ["contactGroupResourceName": .string($0)]] }, if: true)
        }
        return (fields, changed)
    }

    /// An object with the empty strings left out.
    private static func compact(_ values: [String: String]) -> JSONValue {
        .object(values.filter { !$0.value.isEmpty }.mapValues(JSONValue.string))
    }
}
