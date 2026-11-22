import Foundation

/// Mailbox names in IMAP's modified UTF-7 (RFC 3501 §5.1.3), where "Café" is spelled "Caf&AOk-".
public enum IMAPMailboxName {
    /// The name as people read it. Malformed `&…-` runs are kept as they are.
    public static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var result = ""
        var index = name.startIndex
        while index < name.endIndex {
            let character = name[index]
            guard character == "&" else {
                result.append(character)
                index = name.index(after: index)
                continue
            }
            let start = name.index(after: index)
            guard let dash = name[start...].firstIndex(of: "-") else {
                result += name[index...]
                break
            }
            let encoded = name[start..<dash]
            if encoded.isEmpty {
                result.append("&")
            } else if let decoded = decodeUTF16(String(encoded)) {
                result += decoded
            } else {
                result += name[index...dash]
            }
            index = name.index(after: dash)
        }
        return result
    }

    /// The name as the server wants it: printable ASCII as it is, "&" as "&-", anything else as UTF-16 in
    /// modified base64 between "&" and "-".
    public static func encode(_ name: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            let base64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            result += "&" + base64 + "-"
            pending.removeAll()
        }
        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                if scalar == "&" { result += "&-" } else { result.unicodeScalars.append(scalar) }
            } else {
                pending.append(contentsOf: Character(scalar).utf16)
            }
        }
        flush()
        return result
    }

    /// "INBOX" in capitals however the server spelled it (the name is case-insensitive), including at the start of
    /// the inbox's subfolders.
    static func normalizingInbox(_ name: String, delimiter: String?) -> String {
        if name.caseInsensitiveCompare("INBOX") == .orderedSame { return "INBOX" }
        if let delimiter, !delimiter.isEmpty, name.prefix(5).caseInsensitiveCompare("INBOX") == .orderedSame,
           name.dropFirst(5).hasPrefix(delimiter) {
            return "INBOX" + name.dropFirst(5)
        }
        return name
    }

    private static func decodeUTF16(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: ",", with: "/")
        guard base64.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
            || $0 == "+" || $0 == "/" }) else { return nil }
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A piece of a command as it's written to the server.
enum IMAPCommandPart: Sendable, Hashable {
    case text(String)
    /// Text that holds a password or token: written as it is, kept out of transcripts.
    case secret(String, shownAs: String)
    /// Bytes sent as a literal (`{n}` then the bytes), for text that can't be quoted and for messages.
    case literal(Data)
    /// A literal that holds a password.
    case secretLiteral(Data)
}

/// Strings as command arguments.
enum IMAPArgument {
    /// Whether a string can go between quotes: 7-bit, no NUL, no line breaks.
    static func isQuotable(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 0x01 && $0 <= 0x7F && $0 != 0x0D && $0 != 0x0A }
    }

    /// Whether a string can go bare, as an atom (a keyword, say): ASCII with no spaces, control characters or any of
    /// `(){%*"\]`.
    static func isAtom(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in byte > 0x20 && byte < 0x7F && !atomSpecials.contains(byte) }
    }

    private static let atomSpecials = Set("(){%*\"\\]".utf8)

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A quoted string, or a literal when the string holds line breaks or anything beyond ASCII.
    static func string(_ value: String) -> IMAPCommandPart {
        isQuotable(value) ? .text(quoted(value)) : .literal(Data(value.utf8))
    }

    /// The same for a password, which never appears in transcripts.
    static func secret(_ value: String) -> IMAPCommandPart {
        isQuotable(value) ? .secret(quoted(value), shownAs: "\"…\"") : .secretLiteral(Data(value.utf8))
    }
}

/// Builds the parts of a command, joining text and starting literals where they're needed.
struct IMAPCommandBuilder {
    private(set) var parts: [IMAPCommandPart] = []
    /// Whether a string beyond ASCII went in (a search then needs `CHARSET UTF-8`).
    private(set) var hasNonASCII = false

    mutating func text(_ text: String) {
        if case let .text(existing)? = parts.last {
            parts[parts.count - 1] = .text(existing + text)
        } else {
            parts.append(.text(text))
        }
    }

    mutating func string(_ value: String) {
        if value.utf8.contains(where: { $0 >= 0x80 }) { hasNonASCII = true }
        let part = IMAPArgument.string(value)
        if case let .text(quoted) = part { text(quoted) } else { parts.append(part) }
    }

    /// A header field name: as an atom when it's a plain name, quoted otherwise.
    mutating func fieldName(_ name: String) {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0)
            || ("0"..."9").contains($0) || $0 == "-" }
        if plain { text(name) } else { string(name) }
    }
}

