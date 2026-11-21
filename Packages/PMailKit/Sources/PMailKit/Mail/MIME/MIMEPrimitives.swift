import Foundation

/// Reads and writes RFC 2047 encoded words ("=?utf-8?B?SGk=?="), the way non-ASCII text goes into mail headers.
public enum EncodedWords {
    /// The text with every well-formed encoded word decoded. Whitespace between two encoded words is dropped, as the
    /// standard says, and neighboring words in the same character set are decoded together, so a character that a
    /// sender split across two words still reads. Malformed words are left as they are.
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var result = ""
        var rest = Substring(text)
        var pending: (charset: String, bytes: Data)?
        var noCloseBefore: String.Index?

        func flush() {
            if let run = pending { result += Charsets.decode(run.bytes, charset: run.charset) }
            pending = nil
        }

        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            guard let word = parseWord(rest[start.lowerBound...], noCloseBefore: &noCloseBefore) else {
                flush()
                result += before + "=?"
                rest = rest[start.upperBound...]
                continue
            }
            let onlyWhitespace = before.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
            if var run = pending, onlyWhitespace {
                // Whitespace between neighboring encoded words isn't part of the text.
                if run.charset == word.charset {
                    run.bytes.append(word.bytes)
                    pending = run
                } else {
                    flush()
                    pending = (word.charset, word.bytes)
                }
            } else {
                flush()
                result += before
                pending = (word.charset, word.bytes)
            }
            rest = rest[word.end...]
        }
        flush()
        result += rest
        return result
    }

    /// One encoded word at the start of `text`. The encoded text can't hold whitespace, so the search for its end
    /// stops at the first whitespace; `noCloseBefore` remembers where a failed search stopped, since a word starting
    /// before there can't end either, which keeps a header full of stray "=?" from taking quadratic time.
    private static func parseWord(_ text: Substring,
                                  noCloseBefore: inout String.Index?) -> (charset: String, bytes: Data, end: Substring.Index)? {
        // =?charset?encoding?text?=
        let afterOpen = text.index(text.startIndex, offsetBy: 2)
        guard let charsetEnd = text[afterOpen...].firstIndex(of: "?") else { return nil }
        let encodingStart = text.index(after: charsetEnd)
        guard encodingStart < text.endIndex, let encodingEnd = text[encodingStart...].firstIndex(of: "?"),
              text.distance(from: encodingStart, to: encodingEnd) == 1 else { return nil }
        let payloadStart = text.index(after: encodingEnd)
        if let limit = noCloseBefore, payloadStart < limit { return nil }
        let searchEnd = text[payloadStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        guard let close = text[payloadStart..<searchEnd].range(of: "?=") else {
            noCloseBefore = searchEnd
            return nil
        }
        var charset = text[afterOpen..<charsetEnd].lowercased()
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }  // RFC 2231 language
        guard !charset.isEmpty, charset.count <= 64, !charset.contains(where: \.isWhitespace) else { return nil }
        let payload = text[payloadStart..<close.lowerBound]
        let bytes: Data?
        switch text[encodingStart].uppercased() {
        case "B": bytes = TransferEncoding.decodeBase64(String(payload))
        case "Q":
            bytes = TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8), isHeader: true)
        default: bytes = nil
        }
        guard let bytes else { return nil }
        return (charset, bytes, close.upperBound)
    }

    /// Encodes text as UTF-8 encoded words of at most 75 characters each, for header text that can't go as it is.
    /// Quoted-printable ("Q") is used when it comes out shorter, base64 ("B") otherwise. Words break only between
    /// characters, never inside one, and use only characters that are safe in every kind of header, names included.
    static func encode(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let quotedLength = bytes.reduce(0) { $0 + (isSafeInQ($1) ? 1 : 3) }
        let base64Length = (bytes.count + 2) / 3 * 4
        let useQ = quotedLength <= base64Length
        // "=?utf-8?Q?" and "?=" leave 63 characters of the 75 for the text: 63 Q characters or 45 bytes of base64.
        var words: [String] = []
        var chunk: [UInt8] = []
        var chunkLength = 0

        func flush() {
            guard !chunk.isEmpty else { return }
            if useQ {
                words.append("=?utf-8?Q?" + quoted(chunk) + "?=")
            } else {
                words.append("=?utf-8?B?" + Data(chunk).base64EncodedString() + "?=")
            }
            chunk.removeAll()
            chunkLength = 0
        }

        for scalar in text.unicodeScalars {
            let scalarBytes = Array(String(scalar).utf8)
            if useQ {
                let cost = scalarBytes.reduce(0) { $0 + (isSafeInQ($1) ? 1 : 3) }
                if chunkLength + cost > 63 { flush() }
                chunkLength += cost
            } else if chunk.count + scalarBytes.count > 45 {
                flush()
            }
            chunk.append(contentsOf: scalarBytes)
        }
        flush()
        return words
    }

    /// Characters a Q-encoded word may hold as they are, even inside a display name (RFC 2047 section 5).
    private static func isSafeInQ(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "!"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "/"), UInt8(ascii: " "):
            true
        default:
            false
        }
    }

    private static func quoted(_ bytes: [UInt8]) -> String {
        var result = ""
        for byte in bytes {
            if byte == UInt8(ascii: " ") {
                result.append("_")
            } else if isSafeInQ(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += "=" + TransferEncoding.hexDigits(byte)
            }
        }
        return result
    }
}

