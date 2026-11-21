import Foundation
import PMailKit

/// The real services for each kind of account: the provider's web services for Google and Microsoft accounts, and
/// IMAP or POP with SMTP, CalDAV and CardDAV (or calendars and contacts kept on the Mac) for iCloud and other
/// accounts.
struct LiveServiceFactory: ServiceFactory {
    let oauth: OAuthConfiguration
    /// Application Support/PMail, where accounts without servers for some things keep them.
    let folder: URL

    func services(for account: Account, secrets: any SecretStore) -> AccountServices {
        let secret: StoredSecret?
        do {
            secret = try secrets.secret(for: account.id)
        } catch {
            return unavailable(error as? PMailError ?? .notSignedIn)
        }
        guard let secret else { return unavailable(.notSignedIn) }
        switch account.kind {
        case .google, .microsoft:
            return webServices(for: account, secret: secret, secrets: secrets)
        case .icloud, .other:
            return internetServices(for: account, secret: secret)
        }
    }

    /// Where an account keeps what it keeps on the Mac (the same folder as its cache and Outbox).
    func storage(for account: Account) -> URL {
        AppDelegate.accountsFolder(in: folder).appendingPathComponent(account.id.uuidString, isDirectory: true)
    }

    private func unavailable(_ reason: PMailError) -> AccountServices {
        let service = UnavailableService(reason)
        return AccountServices(mail: service, calendar: service, contacts: service)
    }

    private func webServices(for account: Account, secret: StoredSecret, secrets: any SecretStore) -> AccountServices {
        guard let provider = oauth.provider(for: account.kind) else {
            return unavailable(.notConfigured("\(account.kind.displayName) sign-in isn’t set up in this copy of PMail."))
        }
        guard case let .oauth(tokens) = secret else { return unavailable(.notSignedIn) }
        let id = account.id
        // New tokens are saved as they come, so a refresh survives quitting.
        let tokenProvider = OAuthTokenProvider(client: OAuthClient(provider: provider), tokens: tokens) { fresh in
            try? secrets.setSecret(.oauth(fresh), for: id)
        }
        if account.kind == .google {
            return AccountServices(mail: GoogleMailService(email: account.email, tokens: tokenProvider),
                                   calendar: GoogleCalendarService(tokens: tokenProvider),
                                   contacts: GoogleContactsService(tokens: tokenProvider))
        }
        return AccountServices(mail: MicrosoftMailService(email: account.email, tokens: tokenProvider),
                               calendar: MicrosoftCalendarService(tokens: tokenProvider),
                               contacts: MicrosoftContactsService(tokens: tokenProvider))
    }

    private func internetServices(for account: Account, secret: StoredSecret) -> AccountServices {
        guard case let .password(password) = secret, let incoming = account.incoming else { return unavailable(.notSignedIn) }
        let place = storage(for: account)
        let sender: any MailSending = account.outgoing.map {
            SMTPSender(settings: $0, credential: .password(username: $0.username, password: password))
        } ?? NoOutgoingServer()
        let mailCredential = Credential.password(username: incoming.username, password: password)
        // Mail kept on this Mac: everything but the inbox for POP, and Sent, Drafts and Trash for an IMAP server
        // without them.
        let localMail = LocalMailStore(folder: place.appendingPathComponent("Mail", isDirectory: true))
        let mail: any MailService = incoming.mailProtocol == .pop3
            ? POPMailService(account: account, incoming: incoming, credential: mailCredential, store: localMail, sender: sender)
            : IMAPMailService(account: account, incoming: incoming, credential: mailCredential, sender: sender, localStore: localMail)
        // Calendars and contacts sign in with the Apple Account (iCloud) or the account's own user name.
        let serverCredential = Credential.password(username: account.serverLoginName ?? incoming.username, password: password)
        let calendar: any CalendarService = account.calendarServer.map {
            CalDAVCalendarService(serverURL: $0, credential: serverCredential, ownerEmail: account.email)
        } ?? LocalCalendarService(folder: place.appendingPathComponent("Calendar", isDirectory: true), ownerEmail: account.email)
        let contacts: any ContactsService = account.contactsServer.map {
            CardDAVContactsService(serverURL: $0, credential: serverCredential)
        } ?? LocalContactsService(folder: place.appendingPathComponent("Contacts", isDirectory: true))
        return AccountServices(mail: mail, calendar: calendar, contacts: contacts)
    }
}

/// Sending for an account with no outgoing server, which explains why it can't.
private struct NoOutgoingServer: MailSending {
    func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {
        throw PMailError.notSupported("This account has no outgoing (SMTP) server. Add one in Account Settings.")
    }
}
