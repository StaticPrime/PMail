import Foundation

/// The categories an inbox is sorted into on the Mac, for accounts whose server doesn't sort mail itself (iCloud,
/// other IMAP servers, POP). Each is a tab above the inbox.
public enum InboxCategory: String, Codable, Sendable, CaseIterable, Hashable {
    /// Mail from people, and anything that fits nowhere else.
    case primary
    /// Receipts, orders, shipping, bookings, bills and statements.
    case transactions
    /// Notifications, alerts, newsletters and mailing lists.
    case updates
    /// Offers, deals and marketing.
    case promotions
    /// Social networks and the like.
    case social

    public var name: String {
        switch self {
        case .primary: "Primary"
        case .transactions: "Transactions"
        case .updates: "Updates"
        case .promotions: "Promotions"
        case .social: "Social"
        }
    }

    public var symbol: String {
        switch self {
        case .primary: "tray"
        case .transactions: "cart"
        case .updates: "info.circle"
        case .promotions: "tag"
        case .social: "person.2"
        }
    }

    /// The tab's ID in `ListRequest.tabID`.
    public var tabID: String { "category:\(rawValue)" }

    public var tab: InboxTab { InboxTab(id: tabID, name: name, symbol: symbol) }

    /// Every category's tab, Primary first.
    public static var tabs: [InboxTab] { allCases.map(\.tab) }

    /// The category a tab ID names, or nil for one that isn't a category tab.
    public init?(tabID: String?) {
        guard let tabID, tabID.hasPrefix("category:"), let category = InboxCategory(rawValue: String(tabID.dropFirst(9))) else {
            return nil
        }
        self = category
    }
}

/// What a message's headers say about its sender, for sorting the inbox.
public struct SenderHints: Codable, Sendable, Hashable {
    /// It has a List-Unsubscribe header: newsletters and marketing.
    public var canUnsubscribe: Bool
    /// Its List-Id header (the list's identifier, between the angle brackets), for mailing lists.
    public var listID: String?
    /// Precedence: bulk, list or junk.
    public var isBulk: Bool
    /// Auto-Submitted (other than "no"): sent by a machine, not a person.
    public var isAutomatic: Bool
    /// Whether a mail server's spam filter marked it as junk in its headers (X-Spam-Flag, X-Spam-Status, X-Spam,
    /// X-MS-Exchange-Organization-SCL) without moving it; nil when no such header says either way.
    public var serverMarkedJunk: Bool?

    public init(canUnsubscribe: Bool = false, listID: String? = nil, isBulk: Bool = false, isAutomatic: Bool = false,
                serverMarkedJunk: Bool? = nil) {
        self.canUnsubscribe = canUnsubscribe
        self.listID = listID
        self.isBulk = isBulk
        self.isAutomatic = isAutomatic
        self.serverMarkedJunk = serverMarkedJunk
    }

    /// What a message's List-Unsubscribe, List-Id, Precedence and Auto-Submitted header fields say, and any spam filter's
    /// marks. `field` gives a field's value by its name in lowercase, or nil when the message doesn't have it.
    public init(field: (String) -> String?) {
        func value(_ name: String) -> String? {
            guard let value = field(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        // The first word of a value, in lowercase: "bulk" in "Bulk (newsletter)", "auto-replied" in "auto-replied; x=y".
        func keyword(_ name: String) -> String? {
            value(name).map { String($0.lowercased().prefix { !$0.isWhitespace && $0 != ";" && $0 != "(" }) }
        }
        self.init(canUnsubscribe: value("list-unsubscribe") != nil, listID: value("list-id").flatMap(Self.listIdentifier),
                  isBulk: keyword("precedence").map { ["bulk", "list", "junk"].contains($0) } ?? false,
                  isAutomatic: keyword("auto-submitted").map { !$0.isEmpty && $0 != "no" } ?? false,
                  serverMarkedJunk: Self.spamMark(keyword))
    }

    /// What spam filters' headers say: "X-Spam-Flag: YES", "X-Spam-Status: Yes, score=7.1", "X-Spam: Yes", or an
    /// Exchange spam confidence level of 5 or more (-1 means the sender is trusted).
    static func spamMark(_ keyword: (String) -> String?) -> Bool? {
        let saysYes = ["x-spam-flag", "x-spam-status", "x-spam"].compactMap(keyword).map { $0.hasPrefix("yes") || $0.hasPrefix("true") }
        let level = keyword("x-ms-exchange-organization-scl").flatMap { Int($0) }
        guard !saysYes.isEmpty || level != nil else { return nil }
        return saysYes.contains(true) || (level ?? 0) >= 5
    }

    /// The identifier in a List-Id ("dev.lists.example.org" in "Dev talk <dev.lists.example.org>"), or the whole
    /// value when it has no angle brackets.
    static func listIdentifier(_ value: String) -> String? {
        if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            let identifier = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !identifier.isEmpty { return identifier }
        }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t<>"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ParsedMessage {
    /// What the message's headers say about its sender, for sorting an inbox into categories.
    public var senderHints: SenderHints { SenderHints(field: { header($0) }) }
}

/// Sorts one account's inbox into categories: by the person's own choice for a sender ("always put mail from them in
/// Promotions"), otherwise by the rules (`InboxCategorizer`). The choices are kept in a JSON file; one that's missing
/// or can't be read counts as no choices. Every change is written straight away.
public actor InboxSorter {
    public let file: URL
    /// The choices, by address in lowercase, once read from the file.
    private var choices: [String: InboxCategory]?

    public init(file: URL) {
        self.file = file
    }

    /// The category a message belongs in: the one chosen for its sender, else the rules'.
    public func category(of message: MessageSummary) -> InboxCategory {
        if let email = message.from?.email, let chosen = loaded()[Self.key(for: email)] { return chosen }
        return InboxCategorizer.category(for: message)
    }

    /// The categories of several messages, in the same order.
    public func categories(of messages: [MessageSummary]) -> [InboxCategory] {
        messages.map { category(of: $0) }
    }

    /// The category chosen for a sender's mail, or nil when it's sorted automatically.
    public func chosenCategory(forSender email: String) -> InboxCategory? {
        loaded()[Self.key(for: email)]
    }

    /// Puts a sender's mail in a category from now on (nil goes back to sorting it automatically).
    public func setCategory(_ category: InboxCategory?, forSender email: String) throws {
        let key = Self.key(for: email)
        guard !key.isEmpty else { return }
        var updated = loaded()
        guard updated[key] != category else { return }
        updated[key] = category
        try save(updated)
    }

    /// The senders the person has put in a category, by address in lowercase.
    public func senderCategories() -> [String: InboxCategory] { loaded() }

    /// An address as choices are kept: without spaces or angle brackets around it, in lowercase.
    static func key(for email: String) -> String {
        email.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>")).lowercased()
    }

    /// The file's contents. Categories are kept by name, so one this version doesn't know is skipped, not fatal.
    private struct Stored: Codable {
        var version: Int?
        var senders: [String: String]?
    }

    private func loaded() -> [String: InboxCategory] {
        if let choices { return choices }
        var read: [String: InboxCategory] = [:]
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            for (email, name) in stored.senders ?? [:] {
                let key = Self.key(for: email)
                if !key.isEmpty, let category = InboxCategory(rawValue: name) { read[key] = category }
            }
        }
        choices = read
        return read
    }

    private func save(_ new: [String: InboxCategory]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Stored(version: 1, senders: new.mapValues(\.rawValue))).write(to: file, options: .atomic)
        } catch {
            throw PMailError.server("PMail couldn’t save the inbox categories: \(error.localizedDescription)")
        }
        choices = new
    }
}
