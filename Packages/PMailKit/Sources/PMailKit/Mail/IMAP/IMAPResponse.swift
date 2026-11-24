import Foundation

/// One value in an IMAP response: a bare word, a string, NIL, or a parenthesized list of more values.
public indirect enum IMAPValue: Sendable, Hashable {
    /// A bare word or number, as the server wrote it ("FLAGS", "42", "\Seen", "BODY[1]<0>").
    case atom(String)
    /// A quoted string or a literal, as the bytes the server sent.
    case string(Data)
    /// NIL, the server's way of saying there's no value.
    case null
    /// A parenthesized list.
    case list([IMAPValue])

    /// The value as text: an atom as it is, a string decoded as UTF-8. Nil for NIL and lists.
    public var text: String? {
        switch self {
        case let .atom(atom): return atom
        case let .string(data): return String(decoding: data, as: UTF8.self)
        case .null, .list: return nil
        }
    }

    /// The bytes of a string or an atom. Nil for NIL and lists.
    public var data: Data? {
        switch self {
        case let .atom(atom): return Data(atom.utf8)
        case let .string(data): return data
        case .null, .list: return nil
        }
    }

    /// The value as a number, for atoms (and strings) made of digits.
    public var number: Int? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(text)
    }

    /// The value as a UID, UIDVALIDITY or other unsigned 32-bit number.
    public var uint32: UInt32? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return UInt32(text)
    }

    /// The values inside a list. Nil for anything else.
    public var items: [IMAPValue]? {
        if case let .list(items) = self { return items }
        return nil
    }

    public var isNull: Bool { self == .null }
}

/// The word that starts a status response.
public enum IMAPStatus: String, Sendable, Hashable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
    case preauth = "PREAUTH"
    case bye = "BYE"
}

/// A status response (OK, NO, BAD, PREAUTH or BYE) with its optional response code and the server's own words.
public struct IMAPStatusResponse: Sendable, Hashable {
    public var status: IMAPStatus
    public var code: IMAPResponseCode?
    public var text: String

    public init(status: IMAPStatus, code: IMAPResponseCode? = nil, text: String = "") {
        self.status = status
        self.code = code
        self.text = text
    }
}

/// The bracketed code at the start of a status response's text, such as `[UIDVALIDITY 3857529045]`.
public enum IMAPResponseCode: Sendable, Hashable {
    /// Text the server wants shown to the person.
    case alert
    case capability([String])
    case permanentFlags([String])
    case uidValidity(UInt32)
    case uidNext(UInt32)
    /// The sequence number of the first unseen message.
    case unseen(Int)
    /// Where an appended message went (UIDPLUS).
    case appendUID(uidValidity: UInt32, uid: UInt32)
    /// Where copied or moved messages went, in the same order as `source` (UIDPLUS).
    case copyUID(uidValidity: UInt32, source: [UInt32], destination: [UInt32])
    /// The mailbox's highest modification sequence (CONDSTORE): it grows whenever a message is added or changed.
    case highestModSeq(UInt64)
    /// The mailbox doesn't keep modification sequences (CONDSTORE).
    case noModSeq
    /// The destination mailbox doesn't exist, and creating it might help.
    case tryCreate
    case readOnly
    case readWrite
    /// Any other code, with whatever followed its name.
    case other(name: String, text: String)
}

/// An untagged response: data the server sends before finishing a command, or on its own.
public enum IMAPUntaggedResponse: Sendable, Hashable {
    /// OK, NO, BAD, PREAUTH or BYE.
    case condition(IMAPStatusResponse)
    case capability([String])
    case list(IMAPMailbox)
    /// A STATUS response: attribute names in capitals ("MESSAGES", "UNSEEN") and their values.
    case status(mailbox: String, attributes: [String: Int])
    case search([UInt32])
    case flags([String])
    case exists(Int)
    case recent(Int)
    case expunge(Int)
    case fetch(IMAPFetchResponse)
    /// Anything else (ENABLED, ID, NAMESPACE…), or a response that couldn't be read.
    case other(name: String, values: [IMAPValue])
}

/// One response from the server.
public enum IMAPResponse: Sendable, Hashable {
    /// A `+` continuation request: the server is ready for a literal or an authentication response.
    case continuation(String)
    case untagged(IMAPUntaggedResponse)
    /// The end of a command.
    case tagged(tag: String, IMAPStatusResponse)
}

