import Foundation

/// Starts replies and forwards: who they go to, their subject, the conversation headers and the quoted original.
public enum ReplyBuilder {
    public enum Kind: Sendable, Hashable {
        case reply
        case replyAll
        case forward
    }

    /// The fields a new reply or forward starts with.
    public struct Draft: Sendable, Hashable {
        public var to: [MailAddress]
        public var cc: [MailAddress]
        public var subject: String
        public var inReplyTo: String?
        public var references: [String]
        public var threadID: String?
        /// The original, quoted, as HTML to go under the new text.
        public var quotedHTML: String
        /// The original, quoted, as plain text.
        public var quotedText: String
        /// The original's attachments, for a forward.
        public var attachments: [Attachment]
    }

    /// The subject with one "Re: " (or "Fwd: ") in front, however many prefixes the original had.
    public static func subject(_ original: String, kind: Kind) -> String {
        var base = original.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "fw:", "fwd:", "aw:", "sv:", "vs:", "antw:", "rif:", "réf:"]
        var stripped = true
        while stripped {
            stripped = false
            for prefix in prefixes where base.lowercased().hasPrefix(prefix) {
                base = String(base.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        return (kind == .forward ? "Fwd: " : "Re: ") + base
    }

    /// Who a reply goes to. Replying to your own message goes to the people it went to.
    public static func recipients(for message: MailMessage, kind: Kind, me: String) -> (to: [MailAddress], cc: [MailAddress]) {
        guard kind != .forward else { return ([], []) }
        let summary = message.summary
        let fromMe = summary.from?.isSameMailbox(as: me) ?? false
        var to: [MailAddress]
        if fromMe {
            to = summary.to
        } else if !message.replyTo.isEmpty {
            to = message.replyTo
        } else {
            to = summary.from.map { [$0] } ?? []
        }
        var cc: [MailAddress] = []
        if kind == .replyAll {
            if !fromMe { to += summary.to }
            cc = summary.cc
        }
        func unique(_ list: [MailAddress], excluding: [MailAddress]) -> [MailAddress] {
            var seen = Set(excluding.map { $0.email.lowercased() })
            if !(fromMe && kind == .reply) { seen.insert(me.lowercased()) }
            return list.filter { seen.insert($0.email.lowercased()).inserted }
        }
        let finalTo = unique(to, excluding: [])
        let finalCc = unique(cc, excluding: finalTo)
        return (finalTo.isEmpty ? to : finalTo, finalCc)
    }

    /// Everything a reply or forward to `message` starts with.
    public static func draft(for message: MailMessage, kind: Kind, me: String, formatting: MailFormatting = MailFormatting()) -> Draft {
        let summary = message.summary
        let (to, cc) = recipients(for: message, kind: kind, me: me)
        var references = summary.references
        if let id = summary.messageIDHeader, !references.contains(id) { references.append(id) }
        let sender = summary.from.map { $0.name.map { "\($0) <\(summary.from!.email)>" } ?? $0.email } ?? "someone"
        let dateText = formatting.messageDate(summary.date).replacingOccurrences(of: " \\(.*\\)$", with: "", options: .regularExpression)
        let originalText = message.textBody ?? message.htmlBody.map(HTMLText.plainText(fromHTML:)) ?? ""
        let originalHTML = message.htmlBody ?? "<div style=\"white-space: pre-wrap\">\(escapeHTML(originalText))</div>"
        let quotedHTML: String
        let quotedText: String
        if kind == .forward {
            let header = ["---------- Forwarded message ---------", "From: \(sender)", "Date: \(dateText)", "Subject: \(summary.subject)",
                          "To: \(summary.to.map(\.formatted).joined(separator: ", "))"]
                + (summary.cc.isEmpty ? [] : ["Cc: \(summary.cc.map(\.formatted).joined(separator: ", "))"])
            quotedText = header.joined(separator: "\n") + "\n\n" + originalText
            quotedHTML = "<div>" + header.map(escapeHTML).joined(separator: "<br>") + "<br><br>" + originalHTML + "</div>"
        } else {
            let intro = "On \(dateText), \(sender) wrote:"
            quotedText = intro + "\n" + originalText.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            quotedHTML = "<div>\(escapeHTML(intro))<br></div><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">"
                + originalHTML + "</blockquote>"
        }
        return Draft(to: to, cc: cc, subject: subject(summary.subject, kind: kind),
                     inReplyTo: kind == .forward ? nil : summary.messageIDHeader,
                     references: kind == .forward ? [] : references, threadID: kind == .forward ? nil : summary.threadID,
                     quotedHTML: quotedHTML, quotedText: quotedText,
                     attachments: kind == .forward ? message.attachments : [])
    }

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
