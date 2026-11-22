import Foundation

/// Dates as the web services write them: RFC 3339 date-times and plain "2026-11-21" days.
enum WebDate {
    /// Reads an RFC 3339 / ISO 8601 date-time: "2026-11-21T10:00:00-05:00", "2026-11-21T15:00:00Z", or Microsoft's
    /// "2026-11-21T15:00:00.0000000" (no zone, read in `defaultZone`). A plain day reads as midnight in `defaultZone`.
    static func parse(_ text: String, defaultZone: TimeZone = .gmt) -> Date? {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start >= 0, start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }

        guard let year = digits(0, 4), byte(4) == UInt8(ascii: "-"), let month = digits(5, 2), byte(7) == UInt8(ascii: "-"),
              let day = digits(8, 2), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        var index = 10
        var fraction = 0.0
        if let separator = byte(index), separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == 0x20 {
            guard let hour = digits(11, 2), byte(13) == UInt8(ascii: ":"), let minute = digits(14, 2),
                  (0...24).contains(hour), (0...59).contains(minute) else { return nil }
            components.hour = hour
            components.minute = minute
            index = 16
            if byte(index) == UInt8(ascii: ":") {
                guard let second = digits(17, 2), (0...60).contains(second) else { return nil }
                components.second = second
                index = 19
                if let mark = byte(index), mark == UInt8(ascii: ".") || mark == UInt8(ascii: ",") {
                    index += 1
                    var scale = 0.1
                    while let digit = byte(index), (48...57).contains(digit) {
                        fraction += Double(digit - 48) * scale
                        scale /= 10
                        index += 1
                    }
                }
            }
        }
        var zone = defaultZone
        if let mark = byte(index) {
            if mark == UInt8(ascii: "Z") || mark == UInt8(ascii: "z") {
                zone = .gmt
                index += 1
            } else if mark == UInt8(ascii: "+") || mark == UInt8(ascii: "-") {
                guard let hours = digits(index + 1, 2) else { return nil }
                var minutesStart = index + 3
                if byte(minutesStart) == UInt8(ascii: ":") { minutesStart += 1 }
                let minutes = digits(minutesStart, 2) ?? 0
                index = digits(minutesStart, 2) == nil ? index + 3 : minutesStart + 2
                let sign = mark == UInt8(ascii: "-") ? -1 : 1
                guard let offset = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) else { return nil }
                zone = offset
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }

    /// Reads "2026-11-21" (or the day part of a longer date-time) as midnight starting that day in `zone`, the way
    /// all-day events and birthdays are kept.
    static func localMidnight(_ text: String, in zone: TimeZone = .current) -> Date? {
        guard let parts = dayComponents(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }

    /// The year, month and day of "2026-11-21" (or of a longer date-time's first ten characters).
    static func dayComponents(_ text: String) -> DateComponents? {
        let day = String(text.trimmingCharacters(in: .whitespaces).prefix(10))
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]),
              let dayOfMonth = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        return DateComponents(year: year, month: month, day: dayOfMonth)
    }

    /// "2026-11-21T15:00:00Z".
    static func utcString(_ date: Date) -> String { utcLocalString(date) + "Z" }

    /// "2026-11-21T15:00:00", in UTC but without the "Z" (Microsoft's form, with the zone given beside it).
    static func utcLocalString(_ date: Date) -> String { dateTimeString(date, in: .gmt) }

    /// "2026-11-21T09:00:00" in a time zone, without the zone.
    static func dateTimeString(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
        return day + "T\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))"
    }

    /// "2026-11-21": the day a moment falls on in `zone`.
    static func dayString(_ date: Date, in zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    /// Midnight starting the day a moment falls on in `zone`.
    static func startOfDay(_ date: Date, in zone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.startOfDay(for: date)
    }

    private static func pad(_ number: Int?, _ width: Int) -> String {
        let text = String(max(number ?? 0, 0))
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// Base64 as the web services want it.
enum WebBase64 {
    /// base64url without padding (RFC 4648 §5), for the `raw` fields of Google's mail API.
    static func urlEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Addresses and message IDs from header values the services hand back as text.
enum WebAddresses {
    /// The addresses in a From, To or Cc value: `"Rivera, Jamie" <jamie@example.com>, sam@example.com (Sam)`, groups and
    /// encoded words included. Pieces that hold no address are skipped.
    static func parse(_ value: String) -> [MailAddress] {
        var addresses: [MailAddress] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        func finish() {
            if let address = address(from: current) { addresses.append(address) }
            current = ""
        }
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes || commentDepth > 0 {
                current.append(character)
                escaped = true
                continue
            }
            if inQuotes {
                if character == "\"" { inQuotes = false }
                current.append(character)
                continue
            }
            switch character {
            case "\"" where commentDepth == 0:
                inQuotes = true
                current.append(character)
            case "(":
                commentDepth += 1
                current.append(character)
            case ")" where commentDepth > 0:
                commentDepth -= 1
                current.append(character)
            case "<" where commentDepth == 0:
                angleDepth += 1
                current.append(character)
            case ">" where commentDepth == 0 && angleDepth > 0:
                angleDepth -= 1
                current.append(character)
            case ",", ";":
                if commentDepth == 0 && angleDepth == 0 { finish() } else { current.append(character) }
            case ":" where commentDepth == 0 && angleDepth == 0 && !current.contains("@"):
                current = ""  // A group's name ("Team: a@example.com, b@example.com;").
            default:
                current.append(character)
            }
        }
        finish()
        return addresses
    }

    /// One address: `Name <address>`, `<address>`, or `address (Name)`.
    private static func address(from piece: String) -> MailAddress? {
        let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else { return nil }
            let name = cleanName(removingComments(String(text[..<open])))
            return MailAddress(name: name, email: email)
        }
        var comment = ""
        var bare = ""
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
                if depth == 1 { continue }
            } else if character == ")", depth > 0 {
                depth -= 1
                if depth == 0 { continue }
            }
            if depth > 0 { comment.append(character) } else { bare.append(character) }
        }
        let email = bare.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        guard !email.isEmpty, !email.contains(" ") else { return nil }
        return MailAddress(name: cleanName(comment), email: email)
    }

    private static func removingComments(_ text: String) -> String {
        guard text.contains("(") else { return text }
        return text.replacingOccurrences(of: "\\([^()]*\\)", with: " ", options: .regularExpression)
    }

    /// A display name without its quotes and escapes, encoded words decoded, spaces tidied.
    private static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
            var unescaped = ""
            var escaped = false
            for character in name {
                if escaped || character != "\\" {
                    unescaped.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            name = unescaped
        }
        name = EncodedWords.decode(name)
        name = name.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// The message IDs in a References or In-Reply-To value, with their angle brackets.
    static func messageIDs(_ value: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            ids.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            ids = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).map(String.init)
        }
        return ids
    }

    /// A Message-ID without its angle brackets ("<abc@example.com>" as "abc@example.com"), or nil when nothing's left.
    static func bareMessageID(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") { text.removeFirst() }
        if text.hasSuffix(">") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Text from event descriptions and notes, which may or may not be HTML.
enum WebText {
    /// Whether the text has HTML tags in it (an address in angle brackets doesn't count).
    static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: "</?[A-Za-z][A-Za-z0-9]*(\\s[^<>]*)?/?>", options: .regularExpression) != nil
    }

    /// Plain text from HTML, with blank lines between blocks kept to one.
    static func plainText(fromHTML html: String) -> String {
        let text = HTMLText.plainText(fromHTML: html)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text from a description that may be HTML: converted when it has tags, kept as it is otherwise.
    static func plainText(fromPossibleHTML text: String) -> String {
        looksLikeHTML(text) ? plainText(fromHTML: text) : text
    }
}

