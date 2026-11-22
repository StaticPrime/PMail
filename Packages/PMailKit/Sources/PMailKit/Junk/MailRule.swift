import Foundation

/// What's known about a new message when deciding what to do with it: the message, its account, whether the junk
/// filter (or the server) calls it junk, and who its sender is to the person.
public struct MessageFacts: Sendable {
    public var summary: MessageSummary
    /// The whole message, for conditions about its text, headers or attachments; nil when it wasn't loaded.
    public var message: MailMessage?
    /// The account's address and the person's full name.
    public var account: String
    public var fullName: String
    public var isJunk = false
    public var senderInContacts = false
    public var senderInPreviousRecipients = false
    public var senderIsStarred = false
    /// The labels of the sender's contact card, lowercased.
    public var senderLabels: Set<String> = []
    public var now: Date

    public init(summary: MessageSummary, message: MailMessage? = nil, account: String, fullName: String, now: Date = Date()) {
        self.summary = summary
        self.message = message
        self.account = account.lowercased()
        self.fullName = fullName
        self.now = now
    }

    /// Whether the message is addressed to the account by the person's full name ("Jamie Rivera <jamie@…>"), as mail
    /// from people who know them mostly is.
    public var addressedToFullName: Bool {
        let name = Self.plain(fullName)
        guard !name.isEmpty else { return false }
        return (summary.to + summary.cc).contains { $0.email.lowercased() == account && Self.plain($0.name ?? "") == name }
    }

    private static func plain(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A rule for new mail: when all (or any) of its conditions are met, its actions are done. Settings ▸ Junk Mail ▸
/// Advanced keeps one, for "Do what I set up under Advanced".
public struct MailRule: Codable, Sendable, Hashable {
    public var description: String
    public var matchesAll: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]

    public init(description: String, matchesAll: Bool = true, conditions: [RuleCondition], actions: [RuleAction]) {
        self.description = description
        self.matchesAll = matchesAll
        self.conditions = conditions
        self.actions = actions
    }

    /// The rule junk handling starts with: junk from strangers who don't know the person's name goes to the Junk folder.
    public static let junk = MailRule(description: "Junk", conditions: [
        RuleCondition(.senderNotInContacts), RuleCondition(.senderNotInPreviousRecipients), RuleCondition(.notAddressedToFullName),
        RuleCondition(.isJunk),
    ], actions: [RuleAction(.moveToJunk)])

    public func matches(_ facts: MessageFacts) -> Bool {
        guard !conditions.isEmpty else { return false }
        return matchesAll ? conditions.allSatisfy { $0.matches(facts) } : conditions.contains { $0.matches(facts) }
    }

    /// Whether a condition needs the whole message (its text, headers or attachments), not just its summary.
    public var needsWholeMessage: Bool { conditions.contains { $0.field.needsWholeMessage } }
}

/// One of a rule's conditions.
public struct RuleCondition: Codable, Sendable, Hashable, Identifiable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case from, to, cc, subject, anyRecipient
        case addressedToFullName, notAddressedToFullName
        case dateSent, dateReceived
        case account
        case senderInContacts, senderNotInContacts
        case senderInPreviousRecipients, senderNotInPreviousRecipients
        case senderIsStarred, senderHasLabel, senderLacksLabel
        case content, isJunk, isSigned, isEncrypted
        case priorityHigh, priorityNormal, priorityLow
        case attachmentName, attachmentType
        case header
        case everyMessage

        public var name: String {
            switch self {
            case .from: "From"
            case .to: "To"
            case .cc: "Cc"
            case .subject: "Subject"
            case .anyRecipient: "Any recipient"
            case .addressedToFullName: "Message is addressed to my full name"
            case .notAddressedToFullName: "Message is not addressed to my full name"
            case .dateSent: "Date sent"
            case .dateReceived: "Date received"
            case .account: "Account"
            case .senderInContacts: "Sender is in my contacts"
            case .senderNotInContacts: "Sender is not in my contacts"
            case .senderInPreviousRecipients: "Sender is someone I’ve written to"
            case .senderNotInPreviousRecipients: "Sender is not someone I’ve written to"
            case .senderIsStarred: "Sender is a starred contact"
            case .senderHasLabel: "Sender has the contact label"
            case .senderLacksLabel: "Sender doesn’t have the contact label"
            case .content: "Message content"
            case .isJunk: "Message is junk mail"
            case .isSigned: "Message is signed"
            case .isEncrypted: "Message is encrypted"
            case .priorityHigh: "Priority is high"
            case .priorityNormal: "Priority is normal"
            case .priorityLow: "Priority is low"
            case .attachmentName: "Any attachment name"
            case .attachmentType: "Attachment type"
            case .header: "Header"
            case .everyMessage: "Every message"
            }
        }