/// UID sets in commands ("1:3,7") and in response codes.
public enum IMAPSequenceSet {
    /// The UIDs, sorted, with runs written as ranges.
    public static func string(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var end = start
            while index + 1 < sorted.count, end < UInt32.max, sorted[index + 1] == end + 1 {
                end += 1
                index += 1
            }
            ranges.append(start == end ? "\(start)" : "\(start):\(end)")
            index += 1
        }
        return ranges.joined(separator: ",")
    }

    /// Every UID in a set like "304,319:320", in order, up to `limit` of them.
    public static func parse(_ text: String, limit: Int = 100_000) -> [UInt32] {
        var result: [UInt32] = []
        for piece in text.split(separator: ",") {
            let bounds = piece.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = bounds.first.flatMap({ UInt32($0) }) else { continue }
            let last = bounds.count > 1 ? (UInt32(bounds[1]) ?? first) : first
            var uid = min(first, last)
            let high = max(first, last)
            while result.count < limit {
                result.append(uid)
                if uid == high { break }
                uid += 1
            }
            if result.count >= limit { break }
        }
        return result
    }
}

/// What to search for with UID SEARCH. Keys side by side must all match; `or` and `not` combine them.
public indirect enum IMAPSearchKey: Sendable, Hashable {
    case all
    case seen
    case unseen
    case flagged
    case unflagged
    case answered
    case deleted
    case undeleted
    case draft
    /// The text anywhere in the message, headers or body.
    case text(String)
    case body(String)
    case subject(String)
    case from(String)
    case to(String)
    case cc(String)
    /// A header field containing the text (an empty text matches every message that has the field).
    case header(String, String)
    /// Messages with a keyword: a flag without a backslash, such as a label's. Text that can't be a keyword matches
    /// nothing.
    case keyword(String)
    case uids([UInt32])
    /// Messages with this UID or a higher one (`UID n:*`). The newest message always matches, even when its UID is
    /// lower, so callers check what comes back.
    case uidsFrom(UInt32)
    case since(Date)
    case before(Date)
    case not(IMAPSearchKey)
    case or(IMAPSearchKey, IMAPSearchKey)
    /// Keys that must all match, in parentheses.
    case allOf([IMAPSearchKey])

    /// One key that matches when any of the keys does; nil for none.
    public static func any(_ keys: [IMAPSearchKey]) -> IMAPSearchKey? {
        guard var result = keys.last else { return nil }
        for key in keys.dropLast().reversed() { result = .or(key, result) }
        return result
    }

    func write(into builder: inout IMAPCommandBuilder) {
        func string(_ keyword: String, _ value: String) {
            builder.text(keyword + " ")
            builder.string(value)
        }
        switch self {
        case .all: builder.text("ALL")
        case .seen: builder.text("SEEN")
        case .unseen: builder.text("UNSEEN")
        case .flagged: builder.text("FLAGGED")
        case .unflagged: builder.text("UNFLAGGED")
        case .answered: builder.text("ANSWERED")
        case .deleted: builder.text("DELETED")
        case .undeleted: builder.text("UNDELETED")
        case .draft: builder.text("DRAFT")
        case let .text(value): string("TEXT", value)
        case let .body(value): string("BODY", value)
        case let .subject(value): string("SUBJECT", value)
        case let .from(value): string("FROM", value)
        case let .to(value): string("TO", value)
        case let .cc(value): string("CC", value)
        case let .header(name, value):
            builder.text("HEADER ")
            builder.fieldName(name)
            builder.text(" ")
            builder.string(value)
        case let .keyword(keyword): builder.text(IMAPArgument.isAtom(keyword) ? "KEYWORD " + keyword : "NOT ALL")
        case let .uids(uids): builder.text("UID " + (uids.isEmpty ? "0" : IMAPSequenceSet.string(uids)))
        case let .uidsFrom(first): builder.text("UID \(max(first, 1)):*")
        case let .since(date): builder.text("SINCE " + IMAPDate.day(date))
        case let .before(date): builder.text("BEFORE " + IMAPDate.day(date))
        case let .not(key):
            builder.text("NOT ")
            key.write(into: &builder)
        case let .or(first, second):
            builder.text("OR ")
            first.write(into: &builder)
            builder.text(" ")
            second.write(into: &builder)
        case let .allOf(keys):
            builder.text("(")
            for (index, key) in keys.enumerated() {
                if index > 0 { builder.text(" ") }
                key.write(into: &builder)
            }
            builder.text(")")
        }
    }

    /// Search keys for words someone typed: each word (or "quoted phrase") must be in the sender, the subject or
    /// the text.
    public static func matching(query: String) -> [IMAPSearchKey] {
        words(in: query).prefix(8).map { .or(.or(.from($0), .subject($0)), .text($0)) }
    }

    static func words(in query: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        func finish() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for character in query {
            if character == "\"" {
                finish()
                inQuotes.toggle()
            } else if character.isWhitespace, !inQuotes {
                finish()
            } else {
                current.append(character)
            }
        }
        finish()
        return words
    }
}
