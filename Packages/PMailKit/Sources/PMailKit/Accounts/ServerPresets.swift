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
    }

    private static let knownProviders: [Provider] = [
        Provider(domains: ["yahoo.com", "ymail.com", "rocketmail.com"], imap: "imap.mail.yahoo.com", pop: "pop.mail.yahoo.com",
                 smtp: "smtp.mail.yahoo.com", smtpSecurity: .tls),
        Provider(domains: ["aol.com"], imap: "imap.aol.com", pop: "pop.aol.com", smtp: "smtp.aol.com", smtpSecurity: .tls),
        Provider(domains: ["fastmail.com", "fastmail.fm"], imap: "imap.fastmail.com", pop: "pop.fastmail.com",
                 smtp: "smtp.fastmail.com", smtpSecurity: .tls),
        Provider(domains: ["zoho.com", "zohomail.com"], imap: "imap.zoho.com", pop: "pop.zoho.com", smtp: "smtp.zoho.com",
                 smtpSecurity: .tls),
        Provider(domains: ["gmx.com", "gmx.net", "gmx.de"], imap: "imap.gmx.com", pop: "pop.gmx.com", smtp: "mail.gmx.com",
                 smtpSecurity: .startTLS),
        Provider(domains: ["mail.com"], imap: "imap.mail.com", pop: "pop.mail.com", smtp: "smtp.mail.com", smtpSecurity: .startTLS),
        Provider(domains: ["yandex.com", "yandex.ru"], imap: "imap.yandex.com", pop: "pop.yandex.com", smtp: "smtp.yandex.com",
                 smtpSecurity: .tls),
        Provider(domains: ["icloud.com", "me.com", "mac.com"], imap: "imap.mail.me.com", pop: nil, smtp: "smtp.mail.me.com",
                 smtpSecurity: .startTLS),
    ]
}
