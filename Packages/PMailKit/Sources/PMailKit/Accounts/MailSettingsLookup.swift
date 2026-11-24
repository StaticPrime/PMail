import Foundation

/// An address's mail servers, found from the address alone (see `MailSettingsLookup`).
public struct FoundMailSettings: Sendable, Equatable {
    /// Where the settings came from.
    public enum Source: String, Sendable, Equatable {
        /// PMail's own list of providers.
        case knownProvider
        /// The setup file the address's domain publishes.
        case setupFile
        /// The domain's SRV records.
        case dnsRecords
        /// The usual server names, tried to see which answer.
        case triedServers
    }

    /// The incoming server: IMAP when there is one, else POP.
    public var incoming: ServerSettings
    /// The other kind of incoming server, when both were found (POP beside IMAP), for the person to choose instead.
    public var otherIncoming: ServerSettings?
    public var outgoing: ServerSettings
    /// Calendar and contacts servers, when the setup file names them.
    public var calendarServer: URL?
    public var contactsServer: URL?
    public var source: Source

    public init(incoming: ServerSettings, otherIncoming: ServerSettings? = nil, outgoing: ServerSettings, calendarServer: URL? = nil,
                contactsServer: URL? = nil, source: Source) {
        self.incoming = incoming
        self.otherIncoming = otherIncoming
        self.outgoing = outgoing
        self.calendarServer = calendarServer
        self.contactsServer = contactsServer
        self.source = source
    }
}

/// What looking up an address found.
public enum MailSettingsResult: Sendable, Equatable {
    /// Servers to sign in to with a password.
    case servers(FoundMailSettings)
    /// The address's mail is with a provider PMail signs in to its own way (Google, Microsoft, iCloud).
    case provider(AccountKind)
    case notFound
}

/// Finds an address's mail servers from the address alone, so the person only types their address and password:
///
/// 1. PMail's own list of providers, by the address's domain.
/// 2. Who handles the domain's mail (its MX records): a company's own domain at Google, Microsoft or iCloud is sent
///    to that sign-in, and one at a provider on the list gets that provider's servers.
/// 3. The setup file the domain publishes (autoconfig, at autoconfig.<domain> or <domain>/.well-known) and its SRV
///    records (RFC 6186, RFC 8314), asked at once.
/// 4. The usual server names (the MX host, mail.<domain>, imap.<domain> and so on) on the encrypted ports, tried to
///    see which answer with a mail server's greeting. No password is sent.
///
/// Only the address's own domain, its servers and the Mac's resolver are asked: no lookup service learns the address.
public struct MailSettingsLookup: Sendable {
    let dns: any DNSRecordLookup
    let transport: any HTTPTransport
    let probe: any MailServerProbe

    public init(dns: any DNSRecordLookup = SystemDNS(), transport: any HTTPTransport = URLSessionTransport(),
                probe: any MailServerProbe = NetworkMailServerProbe()) {
        self.dns = dns
        self.transport = transport
        self.probe = probe
    }