        /// What it compares: text (with contains, begins with…), an age in days, an account, a label, a kind of file,
        /// or nothing.
        public var takesText: Bool { [.from, .to, .cc, .subject, .anyRecipient, .content, .attachmentName, .header].contains(self) }
        public var takesDays: Bool { self == .dateSent || self == .dateReceived }
        public var takesLabel: Bool { self == .senderHasLabel || self == .senderLacksLabel }

        var needsWholeMessage: Bool {
            [.content, .isSigned, .isEncrypted, .priorityHigh, .priorityNormal, .priorityLow, .attachmentName, .attachmentType, .header].contains(self)
        }
    }

    public enum Comparison: String, Codable, Sendable, CaseIterable {
        case contains, doesNotContain, beginsWith, endsWith, isEqualTo
        case lessThanDaysOld, moreThanDaysOld

        public var name: String {
            switch self {
            case .contains: "contains"
            case .doesNotContain: "does not contain"
            case .beginsWith: "begins with"
            case .endsWith: "ends with"
            case .isEqualTo: "is equal to"
            case .lessThanDaysOld: "is less than"
            case .moreThanDaysOld: "is more than"
            }
        }

        public static let forText: [Comparison] = [.contains, .doesNotContain, .beginsWith, .endsWith, .isEqualTo]
        public static let forDays: [Comparison] = [.lessThanDaysOld, .moreThanDaysOld]
    }

    public var id: UUID
    public var field: Field
    public var comparison: Comparison
    /// The text, days, account address, label or kind of file it compares with.
    public var value: String
    /// The header's name, for `.header`.
    public var header: String

    public init(_ field: Field, _ comparison: Comparison = .contains, _ value: String = "", header: String = "", id: UUID = UUID()) {
        self.id = id
        self.field = field
        self.comparison = comparison
        self.value = value
        self.header = header
    }

    public func matches(_ facts: MessageFacts) -> Bool {
        let summary = facts.summary
        switch field {
        case .from: return compare(Self.addressTexts(summary.from.map { [$0] } ?? []))
        case .to: return compare(Self.addressTexts(summary.to))
        case .cc: return compare(Self.addressTexts(summary.cc))
        case .anyRecipient: return compare(Self.addressTexts(summary.to + summary.cc + (facts.message?.bcc ?? [])))
        case .subject: return compare([summary.subject])
        case .addressedToFullName: return facts.addressedToFullName
        case .notAddressedToFullName: return !facts.addressedToFullName
        case .dateSent, .dateReceived:
            guard let days = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
            let age = facts.now.timeIntervalSince(summary.date) / 86_400
            return comparison == .moreThanDaysOld ? age > days : age < days
        case .account: return facts.account == value.lowercased()
        case .senderInContacts: return facts.senderInContacts
        case .senderNotInContacts: return !facts.senderInContacts
        case .senderInPreviousRecipients: return facts.senderInPreviousRecipients
        case .senderNotInPreviousRecipients: return !facts.senderInPreviousRecipients
        case .senderIsStarred: return facts.senderIsStarred
        case .senderHasLabel: return facts.senderLabels.contains(value.lowercased().trimmingCharacters(in: .whitespaces))
        case .senderLacksLabel: return !facts.senderLabels.contains(value.lowercased().trimmingCharacters(in: .whitespaces))
        case .content: return compare([Self.text(of: facts)])
        case .isJunk: return facts.isJunk
        case .isSigned: return Self.contentType(of: facts.message).map(Self.isSigned) ?? false
        case .isEncrypted: return Self.contentType(of: facts.message).map(Self.isEncrypted) ?? false
        case .priorityHigh: return Self.priority(of: facts.message) == .high
        case .priorityNormal: return Self.priority(of: facts.message) == .normal
        case .priorityLow: return Self.priority(of: facts.message) == .low
        case .attachmentName: return compare(facts.message?.attachments.map(\.filename) ?? [])
        case .attachmentType:
            guard let kind = AttachmentKind(rawValue: value) else { return false }
            return facts.message?.attachments.contains { AttachmentKind.of($0) == kind } ?? false
        case .header: return compare(Self.headerValues(header, in: facts.message))
        case .everyMessage: return true
        }
    }

    /// Text comparisons ignore case. With nothing to look for, a condition never matches.
    func compare(_ values: [String]) -> Bool {
        let wanted = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return false }
        let haystacks = values.map { $0.lowercased() }
        switch comparison {
        case .contains: return haystacks.contains { $0.contains(wanted) }
        case .doesNotContain: return !haystacks.contains { $0.contains(wanted) }
        case .beginsWith: return haystacks.contains { $0.hasPrefix(wanted) }
        case .endsWith: return haystacks.contains { $0.hasSuffix(wanted) }
        case .isEqualTo: return haystacks.contains { $0 == wanted }
        case .lessThanDaysOld, .moreThanDaysOld: return false
        }
    }

    /// Each address and each name, so "is equal to" matches either.
    static func addressTexts(_ addresses: [MailAddress]) -> [String] {
        addresses.flatMap { [$0.email, $0.name].compactMap { $0 } }
    }

    static func text(of facts: MessageFacts) -> String {
        if let text = facts.message?.textBody, !text.isEmpty { return text }
        if let html = facts.message?.htmlBody, !html.isEmpty { return HTMLText.plainText(fromHTML: html) }
        return facts.summary.snippet
    }

    static func headerValues(_ name: String, in message: MailMessage?) -> [String] {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, let raw = message?.rawSource, let value = MIMEParser.parse(raw).header(name) else { return [] }
        return [value]
    }

    static func contentType(of message: MailMessage?) -> String? {
        headerValues("content-type", in: message).first?.lowercased()
    }

    static func isSigned(_ type: String) -> Bool {
        type.hasPrefix("multipart/signed") || (type.contains("pkcs7-mime") && type.contains("signed-data"))
    }

    static func isEncrypted(_ type: String) -> Bool {
        type.hasPrefix("multipart/encrypted") || (type.contains("pkcs7-mime") && !type.contains("signed-data"))
    }

    enum Priority { case high, normal, low }

    /// What X-Priority, Importance or Priority says; normal when none does.
    static func priority(of message: MailMessage?) -> Priority {
        if let value = headerValues("x-priority", in: message).first, let level = Int(value.prefix { $0.isNumber }) {
            return level <= 2 ? .high : level >= 4 ? .low : .normal
        }
        let words = (headerValues("importance", in: message) + headerValues("priority", in: message)).map { $0.lowercased() }
        if words.contains(where: { $0.contains("high") || $0.contains("urgent") }) { return .high }
        if words.contains(where: { $0.contains("low") || $0.contains("non-urgent") }) { return .low }
        return .normal
    }
}

