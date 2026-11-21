import Foundation

/// Reads address headers (From, To, Cc…): RFC 5322 address lists, and the many ways mail gets them slightly wrong.
public enum AddressParser {
    /// The addresses in a header value, in order. Handles quoted names with commas in them, names in comments
    /// ("jamie@example.com (Jamie Rivera)"), groups ("Friends: a@example.com, b@example.com;", whose members are
    /// listed and whose name is dropped), bare addresses, missing angle brackets, encoded words in names, and an
    /// unquoted "Rivera, Jamie <jamie@example.com>". Entries without an address are skipped.
    public static func parse(_ text: String) -> [MailAddress] {
        var addresses: [MailAddress] = []
        var segment: [Token] = []
        var inGroup = false
        var carried: String?

        func finishSegment() {
            if let address = mailbox(from: segment, carried: &carried) { addresses.append(address) }
            segment.removeAll()
        }

        for token in tokenize(text) {
            switch token {
            case .comma:
                finishSegment()
            case .colon:
                if inGroup {
                    continue
                }
                // A group starts: what came before the colon is its name, which isn't an address.
                segment.removeAll()
                carried = nil
                inGroup = true
            case .semicolon:
                finishSegment()
                carried = nil
                inGroup = false
            default:
                segment.append(token)
            }
        }
        finishSegment()
        return addresses
    }

    private enum Token {
        /// An atom (which here includes "@" and "."), or a quoted string's contents.
        case word(String, quoted: Bool, spaceBefore: Bool)
        /// What was between angle brackets.
        case angle(String)
        case comment(String)
        case comma
        case colon
        case semicolon
    }

    private static func tokenize(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        var sawSpace = false
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                sawSpace = true
                index += 1
                continue
            }
            switch character {
            case ",":
                tokens.append(.comma)
                index += 1
            case ":":
                tokens.append(.colon)
                index += 1
            case ";":
                tokens.append(.semicolon)
                index += 1
            case "\"":
                index += 1
                var value = ""
                while index < characters.count {
                    let next = characters[index]
                    if next == "\\", index + 1 < characters.count {
                        value.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    index += 1
                    if next == "\"" { break }
                    value.append(next)
                }
                tokens.append(.word(value, quoted: true, spaceBefore: sawSpace))
            case "(":
                index += 1
                var value = ""
                var depth = 1
                while index < characters.count {
                    let next = characters[index]
                    if next == "\\", index + 1 < characters.count {
                        value.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    index += 1
                    if next == "(" {
                        depth += 1
                    } else if next == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    value.append(next)
                }
                tokens.append(.comment(value))
            case "<":
                index += 1
                var value = ""
                var inQuotes = false
                while index < characters.count {
                    let next = characters[index]
                    if next == "\"" { inQuotes.toggle() }
                    if next == ">", !inQuotes { break }
                    value.append(next)
                    index += 1
                }
                if index < characters.count { index += 1 }  // the ">"
                tokens.append(.angle(value))
            case ">", ")":
                index += 1  // stray
            default:
                var value = ""
                while index < characters.count {
                    let next = characters[index]
                    if next == "[" {
                        // A domain literal ("[192.0.2.1]", "[IPv6:…]"), whose colons aren't group colons.
                        while index < characters.count {
                            value.append(characters[index])
                            index += 1
                            if characters[index - 1] == "]" { break }
                        }
                        continue
                    }
                    if next.isWhitespace || ",:;\"(<>)".contains(next) { break }
                    value.append(next)
                    index += 1
                }
                tokens.append(.word(value, quoted: false, spaceBefore: sawSpace))
            }
            sawSpace = false
        }
        return tokens
    }

    /// One mailbox from the tokens between two commas. `carried` holds the words of an earlier piece that had no
    /// address, which become the start of this one's name ("Rivera" + "Jamie <jamie@example.com>").
    private static func mailbox(from tokens: [Token], carried: inout String?) -> MailAddress? {
        var words: [(text: String, quoted: Bool, spaceBefore: Bool)] = []
        var angle: String?
        var comments: [String] = []
        for token in tokens {
            switch token {
            case let .word(text, quoted, spaceBefore):
                // A quoted local part right before its domain: "john doe"@example.com.
                if !quoted, !spaceBefore, text.hasPrefix("@"), let last = words.last, last.quoted {
                    words[words.count - 1] = ("\"\(last.text)\"\(text)", false, last.spaceBefore)
                } else {
                    words.append((text, quoted, spaceBefore))
                }
            case let .angle(text):
                if angle == nil { angle = text }
            case let .comment(text):
                comments.append(text)
            default:
                break
            }
        }

        if let angle {
            let email = cleanAddress(angle)
            var name = phrase(words)
            if name.isEmpty, let comment = comments.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                name = decodedName(comment)
            }
            if let earlier = carried { name = name.isEmpty ? earlier : earlier + ", " + name }
            carried = nil
            guard !email.isEmpty else { return nil }
            return MailAddress(name: tidyName(name, email: email), email: email)
        }

        if let index = words.lastIndex(where: { !$0.quoted && $0.text.contains("@") }) {
            let email = cleanAddress(words[index].text)
            var others = words
            others.remove(at: index)
            var name = phrase(others)
            if name.isEmpty, let comment = comments.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                name = decodedName(comment)
            }
            carried = nil
            guard !email.isEmpty else { return nil }
            return MailAddress(name: tidyName(name, email: email), email: email)
        }

        let leftover = phrase(words)
        if !leftover.isEmpty { carried = carried.map { $0 + ", " + leftover } ?? leftover }
        return nil
    }

    /// The display name: the words joined with single spaces, encoded words decoded (inside quotes too, which isn't
    /// allowed but is common).
    private static func phrase(_ words: [(text: String, quoted: Bool, spaceBefore: Bool)]) -> String {
        decodedName(words.map(\.text).filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func decodedName(_ text: String) -> String {
        let decoded = EncodedWords.decode(text)
        let singleLine = decoded.map { $0.isNewline || $0 == "\t" ? " " : $0 }
        return String(singleLine).trimmingCharacters(in: .whitespaces)
    }

    /// The name without wrapping single quotes ('Jamie Rivera'), and nil when it only repeats the address.
    private static func tidyName(_ name: String, email: String) -> String? {
        var name = name
        if name.count > 2, name.hasPrefix("'"), name.hasSuffix("'") {
            name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<> "))
        if bare.isEmpty || bare.caseInsensitiveCompare(email) == .orderedSame { return nil }
        return name
    }

    /// An address as found between angle brackets or bare: without spaces, a "mailto:", stray brackets or an old
    /// source route ("@relay.example:jamie@example.com").
    private static func cleanAddress(_ text: String) -> String {
        var address = ""
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, character.isWhitespace || character == "<" || character == ">" { continue }
            address.append(character)
        }
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        if address.hasPrefix("@"), let colon = address.firstIndex(of: ":") {
            address = String(address[address.index(after: colon)...])
        }
        return address
    }
}
