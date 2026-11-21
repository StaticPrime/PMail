import Foundation
import Security

/// The list of accounts, kept as JSON in Application Support. Secrets are never in it: see `SecretStore`.
public struct AccountStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The saved accounts, oldest first; none if there's no file yet or it can't be read.
    public func load() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    public func save(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// What an account signs in with, as kept in the keychain.
public enum StoredSecret: Codable, Sendable, Hashable {
    case password(String)
    case oauth(OAuthTokens)
}

/// Where passwords and tokens are kept.
public protocol SecretStore: Sendable {
    func secret(for account: UUID) throws -> StoredSecret?
    /// Saves a secret, or removes it when `secret` is nil.
    func setSecret(_ secret: StoredSecret?, for account: UUID) throws
}

/// The login keychain: one generic password item per account, readable only by PMail.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.pugglesoft.PMail") {
        self.service = service
    }

    public func secret(for account: UUID) throws -> StoredSecret? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        return try JSONDecoder().decode(StoredSecret.self, from: data)
    }

    public func setSecret(_ secret: StoredSecret?, for account: UUID) throws {
        guard let secret else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
            return
        }
        let data = try JSONEncoder().encode(secret)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "PMail account"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    private func baseQuery(_ account: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.uuidString]
    }

    private static func error(_ status: OSStatus) -> PMailError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return .server("The keychain couldn’t be used: \(message)")
    }
}

/// Secrets kept in memory only, for tests and the sample accounts.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: StoredSecret] = [:]

    public init() {}

    public func secret(for account: UUID) throws -> StoredSecret? { lock.withLock { secrets[account] } }

    public func setSecret(_ secret: StoredSecret?, for account: UUID) throws {
        lock.withLock { secrets[account] = secret }
    }
}