    public func lookUp(email: String) async -> MailSettingsResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let domain = ServerPresets.domain(of: address), domain.contains("."), !domain.contains(" ") else { return .notFound }
        if let kind = ServerPresets.browserSignInKind(for: address) { return .provider(kind) }
        if ServerPresets.isICloudAddress(address) { return .provider(.icloud) }
        if let known = ServerPresets.knownSettings(forDomain: domain, email: address) { return .servers(known) }
        let exchangers = await dns.mailExchangers(for: domain)
        if let kind = ServerPresets.signInKind(forMailExchangers: exchangers) { return .provider(kind) }
        if let hosted = ServerPresets.knownSettings(forMailExchangers: exchangers, email: address) { return .servers(hosted) }
        async let file = setupFile(for: domain, email: address)
        async let records = serviceRecords(for: domain, email: address)
        if let found = await file { return .servers(found) }
        if let found = await records { return .servers(found) }
        if let found = await triedServers(for: domain, email: address, exchangers: exchangers) { return .servers(found) }
        return .notFound
    }

    // MARK: The domain's setup file

    /// The setup file the domain publishes, from its own HTTPS servers only.
    func setupFile(for domain: String, email: String) async -> FoundMailSettings? {
        let query = [URLQueryItem(name: "emailaddress", value: email)]
        let places = ["https://autoconfig.\(domain)/mail/config-v1.1.xml", "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml"]
        for place in places {
            guard var components = URLComponents(string: place) else { continue }
            components.queryItems = query
            guard let url = components.url else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/xml, text/xml;q=0.9", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await transport.data(for: request), (200..<300).contains(response.statusCode),
                  let found = MailSetupFile.read(data, email: email) else { continue }
            return found
        }
        return nil
    }

    // MARK: SRV records

    /// Servers the domain's SRV records name: IMAP (or POP) and submission, the encrypted ones first.
    func serviceRecords(for domain: String, email: String) async -> FoundMailSettings? {
        async let imaps = dns.services("_imaps._tcp.\(domain)")
        async let imap = dns.services("_imap._tcp.\(domain)")
        async let pop3s = dns.services("_pop3s._tcp.\(domain)")
        async let pop3 = dns.services("_pop3._tcp.\(domain)")
        async let submissions = dns.services("_submissions._tcp.\(domain)")
        async let submission = dns.services("_submission._tcp.\(domain)")
        func settings(_ records: [ServiceRecord], _ mailProtocol: MailProtocol, _ security: ConnectionSecurity) -> ServerSettings? {
            DNSRecordData.ordered(records).first.map {
                ServerSettings(mailProtocol: mailProtocol, host: $0.host, port: $0.port, security: security, username: email)
            }
        }
        let (secureIMAP, plainIMAP, securePOP, plainPOP) = await (imaps, imap, pop3s, pop3)
        let (secureSubmission, plainSubmission) = await (submissions, submission)
        let imapServer = settings(secureIMAP, .imap, .tls) ?? settings(plainIMAP, .imap, .startTLS)
        let popServer = settings(securePOP, .pop3, .tls) ?? settings(plainPOP, .pop3, .startTLS)
        let outgoing = settings(secureSubmission, .smtp, .tls) ?? settings(plainSubmission, .smtp, .startTLS)
        guard let incoming = imapServer ?? popServer, let outgoing else { return nil }
        return FoundMailSettings(incoming: incoming, otherIncoming: imapServer == nil ? nil : popServer, outgoing: outgoing, source: .dnsRecords)
    }

    // MARK: The usual names

    /// The usual server names, tried at once on the encrypted ports (then the ones that start plain and switch to
    /// encryption): the first, in the order of likelihood, to answer as a mail server is used. The names are the
    /// domain's own mail exchangers, its usual mail names, and the usual names at the company its mail exchangers
    /// belong to (a hosting company's imap.<company>, say).
    func triedServers(for domain: String, email: String, exchangers: [String]) async -> FoundMailSettings? {
        let ownExchangers = exchangers.filter { $0 == domain || $0.hasSuffix("." + domain) }
        let companies = exchangers.compactMap(Self.registeredDomain).filter { $0 != domain }
        func candidates(_ mailProtocol: MailProtocol, _ names: [String]) -> [ServerSettings] {
            var seen = Set<String>()
            let hosts = (ownExchangers + names.map { $0.isEmpty ? domain : "\($0).\(domain)" }
                + companies.prefix(1).flatMap { company in names.filter { !$0.isEmpty }.map { "\($0).\(company)" } })
                .filter { seen.insert($0).inserted }
            return [ConnectionSecurity.tls, .startTLS].flatMap { security in
                hosts.map { ServerSettings(mailProtocol: mailProtocol, host: $0, security: security, username: email) }
            }
        }
        let popCandidates = candidates(.pop3, ["mail", "pop", "pop3", ""])
        let pop = Task { await firstAnswering(popCandidates) }
        async let imap = firstAnswering(candidates(.imap, ["mail", "imap", ""]))
        async let smtp = firstAnswering(candidates(.smtp, ["mail", "smtp", ""]))
        let (imapServer, outgoing) = await (imap, smtp)
        // POP beside IMAP is only an alternative: it's waited for a moment, not until every name has timed out.
        let popServer = imapServer == nil ? await pop.value : await Self.value(of: pop, within: 0.5)
        guard let incoming = imapServer ?? popServer, let outgoing else { return nil }
        return FoundMailSettings(incoming: incoming, otherIncoming: imapServer == nil ? nil : popServer, outgoing: outgoing, source: .triedServers)
    }

    /// A task's answer if it comes within the time, else nil (the task carries on, unheeded).
    static func value(of task: Task<ServerSettings?, Never>, within seconds: Double) async -> ServerSettings? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ServerSettings?, Never>) in
            let race = FirstAnswer(continuation)
            Task { race.answer(await task.value) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.answer(nil)
            }
        }
    }

    /// The domain a host name was registered under ("mx1.mail.example.co.uk" → "example.co.uk"), near enough: the last
    /// two labels, or three when the second to last is a short one under a two-letter country code.
    static func registeredDomain(of host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let keep = labels.count >= 3 && labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// The first of the candidates, in their order, that answers as a mail server. They're all tried at once, and the
    /// answer comes as soon as every one before the winner has failed; the ones still trying are left to time out.
    func firstAnswering(_ candidates: [ServerSettings]) async -> ServerSettings? {
        guard !candidates.isEmpty else { return nil }
        let probe = self.probe
        let winner = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let race = ProbeRace(count: candidates.count, continuation: continuation)
            for (index, candidate) in candidates.enumerated() {
                Task { race.record(index, answered: await probe.answers(candidate)) }
            }
        }
        return winner.map { candidates[$0] }
    }
}