/// What a FETCH response said about one message.
public struct IMAPFetchResponse: Sendable, Hashable {
    public var sequenceNumber: Int
    public var uid: UInt32?
    public var flags: [String]?
    public var internalDate: Date?
    public var size: Int?
    public var envelope: IMAPEnvelope?
    public var bodyStructure: IMAPBodyPart?
    /// Body sections, keyed by their section text in capitals without any partial range: "" for the whole
    /// message, "1.2", "TEXT", "HEADER.FIELDS (REFERENCES IN-REPLY-TO)".
    public var sections: [String: Data]
    /// The server's own conversation ID (X-GM-THRID), from servers that offer X-GM-EXT-1.
    public var threadID: String?
    /// The message's labels (X-GM-LABELS), from servers that offer X-GM-EXT-1: Gmail's own ones with a backslash
    /// ("\Inbox", "\Important"), the account's by name, decoded ("Work/Projects").
    public var gmailLabels: [String]?
    /// The message's own ID (X-GM-MSGID), the same in every mailbox it shows in, from servers that offer X-GM-EXT-1.
    public var gmailMessageID: String?
    /// The message's modification sequence (CONDSTORE).
    public var modSeq: UInt64?

    public init(sequenceNumber: Int, uid: UInt32? = nil, flags: [String]? = nil, internalDate: Date? = nil, size: Int? = nil,
                envelope: IMAPEnvelope? = nil, bodyStructure: IMAPBodyPart? = nil, sections: [String: Data] = [:],
                threadID: String? = nil, gmailLabels: [String]? = nil) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
        self.envelope = envelope
        self.bodyStructure = bodyStructure
        self.sections = sections
        self.threadID = threadID
        self.gmailLabels = gmailLabels
    }

    /// Reads the attribute list of a FETCH response: `(UID 7 FLAGS (\Seen) BODY[1]<0> {12}…)`.
    init(sequenceNumber: Int, attributes items: [IMAPValue]) {
        self.init(sequenceNumber: sequenceNumber)
        var index = 0
        while index + 1 < items.count {
            defer { index += 2 }
            guard case let .atom(name) = items[index] else { continue }
            let value = items[index + 1]
            switch name.uppercased() {
            case "UID": uid = value.uint32
            case "FLAGS": flags = value.items?.compactMap(\.text) ?? []
            case "INTERNALDATE": internalDate = value.text.flatMap(IMAPDate.parse)
            case "RFC822.SIZE": size = value.number
            case "ENVELOPE": envelope = IMAPEnvelope(value)
            case "BODYSTRUCTURE", "BODY": bodyStructure = IMAPBodyPart.parse(value) ?? bodyStructure
            case "X-GM-THRID": threadID = value.text
            case "X-GM-MSGID": gmailMessageID = value.text
            case "MODSEQ": modSeq = (value.items?.first?.text ?? value.text).flatMap { UInt64($0) }
            case "X-GM-LABELS":
                gmailLabels = (value.items ?? []).compactMap(\.text).map { $0.hasPrefix("\\") ? $0 : IMAPMailboxName.decode($0) }
            case "RFC822": sections[""] = value.data ?? Data()
            case "RFC822.HEADER": sections["HEADER"] = value.data ?? Data()
            case "RFC822.TEXT": sections["TEXT"] = value.data ?? Data()
            default:
                if let key = Self.sectionKey(fromItemName: name) { sections[key] = value.data ?? Data() }
            }
        }
    }

    /// A body section's bytes ("" for the whole message, "1.2" for a part), however the server spaced or cased it.
    public func section(_ spec: String) -> Data? {
        sections[Self.normalizedSection(spec)]
    }

    /// The bytes of the first `HEADER.FIELDS (…)` section.
    public var headerFields: Data? {
        sections.keys.sorted().first { $0.hasPrefix("HEADER.FIELDS") }.flatMap { sections[$0] }
    }

    /// Whether the message has a flag (case doesn't matter: "\Seen", "\SEEN").
    public func hasFlag(_ flag: String) -> Bool {
        flags?.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } ?? false
    }

    /// Adds what a later FETCH response said about the same message (servers may split one answer into several).
    public mutating func merge(_ other: IMAPFetchResponse) {
        uid = other.uid ?? uid
        flags = other.flags ?? flags
        internalDate = other.internalDate ?? internalDate
        size = other.size ?? size
        envelope = other.envelope ?? envelope
        bodyStructure = other.bodyStructure ?? bodyStructure
        threadID = other.threadID ?? threadID
        gmailLabels = other.gmailLabels ?? gmailLabels
        gmailMessageID = other.gmailMessageID ?? gmailMessageID
        modSeq = other.modSeq ?? modSeq
        sections.merge(other.sections) { _, new in new }
    }

    /// The section key for a fetch item name like `BODY[HEADER.FIELDS (DATE)]<0>`, or nil if it isn't a section.
    static func sectionKey(fromItemName name: String) -> String? {
        guard let open = name.firstIndex(of: "["), let close = name[open...].firstIndex(of: "]") else { return nil }
        let item = name[..<open].uppercased()
        guard ["BODY", "BINARY", "BODY.PEEK", "BINARY.PEEK"].contains(item) else { return nil }
        return normalizedSection(String(name[name.index(after: open)..<close]))
    }

    /// Section text in one spelling: capitals, single spaces, no quotes around header field names.
    static func normalizedSection(_ spec: String) -> String {
        let words = spec.uppercased().replacingOccurrences(of: "\"", with: "").split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.joined(separator: " ").replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
    }
}

