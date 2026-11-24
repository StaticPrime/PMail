import Foundation

/// What a Google account's mail over IMAP keeps between calls.
struct GmailIMAPState {
    /// Each label's unread and total messages, counted now and then: an account can have many labels.
    var labelCounts: [String: (unread: Int, total: Int?)] = [:]
    var labelCountsLoaded: Date?
    /// Each label's color by its name, from Google's mail API now and then.
    var colors: [String: String] = [:]
    var colorsLoaded: Date?
    /// When the mailboxes were last listed, with the store (which counts without them).
    var mailboxesListed: Date?
}

/// A Google account's mail over IMAP, the Gmail way (`isGmail`):
///
/// - Labels rather than folders. A message can have several, and each shows on the server as a mailbox. Archiving
///   takes the inbox's label off and leaves the message in All Mail; "Move to" a label puts the label on and takes the
///   message out of where it was (the inbox, the label showing, the trash or spam).
/// - Gmail's special folders under "[Gmail]" (Starred, Important, Sent, Drafts, Spam, Trash, All Mail), found by their
///   special-use marks and shown with Gmail's names.
/// - The inbox's category tabs and Gmail's search terms, through Gmail's own search (X-GM-RAW).
/// - Conversations by Gmail's conversation IDs (X-GM-THRID), opened whole from All Mail, replies sent included.
/// - Sent mail is filed by Gmail's outgoing server itself.
///
/// Label colors, making and changing labels, and the signature go through Google's mail API (`gmailAPI`), each a
/// request or two at almost no cost to its quota; everything else is IMAP.
extension IMAPMailService {
    /// Gmail's category tabs, with the IDs its categories have everywhere in PMail.
    static let gmailTabs = GoogleMailService.tabs
    /// Seconds before label counts are counted again.
    static let gmailLabelCountsFreshFor: TimeInterval = 60
    /// Seconds before label colors are asked for again.
    static let gmailColorsFreshFor: TimeInterval = 300

    /// The Gmail search that finds a category tab's mail.
    static func gmailCategorySearch(_ tabID: String) -> String? {
        switch tabID {
        case "CATEGORY_PERSONAL": "category:primary"
        case "CATEGORY_SOCIAL": "category:social"
        case "CATEGORY_PROMOTIONS": "category:promotions"
        case "CATEGORY_UPDATES": "category:updates"
        case "CATEGORY_FORUMS": "category:forums"
        default: nil
        }
    }

    // MARK: Folders

    /// Gmail's special folders by their special-use marks only: a label someone named "Sent" or "Archive" stays a label.
    static func gmailRoles(_ mailboxes: [IMAPMailbox]) -> [String: FolderRole] {
        let marks: [(String, FolderRole)] = [("\\Sent", .sent), ("\\Drafts", .drafts), ("\\Trash", .trash), ("\\Junk", .spam),
                                             ("\\All", .allMail), ("\\Flagged", .starred), ("\\Important", .important)]
        var roles: [String: FolderRole] = [:]
        for mailbox in mailboxes {
            if mailbox.isInbox {
                roles[mailbox.name] = .inbox
            } else if let role = marks.first(where: { mailbox.hasAttribute($0.0) })?.1, !roles.values.contains(role) {
                roles[mailbox.name] = role
            }
        }
        return roles
    }

    /// The name Gmail gives a special folder.
    static func gmailFolderName(_ role: FolderRole) -> String? {
        switch role {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .important: "Important"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .spam: "Spam"
        case .trash: "Trash"
        case .allMail: "All Mail"
        default: nil
        }
    }

