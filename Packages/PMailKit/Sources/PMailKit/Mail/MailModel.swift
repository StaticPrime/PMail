import Foundation

/// An email address with the name that goes with it.
public struct MailAddress: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name if there is one, else the address.
    public var displayName: String { name ?? email }

    /// The first name, or the part of the address before the @: what a conversation's list of people shows.
    public var shortName: String {
        if let name, let first = name.split(separator: " ").first {
            // "Rivera, Jamie" puts the first name second.
            if first.hasSuffix(","), let second = name.split(separator: " ").dropFirst().first { return String(second) }
            return String(first)
        }
        return String(email.split(separator: "@").first ?? Substring(email))
    }

    /// "Jamie Rivera <jamie@example.com>", quoting the name when it needs it. Not encoded for headers: the MIME
    /// builder encodes names that aren't plain ASCII.
    public var formatted: String {
        guard let name else { return email }
        let needsQuotes = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        let shown = needsQuotes ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : name
        return "\(shown) <\(email)>"
    }

    /// Whether two addresses are the same mailbox (addresses compare without regard to case).
    public func isSameMailbox(as other: MailAddress) -> Bool { email.lowercased() == other.email.lowercased() }
    public func isSameMailbox(as other: String) -> Bool { email.lowercased() == other.lowercased() }
}

/// The special folders, which PMail shows with their own names, icons and places in the sidebar.
public enum FolderRole: String, Codable, Sendable, Hashable, CaseIterable {
    case inbox, starred, important, snoozed, sent, drafts, scheduled, outbox, archive, allMail, spam, trash

    /// The order the sidebar lists them in.
    public var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

/// A mailbox: a folder (each message is in one) or a label (a message can have many).
public struct MailFolder: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case folder
        case label
    }

    /// The provider's own ID for it: an IMAP mailbox's full path, a label ID, a folder ID.
    public var id: String
    /// The name to show: the last part of a nested folder's path.
    public var name: String
    public var role: FolderRole?
    public var kind: Kind
    public var unreadCount: Int
    public var totalCount: Int?
    /// The folder it's inside, for nested folders and labels ("Work/Projects" is inside "Work").
    public var parentID: String?
    /// A label's color, "#RRGGBB".
    public var colorHex: String?
    /// Whether it can hold messages (some IMAP folders only hold other folders).
    public var isSelectable: Bool

    public init(id: String, name: String, role: FolderRole? = nil, kind: Kind = .folder, unreadCount: Int = 0,
                totalCount: Int? = nil, parentID: String? = nil, colorHex: String? = nil, isSelectable: Bool = true) {
        self.id = id
        self.name = name
        self.role = role
        self.kind = kind
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.parentID = parentID
        self.colorHex = colorHex
        self.isSelectable = isSelectable
    }
}