/// Kinds of attached file, for the Attachment type condition.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case image, pdf, document, spreadsheet, presentation, archive, audio, video, calendar

    public var name: String {
        switch self {
        case .image: "Picture"
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .archive: "Archive"
        case .audio: "Sound"
        case .video: "Video"
        case .calendar: "Calendar invitation"
        }
    }

    /// What kind a file is, by its type and then its name's extension.
    public static func of(_ attachment: Attachment) -> AttachmentKind? {
        let type = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        if type == "application/pdf" || ext == "pdf" { return .pdf }
        if type == "text/calendar" || ext == "ics" { return .calendar }
        if ["zip", "gz", "tgz", "rar", "7z", "tar", "bz2", "xz"].contains(ext) || type.contains("zip") || type.contains("compressed") { return .archive }
        if ["xls", "xlsx", "numbers", "csv", "ods"].contains(ext) || type.contains("spreadsheet") || type.contains("excel") { return .spreadsheet }
        if ["ppt", "pptx", "key", "odp"].contains(ext) || type.contains("presentation") || type.contains("powerpoint") { return .presentation }
        if ["doc", "docx", "pages", "rtf", "txt", "odt", "md"].contains(ext) || type.contains("word") || type.hasPrefix("text/") { return .document }
        return nil
    }
}

