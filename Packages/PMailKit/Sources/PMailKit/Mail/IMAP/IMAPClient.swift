import Foundation
import os

/// An IMAP4rev1 client (RFC 3501, with the extensions mail servers commonly offer): it connects, protects the
/// connection, signs in, and runs commands one at a time on a single connection.
///
/// Mailbox names go in and come out decoded ("Projects/Café"); the client spells them in modified UTF-7 for the
/// server. Commands on messages work in the mailbox chosen with `select(_:readOnly:)`. Untagged responses the
/// server sends unasked (new mail, another device's flag changes) are taken in along the way and never derail a
/// command. Failures are `PMailError`s: a NO or BAD is `.server`, a broken connection `.connectionFailed`, after
/// which the client is disconnected and `connect` has to be called again.
public actor IMAPClient {
    /// What a finished command left behind: its tagged status, and the untagged responses that came with it.
    struct CommandResult {
        var status: IMAPStatusResponse
        var untagged: [IMAPUntaggedResponse]
    }

    /// Where an IDLE is up to.
    private struct IdleSession {
        var number: Int
        /// The server answered "+", so DONE may be sent.
        var isIdling = false
        /// New mail, the deadline or cancellation asked for the IDLE to end.
        var endRequested = false
        var doneSent = false
        var sawChange = false
        /// Drops the connection if the server doesn't finish the IDLE once asked to.
        var graceTimer: Task<Void, Never>?
    }

    /// What the client logs (debug level, mailbox names kept private): what LIST found, for diagnosing a server.
    static let log = Logger(subsystem: "com.pugglesoft.PMail", category: "IMAP")

    /// The fetch items for a message list row: flags, dates, size, envelope, structure, the threading headers, and the
    /// headers that say whether it came from a list or a machine (for sorting the inbox into categories).
    public static let summaryItems = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE "
        + "BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-ID PRECEDENCE AUTO-SUBMITTED)]"

    private let connector: any ByteStreamConnector
    private var connection: LineConnection?
    private var security: ConnectionSecurity = .tls
    private var isEncrypted = false
    private var tagNumber = 0
    private var byeText: String?
    private var sawCapabilities = false
    /// How the server spelled each mailbox in its last LIST, for servers that don't round-trip modified UTF-7.
    private var serverNames: [String: String] = [:]
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The IDLE in progress, if any.
    private var idleSession: IdleSession?
    /// How many IDLEs have run, so a late timer can tell whether its IDLE is still the one in progress.
    private var idleCount = 0
    /// How many seconds the server gets to finish an IDLE once asked to before its connection is given up for dead.
    private(set) var idleEndGrace: TimeInterval = 15

    /// What the server says it can do, in capitals ("IMAP4REV1", "AUTH=PLAIN", "MOVE").
    public private(set) var capabilities: Set<String> = []
    public private(set) var isAuthenticated = false
    /// The mailbox commands work in, with its message count kept up to date.
    public private(set) var selectedMailbox: IMAPSelectedMailbox?
    /// Messages from `[ALERT]` responses, which the server wants shown to the person (the latest 20).
    public private(set) var alerts: [String] = []

    public init(connector: any ByteStreamConnector = URLSessionConnector()) {
        self.connector = connector
    }

    /// Whether the client has a connection (it may still find out it has dropped on the next command).
    public var isConnected: Bool { connection != nil }

    public func hasCapability(_ name: String) -> Bool { capabilities.contains(name.uppercased()) }

    // MARK: Connecting and signing in

    /// Connects and reads the server's greeting. With `.startTLS` the connection is upgraded before anything else
    /// happens, and a server that doesn't offer STARTTLS is refused rather than used unprotected.
    public func connect(host: String, port: Int, security: ConnectionSecurity) async throws {
        try await exclusively {
            self.disconnectNow()
            let stream: any ByteStream
            do {
                stream = try await self.connector.connect(host: host, port: port, security: security)
            } catch let error as PMailError {
                throw error
            } catch {
                throw PMailError.connectionFailed(error.localizedDescription)
            }
            self.connection = LineConnection(stream: stream)
            self.security = security
            self.isEncrypted = security == .tls
            do {
                try await self.greet()
            } catch {
                self.disconnectNow()
                throw error
            }
        }
    }

    private func greet() async throws {
        guard let connection else { throw PMailError.connectionFailed("") }
        let greeting: IMAPResponse
        do {
            greeting = try await readResponse(from: connection)
        } catch {
            throw translate(error)
        }
        guard case let .untagged(.condition(status)) = greeting else {
            throw PMailError.protocolError("the server didn’t greet PMail the way an IMAP server does")
        }
        switch status.status {
        case .bye: throw PMailError.connectionFailed(status.text)
        case .preauth: isAuthenticated = true
        case .ok: break
        case .no, .bad: throw PMailError.server(status.text)
        }
        if case let .capability(names)? = status.code { setCapabilities(names) }
        if security == .startTLS {
            // A server that signs PMail in before encryption could be anyone in between.
            if isAuthenticated {
                throw PMailError.notSupported("The server skipped signing in, so the connection can’t be protected.")
            }
            if capabilities.isEmpty { try await refreshCapabilities() }
            guard capabilities.contains("STARTTLS") else {
                throw PMailError.notSupported("This server doesn’t offer STARTTLS, so PMail won’t send your password to it.")
            }
            let result = try await run([.text("STARTTLS")])
            guard result.status.status == .ok else { throw PMailError.server(result.status.text) }
            do {
                try await connection.startTLS()
            } catch {
                let failure = translate(error)
                disconnectNow()
                throw failure
            }
            isEncrypted = true
            // What the server said before encryption can't be trusted (RFC 3501 §6.2.1).
            capabilities = []
            try await refreshCapabilities()
        } else if capabilities.isEmpty {
            try await refreshCapabilities()
        }
    }

    /// Signs in: a password with AUTHENTICATE PLAIN (or LOGIN when PLAIN isn't offered), a token with XOAUTH2. A
    /// token the server turns down is invalidated and a fresh one tried once. A password is never sent over an
    /// unprotected connection unless the account's security is `.none`.
    public func signIn(_ credential: Credential) async throws {
        try await exclusively {
            guard self.connection != nil else { throw PMailError.connectionFailed("the connection to the server was closed") }
            if self.isAuthenticated { return }
            guard self.isEncrypted || self.security == .none else {
                throw PMailError.notSupported("The connection isn’t protected, so PMail won’t send your password.")
            }
            self.sawCapabilities = false
            switch credential {
            case let .password(username, password):
                if self.capabilities.contains("AUTH=PLAIN") {
                    let result = try await self.authenticate(mechanism: "PLAIN",
                                                             initialResponse: SASL.plain(username: username, password: password))
                    try self.checkSignIn(result)
                } else if !self.capabilities.contains("LOGINDISABLED") {
                    let result = try await self.run([.text("LOGIN "), IMAPArgument.string(username), .text(" "),
                                                     IMAPArgument.secret(password)])
                    try self.checkSignIn(result)
                } else {
                    throw PMailError.notSupported("This server doesn’t accept a password on this connection.")
                }
            case let .oauth(username, tokens):
                try await self.signIn(username: username, tokens: tokens)
            }
            self.isAuthenticated = true
            // Servers often offer more once someone has signed in; most say so in the sign-in's answer.
            if !self.sawCapabilities { try await self.refreshCapabilities() }
        }
    }

    private func signIn(username: String, tokens: any AccessTokenProvider) async throws {
        var attempt = 0
        while true {
            let token: String
            do {
                token = try await tokens.accessToken()
            } catch let error as PMailError {
                throw error
            } catch {
                throw PMailError.authenticationFailed(error.localizedDescription)
            }
            let result = try await authenticate(mechanism: "XOAUTH2",
                                                initialResponse: SASL.xoauth2(username: username, accessToken: token))
            if result.status.status == .ok { return }
            guard attempt == 0 else { throw PMailError.authenticationFailed(result.status.text) }
            // The token may have run out or been revoked: get a fresh one and try once more.
            attempt += 1
            await tokens.invalidateAccessToken()
        }
    }

    /// Runs AUTHENTICATE, sending the initial response inline when the server offers SASL-IR, else after its `+`.
    private func authenticate(mechanism: String, initialResponse: String) async throws -> CommandResult {
        let inline = capabilities.contains("SASL-IR")
        var sentResponse = inline
        let parts: [IMAPCommandPart] = inline
            ? [.text("AUTHENTICATE \(mechanism) "), .secret(initialResponse, shownAs: "…")]
            : [.text("AUTHENTICATE \(mechanism)")]
        return try await run(parts) { _ in
            if !sentResponse {
                sentResponse = true
                return .secret(initialResponse, shownAs: "…")
            }
            // A further challenge explains a failure (XOAUTH2 sends its error this way): an empty line acknowledges
            // it, and "*" cancels any other mechanism.
            return .text(mechanism == "XOAUTH2" ? "" : "*")
        }
    }

    private func checkSignIn(_ result: CommandResult) throws {
        guard result.status.status == .ok else { throw PMailError.authenticationFailed(result.status.text) }
    }

    /// Asks the server what it can do.
    @discardableResult
    public func capability() async throws -> Set<String> {
        try await exclusively {
            try await self.refreshCapabilities()
            return self.capabilities
        }
    }

    private func refreshCapabilities() async throws {
        try check(try await run([.text("CAPABILITY")]))
    }

    // MARK: Mailboxes

    /// Every mailbox, with special-use attributes (\Sent, \Trash…) when the server offers them.
    public func listMailboxes() async throws -> [IMAPMailbox] {
        try await exclusively {
            // Which mailboxes there are always comes from the plain LIST: a server can answer the extended form OK
            // and list nothing at all.
            let result = try await self.run([.text("LIST \"\" \"*\"")])
            try self.check(result)
            var seen = Set<String>()
            var mailboxes: [IMAPMailbox] = []
            for case let .list(mailbox) in result.untagged where seen.insert(mailbox.name).inserted {
                mailboxes.append(mailbox)
            }
            // Most servers with special-use folders (RFC 6154) mark them in the plain LIST. One that offers them but
            // left the marks out is asked for them too; its answer adds marks and folders, and never takes any away.
            let hasRoles = mailboxes.contains { !$0.isInbox && $0.specialUseRole != nil }
            if !hasRoles, self.capabilities.contains("SPECIAL-USE") {
                let extended = try await self.run([.text("LIST \"\" \"*\" RETURN (SPECIAL-USE)")])
                if extended.status.status == .ok {
                    for case let .list(mailbox) in extended.untagged {
                        if let index = mailboxes.firstIndex(where: { $0.name == mailbox.name }) {
                            mailboxes[index].attributes += mailbox.attributes.filter { !mailboxes[index].hasAttribute($0) }
                        } else if seen.insert(mailbox.name).inserted {
                            mailboxes.append(mailbox)
                        }
                    }
                }
            }
            for mailbox in mailboxes { self.serverNames[mailbox.name] = mailbox.rawName }
            Self.log.debug("""
                LIST found \(mailboxes.count) mailboxes on a server offering \(self.capabilities.sorted().joined(separator: " "), privacy: .public): \
                \(mailboxes.map { ([$0.name] + $0.attributes).joined(separator: " ") }.joined(separator: "; "), privacy: .private)
                """)
            return mailboxes
        }
    }

    /// How many messages a mailbox has, how many are unread, and its UIDNEXT and UIDVALIDITY, or just the `items` asked
    /// for ("UIDNEXT", "UNSEEN"…).
    public func status(_ mailbox: String,
                       items: [String] = ["MESSAGES", "UNSEEN", "UIDNEXT", "UIDVALIDITY"]) async throws -> IMAPMailboxStatus {
        // Item names are plain words; anything else would let a caller slip more onto the command line.
        let names = items.filter { item in
            !item.isEmpty && item.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0)
                || ("0"..."9").contains($0) || $0 == "-" }
        }
        let asked = names.isEmpty ? "MESSAGES UNSEEN UIDNEXT UIDVALIDITY" : names.joined(separator: " ")
        return try await exclusively {
            let result = try await self.run([.text("STATUS "), self.mailboxArgument(mailbox), .text(" (\(asked))")])
            try self.check(result)
            var answers: [(name: String, attributes: [String: Int])] = []
            for case let .status(name, attributes) in result.untagged { answers.append((name, attributes)) }
            let attributes = (answers.first { $0.name == mailbox } ?? answers.first)?.attributes ?? [:]
            return IMAPMailboxStatus(mailbox: mailbox, messages: attributes["MESSAGES"], unseen: attributes["UNSEEN"],
                                     uidNext: attributes["UIDNEXT"].flatMap { UInt32(exactly: $0) },
                                     uidValidity: attributes["UIDVALIDITY"].flatMap { UInt32(exactly: $0) })
        }
    }

    /// Opens a mailbox for the commands that follow: SELECT, or EXAMINE when `readOnly`.
    @discardableResult
    public func select(_ mailbox: String, readOnly: Bool = false) async throws -> IMAPSelectedMailbox {
        try await exclusively {
            // A failed SELECT leaves no mailbox selected.
            self.selectedMailbox = nil
            let result = try await self.run([.text(readOnly ? "EXAMINE " : "SELECT "), self.mailboxArgument(mailbox)])
            try self.check(result)
            var selected = IMAPSelectedMailbox(name: mailbox, isReadOnly: readOnly)
            for response in result.untagged {
                switch response {
                case let .exists(count): selected.exists = count
                case let .recent(count): selected.recent = count
                case let .flags(flags): selected.flags = flags
                case let .condition(status):
                    switch status.code {
                    case let .uidValidity(value)?: selected.uidValidity = value
                    case let .uidNext(value)?: selected.uidNext = value
                    case let .permanentFlags(flags)?: selected.permanentFlags = flags
                    default: break
                    }
                default: break
                }
            }
            if case .readOnly? = result.status.code { selected.isReadOnly = true }
            self.selectedMailbox = selected
            return selected
        }
    }

    // MARK: Messages in the selected mailbox

    /// The UIDs of the messages that match every key. Strings beyond ASCII go as literals with `CHARSET UTF-8`.
    public func uidSearch(_ keys: [IMAPSearchKey]) async throws -> [UInt32] {
        try await exclusively {
            var builder = IMAPCommandBuilder()
            for (index, key) in (keys.isEmpty ? [.all] : keys).enumerated() {
                if index > 0 { builder.text(" ") }
                key.write(into: &builder)
            }
            var parts: [IMAPCommandPart] = [.text(builder.hasNonASCII ? "UID SEARCH CHARSET UTF-8 " : "UID SEARCH ")]
            parts += builder.parts
            let result = try await self.run(parts)
            try self.check(result)
            var uids: [UInt32] = []
            for case let .search(found) in result.untagged { uids += found }
            return uids
        }
    }

    /// Fetches items (`"UID FLAGS ENVELOPE"`) for messages, one answer per message in the order they came. Answers
    /// a server splits are joined, and unasked-for updates about other messages are left out.
    public func uidFetch(_ uids: [UInt32], items: String) async throws -> [IMAPFetchResponse] {
        let wanted = Set(uids)
        guard !wanted.isEmpty else { return [] }
        return try await exclusively {
            let result = try await self.run([.text("UID FETCH \(IMAPSequenceSet.string(uids)) (\(items))")])
            try self.check(result)
            var byUID: [UInt32: IMAPFetchResponse] = [:]
            var order: [UInt32] = []
            for case let .fetch(response) in result.untagged {
                guard let uid = response.uid, wanted.contains(uid) else { continue }
                if byUID[uid] == nil {
                    order.append(uid)
                    byUID[uid] = response
                } else {
                    byUID[uid]?.merge(response)
                }
            }
            return order.compactMap { byUID[$0] }
        }
    }

    /// What a message list shows for each message (`summaryItems`, plus the server's conversation ID when it
    /// offers X-GM-EXT-1), optionally with the whole message too.
    public func fetchSummaries(_ uids: [UInt32], withMessage: Bool = false) async throws -> [IMAPFetchResponse] {
        var items = Self.summaryItems
        if capabilities.contains("X-GM-EXT-1") { items += " X-GM-THRID" }
        if withMessage { items += " BODY.PEEK[]" }
        return try await uidFetch(uids, items: items)
    }

    /// One body section of each message, or just its first `length` bytes, without marking anything read.
    public func fetchSection(_ section: String, of uids: [UInt32], length: Int? = nil) async throws -> [IMAPFetchResponse] {
        try await uidFetch(uids, items: "UID BODY.PEEK[\(section)]" + (length.map { "<0.\($0)>" } ?? ""))
    }

    /// Whole messages and their flags, without marking them read.
    public func fetchMessages(_ uids: [UInt32]) async throws -> [IMAPFetchResponse] {
        try await uidFetch(uids, items: "UID FLAGS BODY.PEEK[]")
    }

    /// Adds or removes flags ("\Seen", "\Flagged") without asking for the new flags back.
    public func uidStore(_ uids: [UInt32], adding: Bool, flags: [String]) async throws {
        guard !uids.isEmpty, !flags.isEmpty else { return }
        try await exclusively {
            try await self.store(uids, adding: adding, flags: flags)
        }
    }

    /// Copies messages to another mailbox; returns the COPYUID code when the server gives one.
    @discardableResult
    public func uidCopy(_ uids: [UInt32], to mailbox: String) async throws -> IMAPResponseCode? {
        guard !uids.isEmpty else { return nil }
        return try await exclusively {
            let result = try await self.run([.text("UID COPY \(IMAPSequenceSet.string(uids)) "), self.mailboxArgument(mailbox)])
            try self.check(result)
            return result.status.code
        }
    }

    /// Moves messages to another mailbox: with MOVE when the server offers it, else by copying, marking the
    /// originals deleted and expunging them.
    public func uidMove(_ uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await exclusively {
            let set = IMAPSequenceSet.string(uids)
            if self.capabilities.contains("MOVE") {
                try self.check(try await self.run([.text("UID MOVE \(set) "), self.mailboxArgument(mailbox)]))
            } else {
                try self.check(try await self.run([.text("UID COPY \(set) "), self.mailboxArgument(mailbox)]))
                try await self.store(uids, adding: true, flags: ["\\Deleted"])
                try await self.expungeNow(uids)
            }
        }
    }

    /// Deletes messages for good: marks them \Deleted and expunges them (just them with UIDPLUS; without it,
    /// EXPUNGE removes every message marked deleted).
    public func deleteMessages(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await exclusively {
            try await self.store(uids, adding: true, flags: ["\\Deleted"])
            try await self.expungeNow(uids)
        }
    }

    private func store(_ uids: [UInt32], adding: Bool, flags: [String]) async throws {
        let change = (adding ? "+" : "-") + "FLAGS.SILENT (\(flags.joined(separator: " ")))"
        let command = "UID STORE \(IMAPSequenceSet.string(uids)) \(change)"
        try check(try await run([.text(command)]))
    }

    private func expungeNow(_ uids: [UInt32]) async throws {
        if capabilities.contains("UIDPLUS") {
            try check(try await run([.text("UID EXPUNGE \(IMAPSequenceSet.string(uids))")]))
        } else {
            try check(try await run([.text("EXPUNGE")]))
        }
    }

    /// Removes every message marked \Deleted from the selected mailbox.
    public func expunge() async throws {
        try await exclusively { try self.check(try await self.run([.text("EXPUNGE")])) }
    }

    /// Adds a message to a mailbox, with flags ("\Seen", "\Draft"). Returns where it went when the server says
    /// (APPENDUID).
    @discardableResult
    public func append(_ message: Data, to mailbox: String, flags: [String] = [],
                       date: Date? = nil) async throws -> IMAPAppendResult? {
        try await exclusively {
            var parts: [IMAPCommandPart] = [.text("APPEND "), self.mailboxArgument(mailbox)]
            if !flags.isEmpty { parts.append(.text(" (\(flags.joined(separator: " ")))")) }
            if let date { parts.append(.text(" \"\(IMAPDate.format(date))\"")) }
            parts.append(.text(" "))
            parts.append(.literal(message))
            let result = try await self.run(parts)
            try self.check(result)
            if case let .appendUID(uidValidity, uid)? = result.status.code {
                return IMAPAppendResult(uidValidity: uidValidity, uid: uid)
            }
            return nil
        }
    }

    /// Closes the selected mailbox (expunging messages marked deleted).
    public func closeMailbox() async throws {
        try await exclusively {
            try self.check(try await self.run([.text("CLOSE")]))
            self.selectedMailbox = nil
        }
    }

    /// Does nothing, which gives the server a chance to report new mail and changes. Returns the untagged responses
    /// that came with it (EXISTS, EXPUNGE, FETCH with new flags…).
    @discardableResult
    public func noop() async throws -> [IMAPUntaggedResponse] {
        try await exclusively {
            let result = try await self.run([.text("NOOP")])
            try self.check(result)
            return result.untagged
        }
    }

    /// Signs out politely and disconnects. Never fails: a connection that's already gone is simply closed.
    public func logout() async {
        guard connection != nil else { return }
        _ = try? await exclusively { _ = try await self.run([.text("LOGOUT")]) }
        disconnectNow()
    }

    /// Drops the connection at once.
    public func disconnect() {
        disconnectNow()
    }

    // MARK: Waiting for changes

    /// Listens with IDLE (RFC 2177) until `deadline` for the server to report a change to the selected mailbox. Returns
    /// true as soon as new mail, an expunge or a flag change arrives (an untagged EXISTS, EXPUNGE or FETCH), and false
    /// when the deadline passes or the server ends the IDLE on its own. Either way the IDLE is ended with DONE and its
    /// tagged answer read, so the connection is ready for the next command.
    ///
    /// Cancelling the task ends the IDLE the same way and throws `.cancelled`. A server that hasn't finished the IDLE
    /// `idleEndGrace` seconds after being asked to has its connection dropped; the answer is still returned when it was
    /// already known (the deadline had passed, or a change had arrived), and the next command finds the client
    /// disconnected.
    public func idle(until deadline: ContinuousClock.Instant) async throws -> Bool {
        try await exclusively {
            if Task.isCancelled { throw PMailError.cancelled }
            guard let connection = self.connection else {
                throw PMailError.connectionFailed("the connection to the server was closed")
            }
            guard self.capabilities.contains("IDLE") else {
                throw PMailError.notSupported("This server can’t tell PMail about changes as they happen.")
            }
            guard ContinuousClock.now < deadline else { return false }
            self.tagNumber += 1
            let tag = "A\(self.tagNumber)"
            self.idleCount += 1
            let number = self.idleCount
            self.idleSession = IdleSession(number: number)
            let timer = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                await self.endIdle(number)
            }
            defer {
                timer.cancel()
                self.idleSession?.graceTimer?.cancel()
                self.idleSession = nil
            }
            let refusal: String?
            do {
                refusal = try await withTaskCancellationHandler {
                    try await self.runIdle(tag: tag, number: number, on: connection)
                } onCancel: {
                    Task { await self.endIdle(number) }
                }
            } catch {
                let failure = self.translate(error)
                let session = self.idleSession
                self.disconnectNow()
                if Task.isCancelled { throw PMailError.cancelled }
                if let session, session.endRequested { return session.sawChange }
                throw failure
            }
            if let refusal { throw PMailError.server(refusal) }
            if Task.isCancelled { throw PMailError.cancelled }
            return self.idleSession?.sawChange ?? false
        }
    }

    /// Sends IDLE and reads until its tagged answer. Returns the server's reason when it refused to IDLE.
    private func runIdle(tag: String, number: Int, on connection: LineConnection) async throws -> String? {
        try await connection.writeLine("\(tag) IDLE")
        while true {
            switch try await readResponse(from: connection) {
            case let .untagged(response):
                note(response)
                if Self.isChange(response) {
                    idleSession?.sawChange = true
                    await endIdle(number)
                }
            case .continuation:
                idleSession?.isIdling = true
                if idleSession?.endRequested == true { await sendDone(number) }
            case let .tagged(responseTag, status):
                guard responseTag == tag else { continue }
                if status.status != .ok, idleSession?.isIdling != true { return status.text }
                return nil
            }
        }
    }

    /// Asks for an IDLE to end: DONE straight away if the server is idling, else as soon as it says it is. If the
    /// server hasn't finished `idleEndGrace` seconds later, the connection has likely died quietly and is dropped.
    private func endIdle(_ number: Int) async {
        guard var session = idleSession, session.number == number, !session.endRequested else { return }
        session.endRequested = true
        let grace = idleEndGrace
        session.graceTimer = Task {
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            self.giveUpOnIdle(number)
        }
        idleSession = session
        if session.isIdling { await sendDone(number) }
    }

    private func sendDone(_ number: Int) async {
        guard let session = idleSession, session.number == number, !session.doneSent, let connection else { return }
        idleSession?.doneSent = true
        // A write that fails shows up as a failed read in the IDLE.
        try? await connection.writeLine("DONE")
    }

    private func giveUpOnIdle(_ number: Int) {
        guard idleSession?.number == number else { return }
        connection?.stream.close()
    }

    /// Whether an untagged response during IDLE says the mailbox changed: new mail (or a new count), an expunge, or
    /// changed flags.
    static func isChange(_ response: IMAPUntaggedResponse) -> Bool {
        switch response {
        case .exists, .expunge, .fetch: true
        default: false
        }
    }

    /// Sets how long the server gets to finish an IDLE, for tests.
    func setIdleEndGrace(_ seconds: TimeInterval) {
        idleEndGrace = max(0, seconds)
    }

    // MARK: Running commands

    /// Writes a command and reads until its tagged answer, taking in every untagged response along the way.
    /// Continuation requests go to `onContinuation`, which returns the line to answer with.
    private func run(_ parts: [IMAPCommandPart],
                     onContinuation: (String) async throws -> IMAPCommandPart? = { _ in nil }) async throws -> CommandResult {
        guard let connection else { throw PMailError.connectionFailed("the connection to the server was closed") }
        tagNumber += 1
        let tag = "A\(tagNumber)"
        var untagged: [IMAPUntaggedResponse] = []
        do {
            if let refusal = try await send(parts, tag: tag, on: connection, untagged: &untagged) {
                return CommandResult(status: refusal, untagged: untagged)
            }
            while true {
                switch try await readResponse(from: connection) {
                case let .untagged(response):
                    note(response)
                    untagged.append(response)
                case let .continuation(text):
                    guard let reply = try await onContinuation(text) else {
                        throw PMailError.protocolError("the server asked for more than PMail had to send")
                    }
                    try await writeReply(reply, on: connection)
                case let .tagged(responseTag, status):
                    guard responseTag == tag else { continue }
                    if case let .capability(names)? = status.code { setCapabilities(names) }
                    return CommandResult(status: status, untagged: untagged)
                }
            }
        } catch {
            let failure = translate(error)
            disconnectNow()
            throw failure
        }
    }

    /// Writes a command, stopping at each synchronizing literal for the server's go-ahead. Returns the tagged
    /// answer if the server refused before the command was complete.
    private func send(_ parts: [IMAPCommandPart], tag: String, on connection: LineConnection,
                      untagged: inout [IMAPUntaggedResponse]) async throws -> IMAPStatusResponse? {
        var line = tag + " "
        var shown = line
        var isSecret = false
        for part in parts {
            switch part {
            case let .text(text):
                line += text
                shown += text
            case let .secret(text, placeholder):
                line += text
                shown += placeholder
                isSecret = true
            case let .literal(data), let .secretLiteral(data):
                let waits = !canSendLiteralAtOnce(data.count)
                let marker = "{\(data.count)\(waits ? "" : "+")}"
                try await writeLine(line + marker, shown: isSecret ? shown + marker : nil, on: connection)
                if waits, let refusal = try await waitForGoAhead(tag: tag, on: connection, untagged: &untagged) {
                    return refusal
                }
                if case .secretLiteral = part {
                    try await connection.stream.write(data)  // Straight to the stream, so it stays out of transcripts.
                } else {
                    try await connection.write(data)
                }
                line = ""
                shown = ""
                isSecret = false
            }
        }
        try await writeLine(line, shown: isSecret ? shown : nil, on: connection)
        return nil
    }

    /// Whether a literal can follow its `{n+}` at once (LITERAL+, or LITERAL- for small ones) instead of waiting
    /// for the server's `+`.
    private func canSendLiteralAtOnce(_ count: Int) -> Bool {
        capabilities.contains("LITERAL+") || (capabilities.contains("LITERAL-") && count <= 4096)
    }

    private func waitForGoAhead(tag: String, on connection: LineConnection,
                                untagged: inout [IMAPUntaggedResponse]) async throws -> IMAPStatusResponse? {
        while true {
            switch try await readResponse(from: connection) {
            case .continuation:
                return nil
            case let .untagged(response):
                note(response)
                untagged.append(response)
            case let .tagged(responseTag, status):
                if responseTag == tag { return status }
            }
        }
    }

    private func writeLine(_ line: String, shown: String?, on connection: LineConnection) async throws {
        if let shown {
            try await connection.writeSecretLine(line, shownAs: shown)
        } else {
            try await connection.writeLine(line)
        }
    }

    private func writeReply(_ reply: IMAPCommandPart, on connection: LineConnection) async throws {
        switch reply {
        case let .text(text): try await connection.writeLine(text)
        case let .secret(text, placeholder): try await connection.writeSecretLine(text, shownAs: placeholder)
        case let .literal(data): try await connection.write(data + Data("\r\n".utf8))
        case let .secretLiteral(data): try await connection.stream.write(data + Data("\r\n".utf8))
        }
    }

    private func readResponse(from connection: LineConnection) async throws -> IMAPResponse {
        try IMAPParser.parse(try await IMAPParser.readResponseData(from: connection))
    }

    /// Keeps track of what untagged responses say about the session.
    private func note(_ response: IMAPUntaggedResponse) {
        switch response {
        case let .capability(names):
            setCapabilities(names)
        case let .condition(status):
            if status.status == .bye { byeText = status.text.isEmpty ? "the server closed the connection" : status.text }
            if case let .capability(names)? = status.code { setCapabilities(names) }
            if case .alert? = status.code, !status.text.isEmpty { alerts = Array((alerts + [status.text]).suffix(20)) }
        case let .exists(count):
            selectedMailbox?.exists = count
        case .expunge:
            if let count = selectedMailbox?.exists, count > 0 { selectedMailbox?.exists = count - 1 }
        default:
            break
        }
    }

    private func setCapabilities(_ names: [String]) {
        capabilities = Set(names.map { $0.uppercased() })
        sawCapabilities = true
    }

    private func check(_ result: CommandResult) throws {
        guard result.status.status == .ok else { throw PMailError.server(result.status.text) }
    }

    private func mailboxArgument(_ name: String) -> IMAPCommandPart {
        IMAPArgument.string(serverNames[name] ?? IMAPMailboxName.encode(name))
    }

    /// The error to report for a failure mid-command: the server's goodbye, if it said one, for a dropped
    /// connection, and `connectionFailed` for anything that isn't already a `PMailError`.
    private func translate(_ error: Error) -> PMailError {
        guard let error = error as? PMailError else { return .connectionFailed(error.localizedDescription) }
        if case .connectionFailed = error, let byeText { return .connectionFailed(byeText) }
        return error
    }

    private func disconnectNow() {
        connection?.stream.close()
        connection = nil
        isAuthenticated = false
        isEncrypted = false
        selectedMailbox = nil
        capabilities = []
        tagNumber = 0
        byeText = nil
    }

    /// Runs `body` with no other command in flight, so commands from different tasks never interleave.
    private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        defer {
            if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
