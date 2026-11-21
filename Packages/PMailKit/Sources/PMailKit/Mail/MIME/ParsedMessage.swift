import Foundation

/// One header field, unfolded but otherwise as it came (not decoded).
public struct MIMEHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A whole RFC 5322 message, read: decoded headers, the text and HTML bodies, and its files.
public struct ParsedMessage: Sendable, Hashable {
    /// The top-level header fields, in order.
    public var headers: [MIMEHeader]
    /// The subject, with encoded words decoded.
    public var subject: String
    public var from: MailAddress?
    public var sender: MailAddress?
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var replyTo: [MailAddress]
    public var date: Date?
    /// Message-ID, In-Reply-To and References keep their angle brackets.
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    /// The plain-text body, decoded to a string.
    public var textBody: String?
    /// The HTML body, decoded to a string.
    public var htmlBody: String?
    /// Files: parts with a file name or Content-Disposition attachment, with their decoded data. IDs are MIME part
    /// numbers ("2", "1.2").
    public var attachments: [Attachment]
    /// Pictures shown inside the HTML with `cid:`, with their decoded data.
    public var inlineParts: [Attachment]
    public var listUnsubscribe: String?

    public init(headers: [MIMEHeader] = [], subject: String = "", from: MailAddress? = nil, sender: MailAddress? = nil,
                to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [], replyTo: [MailAddress] = [],
                date: Date? = nil, messageID: String? = nil, inReplyTo: String? = nil, references: [String] = [],
                textBody: String? = nil, htmlBody: String? = nil, attachments: [Attachment] = [], inlineParts: [Attachment] = [],
                listUnsubscribe: String? = nil) {
        self.headers = headers
        self.subject = subject
        self.from = from
        self.sender = sender
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inlineParts = inlineParts
        self.listUnsubscribe = listUnsubscribe
    }

    /// The first header field with this name (case doesn't matter), unfolded, not decoded.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// A short, single-line start of the text, for message lists: the text body, or the HTML body's text.
    public var snippet: String {
        let source = textBody ?? htmlBody.map(HTMLText.plainText(fromHTML:)) ?? ""
        return HTMLText.snippet(from: source)
    }

    /// A summary for the message list, for services that only have the raw message (POP, a local mailbox).
    public func summary(id: String, threadID: String? = nil, folderID: String? = nil, labelIDs: [String] = [],
                        isUnread: Bool = false, isStarred: Bool = false, size: Int? = nil) -> MessageSummary {
        MessageSummary(id: id, threadID: threadID ?? references.first ?? inReplyTo ?? messageID ?? id, folderID: folderID,
                       labelIDs: labelIDs, from: from, to: to, cc: cc, subject: subject, snippet: snippet, date: date ?? Date(),
                       isUnread: isUnread, isStarred: isStarred, hasAttachments: !attachments.isEmpty,
                       messageIDHeader: messageID, inReplyTo: inReplyTo, references: references, size: size)
    }

    /// The whole message for the reading pane.
    public func mailMessage(summary: MessageSummary, rawSource: Data? = nil) -> MailMessage {
        MailMessage(summary: summary, replyTo: replyTo, bcc: bcc, htmlBody: htmlBody, textBody: textBody,
                    attachments: attachments, inlineParts: inlineParts, listUnsubscribe: listUnsubscribe, rawSource: rawSource)
    }
}

/// Plain text from HTML, and one-line snippets, for message lists.
public enum HTMLText {
    /// The text of an HTML body: tags, styles and scripts removed, entities decoded, blocks on lines of their own.
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        // Whole elements whose contents are never text.
        for element in ["head", "style", "script", "title"] {
            text = text.replacingOccurrences(of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)\\s*>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr|/h[1-6]|/blockquote)\\b[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text)
    }

    /// Decodes the HTML entities mail uses: named ones and numeric ones.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "#39": "'", "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                       "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "zwnj": "",
                                       "zwj": "", "shy": "", "bull": "•", "middot": "·", "euro": "€", "pound": "£"]
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: index)..<semicolon])
                if let value = named[name.lowercased()] {
                    result += value
                    index = text.index(after: semicolon)
                    continue
                }
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let code = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    if let code, let scalar = Unicode.Scalar(code) {
                        result.unicodeScalars.append(scalar)
                        index = text.index(after: semicolon)
                        continue
                    }
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// The first `length` characters of some text, on one line, with runs of spaces made one.
    public static func snippet(from text: String, length: Int = 200) -> String {
        var result = ""
        var lastWasSpace = true
        for character in text {
            if character.isWhitespace || character == "\u{200B}" || character == "\u{FEFF}" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
            if result.count >= length { break }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
