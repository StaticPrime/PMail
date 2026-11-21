import Foundation

/// Sends mail through an SMTP server (RFC 5321). Each send is a session of its own: connect, say hello, upgrade with
/// STARTTLS when the settings ask for it, sign in with a password or an OAuth token, hand over the message, and quit.
///
/// The client introduces itself as `[127.0.0.1]` rather than the computer's name, so messages don't carry it.
public actor SMTPClient {
    public let settings: ServerSettings
    private let credential: Credential
    private let connector: any ByteStreamConnector
    /// The last session's commands and replies, with passwords and tokens left out, for diagnosing a failed send.
    public private(set) var lastTranscript: [String] = []

    public init(settings: ServerSettings, credential: Credential, connector: any ByteStreamConnector = URLSessionConnector()) {
        self.settings = settings
        self.credential = credential
        self.connector = connector
    }

    /// Sends `raw` (a complete message) from `sender` to every address in `recipients`. Fails, naming the address,
    /// if the server refuses any recipient; nothing is sent then.
    public func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {
        let sender = try Self.envelopeAddress(sender)
        var seen = Set<String>()
        var envelope: [String] = []
        for recipient in recipients {
            let address = try Self.envelopeAddress(recipient)
            if seen.insert(address.lowercased()).inserted { envelope.append(address) }
        }
        guard !envelope.isEmpty else { throw PMailError.server("The message has no recipients.") }
        try await runSession(.deliver(raw, sender: sender, recipients: envelope))
    }

    /// Connects and signs in, then signs off, to check the settings when an account is added.
    public func checkSignIn() async throws {
        try await runSession(.signInOnly)
    }

    // MARK: Sessions

    private enum Work {
        case deliver(Data, sender: String, recipients: [String])
        case signInOnly
    }

    /// Thrown inside a session when the server turns an OAuth token down the first time, to try once more with a
    /// fresh token.
    private struct TokenRejected: Error {}

    private func runSession(_ work: Work) async throws {
        var attempt = 1
        while true {
            let connection = try await openConnection()
            await connection.startTranscript()
            do {
                let capabilities = try await greetAndSignIn(connection, attempt: attempt)
                if case let .deliver(raw, sender, recipients) = work {
                    try await deliver(raw, from: sender, to: recipients, capabilities: capabilities, over: connection)
                }
                await quit(connection)
                lastTranscript = await connection.transcript ?? []
                await connection.close()
                return
            } catch is TokenRejected {
                lastTranscript = await connection.transcript ?? []
                await connection.close()
                if case let .oauth(_, tokens) = credential { await tokens.invalidateAccessToken() }
                attempt += 1
            } catch {
                let failure = Self.pmailError(error)
                lastTranscript = await connection.transcript ?? []
                switch failure {
                case .server, .authenticationFailed:
                    // The server is still listening, so say goodbye; after a broken connection there's no one to tell.
                    try? await connection.writeLine("QUIT")
                default:
                    break
                }
                await connection.close()
                throw failure
            }
        }
    }

    private func openConnection() async throws -> LineConnection {
        do {
            let stream = try await connector.connect(host: settings.host, port: settings.port, security: settings.security)
            return LineConnection(stream: stream)
        } catch {
            throw Self.pmailError(error)
        }
    }

    /// The greeting, EHLO, STARTTLS and sign-in. Returns what the server said it can do, after encryption.
    private func greetAndSignIn(_ connection: LineConnection, attempt: Int) async throws -> SMTPCapabilities {
        let greeting = try await readReply(connection)
        guard greeting.code == 220 else { throw Self.failure(greeting) }
        var capabilities = try await hello(connection)
        var isEncrypted = settings.security == .tls
        if settings.security == .startTLS {
            guard capabilities.has("STARTTLS") else {
                throw PMailError.connectionFailed("the server doesn’t offer a secure connection (STARTTLS)")
            }
            try await connection.writeLine("STARTTLS")
            let reply = try await readReply(connection)
            guard reply.code == 220 else { throw Self.failure(reply) }
            try await connection.startTLS()
            isEncrypted = true
            capabilities = try await hello(connection)
        }
        try await authenticate(connection, capabilities: capabilities, isEncrypted: isEncrypted, attempt: attempt)
        return capabilities
    }

    /// EHLO, falling back to HELO for servers too old to know it.
    private func hello(_ connection: LineConnection) async throws -> SMTPCapabilities {
        try await connection.writeLine("EHLO [127.0.0.1]")
        let reply = try await readReply(connection)
        if reply.code == 250 { return SMTPCapabilities(ehloLines: Array(reply.lines.dropFirst())) }
        guard (500...504).contains(reply.code) else { throw Self.failure(reply) }
        try await connection.writeLine("HELO [127.0.0.1]")
        let helo = try await readReply(connection)
        guard helo.code == 250 else { throw Self.failure(helo) }
        return SMTPCapabilities(ehloLines: [])
    }

    private func authenticate(_ connection: LineConnection, capabilities: SMTPCapabilities, isEncrypted: Bool,
                              attempt: Int) async throws {
        // A server that doesn't offer AUTH doesn't take a sign-in (a relay on a trusted network); if it wanted one
        // after all, MAIL FROM is refused with 530.
        guard let mechanisms = capabilities.authMechanisms else { return }
        guard isEncrypted || settings.security == .none else {
            throw PMailError.connectionFailed("the connection isn’t encrypted, so PMail won’t send the password over it")
        }
        switch credential {
        case let .password(username, password):
            if mechanisms.contains("PLAIN") || !mechanisms.contains("LOGIN") {
                try await connection.writeSecretLine("AUTH PLAIN " + SASL.plain(username: username, password: password),
                                                     shownAs: "AUTH PLAIN <hidden>")
                let reply = try await readReply(connection)
                guard reply.code == 235 else { throw Self.failure(reply, signingIn: true) }
            } else {
                let login = SASL.login(username: username, password: password)
                try await connection.writeLine("AUTH LOGIN")
                var reply = try await readReply(connection)
                guard reply.code == 334 else { throw Self.failure(reply, signingIn: true) }
                try await connection.writeSecretLine(login.username, shownAs: "<user name>")
                reply = try await readReply(connection)
                guard reply.code == 334 else { throw Self.failure(reply, signingIn: true) }
                try await connection.writeSecretLine(login.password, shownAs: "<password>")
                reply = try await readReply(connection)
                guard reply.code == 235 else { throw Self.failure(reply, signingIn: true) }
            }
        case let .oauth(username, tokens):
            let token: String
            do {
                token = try await tokens.accessToken()
            } catch {
                throw (error as? PMailError) ?? .authenticationFailed(error.localizedDescription)
            }
            try await connection.writeSecretLine("AUTH XOAUTH2 " + SASL.xoauth2(username: username, accessToken: token),
                                                 shownAs: "AUTH XOAUTH2 <hidden>")
            var reply = try await readReply(connection)
            if reply.code == 334 {
                // The server explained the failure in a challenge (base64 JSON); an empty line gets the final reply.
                try await connection.writeLine("")
                reply = try await readReply(connection)
            }
            if reply.code == 235 { return }
            if reply.code == 535, attempt == 1 { throw TokenRejected() }
            throw Self.failure(reply, signingIn: true)
        }
    }

    private func deliver(_ raw: Data, from sender: String, to recipients: [String], capabilities: SMTPCapabilities,
                         over connection: LineConnection) async throws {
        var command = "MAIL FROM:<\(sender)>"
        if let limit = capabilities.sizeLimit {
            if limit > 0, raw.count > limit {
                let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
                throw PMailError.server("The message is too large to send: this server takes messages up to \(size).")
            }
            command += " SIZE=\(raw.count)"
        }
        if capabilities.has("8BITMIME"), raw.contains(where: { $0 >= 0x80 }) { command += " BODY=8BITMIME" }
        if capabilities.has("SMTPUTF8"), !sender.allSatisfy(\.isASCII) || recipients.contains(where: { !$0.allSatisfy(\.isASCII) }) {
            command += " SMTPUTF8"
        }
        try await connection.writeLine(command)
        var reply = try await readReply(connection)
        guard reply.code == 250 else { throw Self.failure(reply) }

        for recipient in recipients {
            try await connection.writeLine("RCPT TO:<\(recipient)>")
            reply = try await readReply(connection)
            guard reply.code == 250 || reply.code == 251 || reply.code == 252 else {
                throw Self.recipientFailure(recipient, reply)
            }
        }

        try await connection.writeLine("DATA")
        reply = try await readReply(connection)
        guard reply.code == 354 else { throw Self.failure(reply) }
        try await connection.write(Self.dataBlock(raw))
        reply = try await readReply(connection)
        guard reply.code == 250 else { throw Self.failure(reply) }
    }

    /// QUIT, without minding how the server answers: the message has already gone.
    private func quit(_ connection: LineConnection) async {
        do {
            try await connection.writeLine("QUIT")
            _ = try await readReply(connection)
        } catch {
            // Nothing to do: the session is over either way.
        }
    }

    // MARK: Replies

    /// A reply, joined from its lines ("250-…" continues, "250 …" ends).
    struct Reply: Sendable {
        var code: Int
        var lines: [String]

        /// The server's words, without the enhanced status codes ("5.7.8") that some servers put first.
        var reason: String {
            lines.map { line -> String in
                let words = line.split(separator: " ", maxSplits: 1)
                guard let first = words.first, Self.isEnhancedCode(first) else { return line }
                return words.count > 1 ? String(words[1]) : ""
            }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        private static func isEnhancedCode(_ word: Substring) -> Bool {
            let pieces = word.split(separator: ".", omittingEmptySubsequences: false)
            return pieces.count == 3 && pieces.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }
        }
    }

    private func readReply(_ connection: LineConnection) async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try await connection.readLineString()
            guard line.utf8.count >= 3, let code = Int(line.prefix(3)), (100...599).contains(code) else {
                throw PMailError.protocolError("unexpected reply “\(line.prefix(80))”")
            }
            lines.append(String(line.dropFirst(4)))
            if line.dropFirst(3).first != "-" { return Reply(code: code, lines: lines) }
            guard lines.count < 1000 else { throw PMailError.protocolError("the server’s reply was too long") }
        }
    }

    // MARK: Helpers

    /// The SMTP DATA block: CRLF line ends, a dot doubled at the start of any line that has one, and the closing
    /// "." line.
    static func dataBlock(_ raw: Data) -> Data {
        var output = Data(capacity: raw.count + raw.count / 40 + 8)
        var atLineStart = true
        var previousWasCR = false
        for byte in raw {
            if byte == 0x0A {
                if !previousWasCR { output.append(0x0D) }
                output.append(0x0A)
                atLineStart = true
                previousWasCR = false
                continue
            }
            if previousWasCR {
                // A CR on its own ends a line too.
                output.append(0x0A)
                atLineStart = true
            }
            if byte == 0x0D {
                output.append(0x0D)
                previousWasCR = true
                continue
            }
            previousWasCR = false
            if atLineStart, byte == UInt8(ascii: ".") { output.append(UInt8(ascii: ".")) }
            output.append(byte)
            atLineStart = false
        }
        if previousWasCR {
            output.append(0x0A)
            atLineStart = true
        }
        if !atLineStart { output.append(contentsOf: [0x0D, 0x0A]) }
        output.append(contentsOf: Array(".\r\n".utf8))
        return output
    }

    /// An address for MAIL FROM or RCPT TO: trimmed, and refused if anything in it could break the command.
    private static func envelopeAddress(_ address: String) throws -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnsafe = trimmed.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F || $0 == "<" || $0 == ">" }
        guard !trimmed.isEmpty, !isUnsafe else { throw PMailError.server("“\(address)” isn’t a valid email address.") }
        return trimmed
    }

    static func failure(_ reply: Reply, signingIn: Bool = false) -> PMailError {
        let reason = reply.reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch reply.code {
        case 530, 534, 535:
            return .authenticationFailed(reason)
        case 400..<500:
            return .server((reason.isEmpty ? "The server is busy" : reason) + " — try again later")
        default:
            if signingIn, reply.code == 504 { return .authenticationFailed(reason) }
            return .server(reason.isEmpty ? "The server refused (error \(reply.code))." : reason)
        }
    }

    private static func recipientFailure(_ recipient: String, _ reply: Reply) -> PMailError {
        let reason = reply.reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch reply.code {
        case 530, 534, 535:
            return .authenticationFailed(reason)
        case 400..<500:
            let detail = reason.isEmpty ? "" : " (\(reason))"
            return .server("The server couldn’t take mail for \(recipient) right now\(detail) — try again later")
        default:
            return .server("The server refused \(recipient)\(reason.isEmpty ? "." : ": \(reason)")")
        }
    }

    private static func pmailError(_ error: Error) -> PMailError {
        if let error = error as? PMailError { return error }
        if error is CancellationError { return .cancelled }
        return .connectionFailed(error.localizedDescription)
    }
}