/// A tab across the top of the inbox that sorts it into kinds of mail (Primary, Promotions… or Focused and Other).
public struct InboxTab: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// An SF Symbols name.
    public var symbol: String

    public init(id: String, name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

/// What a message list row needs to know about a message, without its body.
public struct MessageSummary: Codable, Sendable, Identifiable, Hashable {
    /// The service's ID for the message, unique within the account. Services may pack what they need into it (an
    /// IMAP service, the mailbox, UIDVALIDITY and UID).
    public var id: String
    /// The conversation it belongs to.
    public var threadID: String
    /// The folder it's in, for services with folders.
    public var folderID: String?
    /// The labels (or categories) it has.
    public var labelIDs: [String]
    public var from: MailAddress?
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var subject: String
    /// The start of the text, on one line, for the list.
    public var snippet: String
    public var date: Date
    public var isUnread: Bool
    public var isStarred: Bool
    public var isImportant: Bool
    public var isDraft: Bool
    public var hasAttachments: Bool
    /// The Message-ID header, with its angle brackets ("<abc@example.com>").
    public var messageIDHeader: String?
    public var inReplyTo: String?
    public var references: [String]
    public var size: Int?
    /// What the message's headers say about its sender, for sorting an inbox into categories on the Mac; nil when
    /// the service didn't read them.
    public var senderHints: SenderHints?
    /// Whether it carries a calendar invitation, answer or cancellation (an iCalendar part); nil when the service
    /// can't tell from what it lists.
    public var isInvitation: Bool?

    public init(id: String, threadID: String? = nil, folderID: String? = nil, labelIDs: [String] = [], from: MailAddress? = nil,
                to: [MailAddress] = [], cc: [MailAddress] = [], subject: String = "", snippet: String = "", date: Date = Date(),
                isUnread: Bool = false, isStarred: Bool = false, isImportant: Bool = false, isDraft: Bool = false,
                hasAttachments: Bool = false, messageIDHeader: String? = nil, inReplyTo: String? = nil, references: [String] = [],
                size: Int? = nil, senderHints: SenderHints? = nil, isInvitation: Bool? = nil) {
        self.senderHints = senderHints
        self.isInvitation = isInvitation
        self.id = id
        self.threadID = threadID ?? id
        self.folderID = folderID
        self.labelIDs = labelIDs
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.isImportant = isImportant
        self.isDraft = isDraft
        self.hasAttachments = hasAttachments
        self.messageIDHeader = messageIDHeader
        self.inReplyTo = inReplyTo
        self.references = references
        self.size = size
    }
}

/// Messages that belong together: an original and its replies, oldest first.
public struct Conversation: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// The conversation's messages that this listing has, oldest first.
    public var messages: [MessageSummary]
    /// How many messages the whole conversation has (some services count ones the listing left out).
    public var messageCount: Int

    public init(id: String, messages: [MessageSummary], messageCount: Int? = nil) {
        self.id = id
        self.messages = messages.sorted { $0.date < $1.date }
        self.messageCount = max(messageCount ?? messages.count, messages.count)
    }

    public var latest: MessageSummary? { messages.last }
    /// The subject, from the first message that has one.
    public var subject: String { messages.first(where: { !$0.subject.isEmpty })?.subject ?? "" }
    public var snippet: String { latest?.snippet ?? "" }
    public var date: Date { latest?.date ?? .distantPast }
    public var isUnread: Bool { messages.contains { $0.isUnread } }
    public var isStarred: Bool { messages.contains { $0.isStarred } }
    public var isImportant: Bool { messages.contains { $0.isImportant } }
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments } }
    /// Whether any of its messages carries a calendar invitation, answer or cancellation.
    public var isInvitation: Bool { messages.contains { $0.isInvitation == true } }
    public var hasDraft: Bool { messages.contains { $0.isDraft } }
    public var labelIDs: Set<String> { Set(messages.flatMap(\.labelIDs)) }

    /// Who wrote the messages, in order, each once: short names, "me" for the account's own address. Lists of
    /// sent mail show who it went to instead.
    public func participants(me: String, showRecipients: Bool = false) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for message in messages {
            let people = showRecipients ? message.to + message.cc : (message.from.map { [$0] } ?? [])
            for person in people where seen.insert(person.email.lowercased()).inserted {
                names.append(person.isSameMailbox(as: me) ? "me" : (messages.count == 1 && !showRecipients ? person.displayName : person.shortName))
            }
        }
        return names
    }

    /// Groups messages into conversations by `threadID`, newest conversation first.
    public static func group(_ messages: [MessageSummary]) -> [Conversation] {
        var order: [String] = []
        var byThread: [String: [MessageSummary]] = [:]
        for message in messages {
            if byThread[message.threadID] == nil { order.append(message.threadID) }
            byThread[message.threadID, default: []].append(message)
        }
        return order.map { Conversation(id: $0, messages: byThread[$0] ?? []) }.sorted { $0.date > $1.date }
    }
}

/// One page of a message list.
public struct ConversationPage: Codable, Sendable {
    public var conversations: [Conversation]
    /// About how many conversations (or messages) the whole list has, for "1–50 of 2,345". Nil when unknown.
    public var totalCount: Int?
    /// Pass back in `ListRequest.pageToken` for the next page; nil on the last page.
    public var nextPageToken: String?

    public init(conversations: [Conversation], totalCount: Int? = nil, nextPageToken: String? = nil) {
        self.conversations = conversations
        self.totalCount = totalCount
        self.nextPageToken = nextPageToken
    }
}

/// Which messages to list.
public struct ListRequest: Sendable, Hashable {
    /// The folder or label; nil for every message (All Mail).
    public var folderID: String?
    /// The inbox tab, for services that have them.
    public var tabID: String?
    /// Search words, in the provider's own search language where it has one.
    public var query: String?
    public var pageSize: Int
    /// The previous page's `nextPageToken`; nil for the first page.
    public var pageToken: String?
    /// The page number, from 0, for services that page by counting.
    public var pageIndex: Int

    public init(folderID: String?, tabID: String? = nil, query: String? = nil, pageSize: Int = 50, pageToken: String? = nil,
                pageIndex: Int = 0) {
        self.folderID = folderID
        self.tabID = tabID
        self.query = query
        self.pageSize = pageSize
        self.pageToken = pageToken
        self.pageIndex = pageIndex
    }
}

/// Something done to messages from the list or the reading pane.
public enum MailAction: Sendable, Hashable {
    case markRead
    case markUnread
    case star
    case unstar
    case markImportant
    case markNotImportant
    /// Out of the inbox, kept in the archive (or All Mail).
    case archive
    case moveToInbox
    case trash
    /// Gone for good (from Trash or Spam).
    case deleteForever
    case markSpam
    case notSpam
    case move(toFolderID: String)
    case addLabel(String)
    case removeLabel(String)
}

/// A whole message: its summary, body and attachments.
public struct MailMessage: Codable, Sendable, Identifiable, Hashable {
    public var summary: MessageSummary
    public var replyTo: [MailAddress]
    public var bcc: [MailAddress]
    public var htmlBody: String?
    public var textBody: String?
    /// Files attached to it, shown under the message. `data` may be nil until loaded.
    public var attachments: [Attachment]
    /// Pictures the HTML shows through `cid:` links, with their data.
    public var inlineParts: [Attachment]
    /// The List-Unsubscribe header, for an Unsubscribe link.
    public var listUnsubscribe: String?
    /// The message as it came from the server, for Show Original and saving as .eml.
    public var rawSource: Data?

