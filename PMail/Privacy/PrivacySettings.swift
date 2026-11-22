import Foundation
import Observation
import PMailKit
import Security

/// Settings ▸ Privacy: how PMail treats pictures and other content from the internet in messages. Kept in the app's
/// settings (the sample settings in sample runs), with the proxy's password in the keychain.
@Observable
final class PrivacySettings {
    /// The app's. Sample runs swap in their own before anything reads it.
    static var shared = PrivacySettings(store: .standard, passwords: KeychainProxyPassword())

    private enum Keys {
        static let protect = "ProtectMailActivity"
        static let block = "BlockRemoteContent"
        static let trusted = "TrustedImageSenders"
        static let proxyOn = "RemoteContentProxyOn"
        static let proxy = "RemoteContentProxy"
        /// Before Settings had a Privacy pane: Mail ▸ “Show pictures in messages without asking”.
        static let alwaysShowPictures = "AlwaysShowPictures"
    }

    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let passwords: any ProxyPasswordStore
    /// Sample runs' pretend internet, used in place of the real one whatever the settings say.
    @ObservationIgnored var sampleFetcher: (any RemoteFetcher)?

    /// Loads each new message's pictures privately in the background as it arrives, so senders can't tell whether or
    /// when it was read, and every message shows its pictures.
    var protectsMailActivity: Bool {
        didSet { store.set(protectsMailActivity, forKey: Keys.protect) }
    }

    /// Loads nothing from the internet until asked: for one message, or for senders whose pictures always show. Has no
    /// effect while Protect Mail Activity is on.
    var blocksRemoteContent: Bool {
        didSet { store.set(blocksRemoteContent, forKey: Keys.block) }
    }

    /// Senders whose pictures show even while remote content is blocked, by address in lowercase.
    var trustedImageSenders: Set<String> {
        didSet { store.set(trustedImageSenders.sorted(), forKey: Keys.trusted) }
    }

    /// Sends every request for remote content through `proxy`, so senders see its address instead of the Mac's, and
    /// none at all when the proxy can't be reached.
    var usesProxy: Bool {
        didSet {
            store.set(usesProxy, forKey: Keys.proxyOn)
            routeChanged()
        }
    }

    var proxy: RemoteContentProxy {
        didSet {
            store.set(try? JSONEncoder().encode(proxy), forKey: Keys.proxy)
            routeChanged()
        }
    }

    init(store: UserDefaults, passwords: any ProxyPasswordStore) {
        self.store = store
        self.passwords = passwords
        protectsMailActivity = store.bool(forKey: Keys.protect)
        blocksRemoteContent = store.object(forKey: Keys.block) as? Bool ?? !store.bool(forKey: Keys.alwaysShowPictures)
        trustedImageSenders = Set(store.stringArray(forKey: Keys.trusted) ?? [])
        usesProxy = store.bool(forKey: Keys.proxyOn)
        proxy = store.data(forKey: Keys.proxy).flatMap { try? JSONDecoder().decode(RemoteContentProxy.self, from: $0) } ?? RemoteContentProxy()
    }

    /// The proxy's password, from the keychain.
    var proxyPassword: String { passwords.password() ?? "" }

    func setProxyPassword(_ password: String) {
        guard password != proxyPassword else { return }
        passwords.setPassword(password)
        routeChanged()
    }

    /// Whether a message's pictures load as it's shown: always while Protect Mail Activity is on, or while nothing is
    /// blocked; otherwise only when asked for this message or its sender.
    func loadsRemoteContent(from sender: String?, shownByHand: Bool) -> Bool {
        if protectsMailActivity || shownByHand || !blocksRemoteContent { return true }
        return sender.map { trustedImageSenders.contains($0.lowercased()) } ?? false
    }

    /// Points the app's loader at the internet as these settings say: only through the proxy while it's on (and
    /// nowhere while it's on but not filled in), directly otherwise.
    func routeChanged() {
        let loader = RemoteContentLoader.shared
        let notFilledIn = RefusingFetcher(reason: "Remote content loads only through a proxy, and the proxy in Settings ▸ Privacy isn’t filled in.")
        if let sampleFetcher {
            loader.use(usesProxy && !proxy.isComplete ? notFilledIn : sampleFetcher, throughProxy: usesProxy)
        } else if usesProxy {
            let password = proxy.username.isEmpty ? nil : passwords.password()
            loader.use(PrivateFetcher(proxy: proxy, password: password) ?? notFilledIn, throughProxy: true)
        } else if let direct = PrivateFetcher(proxy: nil, password: nil) {
            loader.use(direct, throughProxy: false)
        }
    }
}

extension RemoteContentLoader {
    /// The app's loader for remote content, pointed at the internet by `PrivacySettings.routeChanged()` at launch and
    /// whenever the proxy settings change. Until then it loads nothing.
    nonisolated static let shared = RemoteContentLoader(fetcher: RefusingFetcher(reason: "PMail is starting up."))
}

/// Where the proxy's password is kept.
protocol ProxyPasswordStore {
    func password() -> String?
    /// Saves a password, or removes it when it's empty.
    func setPassword(_ password: String)
}

/// The proxy's password in the login keychain, in an item of its own beside the accounts'.
struct KeychainProxyPassword: ProxyPasswordStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pugglesoft.PMail.proxy",
         kSecAttrAccount as String: "remote-content"]
    }

    func password() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String) {
        guard !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "PMail proxy"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// The proxy's password in memory only, for sample runs.
final class MemoryProxyPassword: ProxyPasswordStore {
    private var value: String?

    func password() -> String? { value }

    func setPassword(_ password: String) {
        value = password.isEmpty ? nil : password
    }
}