    /// Gmail's special folders, in the sidebar's order, then the account's labels, nested by "/", with their colors.
    /// The "[Gmail]" folder that holds the special ones isn't shown. Unread counts come for the inbox, Spam and the
    /// labels (the labels' every minute at most), and Drafts counts its drafts.
    func gmailFolders() async throws -> [MailFolder] {
        let colors = await gmailLabelColors()
        let store = await usableGmailStore()
        return try await withClient { client in
            // With the store, the mailboxes are listed again once a minute at most (the counts come from the store).
            var boxes: [IMAPMailbox]
            if store != nil, let known = self.mailboxes, let listed = self.gmail.mailboxesListed,
               Date().timeIntervalSince(listed) < Self.gmailLabelCountsFreshFor {
                boxes = known
            } else {
                boxes = try await client.listMailboxes()
                self.gmail.mailboxesListed = Date()
            }
            if !boxes.contains(where: \.isInbox) { boxes.insert(IMAPMailbox(name: "INBOX"), at: 0) }
            self.mailboxes = boxes
            let roles = Self.gmailRoles(boxes)
            let labelNames = Set(boxes.filter { $0.isSelectable && roles[$0.name] == nil }.map(\.name))
            let now = Date()
            let recount = self.gmail.labelCountsLoaded.map { now.timeIntervalSince($0) >= Self.gmailLabelCountsFreshFor } ?? true
            var special: [MailFolder] = []
            var labels: [MailFolder] = []
            for box in boxes where box.isSelectable {
                if let store {
                    let role = roles[box.name]
                    let counts = await self.gmailStoreCounts(for: box.name, role: role, store: store)
                    if let role {
                        special.append(MailFolder(id: box.name, name: Self.gmailFolderName(role) ?? box.displayName, role: role,
                                                  unreadCount: counts.unread, totalCount: counts.total))
                    } else {
                        labels.append(MailFolder(id: box.name, name: box.displayName, kind: .label, unreadCount: counts.unread,
                                                 parentID: box.parentName.flatMap { labelNames.contains($0) ? $0 : nil },
                                                 colorHex: colors[box.name]))
                    }
                    continue
                }
                if let role = roles[box.name] {
                    var unread = 0
                    var total: Int?
                    if [.inbox, .spam, .drafts].contains(role), let status = try await Self.count(box.name, client: client) {
                        unread = role == .drafts ? status.messages ?? 0 : status.unseen ?? 0
                        total = status.messages
                    }
                    special.append(MailFolder(id: box.name, name: Self.gmailFolderName(role) ?? box.displayName, role: role,
                                              unreadCount: unread, totalCount: total))
                } else {
                    if recount, let status = try await Self.count(box.name, client: client) {
                        self.gmail.labelCounts[box.name] = (status.unseen ?? 0, status.messages)
                    }
                    let counts = self.gmail.labelCounts[box.name]
                    labels.append(MailFolder(id: box.name, name: box.displayName, kind: .label, unreadCount: counts?.unread ?? 0,
                                             totalCount: counts?.total, parentID: box.parentName.flatMap { labelNames.contains($0) ? $0 : nil },
                                             colorHex: colors[box.name]))
                }
            }
            if recount { self.gmail.labelCountsLoaded = now }
            special.sort { ($0.role?.sortOrder ?? 99) < ($1.role?.sortOrder ?? 99) }
            labels.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            return special + labels
        }
    }

    /// A mailbox's counts, or nil when the server won't count it.
    static func count(_ mailbox: String, client: IMAPClient) async throws -> IMAPMailboxStatus? {
        do {
            return try await client.status(mailbox, items: ["MESSAGES", "UNSEEN"])
        } catch PMailError.server {
            return nil
        }
    }

    /// Each label's color by its name, from Google's mail API every few minutes (none without it). The folders never
    /// wait long for them: the first time, three seconds at most; after that, the colors there are show while newer
    /// ones are asked for.
    func gmailLabelColors() async -> [String: String] {
        guard gmailAPI != nil else { return [:] }
        if let loaded = gmail.colorsLoaded {
            if Date().timeIntervalSince(loaded) >= Self.gmailColorsFreshFor { Task { await self.loadLabelColors() } }
            return gmail.colors
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadLabelColors() }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
        return gmail.colors
    }

    /// Asks Google's mail API for the labels' colors.
    func loadLabelColors() async {
        // Noted first, so a slow or failed answer isn't asked for again straight away.
        gmail.colorsLoaded = Date()
        guard let labels = try? await gmailAPI?.userLabels() else { return }
        gmail.colors = labels.compactMapValues(\.colorHex)
    }

    // MARK: Listing

