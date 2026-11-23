import Foundation

/// An account's contacts on a CardDAV server (RFC 6352), such as iCloud's. Contact IDs are the cards' URL paths.
///
/// Groups (the cards iCloud keeps for them) aren't listed as contacts: each member gets the group's name in its
/// `labels`, and adding or removing such a label changes the group's member list. Other labels are saved as the
/// card's categories.
public actor CardDAVContactsService: ContactsService {
    private struct StoredCard: Sendable {
        var etag: String?
        var card: VCardCard
    }

    /// How many cards one addressbook-multiget asks for.
    static let batchSize = 100

    private let serverURL: URL
    private let client: WebDAVClient
    private var homeURL: URL?
    private var books: [URL] = []
    /// Every card last read, contacts and groups, by URL path. Unchanged cards aren't downloaded again.
    private var cards: [String: StoredCard] = [:]
    /// Whether the cards have been read at least once, so the groups are known.
    private var hasLoaded = false

    /// The transport must hand redirects back (WebDAV follows them itself, keeping the sign-in).
    public init(serverURL: URL, credential: Credential, transport: any HTTPTransport = URLSessionTransport(followsRedirects: false)) {
        self.serverURL = serverURL
        client = WebDAVClient(credential: credential, transport: transport)
    }

    public func loadContacts() async throws -> [Contact] {
        let books = try await addressBooks(refresh: true)
        var seen = Set<String>()
        for book in books {
            let listing = try await client.propfind(book, depth: 1, properties: [.resourceType, .getETag])
            let bookPath = book.path(percentEncoded: true)
            var stale: [String] = []
            for response in listing.responses where response.isAvailable {
                guard let url = listing.url(for: response.href) else { continue }
                let path = url.path(percentEncoded: true)
                if path == bookPath || response.property(.resourceType)?.child(DAVNamespace.dav, "collection") != nil { continue }
                seen.insert(path)
                let etag = response.property(.getETag)?.trimmedText
                if let cached = cards[path], cached.etag != nil, cached.etag == etag { continue }
                stale.append(response.href)
            }
            var index = 0
            while index < stale.count {
                let batch = Array(stale[index..<min(index + Self.batchSize, stale.count)])
                index += Self.batchSize
                let answer = try await client.report(book, depth: 1, body: DAVRequestBody.addressbookMultiget(batch))
                for response in answer.responses where response.isAvailable {
                    guard let url = answer.url(for: response.href), let text = response.property(.addressData)?.text,
                          let card = VCardCard.parse(Data(text.utf8)).first else { continue }
                    cards[url.path(percentEncoded: true)] = StoredCard(etag: response.property(.getETag)?.trimmedText, card: card)
                }
            }
        }
        cards = cards.filter { seen.contains($0.key) }
        hasLoaded = true
        return VCard.contacts(from: cards.map { (card: $0.value.card, id: $0.key, etag: $0.value.etag) })
            .sorted { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }
    }

    public func create(_ contact: Contact) async throws -> Contact {
        try await loadGroupsIfNeeded()
        guard let book = try await addressBooks().first else {
            throw PMailError.notSupported("This account has no address book on the server.")
        }
        let uid = contact.uid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let url = book.appendingPathComponent(DAVResourceName.name(for: uid, fileExtension: "vcf"))
        let text = VCardWriter.newCard(for: contact, uid: uid, categories: categories(for: contact.labels))
        let etag = try await save(text, to: url, ifMatch: nil, isNew: true)
        try await updateGroups(member: uid, labels: contact.labels)
        var saved = contact
        saved.id = url.path(percentEncoded: true)
        saved.kind = .contact
        saved.uid = uid
        saved.etag = etag
        return saved
    }

    public func update(_ contact: Contact) async throws -> Contact {
        try await loadGroupsIfNeeded()
        let url = try await resourceURL(of: contact)
        let path = url.path(percentEncoded: true)
        let current: StoredCard
        if let cached = cards[path], cached.etag != nil, cached.etag == contact.etag {
            current = cached
        } else {
            current = try await download(url)
        }
        let uid = current.card.uid ?? contact.uid
        let text = VCardWriter.card(updating: current.card, with: contact, uid: uid ?? UUID().uuidString,
                                    categories: categories(for: contact.labels))
        let etag = try await save(text, to: url, ifMatch: contact.etag ?? current.etag)
        if let uid { try await updateGroups(member: uid, labels: contact.labels) }
        var saved = contact
        saved.uid = uid ?? cards[path]?.card.uid
        saved.etag = etag
        return saved
    }

    public func delete(_ contact: Contact) async throws {
        try await loadGroupsIfNeeded()
        let url = try await resourceURL(of: contact)
        let path = url.path(percentEncoded: true)
        let uid = cards[path]?.card.uid ?? contact.uid
        try await client.delete(url, ifMatch: contact.etag)
        cards[path] = nil
        // Leaving its groups is tidying up; the contact is gone either way.
        if let uid { try? await updateGroups(member: uid, labels: []) }
    }

    /// Reads the cards once before the first change, so labels that are groups on the server are known.
    private func loadGroupsIfNeeded() async throws {
        if !hasLoaded { _ = try await loadContacts() }
    }

    // MARK: Address books

    private func addressBooks(refresh: Bool = false) async throws -> [URL] {
        if !books.isEmpty && !refresh { return books }
        let home: URL
        if let homeURL {
            home = homeURL
        } else {
            home = try await DAVDiscovery.home(client: client, serverURL: serverURL, wellKnown: "carddav", homeSet: .addressbookHomeSet)
            homeURL = home
        }
        let answer = try await client.propfind(home, depth: 1, properties: [.resourceType, .displayName])
        books = answer.responses.filter { response in
            response.isAvailable && response.property(.resourceType)?.child(DAVNamespace.cardDAV, "addressbook") != nil
        }.compactMap { answer.url(for: $0.href) }
        return books
    }

    private func resourceURL(of contact: Contact) async throws -> URL {
        let base = try await addressBooks().first ?? homeURL ?? serverURL
        guard !contact.id.isEmpty, let url = URL(string: contact.id, relativeTo: base)?.absoluteURL else { throw PMailError.notFound }
        return url
    }

    // MARK: Cards

    private func download(_ url: URL) async throws -> StoredCard {
        let (data, etag) = try await client.get(url)
        guard let card = VCardCard.parse(data).first else { throw PMailError.protocolError("the contact on the server couldn’t be read") }
        let stored = StoredCard(etag: etag, card: card)
        cards[url.path(percentEncoded: true)] = stored
        return stored
    }

    /// Saves a card and returns its new ETag (asking for it when the server doesn't send it back).
    private func save(_ text: String, to url: URL, ifMatch: String?, isNew: Bool = false) async throws -> String? {
        var etag = try await client.put(url, data: Data(text.utf8), contentType: "text/vcard; charset=utf-8", ifMatch: ifMatch,
                                        ifNoneMatch: isNew)
        if etag == nil { etag = (try? await client.etag(of: url)) ?? nil }
        if let card = VCardCard.parse(Data(text.utf8)).first { cards[url.path(percentEncoded: true)] = StoredCard(etag: etag, card: card) }
        return etag
    }

    // MARK: Groups

    private var groupNames: Set<String> {
        Set(cards.values.filter(\.card.isGroup).map(\.card.groupName))
    }

    /// The labels that go in a card's CATEGORIES: the ones that aren't groups on the server.
    private func categories(for labels: [String]) -> [String] {
        let groups = groupNames
        return labels.filter { !groups.contains($0) }
    }

    /// Puts a contact into the groups its labels name, and takes it out of the others.
    private func updateGroups(member uid: String, labels: [String]) async throws {
        let wanted = Set(labels)
        let bare = VCardCard.bareUID(uid)
        for (path, stored) in cards where stored.card.isGroup {
            let isMember = stored.card.memberUIDs.contains { $0.caseInsensitiveCompare(bare) == .orderedSame }
            guard isMember != wanted.contains(stored.card.groupName) else { continue }
            try await changeGroup(at: path, member: uid, adding: !isMember)
        }
    }

    /// Adds a member to a group card or removes one, trying again with the newest version if the group changed on
    /// the server in the meantime.
    private func changeGroup(at path: String, member uid: String, adding: Bool) async throws {
        guard let url = URL(string: path, relativeTo: books.first ?? serverURL)?.absoluteURL else { return }
        var stored = cards[path]
        for attempt in 0..<2 {
            if attempt > 0 { stored = try await download(url) }
            guard let group = stored else { return }
            let text = adding ? VCardWriter.addingMember(uid, to: group.card) : VCardWriter.removingMember(uid, from: group.card)
            guard let text else { return }
            do {
                _ = try await save(text, to: url, ifMatch: group.etag)
                return
            } catch PMailError.conflict where attempt == 0 {
                continue
            }
        }
    }
}