/// Turns bytes in a named character set into text.
public enum Charsets {
    /// Decodes `data` in the character set `charset` names (an IANA name like "iso-8859-1" or "Shift_JIS"). Unknown or
    /// missing names, and text that isn't valid in the named set, fall back to UTF-8, then Windows-1252, so mail with
    /// a wrong label still reads. Text labelled Latin-1 or Windows-1252 that is really UTF-8 (a common mistake) is
    /// read as UTF-8, and text that is mostly UTF-8 with a few stray bytes keeps its UTF-8 characters.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(named: charset) {
            // Real Latin-1 text almost never happens to be valid UTF-8 with accented letters in it.
            if isLatin(encoding), utf8Shape(data).multibyte > 0, let text = String(data: data, encoding: .utf8) { return text }
            if let text = String(data: data, encoding: encoding) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let shape = utf8Shape(data)
        if shape.multibyte > shape.invalid { return String(decoding: data, as: UTF8.self) }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// The Foundation encoding for an IANA character set name, or nil if it's unknown.
    public static func encoding(named charset: String?) -> String.Encoding? {
        guard var name = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased(), !name.isEmpty else {
            return nil
        }
        // Labels mail gets wrong, read as the larger sets their senders really used.
        switch name {
        case "utf8", "utf-8", "unicode-1-1-utf-8", "x-unicode20utf8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968", "iso646-us", "us", "646": return nil  // UTF-8 or Windows-1252, by the fallback
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1", "iso_8859-1", "iso_8859-1:1987", "l1", "cp819", "ibm819",
             "cp1252", "x-cp1252", "windows1252":
            name = "windows-1252"
        case "gb2312", "gbk", "x-gbk", "cp936", "euc-cn", "x-euc-cn": name = "gb18030"
        case "ks_c_5601-1987", "ks_c_5601", "korean", "cp949", "x-windows-949": name = "euc-kr"
        case "tis-620", "iso-8859-11": name = "windows-874"
        case "sjis", "x-sjis", "shift-jis", "ms_kanji", "csshiftjis": name = "shift_jis"
        case "cp932", "windows-31j", "x-ms-cp932": name = "cp932"
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func isLatin(_ encoding: String.Encoding) -> Bool {
        encoding == .windowsCP1252 || encoding == .isoLatin1 || encoding == Self.latin9
    }

    private static let latin9 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.isoLatin9.rawValue)))

    /// Counts well-formed multi-byte UTF-8 sequences, and bytes that can't be UTF-8, to tell UTF-8 from single-byte
    /// text.
    static func utf8Shape(_ data: Data) -> (multibyte: Int, invalid: Int) {
        var multibyte = 0
        var invalid = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte < 0x80 {
                    index += 1
                    continue
                }
                let length: Int
                switch byte {
                case 0xC2...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF4: length = 4
                default: length = 0
                }
                var valid = length > 0 && index + length <= bytes.count
                if valid {
                    for offset in 1..<length where bytes[index + offset] & 0xC0 != 0x80 {
                        valid = false
                        break
                    }
                }
                if valid {
                    multibyte += 1
                    index += length
                } else {
                    invalid += 1
                    index += 1
                }
            }
        }
        return (multibyte, invalid)
    }
}

