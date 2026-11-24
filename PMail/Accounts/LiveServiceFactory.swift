import Foundation
import PMailKit

/// The real services for each kind of account: the provider's web services for Google and Microsoft accounts, and
/// IMAP or POP with SMTP, CalDAV and CardDAV (or calendars and contacts kept on the Mac) for iCloud and other
/// accounts.
struct LiveServiceFactory: ServiceFactory {
    let oauth: OAuthConfiguration
    /// Application Support/PMail, where accounts without servers for some things keep them.
    let folder: URL

    func services(for account: Account, secrets: any SecretStore, storage: AccountStorage?) -> AccountServices {
        let secret: StoredSecret?
        do {
            secret = try secrets.secret(for: account.id)
        } catch {
            return unavailable(error as? PMailError ?? .notSignedIn)
        }
        guard let secret else { return unavailable(.notSignedIn) }
        switch account.kind {
        case .google, .microsoft:
            return webServices(for: account, secret: secret, secrets: secrets, keepsMail: storage != nil)
        case .icloud, .other:
            return internetServices(for: account, secret: secret, storage: storage)
        }
    }

    /// Where an account keeps what it keeps on the Mac (the same folder as its cache and Outbox).
    func storage(for account: Account) -> URL {
        AppDelegate.accountsFolder(in: folder).appendingPathComponent(account.id.uuidString, isDirectory: true)
    }

    /// An account's calendars with its tasks beside them, and the kinds of events its calendars can't hold kept on
    /// this Mac.
    private func calendar(_ calendars: any CalendarService, tasks: any TaskService, for account: Account) -> CalendarWithTasks {
        let place = storage(for: account)
        return CalendarWithTasks(calendars: calendars, tasks: tasks, types: EventTypeBook(file: place.appendingPathComponent(EventTypeBook.fileName)),
                                 feeds: CalendarFeeds(folder: place.appendingPathComponent(CalendarFeeds.folderName, isDirectory: true)),
                                 declines: DeclineBook(file: place.appendingPathComponent(DeclineBook.fileName)))
    }

    private func unavailable(_ reason: PMailError) -> AccountServices {
        let service = UnavailableService(reason)
        return AccountServices(mail: service, calendar: service, contacts: service)
    }

    /// `keepsMail`: the window's services, which keep a Google account's mail on this Mac (not a sign-in check's).
    private func webServices(for account: Account, secret: StoredSecret, secrets: any SecretStore, keepsMail: Bool) -> AccountServices {
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
            let storeFolder = keepsMail ? storage(for: account).appendingPathComponent("Gmail", isDirectory: true) : nil
            // An earlier build kept a copy downloaded through Google's mail API here; the Gmail folder replaces it.
            if keepsMail { try? FileManager.default.removeItem(at: storage(for: account).appendingPathComponent("Google Mail", isDirectory: true)) }
            return AccountServices(mail: gmail(for: account, tokens: tokenProvider, storeFolder: storeFolder),
                                   calendar: calendar(GoogleCalendarService(tokens: tokenProvider,
                                                                            dismissedFile: storage(for: account).appendingPathComponent(DismissedEvents.fileName)),
                                                      tasks: GoogleTasksService(tokens: tokenProvider), for: account),
                                   contacts: GoogleContactsService(tokens: tokenProvider))
        }
        // Earlier versions kept the meetings declined here on the Mac; declined meetings aren't kept any more.
        try? FileManager.default.removeItem(at: storage(for: account).appendingPathComponent(MicrosoftCalendarService.oldDeclinedFileName))
        return AccountServices(mail: MicrosoftMailService(email: account.email, tokens: tokenProvider),
                               calendar: calendar(MicrosoftCalendarService(tokens: tokenProvider,
                                                                           followedFile: storage(for: account).appendingPathComponent(FollowedCalendars.fileName)),
                                                  tasks: MicrosoftTasksService(tokens: tokenProvider), for: account),
                               contacts: MicrosoftContactsService(tokens: tokenProvider))
    }

    /// A Google account's mail: Gmail's IMAP and SMTP servers, signed in with the account's Google sign-in, the
    /// Gmail way (labels, category tabs, Gmail's conversations and search), kept on this Mac in `storeFolder` so every
    /// list comes from there. Google's mail API keeps its label colors and signature.
    private func gmail(for account: Account, tokens: any AccessTokenProvider, storeFolder: URL?) -> any MailService {
        let credential = Credential.oauth(username: account.email, tokens: tokens)
        let incoming = ServerSettings(mailProtocol: .imap, host: "imap.gmail.com", security: .tls, username: account.email,
                                      authentication: .oauth2)
        let outgoing = ServerSettings(mailProtocol: .smtp, host: "smtp.gmail.com", security: .tls, username: account.email,
                                      authentication: .oauth2)
        return IMAPMailService(account: account, incoming: incoming, credential: credential,
                               sender: SMTPSender(settings: outgoing, credential: credential),
                               gmailAPI: GoogleMailService(email: account.email, tokens: tokens), gmailStoreFolder: storeFolder)
    }

    private func internetServices(for account: Account, secret: StoredSecret, storage: AccountStorage?) -> AccountServices {
        guard case let .password(password) = secret, let incoming = account.incoming else { return unavailable(.notSignedIn) }
        let place = self.storage(for: account)
        let sender: any MailSending = account.outgoing.map {
            SMTPSender(settings: $0, credential: .password(username: $0.username, password: password))
        } ?? NoOutgoingServer()
        let mailCredential = Credential.password(username: incoming.username, password: password)
        // Mail kept on this Mac: everything but the inbox for POP, and Sent, Drafts and Trash for an IMAP server
        // without them.
        let localMail = LocalMailStore(folder: place.appendingPathComponent("Mail", isDirectory: true))
        // Labels and inbox categories, shared with the window when it has made them.
        let labelBook = storage?.labelBook ?? LabelBook(file: place.appendingPathComponent("Labels.json"))
        let sorter = storage?.sorter ?? InboxSorter(file: place.appendingPathComponent("Categories.json"))
        let mail: any MailService = incoming.mailProtocol == .pop3
            ? POPMailService(account: account, incoming: incoming, credential: mailCredential, store: localMail, sender: sender,
                             labelBook: labelBook, sorter: sorter)
            : IMAPMailService(account: account, incoming: incoming, credential: mailCredential, sender: sender, localStore: localMail,
                              labelBook: labelBook, sorter: sorter)
        // Calendars and contacts sign in with the Apple Account (iCloud) or the account's own user name.
        let serverCredential = Credential.password(username: account.serverLoginName ?? incoming.username, password: password)
        // iCloud sends its meetings' invitations itself when the Apple Account's email is an iCloud address; for one with
        // an email elsewhere, PMail emails them from the account's address. PMail also invites guests for the other
        // accounts (on a calendar kept on this Mac, or those a calendar server doesn't).
        let calendars: any CalendarService = account.calendarServer.map {
            CalDAVCalendarService(serverURL: $0, credential: serverCredential, ownerEmail: account.email, iCloud: account.kind == .icloud)
        } ?? LocalCalendarService(folder: place.appendingPathComponent("Calendar", isDirectory: true), ownerEmail: account.email)
        // Tasks are kept on this Mac: these servers keep none PMail can reach.
        let calendar = calendar(calendars, tasks: LocalTaskService(file: place.appendingPathComponent(LocalTaskService.fileName)), for: account)
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
