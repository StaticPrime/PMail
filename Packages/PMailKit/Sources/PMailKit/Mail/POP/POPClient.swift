import Foundation

/// A message in a POP mailbox: its number in this session, and the unique ID that stays the same across sessions.
public struct POPMessageID: Sendable, Hashable {
    public var number: Int
    public var uid: String

    public init(number: Int, uid: String) {
        self.number = number
        self.uid = uid
    }
}

/// Reads a POP3 mailbox (RFC 1939): signs in, lists messages by their unique IDs, and downloads them.
///
/// `connect()` opens the connection, upgrades it with STLS when the settings ask for it, and signs in with USER and
/// PASS, AUTH PLAIN, or AUTH XOAUTH2 for OAuth accounts. The other calls connect first if needed. Deletions take
/// effect only when `quit()` ends the session cleanly.
public actor POPClient {
    public let settings: ServerSettings
    private let credential: Credential
    private let connector: any ByteStreamConnector
    private var connection: LineConnection?
    private var capabilitiesKnown = false
    /// What the server said it can do (CAPA), by uppercased keyword: "SASL": ["PLAIN", "XOAUTH2"], "UIDL": [].
    public private(set) var capabilities: [String: [String]] = [:]

    public init(settings: ServerSettings, credential: Credential, connector: any ByteStreamConnector = URLSessionConnector()) {
        self.settings = settings
        self.credential = credential
        self.connector = connector
    }

    /// Thrown when the server turns an OAuth token down the first time, to try once more with a fresh token.
    private struct TokenRejected: Error {}

    // MARK: Session

    /// Connects and signs in. Does nothing when already connected.
    public func connect() async throws {
        guard connection == nil else { return }
        var attempt = 1
        while true {
            let opened = try await open()
            do {
                try await signIn(opened, attempt: attempt)
                connection = opened
                return
            } catch is TokenRejected {
                await opened.close()
                if case let .oauth(_, tokens) = credential { await tokens.invalidateAccessToken() }
                attempt += 1
            } catch {
                await opened.close()
                throw Self.pmailError(error)
            }
        }
    }

    /// Ends the session with QUIT, which makes the server carry out deletions, and closes the connection.
    public func quit() async {
        guard let connection else { return }
        self.connection = nil
        do {
            try await connection.writeLine("QUIT")
            _ = try await readStatus(connection)
        } catch {
            // The session is over either way.
        }
        await connection.close()
    }

    /// Closes the connection without QUIT, so deletions in this session are forgotten.
    public func close() async {
        await connection?.close()
        connection = nil
    }

    /// The number of messages and their total size in octets.
    public func stat() async throws -> (count: Int, size: Int) {
        let text = try await command("STAT")
        let numbers = text.split(separator: " ").prefix(2).compactMap { Int($0) }
        guard numbers.count == 2 else { throw PMailError.protocolError("unexpected STAT answer “\(text.prefix(80))”") }
        return (numbers[0], numbers[1])
    }

    /// Every message's number and unique ID, oldest first.
    public func uidl() async throws -> [POPMessageID] {
        let lines: [Data]
        do {
            lines = try await multilineCommand("UIDL")
        } catch PMailError.server {
            throw PMailError.notSupported(
                "This POP server doesn’t give messages lasting IDs (UIDL), so PMail can’t tell which ones it already has.")
        }
        return lines.compactMap { line in
            let words = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 1)
            guard words.count == 2, let number = Int(words[0]), number > 0 else { return nil }
            let uid = words[1].trimmingCharacters(in: .whitespaces)
            return uid.isEmpty ? nil : POPMessageID(number: number, uid: uid)
        }
    }

    /// Every message's size in octets, by number.
    public func list() async throws -> [Int: Int] {
        var sizes: [Int: Int] = [:]
        for line in try await multilineCommand("LIST") {
            let numbers = String(decoding: line, as: UTF8.self).split(separator: " ").prefix(2).compactMap { Int($0) }
            if numbers.count == 2 { sizes[numbers[0]] = numbers[1] }
        }
        return sizes
    }

    /// A message's header and the first `lines` lines of its body.
    public func top(_ number: Int, lines: Int = 0) async throws -> Data {
        Self.joined(try await multilineCommand("TOP \(number) \(max(0, lines))"))
    }

    /// A whole message, with the dot-stuffing undone and CRLF line ends.
    public func retrieve(_ number: Int) async throws -> Data {
        Self.joined(try await multilineCommand("RETR \(number)"))
    }

    /// Marks a message for deletion when the session ends with `quit()`.
    public func delete(_ number: Int) async throws {
        _ = try await command("DELE \(number)")
    }

    // MARK: Connecting and signing in

    private func open() async throws -> LineConnection {
        let stream: any ByteStream
        do {
            stream = try await connector.connect(host: settings.host, port: settings.port, security: settings.security)
        } catch {
            throw Self.pmailError(error)
        }
        let opened = LineConnection(stream: stream)
        do {
            let greeting = try await readStatus(opened)
            guard greeting.ok else {
                throw PMailError.server(greeting.text.isEmpty ? "The server isn’t taking connections." : greeting.text)
            }
            try await loadCapabilities(opened)
            if settings.security == .startTLS {
                if capabilitiesKnown, capabilities["STLS"] == nil {
                    throw PMailError.connectionFailed("the server doesn’t offer a secure connection (STLS)")
                }
                try await opened.writeLine("STLS")
                let reply = try await readStatus(opened)
                guard reply.ok else { throw PMailError.connectionFailed("the server didn’t start a secure connection (STLS)") }
                try await opened.startTLS()
                // What the server offers can change once the connection is encrypted.
                try await loadCapabilities(opened)
            }
            return opened
        } catch {
            await opened.close()
            throw Self.pmailError(error)
        }
    }

    private func loadCapabilities(_ connection: LineConnection) async throws {
        try await connection.writeLine("CAPA")
        let status = try await readStatus(connection)
        capabilities = [:]
        capabilitiesKnown = status.ok
        guard status.ok else { return }
        for line in try await readMultiline(connection) {
            let words = String(decoding: line, as: UTF8.self).split(separator: " ").map { $0.uppercased() }
            guard let keyword = words.first else { continue }
            capabilities[keyword] = Array(words.dropFirst())
        }
    }

    private func signIn(_ connection: LineConnection, attempt: Int) async throws {
        switch credential {
        case let .password(username, password):
            guard !(username + password).contains(where: { $0.isNewline }) else {
                throw PMailError.authenticationFailed("The user name or password has a line break in it.")
            }
            let mechanisms = Set(capabilities["SASL"] ?? [])
            let offersUser = !capabilitiesKnown || capabilities["USER"] != nil
            if offersUser || !mechanisms.contains("PLAIN") {
                try await connection.writeLine("USER \(username)")
                var reply = try await readStatus(connection)
                if reply.ok {
                    try await connection.writeSecretLine("PASS \(password)", shownAs: "PASS <hidden>")
                    reply = try await readStatus(connection)
                    if reply.ok { return }
                }
                throw Self.signInFailure(reply.text)
            }
            let reply = try await authenticate(connection, mechanism: "PLAIN",
                                               response: SASL.plain(username: username, password: password))
            if !reply.ok { throw Self.signInFailure(reply.text) }
        case let .oauth(username, tokens):
            let token: String
            do {
                token = try await tokens.accessToken()
            } catch {
                throw (error as? PMailError) ?? .authenticationFailed(error.localizedDescription)
            }
            let reply = try await authenticate(connection, mechanism: "XOAUTH2",
                                               response: SASL.xoauth2(username: username, accessToken: token))
            if reply.ok { return }
            let failure = Self.signInFailure(reply.text)
            if attempt == 1, case .authenticationFailed = failure { throw TokenRejected() }
            throw failure
        }
    }

    /// AUTH with an initial response (RFC 5034). A "+" challenge after it is either a request for the response
    /// (sent again) or, for XOAUTH2, an error description (answered with an empty line to get the final reply).
    private func authenticate(_ connection: LineConnection, mechanism: String, response: String) async throws -> Status {
        try await connection.writeSecretLine("AUTH \(mechanism) \(response)", shownAs: "AUTH \(mechanism) <hidden>")
        var line = try await connection.readLineString()
        if line.hasPrefix("+"), !line.hasPrefix("+OK") {
            if mechanism == "XOAUTH2" {
                try await connection.writeLine("")
            } else {
                try await connection.writeSecretLine(response, shownAs: "<hidden>")
            }
            line = try await connection.readLineString()
        }
        return try Self.status(from: line)
    }

    // MARK: Commands and answers

    private struct Status {
        var ok: Bool
        var text: String
    }

    private func requireConnection() async throws -> LineConnection {
        try await connect()
        guard let connection else { throw PMailError.connectionFailed("not connected") }
        return connection
    }

    /// Sends a command and returns the text after "+OK"; "-ERR" becomes a `server` error.
    private func command(_ line: String) async throws -> String {
        let connection = try await requireConnection()
        do {
            try await connection.writeLine(line)
            let status = try await readStatus(connection)
            guard status.ok else { throw PMailError.server(status.text.isEmpty ? "The server refused “\(line)”." : status.text) }
            return status.text
        } catch let error as PMailError {
            if case .server = error {} else { await dropConnection() }
            throw error
        } catch {
            await dropConnection()
            throw Self.pmailError(error)
        }
    }

    private func multilineCommand(_ line: String) async throws -> [Data] {
        _ = try await command(line)
        guard let connection else { throw PMailError.connectionFailed("not connected") }
        do {
            return try await readMultiline(connection)
        } catch {
            await dropConnection()
            throw Self.pmailError(error)
        }
    }

    private func dropConnection() async {
        await connection?.close()
        connection = nil
    }

    private func readStatus(_ connection: LineConnection) async throws -> Status {
        try Self.status(from: try await connection.readLineString())
    }

    private static func status(from line: String) throws -> Status {
        if line.hasPrefix("+OK") { return Status(ok: true, text: line.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
        if line.hasPrefix("-ERR") { return Status(ok: false, text: line.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
        throw PMailError.protocolError("unexpected answer “\(line.prefix(80))”")
    }

    /// The lines of a multi-line answer, up to the lone ".", with the extra dot taken off lines that start with one.
    private func readMultiline(_ connection: LineConnection) async throws -> [Data] {
        var lines: [Data] = []
        while true {
            let line = try await connection.readLine()
            if line.count == 1, line.first == UInt8(ascii: ".") { return lines }
            if line.first == UInt8(ascii: ".") {
                lines.append(line.subdata(in: (line.startIndex + 1)..<line.endIndex))
            } else {
                lines.append(line)
            }
        }
    }

    private static func joined(_ lines: [Data]) -> Data {
        var data = Data(capacity: lines.reduce(0) { $0 + $1.count + 2 })
        for line in lines {
            data.append(line)
            data.append(contentsOf: [0x0D, 0x0A])
        }
        return data
    }

    /// A refused sign-in: "[IN-USE]" and other temporary codes (RFC 3206) mean try again later; anything else means
    /// the user name, password or token was wrong.
    private static func signInFailure(_ text: String) -> PMailError {
        var reason = text
        var code = ""
        if reason.hasPrefix("["), let close = reason.firstIndex(of: "]") {
            code = reason[reason.index(after: reason.startIndex)..<close].uppercased()
            reason = reason[reason.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        if ["IN-USE", "SYS/TEMP", "LOGIN-DELAY"].contains(code) {
            let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return .server((trimmed.isEmpty ? "The mailbox is busy" : trimmed) + " — try again later")
        }
        return .authenticationFailed(reason)
    }

    private static func pmailError(_ error: Error) -> PMailError {
        if let error = error as? PMailError { return error }
        if error is CancellationError { return .cancelled }
        return .connectionFailed(error.localizedDescription)
    }
}