/// Colors as "#RRGGBB".
enum WebColor {
    /// "#16a766" or "16A766" as "#16A766"; nil for anything that isn't a six-digit hex color.
    static func hex(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value.uppercased()
    }

    /// A color's red, green and blue, 0 to 255 each; nil for anything `hex` turns down.
    static func components(_ text: String?) -> (red: Int, green: Int, blue: Int)? {
        guard let hex = hex(text), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
    }

    /// The palette color closest to a color as people see it (a distance that weighs red, green and blue the way eyes
    /// do), spelled as the palette spells it. Nil when the color can't be read or the palette is empty.
    static func nearest(to text: String?, in palette: [String]) -> String? {
        guard let wanted = components(text) else { return nil }
        var best: (color: String, distance: Double)?
        for color in palette {
            guard let candidate = components(color) else { continue }
            let meanRed = Double(wanted.red + candidate.red) / 2
            let red = Double(wanted.red - candidate.red), green = Double(wanted.green - candidate.green)
            let blue = Double(wanted.blue - candidate.blue)
            let distance = (2 + meanRed / 256) * red * red + 4 * green * green + (2 + (255 - meanRed) / 256) * blue * blue
            if distance < best?.distance ?? .infinity { best = (color, distance) }
        }
        return best?.color
    }

    /// Black or white text, whichever reads better on a background ("#000000" or "#ffffff").
    static func readableText(on background: String) -> String {
        guard let color = components(background) else { return "#000000" }
        func linear(_ channel: Int) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        // The contrast each would have against the background.
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? "#000000" : "#ffffff"
    }
}

/// The raw messages the web services upload.
enum WebMIME {
    /// The message as RFC 822 text, with a Bcc header when it has Bcc recipients: the web services find every
    /// recipient in the headers, and take Bcc out themselves before the message goes anywhere.
    static func build(_ message: OutgoingMessage) -> Data {
        MIMEBuilder.buildForSaving(message)
    }

    /// Whether the header block (up to the first empty line) has a field with this name.
    static func hasHeader(_ name: String, in data: Data) -> Bool {
        let end = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? data.range(of: Data("\n\n".utf8))?.lowerBound
            ?? data.endIndex
        let text = String(decoding: data[data.startIndex..<end], as: UTF8.self)
        let prefix = name.lowercased() + ":"
        return text.split(whereSeparator: \.isNewline).contains { $0.lowercased().hasPrefix(prefix) }
    }
}

/// Helpers the calendar services share.
enum WebEvents {
    /// The event with a meeting link the calendar can't hold by itself (a FaceTime link the person pasted) written
    /// into the location, or the notes when there's a location already, so it's saved and found again.
    static func withPastedLink(_ event: CalendarEvent, original: CalendarEvent?, addingConference: Bool) -> CalendarEvent {
        guard !addingConference, let conference = event.conference, conference != original?.conference else { return event }
        let link = conference.joinURL.absoluteString
        guard !(event.location ?? "").contains(link), !(event.notes ?? "").contains(link) else { return event }
        var edited = event
        if (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edited.location = link
        } else {
            edited.notes = [event.notes, link].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return edited
    }
}
