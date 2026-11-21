import Foundation

/// One parameter of a content line (`TZID=America/New_York`, `TYPE=HOME,WORK`): its name in capitals, and its values
/// with the quotes taken off but otherwise as the file wrote them.
struct ICalendarParameter: Sendable, Hashable {
    /// The name in capitals, for comparing.
    var name: String
    var values: [String]
    /// The name as the file spelled it ("type"), so lines go back the way they came.
    var spelling: String

    init(_ name: String, _ values: [String]) {
        self.name = name.uppercased()
        self.values = values
        spelling = name
    }

    init(_ name: String, _ value: String) {
        self.init(name, [value])
    }

    /// Text made safe for a parameter value the way RFC 6868 asks (`^n` for a line break, `^'` for a double quote,
    /// `^^` for a caret), for names that go in CN.
    static func encode(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "^": result += "^^"
            case "\n": result += "^n"
            case "\r": continue
            case "\"": result += "^'"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A parameter value with RFC 6868's escapes undone, for showing.
    static func decode(_ text: String) -> String {
        guard text.contains("^") else { return text }
        var result = ""
        var pendingCaret = false
        for scalar in text.unicodeScalars {
            if pendingCaret {
                switch scalar {
                case "n", "N": result += "\n"
                case "'": result += "\""
                case "^": result += "^"
                default: result += "^"; result.unicodeScalars.append(scalar)
                }
                pendingCaret = false
            } else if scalar == "^" {
                pendingCaret = true
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        if pendingCaret { result += "^" }
        return result
    }
}

/// One line of an iCalendar (RFC 5545) file after unfolding, such as `DTSTART;TZID=Europe/Paris:20261121T090000`.
/// vCard (RFC 6350) uses the same line syntax, with a group in front of the name (`item1.EMAIL`).
///
/// The value is kept exactly as the file had it, still escaped, so lines PMail doesn't understand go back to the
/// server unchanged.
struct ICalendarLine: Sendable, Hashable {
    /// The vCard group before the name ("item1" in `item1.EMAIL`), which ties a value to its label.
    var group: String?
    /// The property name, in capitals, for comparing.
    var name: String
    var parameters: [ICalendarParameter]
    /// The raw value, still escaped.
    var value: String
    /// The name as the file spelled it ("X-ABLabel"), so lines go back the way they came.
    var spelling: String

    init(group: String? = nil, _ name: String, parameters: [ICalendarParameter] = [], value: String) {
        self.group = group
        self.name = name.uppercased()
        self.parameters = parameters
        self.value = value
        spelling = name
    }

    /// A line whose value is text, escaped as both formats require.
    static func text(_ name: String, _ text: String, parameters: [ICalendarParameter] = [], group: String? = nil) -> ICalendarLine {
        ICalendarLine(group: group, name, parameters: parameters, value: ICalendarText.escape(text))
    }

    /// The value read as text, with its escapes undone.
    var text: String { ICalendarText.unescape(value) }

    /// The first value of a parameter, if the line has it.
    func parameter(_ name: String) -> String? {
        let name = name.uppercased()
        return parameters.first { $0.name == name }?.values.first
    }

    /// Every value of a parameter, from every time it appears, split at commas: `TYPE=HOME;TYPE=VOICE,PREF` gives
    /// HOME, VOICE and PREF.
    func parameterValues(_ name: String) -> [String] {
        let name = name.uppercased()
        return parameters.filter { $0.name == name }.flatMap(\.values).flatMap { $0.split(separator: ",").map(String.init) }
    }

    /// Sets a parameter to one value where it was, or adds it at the end; nil takes it off.
    mutating func setParameter(_ name: String, _ value: String?) {
        let name = name.uppercased()
        guard let value else {
            parameters.removeAll { $0.name == name }
            return
        }
        if let index = parameters.firstIndex(where: { $0.name == name }) {
            parameters[index].values = [value]
            var seen = false
            parameters.removeAll { parameter in
                guard parameter.name == name else { return false }
                defer { seen = true }
                return seen
            }
        } else {
            parameters.append(ICalendarParameter(name, value))
        }
    }

    /// Reads one unfolded line, or returns nil for a line that isn't a property (no name, or no colon).
    init?(parsing line: String) {
        let bytes = line.utf8
        let end = bytes.endIndex
        let semicolon = UInt8(ascii: ";"), colon = UInt8(ascii: ":"), equals = UInt8(ascii: "="), comma = UInt8(ascii: ","),
            quote = UInt8(ascii: "\"")
        var index = bytes.startIndex
        while index < end, bytes[index] != semicolon, bytes[index] != colon { index = bytes.index(after: index) }
        guard index < end else { return nil }
        let fullName = line[line.startIndex..<index].trimmingCharacters(in: .whitespaces)
        guard !fullName.isEmpty else { return nil }

        var parameters: [ICalendarParameter] = []
        while index < end, bytes[index] == semicolon {
            index = bytes.index(after: index)
            let nameStart = index
            while index < end, bytes[index] != equals, bytes[index] != semicolon, bytes[index] != colon {
                index = bytes.index(after: index)
            }
            let parameterName = line[nameStart..<index].trimmingCharacters(in: .whitespaces)
            guard index < end, bytes[index] == equals else {
                // vCard 2.1 writes bare types: TEL;WORK;VOICE:…
                if !parameterName.isEmpty { parameters.append(ICalendarParameter("TYPE", parameterName)) }
                continue
            }
            index = bytes.index(after: index)
            var values: [String] = []
            while true {
                if index < end, bytes[index] == quote {
                    index = bytes.index(after: index)
                    let valueStart = index
                    while index < end, bytes[index] != quote { index = bytes.index(after: index) }
                    values.append(String(line[valueStart..<index]))
                    if index < end { index = bytes.index(after: index) }
                    // Anything between the closing quote and the next separator is junk.
                    while index < end, bytes[index] != comma, bytes[index] != semicolon, bytes[index] != colon {
                        index = bytes.index(after: index)
                    }
                } else {
                    let valueStart = index
                    while index < end, bytes[index] != comma, bytes[index] != semicolon, bytes[index] != colon {
                        index = bytes.index(after: index)
                    }
                    values.append(String(line[valueStart..<index]))
                }
                guard index < end, bytes[index] == comma else { break }
                index = bytes.index(after: index)
            }
            if !parameterName.isEmpty { parameters.append(ICalendarParameter(parameterName, values)) }
        }
        guard index < end, bytes[index] == colon else { return nil }

        var group: String?
        var name = fullName
        if let dot = fullName.lastIndex(of: ".") {
            let prefix = String(fullName[..<dot])
            let suffix = String(fullName[fullName.index(after: dot)...])
            if !prefix.isEmpty, !suffix.isEmpty {
                group = prefix
                name = suffix
            }
        }
        self.init(group: group, name, parameters: parameters, value: String(line[bytes.index(after: index)...]))
    }

    /// The line as a file writes it, before folding.
    var serialized: String {
        var text = group.map { "\($0)." } ?? ""
        text += spelling.uppercased() == name ? spelling : name
        for parameter in parameters {
            let parameterName = parameter.spelling.uppercased() == parameter.name ? parameter.spelling : parameter.name
            text += ";" + parameterName + "=" + parameter.values.map(Self.quotedIfNeeded).joined(separator: ",")
        }
        text += ":"
        if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            // A raw value can't hold a line break; write it the way text values do.
            text += value.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\n")
        } else {
            text += value
        }
        return text
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        let cleaned = value.contains("\"") ? value.replacingOccurrences(of: "\"", with: "^'") : value
        return cleaned.contains(where: { $0 == ":" || $0 == ";" || $0 == "," }) ? "\"\(cleaned)\"" : cleaned
    }
}

/// Escaping for text values, which iCalendar and vCard share: backslash, semicolon, comma and line breaks.
enum ICalendarText {
    /// Text made safe for a TEXT value.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case ";": result += "\\;"
            case ",": result += "\\,"
            case "\r":
                result += "\\n"
                previousWasReturn = true
                continue
            case "\n":
                if !previousWasReturn { result += "\\n" }
            default:
                result.unicodeScalars.append(scalar)
            }
            previousWasReturn = false
        }
        return result
    }

    /// A TEXT value with its escapes undone. Unknown escapes (`\:` from careless writers) give the character itself.
    static func unescape<S: StringProtocol>(_ text: S) -> String {
        guard text.contains("\\") else { return String(text) }
        var result = ""
        var escaping = false
        for scalar in text.unicodeScalars {
            if escaping {
                if scalar == "n" || scalar == "N" { result += "\n" } else { result.unicodeScalars.append(scalar) }
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        if escaping { result += "\\" }
        return result
    }

    /// Splits a value at separators that aren't escaped (the `;` between a vCard name's parts, the `,` between
    /// categories). The parts stay escaped.
    static func split<S: StringProtocol>(_ value: S, at separator: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for scalar in value.unicodeScalars {
            if escaping {
                current.unicodeScalars.append(scalar)
                escaping = false
            } else if scalar == "\\" {
                current.unicodeScalars.append(scalar)
                escaping = true
            } else if scalar == separator {
                parts.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        parts.append(current)
        return parts
    }
}

/// Line folding: files fold long lines by breaking them and starting the next line with a space.
enum ICalendarFolding {
    /// Most octets on one line of a file, not counting the line break.
    static let lineLength = 75

    /// A file's lines with folds undone. Unfolding works on the bytes, so a fold a careless writer put in the middle
    /// of a multibyte character still joins back into the character. Takes CRLF, LF or a lone CR as line breaks,
    /// and joins quoted-printable soft breaks from old vCards.
    static func unfoldedLines(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var current: [UInt8] = []
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            guard byte == 0x0D || byte == 0x0A else {
                current.append(byte)
                index += 1
                continue
            }
            var next = index + 1
            if byte == 0x0D, next < count, bytes[next] == 0x0A { next += 1 }
            // A quoted-printable soft break: the "=" and the line break go, and the next line is data.
            if current.last == UInt8(ascii: "="), next < count, isQuotedPrintable(current) {
                current.removeLast()
                index = next
                continue
            }
            if next < count, bytes[next] == 0x20 || bytes[next] == 0x09 {
                index = next + 1
                continue
            }
            if !current.isEmpty { lines.append(decode(current)) }
            current.removeAll(keepingCapacity: true)
            index = next
        }
        if !current.isEmpty { lines.append(decode(current)) }
        return lines
    }

    /// A line folded so no line is longer than 75 octets, breaking only between characters (never inside a UTF-8
    /// sequence). The breaks are CRLF followed by a space.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > lineLength else { return line }
        var result = ""
        result.reserveCapacity(line.utf8.count + line.utf8.count / 24)
        var octets = 0
        for scalar in line.unicodeScalars {
            let width = UTF8.width(scalar)
            if octets + width > lineLength {
                result += "\r\n "
                octets = 1
            }
            result.unicodeScalars.append(scalar)
            octets += width
        }
        return result
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func isQuotedPrintable(_ bytes: [UInt8]) -> Bool {
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return false }
        return String(decoding: bytes[..<colon], as: UTF8.self).uppercased().contains("QUOTED-PRINTABLE")
    }
}