/// A mailbox as LIST describes it.
public struct IMAPMailbox: Sendable, Hashable {
    /// The full path, decoded ("Projects/Café"). The inbox is always "INBOX".
    public var name: String
    /// The path as the server spells it (modified UTF-7), for commands.
    public var rawName: String
    /// The character between levels of the hierarchy ("/" or "."); nil when the server has no hierarchy.
    public var delimiter: String?
    /// The attributes, as the server sent them ("\HasNoChildren", "\Sent").
    public var attributes: [String]

    public init(name: String, rawName: String? = nil, delimiter: String? = "/", attributes: [String] = []) {
        self.name = IMAPMailboxName.normalizingInbox(name, delimiter: delimiter)
        self.rawName = rawName ?? IMAPMailboxName.encode(name)
        self.delimiter = delimiter
        self.attributes = attributes
    }

    /// Reads the values after `LIST`: `(\HasNoChildren \Sent) "/" "Sent Messages"`.
    init?(listValues values: [IMAPValue]) {
        guard values.count >= 3, let flags = values[0].items, let nameData = values[2].data else { return nil }
        let raw = String(decoding: nameData, as: UTF8.self)
        let delimiter = values[1].text.flatMap { $0.isEmpty ? nil : $0 }
        self.init(name: IMAPMailboxName.decode(raw), rawName: raw, delimiter: delimiter, attributes: flags.compactMap(\.text))
    }

    /// Whether the mailbox has an attribute (case doesn't matter).
    public func hasAttribute(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }

    /// Whether the mailbox can hold messages (some only hold other mailboxes).
    public var isSelectable: Bool { !hasAttribute("\\Noselect") && !hasAttribute("\\NonExistent") }

    public var isInbox: Bool { name == "INBOX" }

    /// The role its special-use attribute (RFC 6154) gives it, if any.
    public var specialUseRole: FolderRole? {
        if isInbox { return .inbox }
        let roles: [(String, FolderRole)] = [("\\Sent", .sent), ("\\Drafts", .drafts), ("\\Trash", .trash), ("\\Junk", .spam),
                                             ("\\Archive", .archive), ("\\All", .allMail)]
        return roles.first { hasAttribute($0.0) }?.1
    }

    /// The path of the mailbox it's inside, if it's nested.
    public var parentName: String? {
        guard let delimiter, let range = name.range(of: delimiter, options: .backwards) else { return nil }
        let parent = String(name[..<range.lowerBound])
        return parent.isEmpty ? nil : parent
    }

    /// The last part of the path, for showing.
    public var displayName: String {
        if isInbox { return "Inbox" }
        guard let delimiter, let last = name.components(separatedBy: delimiter).last, !last.isEmpty else { return name }
        return last
    }
}

/// What STATUS said about a mailbox.
public struct IMAPMailboxStatus: Sendable, Hashable {
    public var mailbox: String
    public var messages: Int?
    public var unseen: Int?
    public var uidNext: UInt32?
    public var uidValidity: UInt32?

    public init(mailbox: String, messages: Int? = nil, unseen: Int? = nil, uidNext: UInt32? = nil, uidValidity: UInt32? = nil) {
        self.mailbox = mailbox
        self.messages = messages
        self.unseen = unseen
        self.uidNext = uidNext
        self.uidValidity = uidValidity
    }
}

/// The mailbox SELECT or EXAMINE opened, as the server described it.
public struct IMAPSelectedMailbox: Sendable, Hashable {
    public var name: String
    public var isReadOnly: Bool
    /// How many messages it has, kept up to date as EXISTS and EXPUNGE responses arrive.
    public var exists: Int
    public var recent: Int
    public var uidValidity: UInt32?
    public var uidNext: UInt32?
    public var flags: [String]
    public var permanentFlags: [String]
    /// The highest modification sequence, when it was opened with CONDSTORE.
    public var highestModSeq: UInt64?

    public init(name: String, isReadOnly: Bool, exists: Int = 0, recent: Int = 0, uidValidity: UInt32? = nil,
                uidNext: UInt32? = nil, flags: [String] = [], permanentFlags: [String] = [], highestModSeq: UInt64? = nil) {
        self.name = name
        self.isReadOnly = isReadOnly
        self.exists = exists
        self.recent = recent
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.flags = flags
        self.permanentFlags = permanentFlags
        self.highestModSeq = highestModSeq
    }
}

/// Where APPEND put a message, from servers that say (UIDPLUS).
public struct IMAPAppendResult: Sendable, Hashable {
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(uidValidity: UInt32, uid: UInt32) {
        self.uidValidity = uidValidity
        self.uid = uid
    }
}