/// What an SMTP server said it can do in its EHLO reply.
struct SMTPCapabilities: Sendable, Hashable {
    /// Parameters by uppercased keyword ("SIZE": ["35882577"], "AUTH": ["PLAIN", "LOGIN"]).
    var keywords: [String: [String]] = [:]

    init(ehloLines: [String]) {
        for line in ehloLines {
            var words = line.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            // Old servers write "AUTH=LOGIN PLAIN".
            if let equals = words[0].firstIndex(of: "=") {
                let value = String(words[0][words[0].index(after: equals)...])
                words[0] = String(words[0][..<equals])
                if !value.isEmpty { words.insert(value, at: 1) }
            }
            let keyword = words[0].uppercased()
            keywords[keyword, default: []].append(contentsOf: words.dropFirst().map { $0.uppercased() })
        }
    }

    func has(_ keyword: String) -> Bool { keywords[keyword] != nil }

    /// The sign-in mechanisms offered, or nil when the server doesn't offer AUTH at all.
    var authMechanisms: Set<String>? { keywords["AUTH"].map(Set.init) }

    /// The largest message the server takes: nil when it doesn't say it checks sizes, 0 when it has no fixed limit.
    var sizeLimit: Int? {
        guard let parameters = keywords["SIZE"] else { return nil }
        return parameters.first.flatMap { Int($0) } ?? 0
    }
}
