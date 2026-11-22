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
    /// Its List-Id header, for mailing lists.
    public var listID: String?
    /// Precedence: bulk, list or junk.
    public var isBulk: Bool
    /// Auto-Submitted (other than "no"): sent by a machine, not a person.
    public var isAutomatic: Bool

    public init(canUnsubscribe: Bool = false, listID: String? = nil, isBulk: Bool = false, isAutomatic: Bool = false) {
        self.canUnsubscribe = canUnsubscribe
        self.listID = listID
        self.isBulk = isBulk
        self.isAutomatic = isAutomatic
    }
}

/// Sorts one account's inbox into categories: by the person's own choice for a sender ("always put mail from them in
/// Promotions"), otherwise by what the message and its headers say. The choices are kept in a JSON file.
public actor InboxSorter {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The category a message belongs in.
    public func category(of message: MessageSummary) -> InboxCategory {
        // Filled in by the sorting work: the sender's chosen category first, then the message's own signs.
        .primary
    }

    /// Puts a sender's mail in a category from now on (nil goes back to sorting it automatically).
    public func setCategory(_ category: InboxCategory?, forSender email: String) throws {}

    /// The senders the person has put in a category, by address in lowercase.
    public func senderCategories() -> [String: InboxCategory] { [:] }
}