/// Whichever answer comes first.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ServerSettings?, Never>?

    init(_ continuation: CheckedContinuation<ServerSettings?, Never>) {
        self.continuation = continuation
    }

    func answer(_ value: ServerSettings?) {
        let waiting = lock.withLock { () -> CheckedContinuation<ServerSettings?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

/// Candidates tried at once: the first in order to answer wins once every one before it has failed.
private final class ProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool?]
    private var continuation: CheckedContinuation<Int?, Never>?

    init(count: Int, continuation: CheckedContinuation<Int?, Never>) {
        results = Array(repeating: nil, count: count)
        self.continuation = continuation
    }

    func record(_ index: Int, answered: Bool) {
        let decided: (CheckedContinuation<Int?, Never>, Int?)? = lock.withLock {
            guard let continuation else { return nil }
            results[index] = answered
            for (position, result) in results.enumerated() {
                guard let result else { return nil }
                if result {
                    self.continuation = nil
                    return (continuation, position)
                }
            }
            self.continuation = nil
            return (continuation, nil)
        }
        if let (continuation, winner) = decided { continuation.resume(returning: winner) }
    }
}

// MARK: Trying a server

/// Whether a server answers as the mail server it should be.
public protocol MailServerProbe: Sendable {
    func answers(_ server: ServerSettings) async -> Bool
}