/// One of a rule's actions.
public struct RuleAction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case moveToJunk, markJunk, moveToTrash, archive, moveToFolder, addLabel, markRead, star, notify, playSound, bounceDockIcon

        public var name: String {
            switch self {
            case .moveToJunk: "Move to Junk or Spam"
            case .markJunk: "Mark as junk, leaving it in the inbox"
            case .moveToTrash: "Move to Trash"
            case .archive: "Archive"
            case .moveToFolder: "Move to the folder"
            case .addLabel: "Add the label"
            case .markRead: "Mark as read"
            case .star: "Star"
            case .notify: "Send a notification"
            case .playSound: "Play the sound"
            case .bounceDockIcon: "Bounce PMail’s icon in the Dock"
            }
        }

        /// What it needs: a folder's or label's name, or a sound.
        public var takesName: Bool { self == .moveToFolder || self == .addLabel }
        public var takesSound: Bool { self == .playSound }
        /// Whether it takes the message out of the inbox.
        public var movesOut: Bool { [.moveToJunk, .moveToTrash, .archive, .moveToFolder].contains(self) }
    }

    /// The sounds macOS comes with, for Play the sound.
    public static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    public var id: UUID
    public var kind: Kind
    public var value: String

    public init(_ kind: Kind, _ value: String = "", id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

/// How new mail is handled, as Settings ▸ Junk Mail says: junk (by PMail's filter, or a server's own marks) and mail
/// from blocked senders.
public struct JunkPolicy: Codable, Sendable, Equatable {
    public enum JunkAction: String, Codable, Sendable, CaseIterable {
        /// Marked as junk, left in the inbox.
        case mark
        case moveToJunk
        /// The Advanced rule.
        case custom
    }

    public enum BlockedAction: String, Codable, Sendable, CaseIterable {
        case mark, moveToJunk, moveToTrash
    }

    public var filtersJunk = true
    public var junkAction = JunkAction.mark
    /// Mail never taken for junk: from people in the contacts, people written to before, and mail addressed by full name.
    public var exemptsContacts = true
    public var exemptsPreviousRecipients = true
    public var exemptsFullName = true
    /// Whether a server's spam marks in a message's headers make it junk.
    public var trustsServerMarks = true
    public var customRule = MailRule.junk
    public var filtersBlocked = true
    public var blockedAction = BlockedAction.moveToJunk

    public init() {}

    /// What happens to a new message.
    public enum Outcome: Sendable, Equatable {
        case nothing
        case markBlocked, markJunk, moveToJunk, moveToTrash
        /// The Advanced rule's actions.
        case actions([RuleAction])
    }

    /// What to do with a new message: a blocked sender's first, then junk, unless an exception says it isn't.
    public func outcome(for facts: MessageFacts, fromBlockedSender: Bool) -> Outcome {
        if filtersBlocked, fromBlockedSender {
            switch blockedAction {
            case .mark: return .markBlocked
            case .moveToJunk: return .moveToJunk
            case .moveToTrash: return .moveToTrash
            }
        }
        guard filtersJunk else { return .nothing }
        if junkAction == .custom { return customRule.matches(facts) ? .actions(customRule.actions) : .nothing }
        guard facts.isJunk, !isExempt(facts) else { return .nothing }
        return junkAction == .mark ? .markJunk : .moveToJunk
    }

    public func isExempt(_ facts: MessageFacts) -> Bool {
        (exemptsContacts && facts.senderInContacts) || (exemptsPreviousRecipients && facts.senderInPreviousRecipients)
            || (exemptsFullName && facts.addressedToFullName)
    }

    // Settings saved by an earlier version may lack newer keys; those take their defaults.
    enum CodingKeys: String, CodingKey {
        case filtersJunk, junkAction, exemptsContacts, exemptsPreviousRecipients, exemptsFullName, trustsServerMarks, customRule,
             filtersBlocked, blockedAction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = JunkPolicy()
        filtersJunk = try container.decodeIfPresent(Bool.self, forKey: .filtersJunk) ?? defaults.filtersJunk
        junkAction = try container.decodeIfPresent(JunkAction.self, forKey: .junkAction) ?? defaults.junkAction
        exemptsContacts = try container.decodeIfPresent(Bool.self, forKey: .exemptsContacts) ?? defaults.exemptsContacts
        exemptsPreviousRecipients = try container.decodeIfPresent(Bool.self, forKey: .exemptsPreviousRecipients) ?? defaults.exemptsPreviousRecipients
        exemptsFullName = try container.decodeIfPresent(Bool.self, forKey: .exemptsFullName) ?? defaults.exemptsFullName
        trustsServerMarks = try container.decodeIfPresent(Bool.self, forKey: .trustsServerMarks) ?? defaults.trustsServerMarks
        customRule = try container.decodeIfPresent(MailRule.self, forKey: .customRule) ?? defaults.customRule
        filtersBlocked = try container.decodeIfPresent(Bool.self, forKey: .filtersBlocked) ?? defaults.filtersBlocked
        blockedAction = try container.decodeIfPresent(BlockedAction.self, forKey: .blockedAction) ?? defaults.blockedAction
    }
}
