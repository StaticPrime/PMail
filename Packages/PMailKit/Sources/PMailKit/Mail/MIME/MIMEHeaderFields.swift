import Foundation

/// Reads the header block at the start of a message or part: the fields, unfolded, and where the body starts.
enum MIMEHeaderReader {
    /// The fields in `bytes` up to the first empty line, and the index where the body starts. A line that can't be a
    /// header field (no colon, or a name with spaces in it) also ends the block, so a message missing its blank line
    /// still has a body. A leading mbox "From " line is skipped.
    static func read(_ bytes: ArraySlice<UInt8>) -> (fields: [MIMEHeader], bodyStart: Int) {
        var fields: [(name: String, value: [UInt8])] = []
        var index = bytes.startIndex
        let end = bytes.endIndex
        var isFirstLine = true
        while index < end {
            let lineEnd = bytes[index..<end].firstIndex(of: 0x0A) ?? end
            var contentEnd = lineEnd
            if contentEnd > index, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let next = lineEnd < end ? lineEnd + 1 : end
            let line = bytes[index..<contentEnd]
            if line.isEmpty { return (finish(fields), next) }
            if let first = line.first, first == 0x20 || first == 0x09 {
                // A folded continuation: unfolding drops the line break and keeps the whitespace. Before any field it
                // can't be one, so the part has no headers and this is already its (indented) body.
                guard !fields.isEmpty else { return (finish(fields), index) }
                fields[fields.count - 1].value.append(contentsOf: line)
            } else if let colon = line.firstIndex(of: UInt8(ascii: ":")), let name = fieldName(line[line.startIndex..<colon]) {
                fields.append((name, Array(line[(colon + 1)...])))
            } else if isFirstLine, line.starts(with: Array("From ".utf8)) {
                // An mbox separator line, not part of the message.
            } else {
                return (finish(fields), index)
            }
            isFirstLine = false
            index = next
        }
        return (finish(fields), end)
    }

    /// The field name, if these bytes can be one: printable ASCII without spaces (trailing spaces before the colon
    /// are an old form, and allowed).
    private static func fieldName(_ bytes: ArraySlice<UInt8>) -> String? {
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        let name = bytes[bytes.startIndex..<end]
        guard !name.isEmpty, name.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    private static func finish(_ fields: [(name: String, value: [UInt8])]) -> [MIMEHeader] {
        fields.map { MIMEHeader(name: $0.name, value: text(of: $0.value).trimmingCharacters(in: .whitespaces)) }
    }

    /// Header bytes as text: ASCII as it is, anything else as UTF-8 (RFC 6532) or, failing that, the usual fallbacks.
    static func text(of bytes: [UInt8]) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        return Charsets.decode(Data(bytes), charset: nil)
    }
}

/// A header value with parameters, like `text/plain; charset="utf-8"` or `attachment; filename*=utf-8''r%C3%A9sum%C3%A9`
/// (RFC 2045, with the RFC 2231 extensions for long and non-ASCII values).
struct ParameterizedValue: Sendable, Hashable {
    /// The value before the parameters, lowercased, without spaces or comments ("text/plain").
    var value: String
    /// The parameters by lowercased name, unquoted, with RFC 2231 continuations joined and decoded.
    var parameters: [String: String]

    init(value: String, parameters: [String: String] = [:]) {
        self.value = value
        self.parameters = parameters
    }

    init(parsing text: String) {
        var segments = Self.segments(of: text)
        var first = Self.removingComments(from: segments.removeFirst()).trimmingCharacters(in: .whitespaces)
        // "text/html charset=utf-8", with the semicolon missing: keep what follows the value as parameters.
        if let space = first.firstIndex(where: \.isWhitespace) {
            let remainder = first[space...].trimmingCharacters(in: .whitespaces)
            if remainder.contains("=") { segments.insert(remainder, at: 0) }
            first = String(first[..<space])
        }
        value = first.lowercased()

        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, value: String, encoded: Bool)]] = [:]
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            let rawValue = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            var parameterValue = Self.unquote(rawValue)
            if !rawValue.hasPrefix("\""), name != "name", name != "filename", !name.hasPrefix("name*"), !name.hasPrefix("filename*") {
                parameterValue = Self.removingTrailingComment(from: parameterValue)
            }
            if let star = name.firstIndex(of: "*") {
                let base = String(name[..<star])
                let marker = name[name.index(after: star)...]
                if marker.isEmpty {
                    extended[base, default: []].append((0, parameterValue, true))
                } else if marker.hasSuffix("*"), let index = Int(marker.dropLast()) {
                    extended[base, default: []].append((index, parameterValue, true))
                } else if let index = Int(marker) {
                    extended[base, default: []].append((index, parameterValue, false))
                } else if plain[name] == nil {
                    plain[name] = parameterValue
                }
            } else if plain[name] == nil {
                plain[name] = parameterValue
            }
        }
        for (base, pieces) in extended {
            if let joined = Self.joinExtended(pieces.sorted { $0.index < $1.index }) { plain[base] = joined }
        }
        parameters = plain
    }

    /// Splits at semicolons that aren't inside quotes.
    private static func segments(of text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if inQuotes {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                current.append(character)
            case ";":
                segments.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        segments.append(current)
        return segments
    }

    private static func removingComments(from text: String) -> String {
        guard text.contains("(") else { return text }
        var result = ""
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")", depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    /// "us-ascii (Plain text)" becomes "us-ascii".
    private static func removingTrailingComment(from text: String) -> String {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "("), open > text.startIndex,
              text[text.index(before: open)].isWhitespace else { return text }
        return text[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// The contents of a quoted string, with `\"` and `\\` unescaped (other backslashes, as in Windows paths, stay).
    /// Text that isn't quoted comes back as it is.
    static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\"") else { return text }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\"" || text[next] == "\\" {
                    result.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            } else if character == "\"" {
                break
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// Joins RFC 2231 pieces: percent-encoded ones carry bytes (the first naming their character set, as
    /// `utf-8'en'…`), plain ones carry text.
    private static func joinExtended(_ pieces: [(index: Int, value: String, encoded: Bool)]) -> String? {
        guard !pieces.isEmpty else { return nil }
        var bytes = Data()
        var charset: String?
        for (position, piece) in pieces.enumerated() {
            var value = Substring(piece.value)
            if position == 0, piece.encoded {
                let quotes = value.indices.filter { value[$0] == "'" }
                if quotes.count >= 2 {
                    let name = value[..<quotes[0]]
                    charset = name.isEmpty ? nil : String(name)
                    value = value[value.index(after: quotes[1])...]
                }
            }
            if piece.encoded {
                bytes.append(percentDecoded(value))
            } else {
                bytes.append(Data(value.utf8))
            }
        }
        return Charsets.decode(bytes, charset: charset)
    }

    private static func percentDecoded(_ text: Substring) -> Data {
        let source = Array(text.utf8)
        var output = Data()
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
               let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(source[index])
                index += 1
            }
        }
        return output
    }
}