/// Content-Transfer-Encoding: base64 and quoted-printable.
public enum TransferEncoding {
    /// Decodes base64, ignoring line breaks and anything else outside the alphabet, and tolerating missing padding
    /// and padding in the middle (where a sender glued two pieces together).
    public static func decodeBase64(_ text: String) -> Data? {
        decodeBase64(Data(text.utf8))
    }

    public static func decodeBase64(_ data: Data) -> Data? {
        var output = [UInt8]()
        output.reserveCapacity(data.count / 4 * 3 + 3)
        var quantum: UInt32 = 0
        var count = 0

        func flushPartial() {
            // Two characters make one byte, three make two; a lone character carries too few bits for any.
            if count == 2 {
                output.append(UInt8(truncatingIfNeeded: quantum >> 4))
            } else if count == 3 {
                output.append(UInt8(truncatingIfNeeded: quantum >> 10))
                output.append(UInt8(truncatingIfNeeded: quantum >> 2))
            }
            quantum = 0
            count = 0
        }

        for byte in data {
            let value: UInt8
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte - UInt8(ascii: "0") + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62  // "-" and "_" are base64url
            case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
            case UInt8(ascii: "="):
                flushPartial()
                continue
            default:
                continue
            }
            quantum = quantum << 6 | UInt32(value)
            count += 1
            if count == 4 {
                output.append(UInt8(truncatingIfNeeded: quantum >> 16))
                output.append(UInt8(truncatingIfNeeded: quantum >> 8))
                output.append(UInt8(truncatingIfNeeded: quantum))
                quantum = 0
                count = 0
            }
        }
        flushPartial()
        return Data(output)
    }

    /// Decodes quoted-printable: "=XX" bytes and soft line breaks ("=" at a line's end). Spaces and tabs at the end
    /// of a line are dropped, since mail servers may add them on the way. In headers (RFC 2047 Q encoding) the caller
    /// has already turned "_" into spaces. Malformed escapes are kept as they are.
    public static func decodeQuotedPrintable(_ data: Data, isHeader: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var spaces: [UInt8] = []  // literal spaces and tabs, held back until it's clear they don't end a line
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09:
                if isHeader { output.append(byte) } else { spaces.append(byte) }
                index += 1
            case 0x0A:
                spaces.removeAll()
                output.append(0x0A)
                index += 1
            case 0x0D where index + 1 < bytes.count && bytes[index + 1] == 0x0A:
                spaces.removeAll()
                output.append(0x0D)
                output.append(0x0A)
                index += 2
            case UInt8(ascii: "="):
                output.append(contentsOf: spaces)
                spaces.removeAll()
                // A soft line break: "=", optional spaces, then CRLF or LF (or the end of the text).
                var next = index + 1
                while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
                if next < bytes.count, bytes[next] == 0x0D, next + 1 < bytes.count, bytes[next + 1] == 0x0A {
                    index = next + 2
                    continue
                }
                if next < bytes.count, bytes[next] == 0x0A {
                    index = next + 1
                    continue
                }
                if next >= bytes.count, !isHeader {
                    index = next
                    continue
                }
                if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
                index += 1
            default:
                output.append(contentsOf: spaces)
                spaces.removeAll()
                output.append(byte)
                index += 1
            }
        }
        output.append(contentsOf: spaces)
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    /// Two uppercase hexadecimal digits for a byte ("3D").
    static func hexDigits(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    /// Base64 in lines of 76 characters separated by CRLF, for attachments.
    static func encodeBase64Lines(_ data: Data) -> [UInt8] {
        [UInt8](data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
    }

    /// Quoted-printable for text whose lines already end with CRLF: lines of at most 76 characters, with "="
    /// soft breaks, and spaces at the ends of lines encoded so no server can strip them.
    static func encodeQuotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count + bytes.count / 8)
        var lineLength = 0

        func emit(_ piece: [UInt8]) {
            if lineLength + piece.count > 75 {
                output.append(contentsOf: [UInt8(ascii: "="), 0x0D, 0x0A])
                lineLength = 0
            }
            output.append(contentsOf: piece)
            lineLength += piece.count
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                output.append(contentsOf: [0x0D, 0x0A])
                lineLength = 0
                index += 2
                continue
            }
            let endsLine = index + 1 == bytes.count
                || (bytes[index + 1] == 0x0D && index + 2 < bytes.count && bytes[index + 2] == 0x0A)
            switch byte {
            case 0x20, 0x09:
                emit(endsLine ? Array(("=" + hexDigits(byte)).utf8) : [byte])
            case 33...126 where byte != UInt8(ascii: "="):
                emit([byte])
            default:
                emit(Array(("=" + hexDigits(byte)).utf8))
            }
            index += 1
        }
        return output
    }
}