    /// What narrows a list the Gmail way: Gmail's own search for something typed (over All Mail, where a search lists),
    /// or a category tab's search in the inbox.
    static func gmailSearchKeys(for request: ListRequest, in mailbox: String) -> [IMAPSearchKey] {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty { return [.gmailSearch(query)] }
        if mailbox == "INBOX", let tab = request.tabID, let search = gmailCategorySearch(tab) { return [.gmailSearch(search)] }
        return []
    }

    /// Whether a list's search gives the same messages however their flags change: none (the whole mailbox), or a
    /// category tab's. Such a list's first page can use its last search too.
    static func searchIgnoresFlags(_ keys: [IMAPSearchKey]) -> Bool {
        keys.allSatisfy { key in
            if case let .gmailSearch(query) = key { return query.hasPrefix("category:") && !query.contains(" ") }
            return false
        }
    }

    /// A message's labels as PMail names them: the account's by name (as their mailboxes are), the inbox as "INBOX".
    /// Gmail's others show another way (starred, important, sent, drafts) or not at all.
    static func gmailLabelIDs(_ labels: [String]) -> [String] {
        labels.compactMap { label in
            if label.caseInsensitiveCompare("\\Inbox") == .orderedSame { return "INBOX" }
            return label.hasPrefix("\\") ? nil : label
        }
    }

    // MARK: Reading

    /// A whole conversation: the messages the list showed, from where it showed them, and the rest of the conversation
    /// from All Mail by Gmail's conversation ID (replies sent from the account, archived messages), leaving out the
    /// trash and spam unless the list showed them. Nil for a conversation ID that isn't Gmail's (it opens the usual
    /// way).
    func gmailConversation(id: String, hint: Conversation?) async throws -> [MailMessage]? {
        guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return try await withClient { client -> [MailMessage]? in
            var messages: [MailMessage] = []
            var shown = Set<String>()
            let known = (hint?.messages ?? []).compactMap { summary in IMAPMessageID(rawValue: summary.id).map { (summary, $0) } }
            for (mailbox, group) in Self.grouped(known, by: { $0.1.mailbox }) {
                let selected = try await self.ensureSelected(mailbox, writable: false, client: client)
                var byUID: [UInt32: MessageSummary] = [:]
                for (summary, messageID) in group where messageID.uidValidity == (selected.uidValidity ?? 0) { byUID[messageID.uid] = summary }
                for response in try await client.fetchMessages(byUID.keys.sorted()) {
                    guard let uid = response.uid, var summary = byUID[uid], let raw = response.section("") else { continue }
                    Self.applyFlags(response.flags, to: &summary)
                    if let header = summary.messageIDHeader { shown.insert(Self.messageIDKey(header)) }
                    messages.append(MIMEParser.parse(raw).mailMessage(summary: summary, rawSource: raw))
                }
            }
            if let allMail = Self.gmailRoles(try await self.knownMailboxes(client: client)).first(where: { $0.value == .allMail })?.key {
                let selected = try await self.ensureSelected(allMail, writable: false, client: client)
                let uids = selected.exists == 0 ? [] : try await client.uidSearch([.gmailThread(id)])
                if !uids.isEmpty {
                    for response in try await client.fetchSummaries(uids.sorted(), withMessage: true) {
                        guard let uid = response.uid, let raw = response.section("") else { continue }
                        let parsed = MIMEParser.parse(raw)
                        let place = IMAPMessageID(mailbox: allMail, uidValidity: selected.uidValidity ?? 0, uid: uid)
                        let summary = Self.summary(from: response, id: place, snippet: parsed.snippet)
                        // Already shown from where the list had it.
                        if let header = summary.messageIDHeader, !shown.insert(Self.messageIDKey(header)).inserted { continue }
                        messages.append(parsed.mailMessage(summary: summary, rawSource: raw))
                    }
                }
            }
            return messages.isEmpty ? nil : messages.sorted { $0.summary.date < $1.summary.date }
        }
    }

    // MARK: Actions