    public var id: String { summary.id }

    public init(summary: MessageSummary, replyTo: [MailAddress] = [], bcc: [MailAddress] = [], htmlBody: String? = nil,
                textBody: String? = nil, attachments: [Attachment] = [], inlineParts: [Attachment] = [],
                listUnsubscribe: String? = nil, rawSource: Data? = nil) {
        self.summary = summary
        self.replyTo = replyTo
        self.bcc = bcc
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.inlineParts = inlineParts
        self.listUnsubscribe = listUnsubscribe
        self.rawSource = rawSource
    }
}

/// A file attached to a message (or a picture inside it).
public struct Attachment: Codable, Sendable, Identifiable, Hashable {
    /// The service's ID for it (a MIME part number, an attachment ID).
    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// The Content-ID, without angle brackets, for pictures the HTML shows with `cid:`.
    public var contentID: String?
    public var isInline: Bool
    public var data: Data?

    public init(id: String, filename: String, mimeType: String, size: Int, contentID: String? = nil, isInline: Bool = false,
                data: Data? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.data = data
    }
}

/// A message to send (or save as a draft).
public struct OutgoingMessage: Codable, Sendable, Hashable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String
    /// The plain-text version, always present.
    public var textBody: String
    /// The formatted version, if the message has formatting.
    public var htmlBody: String?
    public var attachments: [OutgoingAttachment]
    /// The Message-ID of the message this replies to.
    public var inReplyTo: String?
    public var references: [String]
    /// The conversation it replies in, for services that keep conversations by ID.
    public var threadID: String?
    /// Its own Message-ID, with angle brackets.
    public var messageID: String
    public var date: Date
    /// A calendar invitation, answer or cancellation it carries (iMIP), which mail programs show with the event.
    public var calendar: OutgoingCalendar?

    public init(from: MailAddress, to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                replyTo: [MailAddress] = [], subject: String = "", textBody: String = "", htmlBody: String? = nil,
                attachments: [OutgoingAttachment] = [], inReplyTo: String? = nil, references: [String] = [],
                threadID: String? = nil, messageID: String? = nil, date: Date = Date(), calendar: OutgoingCalendar? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadID = threadID
        self.messageID = messageID ?? Self.newMessageID(for: from.email)
        self.date = date
        self.calendar = calendar
    }

    /// Everyone it goes to: To, Cc and Bcc.
    public var allRecipients: [MailAddress] { to + cc + bcc }

    /// A new, unique Message-ID on the sender's domain.
    public static func newMessageID(for email: String) -> String {
        let domain = ServerPresets.domain(of: email) ?? "localhost"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }
}

/// A file to attach to an outgoing message.
/// The iCalendar text of an invitation, answer or cancellation a message carries, with its iTIP method.
public struct OutgoingCalendar: Codable, Sendable, Hashable {
    /// "REQUEST", "CANCEL" or "REPLY".
    public var method: String
    public var text: String

    public init(method: String, text: String) {
        self.method = method
        self.text = text
    }
}

public struct OutgoingAttachment: Codable, Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for a picture shown inside the HTML body with `cid:`.
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

/// What a mail service can do, so the interface only offers what works.
public struct MailCapabilities: Sendable, Hashable {
    /// Folders are labels: a message can have many, and archiving takes the Inbox label off.
    public var usesLabels: Bool
    public var canStar: Bool
    public var canMarkImportant: Bool
    public var hasInboxTabs: Bool
    /// Search runs on the server, in its own search language; otherwise PMail searches what it has fetched.
    public var searchesOnServer: Bool
    public var canArchive: Bool
    public var supportsDrafts: Bool
    /// Messages can be moved between folders (POP accounts keep one inbox).
    public var canMove: Bool
    /// Messages can carry labels, several each, beside whatever folder they're in (`.addLabel`, `.removeLabel`).
    public var canLabel: Bool
    /// Labels can be made, renamed, recolored and deleted.
    public var canEditLabels: Bool
    /// The signature lives on the server too (`loadSignature`, `saveSignature`), so changes go both ways.
    public var syncsSignature: Bool

    public init(usesLabels: Bool = false, canStar: Bool = true, canMarkImportant: Bool = false, hasInboxTabs: Bool = false,
                searchesOnServer: Bool = true, canArchive: Bool = true, supportsDrafts: Bool = true, canMove: Bool = true,
                canLabel: Bool = false, canEditLabels: Bool = false, syncsSignature: Bool = false) {
        self.usesLabels = usesLabels
        self.canStar = canStar
        self.canMarkImportant = canMarkImportant
        self.hasInboxTabs = hasInboxTabs
        self.searchesOnServer = searchesOnServer
        self.canArchive = canArchive
        self.supportsDrafts = supportsDrafts
        self.canMove = canMove
        self.canLabel = canLabel
        self.canEditLabels = canEditLabels
        self.syncsSignature = syncsSignature
    }
}
