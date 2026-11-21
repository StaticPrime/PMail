import Foundation

/// Reads IMAP responses (RFC 3501 syntax): tagged and untagged responses, continuation requests, and the atoms,
/// quoted strings, literals and lists inside them.
///
/// Parsing is forgiving: an untagged response that can't be understood becomes `.other`, so one odd line never
/// derails a command, and malformed data never crashes.
public enum IMAPParser {
    /// The largest literal accepted from a server, so a damaged length can't make PMail wait for gigabytes.
    static let maximumLiteralLength = 1 << 31

    /// Reads one whole response from a connection: its first line, then each literal and line that follows a `{n}`
    /// at a line's end, put back together as the server sent them.
    static func readResponseData(from connection: LineConnection) async throws -> Data {
        var line = try await connection.readLine()
        var response = line
        guard mayCarryLiterals(line) else { return response }
        while let length = literalLength(atEndOf: line) {
            guard length <= maximumLiteralLength else {
                throw PMailError.protocolError("the server sent a literal that was too large")
            }
            response.append(contentsOf: [0x0D, 0x0A])
            response.append(try await connection.readBytes(length))
            line = try await connection.readLine()
            response.append(line)
        }
        return response
    }

    /// The length in a `{n}` (or `{n+}`) that ends a line, if it ends with one.
    static func literalLength(atEndOf line: Data) -> Int? {
        let bytes = [UInt8](line)
        guard bytes.last == UInt8(ascii: "}"), let open = bytes.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = bytes[(open + 1)..<(bytes.count - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Whether a response's first line can be followed by literals. Status responses and continuation requests end
    /// in free text, where a `{5}` is just words.
    static func mayCarryLiterals(_ line: Data) -> Bool {
        let start = String(decoding: line.prefix(64), as: UTF8.self)
        if start.hasPrefix("+") { return false }
        let words = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard words.count >= 2 else { return true }
        let second = words[1].uppercased()
        if words[0] == "*" { return !["OK", "NO", "BAD", "BYE", "PREAUTH"].contains(second) }
        return !["OK", "NO", "BAD"].contains(second)
    }

    /// Reads one response: the bytes of its lines (without the final CRLF) and of any literals in it.
    public static func parse(_ data: Data) throws -> IMAPResponse {
        var scanner = IMAPScanner(data)
        if scanner.current == UInt8(ascii: "+") {
            scanner.index += 1
            return .continuation(scanner.rest())
        }
        let tag = scanner.atom()
        guard !tag.isEmpty else { throw PMailError.protocolError("a response had no tag") }
        scanner.skipSpaces()
        if tag == "*" { return .untagged(untagged(&scanner)) }
        let word = scanner.atom().uppercased()
        guard let status = IMAPStatus(rawValue: word), status == .ok || status == .no || status == .bad else {
            throw PMailError.protocolError("a command’s answer didn’t say whether it worked")
        }
        return .tagged(tag: tag, responseText(&scanner, status: status))
    }

    /// Reads values on their own, the way they appear inside responses (for tests and tools).
    public static func parseValues(_ text: String) throws -> [IMAPValue] {
        var scanner = IMAPScanner(Data(text.utf8))
        return try scanner.values(until: nil)
    }

    private static func untagged(_ scanner: inout IMAPScanner) -> IMAPUntaggedResponse {
        let start = scanner.index
        do {
            return try parseUntagged(&scanner)
        } catch {
            scanner.index = start
            return .other(name: scanner.atom().uppercased(), values: [])
        }
    }

    private static func parseUntagged(_ scanner: inout IMAPScanner) throws -> IMAPUntaggedResponse {
        let word = scanner.atom()
        scanner.skipSpaces()
        if !word.isEmpty, word.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let number = Int(word) {
            let kind = scanner.atom().uppercased()
            switch kind {
            case "EXISTS": return .exists(number)
            case "RECENT": return .recent(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH":
                guard let items = try scanner.values(until: nil).first?.items else {
                    throw PMailError.protocolError("a FETCH response had no list")
                }
                return .fetch(IMAPFetchResponse(sequenceNumber: number, attributes: items))
            default:
                return .other(name: kind, values: (try? scanner.values(until: nil)) ?? [])
            }
        }
        let name = word.uppercased()
        if let status = IMAPStatus(rawValue: name) { return .condition(responseText(&scanner, status: status)) }
        switch name {
        case "CAPABILITY":
            return .capability(scanner.rest().split(separator: " ").map(String.init))
        case "LIST", "LSUB", "XLIST":
            guard let mailbox = IMAPMailbox(listValues: try scanner.values(until: nil)) else {
                throw PMailError.protocolError("a LIST response couldn’t be read")
            }
            return .list(mailbox)
        case "STATUS":
            let values = try scanner.values(until: nil)
            guard values.count >= 2, let nameData = values[0].data, let items = values[1].items else {
                throw PMailError.protocolError("a STATUS response couldn’t be read")
            }
            var attributes: [String: Int] = [:]
            var index = 0
            while index + 1 < items.count {
                if let key = items[index].text, let value = items[index + 1].number { attributes[key.uppercased()] = value }
                index += 2
            }
            let mailbox = IMAPMailboxName.normalizingInbox(IMAPMailboxName.decode(String(decoding: nameData, as: UTF8.self)),
                                                          delimiter: nil)
            return .status(mailbox: mailbox, attributes: attributes)
        case "SEARCH":
            var uids: [UInt32] = []
            while true {
                scanner.skipSpaces()
                guard let uid = UInt32(scanner.atom()) else { break }
                uids.append(uid)
            }
            return .search(uids)
        case "FLAGS":
            return .flags(try scanner.values(until: nil).first?.items?.compactMap(\.text) ?? [])
        default:
            return .other(name: name, values: (try? scanner.values(until: nil)) ?? [])
        }
    }

    /// Reads the rest of a status response: an optional `[CODE …]`, then the server's words.
    static func responseText(_ scanner: inout IMAPScanner, status: IMAPStatus) -> IMAPStatusResponse {
        scanner.skipSpaces()
        var code: IMAPResponseCode?
        if scanner.current == UInt8(ascii: "[") {
            scanner.index += 1
            let start = scanner.index
            do {
                code = try responseCode(&scanner)
            } catch {
                scanner.index = start
                let words = scanner.text(until: UInt8(ascii: "]")).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1)
                _ = scanner.skip(UInt8(ascii: "]"))
                code = .other(name: words.first.map { $0.uppercased() } ?? "",
                              text: words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : "")
            }
        }
        return IMAPStatusResponse(status: status, code: code, text: scanner.rest())
    }

    private static func responseCode(_ scanner: inout IMAPScanner) throws -> IMAPResponseCode {
        let name = scanner.atom().uppercased()
        let code: IMAPResponseCode
        func number() throws -> UInt32 {
            scanner.skipSpaces()
            guard let value = UInt32(scanner.atom()) else { throw PMailError.protocolError("a response code had no number") }
            return value
        }
        func set() throws -> [UInt32] {
            scanner.skipSpaces()
            let uids = IMAPSequenceSet.parse(scanner.atom())
            guard !uids.isEmpty else { throw PMailError.protocolError("a response code had no UIDs") }
            return uids
        }
        switch name {
        case "ALERT": code = .alert
        case "CAPABILITY":
            var names: [String] = []
            while true {
                scanner.skipSpaces()
                let word = scanner.atom()
                if word.isEmpty { break }
                names.append(word)
            }
            code = .capability(names)
        case "PERMANENTFLAGS":
            scanner.skipSpaces()
            code = .permanentFlags(try scanner.value().items?.compactMap(\.text) ?? [])
        case "UIDVALIDITY": code = .uidValidity(try number())
        case "UIDNEXT": code = .uidNext(try number())
        case "UNSEEN": code = .unseen(Int(try number()))
        case "APPENDUID":
            let validity = try number()
            guard let uid = try set().first else { throw PMailError.protocolError("APPENDUID had no UID") }
            code = .appendUID(uidValidity: validity, uid: uid)
        case "COPYUID":
            let validity = try number()
            code = .copyUID(uidValidity: validity, source: try set(), destination: try set())
        case "TRYCREATE": code = .tryCreate
        case "READ-ONLY": code = .readOnly
        case "READ-WRITE": code = .readWrite
        default:
            code = .other(name: name, text: scanner.text(until: UInt8(ascii: "]")).trimmingCharacters(in: .whitespaces))
        }
        scanner.skipSpaces()
        guard scanner.skip(UInt8(ascii: "]")) else { throw PMailError.protocolError("a response code had no end") }
        return code
    }
}

/// Walks through the bytes of one response, reading IMAP's syntax.
struct IMAPScanner {
    /// How deeply lists may nest before the response is treated as damaged (real ones stay far below this).
    static let maximumDepth = 100

    private let bytes: [UInt8]
    var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { index >= bytes.count }
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == 0x20 { index += 1 }
    }

    /// Steps over `byte` if it's next.
    mutating func skip(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    /// Reads an atom: everything up to a space, a parenthesis, a quote, a closing bracket or a control character. A
    /// section in brackets ("BODY[HEADER.FIELDS (DATE FROM)]<0>") is read whole, spaces and all.
    mutating func atom() -> String {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "[") {
                guard let close = bytes[index...].firstIndex(of: UInt8(ascii: "]")) else {
                    index = bytes.count
                    break
                }
                index = close + 1
                continue
            }
            if byte == 0x20 || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\"")
                || byte == UInt8(ascii: "]") || byte < 0x20 || byte == 0x7F {
                break
            }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Reads one value: a list, a quoted string, a literal, NIL or an atom.
    mutating func value(depth: Int = 0) throws -> IMAPValue {
        skipSpaces()
        guard let byte = current else { throw PMailError.protocolError("a response ended early") }
        switch byte {
        case UInt8(ascii: "("):
            guard depth < Self.maximumDepth else { throw PMailError.protocolError("a response nested too deeply") }
            index += 1
            return .list(try values(until: UInt8(ascii: ")"), depth: depth + 1))
        case UInt8(ascii: "\""):
            return .string(try quoted())
        case UInt8(ascii: "{"):
            return .string(try literal())
        case UInt8(ascii: "~") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "{"):
            index += 1
            return .string(try literal())
        default:
            let word = atom()
            guard !word.isEmpty else { throw PMailError.protocolError("a response had an unexpected character") }
            return word.caseInsensitiveCompare("NIL") == .orderedSame ? .null : .atom(word)
        }
    }

    /// Reads values up to `terminator` (stepping over it), or to the end when there's none.
    mutating func values(until terminator: UInt8?, depth: Int = 0) throws -> [IMAPValue] {
        var result: [IMAPValue] = []
        while true {
            skipSpaces()
            guard let byte = current else {
                if terminator == nil { return result }
                throw PMailError.protocolError("a list in a response had no end")
            }
            if let terminator, byte == terminator {
                index += 1
                return result
            }
            if terminator == nil, byte == 0x0D || byte == 0x0A { return result }
            result.append(try value(depth: depth))
        }
    }

    /// Reads a quoted string, undoing `\"` and `\\` escapes.
    mutating func quoted() throws -> Data {
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                output.append(bytes[index + 1])
                index += 2
                continue
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return Data(output)
            }
            output.append(byte)
            index += 1
        }
        throw PMailError.protocolError("a quoted string in a response had no end")
    }

    /// Reads a literal: `{n}`, a line end, then exactly n bytes.
    mutating func literal() throws -> Data {
        index += 1
        let start = index
        while let byte = current, byte >= 0x30, byte <= 0x39 { index += 1 }
        guard index > start, index - start <= 12, let length = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw PMailError.protocolError("a literal in a response had no length")
        }
        _ = skip(UInt8(ascii: "+"))
        guard skip(UInt8(ascii: "}")) else { throw PMailError.protocolError("a literal in a response was malformed") }
        _ = skip(0x0D)
        guard skip(0x0A) else { throw PMailError.protocolError("a literal in a response was malformed") }
        guard length <= bytes.count - index else { throw PMailError.protocolError("a literal in a response was cut short") }
        let data = Data(bytes[index..<(index + length)])
        index += length
        return data
    }

    /// Everything that's left, as trimmed text.
    mutating func rest() -> String {
        let text = String(decoding: bytes[min(index, bytes.count)...], as: UTF8.self)
        index = bytes.count
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text up to (not including) `terminator`, or to the end.
    mutating func text(until terminator: UInt8) -> String {
        let start = index
        while let byte = current, byte != terminator { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
