import Foundation

/// A message's ENVELOPE: the header fields a message list needs, already split up by the server.
public struct IMAPEnvelope: Sendable, Hashable {
    public var date: Date?
    /// The subject, with encoded words decoded.
    public var subject: String
    public var from: [MailAddress]
    public var sender: [MailAddress]
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    /// The first message ID in In-Reply-To, with its angle brackets.
    public var inReplyTo: String?
    /// The Message-ID, with its angle brackets.
    public var messageID: String?

    public init(date: Date? = nil, subject: String = "", from: [MailAddress] = [], sender: [MailAddress] = [],
                replyTo: [MailAddress] = [], to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                inReplyTo: String? = nil, messageID: String? = nil) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }

    /// Reads `(date subject from sender reply-to to cc bcc in-reply-to message-id)`. Missing or odd fields are left
    /// empty rather than failing the whole envelope.
    public init?(_ value: IMAPValue) {
        guard let fields = value.items else { return nil }
        func field(_ index: Int) -> IMAPValue { index < fields.count ? fields[index] : .null }
        self.init()
        date = field(0).data.flatMap { MailDate.parse(Self.headerText($0)) }
        subject = field(1).data.map { EncodedWords.decode(Self.headerText($0)) } ?? ""
        from = Self.addresses(field(2))
        sender = Self.addresses(field(3))
        replyTo = Self.addresses(field(4))
        to = Self.addresses(field(5))
        cc = Self.addresses(field(6))
        bcc = Self.addresses(field(7))
        inReplyTo = field(8).data.flatMap { MessageIDs.first(in: Self.headerText($0)) }
        messageID = field(9).data.flatMap { data in
            let text = Self.headerText(data)
            return MessageIDs.first(in: text) ?? (text.isEmpty ? nil : text)
        }
    }

    /// Reads a list of addresses, each `(name adl mailbox host)`. Groups (RFC 5322 "Team: a@b, c@d;") arrive as a
    /// start marker with a NIL host, the members, and an end marker; the members are kept, the markers dropped.
    static func addresses(_ value: IMAPValue) -> [MailAddress] {
        guard let entries = value.items else { return [] }
        var result: [MailAddress] = []
        for entry in entries {
            guard let parts = entry.items, parts.count >= 4 else { continue }
            guard let host = parts[3].data.map(headerText) else { continue }  // A group's start or end marker.
            guard let mailbox = parts[2].data.map(headerText), !mailbox.isEmpty else { continue }
            let name = parts[0].data.map { EncodedWords.decode(headerText($0)) }
            // Servers mark an address that had no domain with a made-up host.
            let hasHost = !host.isEmpty && host != ".MISSING-HOST-NAME." && host != "MISSING_DOMAIN"
            result.append(MailAddress(name: name, email: hasHost ? "\(mailbox)@\(host)" : mailbox))
        }
        return result
    }

    /// Header text from a server string: UTF-8 (or Windows-1252 for old 8-bit mail), unfolded.
    static func headerText(_ data: Data) -> String {
        Charsets.decode(data, charset: "utf-8").replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// IMAP's dates: INTERNALDATE ("17-Jul-1996 02:44:25 -0700") and the day-only dates searches use ("1-Feb-1994").
public enum IMAPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Reads an INTERNALDATE. The day may be padded with a space (" 7-Jul-1996 …").
    public static func parse(_ text: String) -> Date? {
        let fields = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count >= 2 else { return nil }
        let dateParts = fields[0].split(separator: "-")
        let timeParts = fields[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3, let day = Int(dateParts[0]), let year = Int(dateParts[2]),
              let monthIndex = months.firstIndex(of: dateParts[1].lowercased()),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]),
              (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        var offset = 0
        if fields.count >= 3 {
            let zone = fields[2]
            guard zone.count == 5, let sign = zone.first, sign == "+" || sign == "-", let value = Int(zone.dropFirst()) else {
                return nil
            }
            offset = (sign == "-" ? -1 : 1) * ((value / 100) * 3600 + (value % 100) * 60)
        }
        var components = DateComponents()
        components.year = year
        components.month = monthIndex + 1
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar.date(from: components)
    }

    /// An INTERNALDATE for APPEND: "17-Jul-1996 02:44:25 -0700", in the given time zone.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// A day for SEARCH SINCE and BEFORE: "1-Feb-1994".
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }
}

/// Message IDs in References, In-Reply-To and Message-ID headers.
enum MessageIDs {
    /// Each `<…>` in the text, in order. Text without angle brackets gives its words that look like addresses.
    static func all(in text: String) -> [String] {
        var ids: [String] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = String(rest[open...close])
            if id.count > 2 { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty { ids = text.split(whereSeparator: \.isWhitespace).filter { $0.contains("@") }.map(String.init) }
        return ids
    }

    static func first(in text: String) -> String? { all(in: text).first }
}

/// Header fields from a block of header lines, as a `BODY[HEADER.FIELDS (…)]` fetch returns them.
enum IMAPHeaderFields {
    /// Lowercased field names and their unfolded values; the first field of each name wins.
    static func parse(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        var name: String?
        var value = ""
        func finish() {
            if let name, fields[name] == nil { fields[name] = value.trimmingCharacters(in: .whitespaces) }
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = line.first, first == " " || first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                finish()
                name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                value = String(line[line.index(after: colon)...])
            }
        }
        finish()
        return fields
    }
}
