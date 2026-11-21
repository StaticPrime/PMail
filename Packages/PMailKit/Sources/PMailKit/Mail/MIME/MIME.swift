import Foundation

// PLACEHOLDER — to be replaced by the full MIME implementation (MIMEParser.swift, MIMEBuilder.swift and friends).
// Keep these two entry points and their signatures: the rest of PMailKit calls them.

/// Reads RFC 5322 / MIME messages.
public enum MIMEParser {
    /// Reads a whole message (headers and body, CRLF or LF line ends). Never throws: damaged parts are kept as
    /// well as they can be, so a broken message still shows something.
    public static func parse(_ data: Data) -> ParsedMessage {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let parts = text.components(separatedBy: "\n\n")
        let headerText = parts.first ?? ""
        var headers: [MIMEHeader] = []
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append(MIMEHeader(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        var message = ParsedMessage(headers: headers)
        message.subject = message.header("Subject") ?? ""
        message.textBody = parts.dropFirst().joined(separator: "\n\n")
        message.messageID = message.header("Message-ID")
        return message
    }
}

/// Writes RFC 5322 / MIME messages.
public enum MIMEBuilder {
    /// The complete message, CRLF line ends, ready for SMTP, IMAP APPEND or a provider's raw-message upload.
    /// Bcc recipients are left out of the headers.
    public static func build(_ message: OutgoingMessage) -> Data {
        var lines = [
            "From: \(message.from.formatted)",
            "To: \(message.to.map(\.formatted).joined(separator: ", "))",
            "Subject: \(message.subject)",
            "Message-ID: \(message.messageID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "",
            message.textBody,
        ]
        if !message.cc.isEmpty { lines.insert("Cc: \(message.cc.map(\.formatted).joined(separator: ", "))", at: 2) }
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