    /// Actions the Gmail way, mailbox by mailbox (a message's labels and flags are the same wherever it's listed).
    func gmailPerform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        // A message moved here whose new UID hasn't come yet waits for the next sync.
        let ids = messages.compactMap { IMAPMessageID(rawValue: $0.id) }.filter { $0.uid > 0 }
        guard !ids.isEmpty else { return }
        try await withClient { client in
            let roles = Self.gmailRoles(try await self.knownMailboxes(client: client))
            var skipped = false
            for (mailbox, group) in Self.grouped(ids, by: { $0.mailbox }) {
                let selected = try await self.ensureSelected(mailbox, writable: true, client: client)
                // UIDs from before the mailbox's UIDVALIDITY changed would point at other messages.
                let uids = group.filter { $0.uidValidity == (selected.uidValidity ?? 0) }.map(\.uid)
                if uids.count < group.count { skipped = true }
                guard !uids.isEmpty else { continue }
                try await Self.gmailApply(action, to: uids, in: mailbox, roles: roles, client: client)
            }
            if skipped { throw PMailError.notFound }
        }
    }

    /// One action on messages in the selected mailbox.
    static func gmailApply(_ action: MailAction, to uids: [UInt32], in mailbox: String, roles: [String: FolderRole],
                           client: IMAPClient) async throws {
        let role = roles[mailbox]
        let inTrashOrSpam = role == .trash || role == .spam
        func place(_ wanted: FolderRole) -> String? { roles.first { $0.value == wanted }?.key }
        switch action {
        case .markRead: try await client.uidStore(uids, adding: true, flags: ["\\Seen"])
        case .markUnread: try await client.uidStore(uids, adding: false, flags: ["\\Seen"])
        case .star: try await client.uidStore(uids, adding: true, flags: ["\\Flagged"])
        case .unstar: try await client.uidStore(uids, adding: false, flags: ["\\Flagged"])
        case .markImportant: try await client.uidStoreGmailLabels(uids, adding: true, labels: ["\\Important"])
        case .markNotImportant: try await client.uidStoreGmailLabels(uids, adding: false, labels: ["\\Important"])
        case .archive:
            // Out of the inbox, still in All Mail with its other labels. From the trash or spam, back to All Mail.
            if inTrashOrSpam, let allMail = place(.allMail) {
                try await client.uidMove(uids, to: allMail)
            } else {
                try await client.uidStoreGmailLabels(uids, adding: false, labels: ["\\Inbox"])
            }
        case .moveToInbox, .notSpam:
            if inTrashOrSpam {
                try await client.uidMove(uids, to: "INBOX")
            } else {
                try await client.uidStoreGmailLabels(uids, adding: true, labels: ["\\Inbox"])
            }
        case .markSpam:
            guard role != .spam, let spam = place(.spam) else { return }
            try await client.uidMove(uids, to: spam)
        case .trash:
            // Deleting what's already in the trash deletes it for good.
            if role == .trash {
                try await client.deleteMessages(uids)
            } else if let trash = place(.trash) {
                try await client.uidMove(uids, to: trash)
            }
        case .deleteForever:
            // For good from the trash or spam; from anywhere else, to the trash first.
            if inTrashOrSpam {
                try await client.deleteMessages(uids)
            } else if let trash = place(.trash) {
                try await client.uidMove(uids, to: trash)
            }
        case let .addLabel(label):
            try await client.uidStoreGmailLabels(uids, adding: true, labels: [label])
        case let .removeLabel(label):
            try await client.uidStoreGmailLabels(uids, adding: false, labels: [label])
        case let .move(folderID):
            switch roles[folderID] {
            case .inbox?: try await gmailApply(.moveToInbox, to: uids, in: mailbox, roles: roles, client: client)
            case .trash?: try await gmailApply(.trash, to: uids, in: mailbox, roles: roles, client: client)
            case .spam?: try await gmailApply(.markSpam, to: uids, in: mailbox, roles: roles, client: client)
            case .allMail?: try await gmailApply(.archive, to: uids, in: mailbox, roles: roles, client: client)
            case .starred?: try await gmailApply(.star, to: uids, in: mailbox, roles: roles, client: client)
            case .important?: try await gmailApply(.markImportant, to: uids, in: mailbox, roles: roles, client: client)
            case .sent?, .drafts?:
                throw PMailError.notSupported("Mail can’t be moved there.")
            default:
                guard folderID != mailbox else { return }
                // Gmail's Move to: the label goes on and the message leaves where it was (the inbox, the label showing,
                // the trash or spam). A message listed from All Mail (the mail kept on this Mac lists them all from
                // there) gets the label and leaves the inbox. Starred, Important and Sent aren't places a message
                // leaves, so there the label just goes on.
                if role == .allMail {
                    try await client.uidStoreGmailLabels(uids, adding: true, labels: [folderID])
                    try await client.uidStoreGmailLabels(uids, adding: false, labels: ["\\Inbox"])
                } else if role == nil || role == .inbox || inTrashOrSpam {
                    try await client.uidMove(uids, to: folderID)
                } else {
                    try await client.uidCopy(uids, to: folderID)
                }
            }
        }
    }

    // MARK: Tabs

    /// Unread messages in the inbox under each category tab, by Gmail's search.
    func gmailUnreadCounts(inTabs tabs: [InboxTab]) async throws -> [String: Int] {
        let wanted = tabs.compactMap { tab in Self.gmailCategorySearch(tab.id).map { (tab.id, $0) } }
        guard !wanted.isEmpty else { return [:] }
        if let store = await usableGmailStore() {
            var counts: [String: Int] = [:]
            for (id, _) in wanted { counts[id] = await store.unreadMessages(inTab: id) }
            return counts
        }
        return try await withClient { client in
            let selected = try await self.ensureSelected("INBOX", writable: false, client: client)
            var counts: [String: Int] = [:]
            for (id, search) in wanted {
                counts[id] = selected.exists == 0 ? 0 : Set(try await client.uidSearch([.unseen, .gmailSearch(search)])).count
            }
            return counts
        }
    }

    // MARK: Making, changing and deleting labels

    /// Makes a label with Google's mail API, in the color asked for. Its mailbox, named like it, comes with it.
    func gmailCreateLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        guard let gmailAPI else { throw PMailError.notSupported("This account can’t make labels.") }
        let made = try await gmailAPI.createLabel(named: name, colorHex: colorHex)
        forgetLabels()
        let full = made.name
        let parent = full.range(of: "/", options: .backwards).map { String(full[..<$0.lowerBound]) }
        let last = parent.map { String(full.dropFirst($0.count + 1)) } ?? full
        return MailFolder(id: full, name: last, kind: .label, parentID: parent, colorHex: made.colorHex)
    }

    /// Renames or recolors a label with Google's mail API (its mailbox is renamed with it, and so are the labels
    /// nested inside it).
    func gmailUpdateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        guard let gmailAPI else { throw PMailError.notSupported("This account can’t change labels.") }
        guard let found = try await gmailAPI.userLabels()[label.id] else { throw PMailError.notFound }
        let updated = try await gmailAPI.updateLabel(MailFolder(id: found.id, name: label.name, kind: .label, parentID: label.parentID),
                                                     name: name, colorHex: colorHex)
        forgetLabels()
        let path = label.id.hasSuffix(label.name) ? String(label.id.dropLast(label.name.count)) : ""
        return MailFolder(id: path + updated.name, name: updated.name, kind: .label, parentID: label.parentID,
                          colorHex: updated.colorHex ?? label.colorHex)
    }

    /// Deletes a label with Google's mail API; its messages keep everything else.
    func gmailDeleteLabel(_ label: MailFolder) async throws {
        guard let gmailAPI else { throw PMailError.notSupported("This account can’t delete labels.") }
        guard let found = try await gmailAPI.userLabels()[label.id] else { return }
        try await gmailAPI.deleteLabel(MailFolder(id: found.id, name: label.name, kind: .label))
        forgetLabels()
    }

    /// The labels changed: the mailboxes, counts and colors are loaded again next time.
    private func forgetLabels() {
        mailboxes = nil
        gmail.labelCountsLoaded = nil
        gmail.colorsLoaded = nil
    }

    // MARK: Signature

    /// The signature of the account's own address, as Google keeps it.
    public func loadSignature() async throws -> String? {
        guard let gmailAPI else { throw PMailError.notSupported("This account keeps no signature on its server.") }
        return try await gmailAPI.loadSignature()
    }

    public func saveSignature(html: String) async throws {
        guard let gmailAPI else { throw PMailError.notSupported("This account keeps no signature on its server.") }
        try await gmailAPI.saveSignature(html: html)
    }
}