/// Connects to a server and reads its greeting (IMAP "* OK", POP "+OK", SMTP "220"); on a port that starts plain,
/// it also checks the server offers to switch to encryption. Encrypted connections check the server's certificate as
/// the system does. Nothing more is sent: no user name, no password.
public struct NetworkMailServerProbe: MailServerProbe {
    /// Seconds to wait for a connection and each answer.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 6) {
        self.timeout = timeout
    }

    public func answers(_ server: ServerSettings) async -> Bool {
        let connector = URLSessionConnector(timeout: timeout)
        guard let stream = try? await connector.connect(host: server.host, port: server.port, security: server.security) else { return false }
        defer { stream.close() }
        let mailProtocol = server.mailProtocol
        guard let greeting = try? await Self.readGreeting(from: stream, for: mailProtocol), Self.isGreeting(greeting, for: mailProtocol) else {
            return false
        }
        guard server.security == .startTLS else { return true }
        let (question, mark): (String, String) = switch mailProtocol {
        case .imap: ("A1 CAPABILITY\r\n", "STARTTLS")
        case .pop3: ("CAPA\r\n", "STLS")
        case .smtp: ("EHLO pmail.invalid\r\n", "STARTTLS")
        }
        guard (try? await stream.write(Data(question.utf8))) != nil, let answer = try? await Self.readSome(from: stream) else { return false }
        return answer.uppercased().contains(mark)
    }

    /// Whether a first line is the protocol's greeting.
    static func isGreeting(_ line: String, for mailProtocol: MailProtocol) -> Bool {
        let text = line.uppercased()
        return switch mailProtocol {
        case .imap: text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH")
        case .pop3: text.hasPrefix("+OK")
        case .smtp: text.hasPrefix("220")
        }
    }

    /// The server's greeting: its first line, or for SMTP every line of it ("220-…" lines up to "220 …").
    private static func readGreeting(from stream: any ByteStream, for mailProtocol: MailProtocol) async throws -> String {
        var received = Data()
        while received.count < 8192 {
            let chunk = try await stream.read()
            if chunk.isEmpty { break }
            received.append(chunk)
            let text = String(decoding: received, as: UTF8.self)
            guard text.hasSuffix("\r\n") || text.hasSuffix("\n") else { continue }
            guard mailProtocol == .smtp else { return text }
            let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if !last.hasPrefix("220-") { return text }
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// What the server answers to one question, up to its last line (servers may send several).
    private static func readSome(from stream: any ByteStream) async throws -> String {
        var received = Data()
        while received.count < 16_384 {
            let chunk = try await stream.read()
            if chunk.isEmpty { break }
            received.append(chunk)
            let text = String(decoding: received, as: UTF8.self)
            let lines = text.split(separator: "\r\n", omittingEmptySubsequences: true)
            guard text.hasSuffix("\r\n"), let last = lines.last else { continue }
            // IMAP ends with the tagged reply, POP's CAPA with ".", SMTP's EHLO with "250 " (no dash).
            if last.hasPrefix("A1 ") || last == "." || last.hasPrefix("-ERR") || (last.count >= 4 && !last.dropFirst(3).hasPrefix("-")) {
                return text
            }
        }
        return String(decoding: received, as: UTF8.self)
    }
}

// MARK: The setup file

/// Reads the setup file a domain publishes (the autoconfig format, `clientConfig` version 1.1): its IMAP, POP and SMTP
/// servers, with encryption, that take a password, and the calendar and contacts servers it names.
enum MailSetupFile {
    struct Server {
        var type = ""
        var hostname = ""
        var port: Int?
        var socketType = ""
        var username = ""
        var authentications: [String] = []
        var serverURL = ""
    }

    static func read(_ data: Data, email: String) -> FoundMailSettings? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawClientConfig else { return nil }
        let incoming = reader.incoming.compactMap { settings(from: $0, email: email) }
        let imap = incoming.first { $0.mailProtocol == .imap }
        let pop = incoming.first { $0.mailProtocol == .pop3 }
        guard let first = imap ?? pop, let outgoing = reader.outgoing.compactMap({ settings(from: $0, email: email) }).first else {
            return nil
        }
        func url(_ servers: [Server]) -> URL? {
            servers.compactMap { URL(string: $0.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) }.first { $0.scheme == "https" }
        }
        return FoundMailSettings(incoming: first, otherIncoming: imap == nil ? nil : pop, outgoing: outgoing,
                                 calendarServer: url(reader.calendars), contactsServer: url(reader.addressBooks), source: .setupFile)
    }

    /// A server PMail can use: one of its kinds, encrypted, taking a password, at a plausible host name.
    static func settings(from server: Server, email: String) -> ServerSettings? {
        let mailProtocol: MailProtocol
        switch server.type.lowercased() {
        case "imap": mailProtocol = .imap
        case "pop3": mailProtocol = .pop3
        case "smtp": mailProtocol = .smtp
        default: return nil
        }
        let security: ConnectionSecurity
        switch server.socketType.uppercased() {
        case "SSL", "TLS": security = .tls
        case "STARTTLS": security = .startTLS
        default: return nil
        }
        let methods = server.authentications.map { $0.lowercased() }
        guard methods.isEmpty || methods.contains(where: { $0.hasPrefix("password") }) else { return nil }
        let host = filled(server.hostname, email: email)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return nil }
        let username = filled(server.username, email: email)
        return ServerSettings(mailProtocol: mailProtocol, host: host, port: server.port, security: security,
                              username: username.isEmpty ? email : username)
    }

    /// A value with the address's parts in place of %EMAILADDRESS%, %EMAILLOCALPART% and %EMAILDOMAIN%.
    static func filled(_ template: String, email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let domain = ServerPresets.domain(of: email) ?? ""
        return template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
            .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
            .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var sawClientConfig = false
        var incoming: [Server] = []
        var outgoing: [Server] = []
        var addressBooks: [Server] = []
        var calendars: [Server] = []
        private var current: Server?
        private var currentKind = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "clientConfig": sawClientConfig = true
            case "incomingServer", "outgoingServer", "addressBook", "calendar":
                current = Server(type: attributes["type"] ?? "")
                currentKind = name
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if name == currentKind, let server = current {
                switch name {
                case "incomingServer": incoming.append(server)
                case "outgoingServer": outgoing.append(server)
                case "addressBook": addressBooks.append(server)
                default: calendars.append(server)
                }
                current = nil
                currentKind = ""
                return
            }
            guard current != nil else { return }
            switch name {
            case "hostname": current?.hostname = value
            case "port": current?.port = Int(value)
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "authentication": current?.authentications.append(value)
            case "serverURL": current?.serverURL = value
            default: break
            }
        }
    }
}
