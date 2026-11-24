import Foundation

/// Known server settings: iCloud's, and a guess for other addresses so the person rarely has to type them.
public enum ServerPresets {
    /// iCloud Mail's servers, and iCloud's calendar and contacts servers. Mail signs in with the iCloud address,
    /// calendars and contacts with the Apple Account's email (often the same address), all with one app-specific
    /// password.
    public static func iCloud(email: String, appleAccount: String? = nil) -> (incoming: ServerSettings, outgoing: ServerSettings,
                                                                               calendar: URL, contacts: URL, login: String) {
        let address = email.trimmingCharacters(in: .whitespaces)
        let login = (appleAccount?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? address
        let incoming = ServerSettings(mailProtocol: .imap, host: "imap.mail.me.com", port: 993, security: .tls, username: address)
        let outgoing = ServerSettings(mailProtocol: .smtp, host: "smtp.mail.me.com", port: 587, security: .startTLS, username: address)
        return (incoming, outgoing, URL(string: "https://caldav.icloud.com/")!, URL(string: "https://contacts.icloud.com/")!, login)
    }

    /// Whether an address belongs to iCloud Mail, so the add-account sheet can suggest the iCloud choice.
    public static func isICloudAddress(_ email: String) -> Bool {
        guard let domain = domain(of: email) else { return false }
        return ["icloud.com", "me.com", "mac.com"].contains(domain)
    }

    /// Whether an address is one of the big providers that sign in through their own page instead of a password.
    public static func browserSignInKind(for email: String) -> AccountKind? {
        guard let domain = domain(of: email) else { return nil }
        if ["gmail.com", "googlemail.com"].contains(domain) { return .google }
        if ["outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com"].contains(domain)
            || domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.") || domain.hasPrefix("live.") { return .microsoft }
        return nil
    }

    /// Incoming and outgoing settings for an address: from the table of providers PMail knows, or else the usual
    /// names (imap.domain and smtp.domain) for the person to check.
    public static func guess(forEmail email: String, incoming mailProtocol: MailProtocol = .imap) -> (incoming: ServerSettings, outgoing: ServerSettings) {
        let address = email.trimmingCharacters(in: .whitespaces)
        let domain = domain(of: address) ?? "example.com"
        let known = knownProviders.first { $0.domains.contains(domain) }
        let incomingHost: String
        let incomingSecurity: ConnectionSecurity = .tls
        switch mailProtocol {
        case .pop3: incomingHost = known?.pop ?? "pop.\(domain)"
        default: incomingHost = known?.imap ?? "imap.\(domain)"
        }
        let incoming = ServerSettings(mailProtocol: mailProtocol == .pop3 ? .pop3 : .imap, host: incomingHost,
                                      security: incomingSecurity, username: address)
        let outgoingSecurity = known?.smtpSecurity ?? .startTLS
        let outgoing = ServerSettings(mailProtocol: .smtp, host: known?.smtp ?? "smtp.\(domain)", security: outgoingSecurity,
                                      username: address)
        return (incoming, outgoing)
    }

    /// A provider on PMail's list, by the address's domain, as found settings.
    public static func knownSettings(forDomain domain: String, email: String) -> FoundMailSettings? {
        knownProviders.first { $0.domains.contains(domain) }.map { settings(of: $0, email: email) }
    }

    /// A provider on PMail's list that handles a domain's mail, by the names of its mail exchangers (a company's own
    /// domain at Fastmail, say).
    public static func knownSettings(forMailExchangers exchangers: [String], email: String) -> FoundMailSettings? {
        for exchanger in exchangers {
            let provider = (hostedProviders + knownProviders).first { provider in
                provider.exchangers.contains { exchanger == $0 || exchanger.hasSuffix("." + $0) }
            }
            if let provider { return settings(of: provider, email: email) }
        }
        return nil
    }

    /// The provider PMail signs in to its own way (Google, Microsoft, iCloud) that handles a domain's mail, by the names
    /// of its mail exchangers: a company's own domain at Google Workspace or Microsoft 365, or an iCloud custom domain.
    public static func signInKind(forMailExchangers exchangers: [String]) -> AccountKind? {
        func under(_ host: String, _ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        for exchanger in exchangers {
            if under(exchanger, ["google.com", "googlemail.com"]) { return .google }
            if under(exchanger, ["mail.protection.outlook.com", "olc.protection.outlook.com"]) { return .microsoft }
            if under(exchanger, ["mail.icloud.com"]) { return .icloud }
        }
        return nil
    }

    private static func settings(of provider: Provider, email: String) -> FoundMailSettings {
        let imap = ServerSettings(mailProtocol: .imap, host: provider.imap, security: .tls, username: email)
        let pop = provider.pop.map { ServerSettings(mailProtocol: .pop3, host: $0, security: .tls, username: email) }
        let smtp = ServerSettings(mailProtocol: .smtp, host: provider.smtp, security: provider.smtpSecurity, username: email)
        return FoundMailSettings(incoming: imap, otherIncoming: pop, outgoing: smtp, source: .knownProvider)
    }

    public static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
        return domain.isEmpty ? nil : domain
    }

    private struct Provider {
        var domains: Set<String>
        var imap: String
        var pop: String?
        var smtp: String
        var smtpSecurity: ConnectionSecurity
        /// The names its mail exchangers end in, for companies' own domains it handles.
        var exchangers: [String] = []
    }

    /// Providers' servers for companies' own domains, where those differ from their own addresses' servers.
    private static let hostedProviders: [Provider] = [
        Provider(domains: [], imap: "imappro.zoho.com", pop: "poppro.zoho.com", smtp: "smtppro.zoho.com", smtpSecurity: .tls,
                 exchangers: ["zoho.com"]),
        Provider(domains: [], imap: "imappro.zoho.eu", pop: "poppro.zoho.eu", smtp: "smtppro.zoho.eu", smtpSecurity: .tls,
                 exchangers: ["zoho.eu"]),
    ]

    private static let knownProviders: [Provider] = [
        Provider(domains: ["yahoo.com", "ymail.com", "rocketmail.com"], imap: "imap.mail.yahoo.com", pop: "pop.mail.yahoo.com",
                 smtp: "smtp.mail.yahoo.com", smtpSecurity: .tls, exchangers: ["yahoodns.net"]),
        Provider(domains: ["aol.com"], imap: "imap.aol.com", pop: "pop.aol.com", smtp: "smtp.aol.com", smtpSecurity: .tls),
        Provider(domains: ["fastmail.com", "fastmail.fm"], imap: "imap.fastmail.com", pop: "pop.fastmail.com",
                 smtp: "smtp.fastmail.com", smtpSecurity: .tls, exchangers: ["messagingengine.com"]),
        Provider(domains: ["zoho.com", "zohomail.com"], imap: "imap.zoho.com", pop: "pop.zoho.com", smtp: "smtp.zoho.com",
                 smtpSecurity: .tls),
        Provider(domains: ["gmx.com", "gmx.net", "gmx.de"], imap: "imap.gmx.com", pop: "pop.gmx.com", smtp: "mail.gmx.com",
                 smtpSecurity: .startTLS),
        Provider(domains: ["mail.com"], imap: "imap.mail.com", pop: "pop.mail.com", smtp: "smtp.mail.com", smtpSecurity: .startTLS),
        Provider(domains: ["yandex.com", "yandex.ru"], imap: "imap.yandex.com", pop: "pop.yandex.com", smtp: "smtp.yandex.com",
                 smtpSecurity: .tls, exchangers: ["yandex.net"]),
        Provider(domains: ["icloud.com", "me.com", "mac.com"], imap: "imap.mail.me.com", pop: nil, smtp: "smtp.mail.me.com",
                 smtpSecurity: .startTLS),
    ]
}
