import Foundation

/// Decodes RFC 2047 encoded words ("=?utf-8?B?SGk=?=") in header text.
public enum EncodedWords {
    /// The text with every well-formed encoded word decoded. Whitespace between two encoded words is dropped, as the
    /// standard says; malformed words are left as they are.
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var result = ""
        var rest = Substring(text)
        var pendingSpace = ""
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            guard let word = parseWord(rest[start.lowerBound...]) else {
                result += pendingSpace + before + "=?"
                pendingSpace = ""
                lastWasEncoded = false
                rest = rest[start.upperBound...]
                continue
            }
            if lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) {
                // Whitespace between adjacent encoded words isn't part of the text.
            } else {
                result += pendingSpace + before
            }
            pendingSpace = ""
            result += word.text
            lastWasEncoded = true
            rest = rest[word.end...]
        }
        result += pendingSpace + rest
        return result
    }

    private static func parseWord(_ text: Substring) -> (text: String, end: Substring.Index)? {
        // =?charset?encoding?text?=
        let afterOpen = text.index(text.startIndex, offsetBy: 2)
        guard let charsetEnd = text[afterOpen...].firstIndex(of: "?") else { return nil }
        let encodingStart = text.index(after: charsetEnd)
        guard encodingStart < text.endIndex, let encodingEnd = text[encodingStart...].firstIndex(of: "?"),
              text.distance(from: encodingStart, to: encodingEnd) == 1 else { return nil }
        let payloadStart = text.index(after: encodingEnd)
        guard let close = text[payloadStart...].range(of: "?=") else { return nil }
        var charset = String(text[afterOpen..<charsetEnd])
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }  // RFC 2231 language
        let payload = text[payloadStart..<close.lowerBound]
        guard !payload.contains(" ") else { return nil }
        let bytes: Data?
        switch text[encodingStart].uppercased() {
        case "B": bytes = TransferEncoding.decodeBase64(String(payload))
        case "Q": bytes = TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8), isHeader: true)
        default: bytes = nil
        }
        guard let bytes else { return nil }
        return (Charsets.decode(bytes, charset: charset), close.upperBound)
    }
}

/// Turns bytes in a named character set into text.
public enum Charsets {
    /// Decodes `data` in the character set `charset` names (an IANA name like "iso-8859-1" or "Shift_JIS"). Unknown or
    /// missing names, and text that isn't valid in the named set, fall back to UTF-8, then Windows-1252, so mail with
    /// a wrong label still reads.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// The Foundation encoding for an IANA character set name, or nil if it's unknown.
    public static func encoding(named charset: String?) -> String.Encoding? {
        guard var name = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased(), !name.isEmpty else { return nil }
        // Labels mail gets wrong, read as the larger sets their senders really used.
        switch name {
        case "utf8", "utf-8", "unicode-1-1-utf-8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return nil  // decoded as UTF-8 or Windows-1252 by the fallback
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1", "iso_8859-1", "l1", "cp819": name = "windows-1252"
        case "gb2312", "gbk", "x-gbk", "cp936": name = "gb18030"
        case "ks_c_5601-1987", "ks_c_5601", "korean", "cp949": name = "euc-kr"
        case "tis-620", "iso-8859-11": name = "windows-874"
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

/// Content-Transfer-Encoding: base64 and quoted-printable.
public enum TransferEncoding {
    /// Decodes base64, ignoring line breaks and anything else outside the alphabet, and tolerating missing padding.
    public static func decodeBase64(_ text: String) -> Data? {
        decodeBase64(Data(text.utf8))
    }

    public static func decodeBase64(_ data: Data) -> Data? {
        var clean = [UInt8]()
        clean.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"):
                clean.append(byte)
            case UInt8(ascii: "-"): clean.append(UInt8(ascii: "+"))  // base64url
            case UInt8(ascii: "_"): clean.append(UInt8(ascii: "/"))
            case UInt8(ascii: "="): break
            default: continue
            }
        }
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean))
    }

    /// Decodes quoted-printable: "=XX" bytes and soft line breaks ("=" at a line's end). In headers (RFC 2047 Q
    /// encoding) the caller has already turned "_" into spaces. Malformed escapes are kept as they are.
    public static func decodeQuotedPrintable(_ data: Data, isHeader: Bool = false) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                // A soft line break: "=" then optional spaces, then CRLF or LF.
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
            }
            output.append(byte)
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
    /// years, named or missing zones, comments, and ISO 8601 dates.
    public static func parse(_ text: String) -> Date? {
        var cleaned = text.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).map(String.init)
        var day: Int?, month: Int?, year: Int?, hour = 0, minute = 0, second = 0
        var offsetSeconds: Int?
        var sawTime = false
        for token in tokens {
            let lower = token.lowercased()
            if let monthIndex = months.firstIndex(where: { lower.hasPrefix($0) }), month == nil, lower.first?.isLetter == true {
                month = monthIndex + 1
            } else if token.contains(":"), !sawTime {
                let parts = token.split(separator: ":").map { Int($0) }
                guard parts.count >= 2, let h = parts[0], let m = parts[1] else { continue }
                hour = h
                minute = m
                second = parts.count > 2 ? (parts[2] ?? 0) : 0
                sawTime = true
            } else if (token.hasPrefix("+") || token.hasPrefix("-")), token.count == 5, let value = Int(token.dropFirst()) {
                let sign = token.hasPrefix("-") ? -1 : 1
                offsetSeconds = sign * ((value / 100) * 3600 + (value % 100) * 60)
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
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds ?? 0) ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
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
