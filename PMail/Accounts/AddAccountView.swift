import AppKit
import PMailKit
import SwiftUI

/// Adding an account: pick the provider, then sign in through its page (Google, Microsoft), with an app-specific
/// password (iCloud), or with the servers' names (any other mail account). The account is checked against its
/// server before it's added.
struct AddAccountView: View {
    let app: AppModel
    @State private var kind: AccountKind?
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, initialKind: AccountKind?) {
        self.app = app
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if kind != nil {
                    IconButton(symbol: "chevron.left", help: "Choose another kind of account") { kind = nil }
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Group {
                switch kind {
                case nil:
                    VStack(spacing: 18) {
                        Text("Add an account").font(.pm(24)).foregroundStyle(Theme.textPrimary)
                        Text("Mail, calendar and contacts from the account all show in PMail, and switching accounts switches all three.")
                            .font(.pm(13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                        ProviderGrid(app: app) { kind = $0 }
                            .padding(.top, 6)
                    }
                case .google?, .microsoft?:
                    BrowserSignIn(app: app, kind: kind!) { dismiss() } useOther: { kind = .other }
                case .icloud?:
                    ICloudSignIn(app: app) { dismiss() }
                case .other?:
                    OtherAccountSignIn(app: app) { dismiss() }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 30)
            Spacer(minLength: 0)
        }
        .frame(width: 640, height: kind == .other ? 680 : 520)
        .background(Theme.surface)
    }
}

// MARK: Google and Microsoft

/// Sign-in through the provider's own page, or why it isn't possible in this copy of PMail.
private struct BrowserSignIn: View {
    let app: AppModel
    let kind: AccountKind
    let done: () -> Void
    let useOther: () -> Void
    @State private var email = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var signIn = OAuthSignIn()

    var body: some View {
        VStack(spacing: 18) {
            ProviderLogo(kind: kind, size: 56)
            Text("Sign in with \(kind.displayName)").font(.pm(24)).foregroundStyle(Theme.textPrimary)
            if let provider = app.oauth.provider(for: kind) {
                Text("A \(kind.displayName) sign-in window opens. PMail never sees your password: \(kind.displayName) gives it a key to your mail, calendars and contacts that you can take back at any time.")
                    .font(.pm(13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                TextField("Email address (optional)", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { start(provider) }
                ProviderSignInButton(kind: kind, isWorking: isWorking) { start(provider) }
            } else {
                VStack(spacing: 10) {
                    Text("\(kind.displayName) sign-in isn’t set up in this copy of PMail yet.")
                        .font(.pm(14, .medium)).foregroundStyle(Theme.textPrimary)
                    Text("Signing in with \(kind.displayName) needs PMail’s client ID from \(kind.displayName). Whoever built this copy sets it with the \(kind == .google ? "PMAIL_GOOGLE_CLIENT_ID" : "PMAIL_MICROSOFT_CLIENT_ID") environment variable; the README explains how.")
                        .font(.pm(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        .textSelection(.enabled)
                    if kind == .google {
                        Text("Until then, a Google account can be added for mail only, with an app password, under Other mail account.")
                            .font(.pm(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        OutlinePillButton(title: "Add with an App Password", action: useOther)
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.canvas))
            }
            if let error {
                Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).multilineTextAlignment(.center).frame(maxWidth: 460).textSelection(.enabled)
            }
        }
        .padding(.top, 10)
    }

    private func start(_ provider: OAuthProvider) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            do {
                let result = try await signIn.signIn(with: provider, loginHint: email.isEmpty ? nil : email)
                let account = Account(kind: kind, name: result.identity.name, email: result.identity.email, pictureURL: result.identity.pictureURL)
                let session = try app.accounts.add(account, secret: .oauth(result.tokens))
                session.activate()
                app.show("\(result.identity.email) was added.")
                done()
            } catch PMailError.cancelled {
                isWorking = false
            } catch {
                isWorking = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// "Sign in with Google" / "Sign in with Microsoft", in the providers' own button style: white, with the mark.
private struct ProviderSignInButton: View {
    let kind: AccountKind
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isWorking { ProgressView().controlSize(.small) } else { ProviderLogo(kind: kind, size: 20) }
                Text(isWorking ? "Waiting for \(kind.displayName)…" : "Sign in with \(kind.displayName)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(white: 0.12))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: kind == .google ? 21 : 2).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: kind == .google ? 21 : 2).strokeBorder(Color(white: 0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: iCloud

/// iCloud: the iCloud Mail address and an app-specific password (iCloud doesn't let other apps sign in through a web
/// page). The same password opens iCloud Mail, Calendar and Contacts.
private struct ICloudSignIn: View {
    let app: AppModel
    let done: () -> Void
    @State private var email = ""
    @State private var appleAccount = ""
    @State private var password = ""
    @State private var showsAppleAccount = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            ProviderLogo(kind: .icloud, size: 56)
            Text("Add your iCloud account").font(.pm(24)).foregroundStyle(Theme.textPrimary)
            Text("iCloud asks other apps for an app-specific password instead of your Apple Account password. Make one at account.apple.com under Sign-In and Security ▸ App-Specific Passwords, and paste it here.")
                .font(.pm(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button("Open account.apple.com") { NSWorkspace.shared.open(URL(string: "https://account.apple.com/account/manage")!) }
                .buttonStyle(.link).font(.pm(12.5))
            Form {
                TextField("iCloud email", text: $email, prompt: Text("name@icloud.com"))
                if showsAppleAccount {
                    TextField("Apple Account", text: $appleAccount, prompt: Text("The email you sign in to iCloud with"))
                }
                SecureField("App-specific password", text: $password, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
            }
            .formStyle(.grouped)
            .frame(width: 480, height: showsAppleAccount ? 150 : 112)
            .scrollDisabled(true)
            if !showsAppleAccount {
                Button("My Apple Account uses a different email address") { showsAppleAccount = true }.buttonStyle(.link).font(.pm(12))
            }
            if let error { Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).multilineTextAlignment(.center).frame(maxWidth: 480).textSelection(.enabled) }
            FilledPillButton(title: isWorking ? "Checking…" : "Sign In", isDisabled: isWorking || !email.contains("@") || password.isEmpty) { add() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private func add() {
        isWorking = true
        error = nil
        let presets = ServerPresets.iCloud(email: email, appleAccount: showsAppleAccount ? appleAccount : nil)
        let account = Account(kind: .icloud, name: NSFullUserName(), email: email.trimmingCharacters(in: .whitespaces), incoming: presets.incoming,
                              outgoing: presets.outgoing, calendarServer: presets.calendar, contactsServer: presets.contacts,
                              serverLoginName: presets.login)
        let secret = StoredSecret.password(password.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                try await AccountCheck.verify(account, secret: secret, factory: app.accounts.factory)
                let session = try app.accounts.add(account, secret: secret)
                session.activate()
                app.show("\(account.email) was added.")
                done()
            } catch {
                isWorking = false
                self.error = AccountCheck.explain(error, kind: .icloud)
            }
        }
    }
}

// MARK: Other

/// Any other mail account: name, address and password, then the incoming (IMAP or POP) and outgoing (SMTP)
/// servers, filled in from the address and editable, plus optional calendar and contacts servers.
private struct OtherAccountSignIn: View {
    let app: AppModel
    let done: () -> Void
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var incomingProtocol: MailProtocol = .imap
    @State private var incomingHost = ""
    @State private var incomingPort = 993
    @State private var incomingSecurity: ConnectionSecurity = .tls
    @State private var incomingUser = ""
    @State private var outgoingHost = ""
    @State private var outgoingPort = 587
    @State private var outgoingSecurity: ConnectionSecurity = .startTLS
    @State private var outgoingUser = ""
    @State private var calendarURL = ""
    @State private var contactsURL = ""
    @State private var touchedServers = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ProviderLogo(kind: .other, size: 40)
                Text("Add a mail account").font(.pm(22)).foregroundStyle(Theme.textPrimary)
            }
            Form {
                Section {
                    TextField("Your name", text: $name)
                    TextField("Email address", text: $email).onChange(of: email) { fillServers() }
                    SecureField("Password", text: $password)
                }
                Section("Incoming mail server") {
                    Picker("Type", selection: $incomingProtocol) {
                        Text("IMAP").tag(MailProtocol.imap)
                        Text("POP").tag(MailProtocol.pop3)
                    }
                    .onChange(of: incomingProtocol) { fillServers(force: true) }
                    TextField("Server", text: $incomingHost).onChange(of: incomingHost) { touchedServers = true }
                    HStack {
                        Picker("Security", selection: $incomingSecurity) {
                            ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .onChange(of: incomingSecurity) { incomingPort = ServerSettings.defaultPort(for: incomingProtocol, security: incomingSecurity) }
                        TextField("Port", value: $incomingPort, format: .number.grouping(.never)).frame(width: 120)
                    }
                    TextField("User name", text: $incomingUser)
                }
                Section("Outgoing mail server (SMTP)") {
                    TextField("Server", text: $outgoingHost).onChange(of: outgoingHost) { touchedServers = true }
                    HStack {
                        Picker("Security", selection: $outgoingSecurity) {
                            ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .onChange(of: outgoingSecurity) { outgoingPort = ServerSettings.defaultPort(for: .smtp, security: outgoingSecurity) }
                        TextField("Port", value: $outgoingPort, format: .number.grouping(.never)).frame(width: 120)
                    }
                    TextField("User name", text: $outgoingUser)
                }
                Section {
                    TextField("Calendar (CalDAV) server", text: $calendarURL, prompt: Text("Optional, https://…"))
                    TextField("Contacts (CardDAV) server", text: $contactsURL, prompt: Text("Optional, https://…"))
                } header: {
                    Text("Calendar and contacts")
                } footer: {
                    Text("Without servers here, PMail keeps this account’s calendar and contacts on this Mac.")
                        .font(.pm(11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            .formStyle(.grouped)
            if incomingSecurity == .none || outgoingSecurity == .none {
                Text("Without SSL/TLS or STARTTLS, your password and mail cross the network unprotected.")
                    .font(.pm(12)).foregroundStyle(Theme.danger)
            }
            if let error { Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).multilineTextAlignment(.center).frame(maxWidth: 520).textSelection(.enabled) }
            FilledPillButton(title: isWorking ? "Checking…" : "Sign In", isDisabled: isWorking || !email.contains("@") || password.isEmpty
                             || incomingHost.isEmpty || outgoingHost.isEmpty) { add() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Fills the servers from the address, until the person types their own.
    private func fillServers(force: Bool = false) {
        guard force || !touchedServers else { return }
        let guess = ServerPresets.guess(forEmail: email, incoming: incomingProtocol)
        incomingHost = guess.incoming.host
        incomingPort = guess.incoming.port
        incomingSecurity = guess.incoming.security
        incomingUser = email
        outgoingHost = guess.outgoing.host
        outgoingPort = guess.outgoing.port
        outgoingSecurity = guess.outgoing.security
        outgoingUser = email
        touchedServers = false
    }

    private func add() {
        isWorking = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        let incoming = ServerSettings(mailProtocol: incomingProtocol, host: incomingHost.trimmingCharacters(in: .whitespaces), port: incomingPort,
                                      security: incomingSecurity, username: incomingUser.isEmpty ? address : incomingUser)
        let outgoing = ServerSettings(mailProtocol: .smtp, host: outgoingHost.trimmingCharacters(in: .whitespaces), port: outgoingPort,
                                      security: outgoingSecurity, username: outgoingUser.isEmpty ? address : outgoingUser)
        let account = Account(kind: .other, name: name, email: address, incoming: incoming, outgoing: outgoing,
                              calendarServer: URL(string: calendarURL.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 },
                              contactsServer: URL(string: contactsURL.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 },
                              serverLoginName: address)
        let secret = StoredSecret.password(password)
        Task {
            do {
                try await AccountCheck.verify(account, secret: secret, factory: app.accounts.factory)
                let session = try app.accounts.add(account, secret: secret)
                session.activate()
                app.show("\(account.email) was added.")
                done()
            } catch {
                isWorking = false
                self.error = AccountCheck.explain(error, kind: .other)
            }
        }
    }
}

/// Checks a new account against its servers before it's added: its mail, and its calendars if it has a server.
enum AccountCheck {
    static func verify(_ account: Account, secret: StoredSecret, factory: any ServiceFactory) async throws {
        let secrets = MemorySecretStore()
        try secrets.setSecret(secret, for: account.id)
        let services = factory.services(for: account, secrets: secrets)
        if case let .password(password) = secret, let incoming = account.incoming, incoming.mailProtocol == .pop3 {
            // A POP account's folders are on the Mac, so sign in to the server itself.
            let client = POPClient(settings: incoming, credential: .password(username: incoming.username, password: password))
            try await client.connect()
            await client.quit()
        } else {
            _ = try await services.mail.loadFolders()
            await services.mail.close()
        }
        if case let .password(password) = secret, let outgoing = account.outgoing, !(services.mail is UnavailableService) {
            try await SMTPClient(settings: outgoing, credential: .password(username: outgoing.username, password: password)).checkSignIn()
        }
        if account.calendarServer != nil { _ = try await services.calendar.loadCalendars() }
    }

    static func explain(_ error: Error, kind: AccountKind) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if (error as? PMailError)?.needsSignIn == true {
            return kind == .icloud ? "iCloud didn’t accept the address and app-specific password. Check both, or make a new app-specific password. (\(reason))"
                : "The server didn’t accept the user name and password. (\(reason))"
        }
        return reason
    }
}
