import Foundation

/// A sender blocked on an account: one address, or every address at a domain and its subdomains. Mail from them goes
/// to Junk as PMail finds it.
public struct BlockedSender: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case address
        case domain
    }

    public var kind: Kind
    /// The address or the domain, in lowercase.
    public var value: String
    public var blockedAt: Date

    public init(kind: Kind, value: String, blockedAt: Date = Date()) {
        self.kind = kind
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>@.")).lowercased()
        self.value = trimmed
        self.blockedAt = blockedAt
    }

    public var id: String { "\(kind.rawValue):\(value)" }

    /// Blocks one address.
    public static func address(_ email: String, at date: Date = Date()) -> BlockedSender {
        BlockedSender(kind: .address, value: email, blockedAt: date)
    }

    /// Blocks everything from an address's domain ("news@mail.example.com" blocks mail.example.com).
    public static func domain(of email: String, at date: Date = Date()) -> BlockedSender? {
        domain(ofAddress: email).map { BlockedSender(kind: .domain, value: $0, blockedAt: date) }
    }

    /// What a list shows for it: the address, or "everything from" the domain.
    public var displayName: String {
        kind == .address ? value : "everything from \(value)"
    }

    /// Whether this rule blocks mail from an address.
    public func matches(_ email: String) -> Bool {
        guard !value.isEmpty else { return false }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch kind {
        case .address:
            return address == value
        case .domain:
            guard let domain = Self.domain(ofAddress: address) else { return false }
            return domain == value || domain.hasSuffix("." + value)
        }
    }

    /// The part of an address after its last "@", in lowercase, or nil when there isn't one.
    public static func domain(ofAddress email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>.")).lowercased()
        return domain.isEmpty ? nil : domain
    }
}

/// An account's blocked senders, kept in a JSON file in its folder. Every change is written straight away.
public actor BlockedSenders {
    public let file: URL
    private var rules: [BlockedSender]?

    public init(file: URL) {
        self.file = file
    }

    /// Everyone blocked, addresses and domains in name order.
    public func all() -> [BlockedSender] {
        loaded().sorted { ($0.value, $0.kind.rawValue) < ($1.value, $1.kind.rawValue) }
    }

    /// Blocks more senders; ones already blocked stay as they were.
    public func add(_ newRules: [BlockedSender]) throws {
        var current = loaded()
        for rule in newRules where !rule.value.isEmpty && !current.contains(where: { $0.id == rule.id }) {
            current.append(rule)
        }
        try save(current)
    }

    /// Unblocks a sender.
    public func remove(id: String) throws {
        try save(loaded().filter { $0.id != id })
    }

    /// Whether mail from an address is blocked.
    public func isBlocked(_ email: String) -> Bool {
        loaded().contains { $0.matches(email) }
    }

    /// The messages whose sender is blocked.
    public func blocked(among messages: [MessageSummary]) -> [MessageSummary] {
        let rules = loaded()
        guard !rules.isEmpty else { return [] }
        return messages.filter { message in
            guard let sender = message.from?.email else { return false }
            return rules.contains { $0.matches(sender) }
        }
    }

    private func loaded() -> [BlockedSender] {
        if let rules { return rules }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([BlockedSender].self, from: $0) } ?? []
        rules = read
        return read
    }

    private func save(_ new: [BlockedSender]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            throw PMailError.server("PMail couldn’t save the blocked senders: \(error.localizedDescription)")
        }
        rules = new
    }
}