/// Dates in mail headers (RFC 5322), read tolerantly and written exactly.
public enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zones: [String: Int] = ["UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5,
                                               "MST": -7, "MDT": -6, "PST": -8, "PDT": -7]

    /// Reads "Sat, 21 Nov 2026 13:45:00 -0500" and the variations mail really has: no weekday, no seconds, two-digit
    /// years, named, missing or "+05:30" zones, comments, and ISO 8601 dates.
    public static func parse(_ text: String) -> Date? {
        var cleaned = text.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        var day: Int?, month: Int?, year: Int?, hour = 0, minute = 0, second = 0
        var offsetSeconds: Int?
        var sawTime = false
        for token in tokens {
            let lower = token.lowercased()
            if let offset = zoneOffset(token) {
                offsetSeconds = offset
            } else if let monthIndex = months.firstIndex(where: { lower.hasPrefix($0) }), month == nil, lower.first?.isLetter == true {
                month = monthIndex + 1
            } else if token.contains(":"), !sawTime {
                let parts = token.split(separator: ":").map { Int($0) }
                guard parts.count >= 2, let h = parts[0], let m = parts[1] else { continue }
                hour = h
                minute = m
                second = parts.count > 2 ? (parts[2] ?? 0) : 0
                sawTime = true
            } else if let hours = zones[token.uppercased()] {
                offsetSeconds = hours * 3600
            } else if let number = Int(token) {
                if day == nil, number >= 1, number <= 31, token.count <= 2 { day = number } else if year == nil { year = number }
            }
        }
        guard let day, let month, var year else { return parseISO(text) }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds ?? 0) ?? .gmt
        return calendar.date(from: components)
    }

    /// "+0530", "-0500" or "+05:30" as seconds from GMT.
    private static func zoneOffset(_ token: String) -> Int? {
        guard let sign = token.first, sign == "+" || sign == "-" else { return nil }
        let digits = token.dropFirst().filter { $0 != ":" }
        guard digits.count == 4, digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
        if token.contains(":"), token.count != 6 { return nil }
        let seconds = (value / 100) * 3600 + (value % 100) * 60
        return sign == "-" ? -seconds : seconds
    }

    /// "Sat, 21 Nov 2026 13:45:00 -0500", in the given time zone.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private static func parseISO(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
}
