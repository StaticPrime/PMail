import Foundation

/// Writes RFC 5322 / MIME messages.
public enum MIMEBuilder {
    /// The complete message, CRLF line ends, ready for SMTP, IMAP APPEND or a provider's raw-message upload.
    /// Bcc recipients are left out of the headers.
    ///
    /// Plain text alone goes as text/plain; with HTML, as multipart/alternative (plain, then HTML); pictures with a
    /// Content-ID are wrapped with the HTML in multipart/related, and other files go in multipart/mixed around it all.
    /// Nothing in the headers names the app or the computer.
    public static func build(_ message: OutgoingMessage) -> Data {
        assemble(message, includeBcc: false)
    }

    /// The message as PMail keeps it for itself (a draft, or the copy filed in Sent): the same as `build`, plus a Bcc
    /// header so the person can still see who got a blind copy. Never hand this version to a server for sending.
    public static func buildForSaving(_ message: OutgoingMessage) -> Data {
        assemble(message, includeBcc: true)
    }

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    private static func assemble(_ message: OutgoingMessage, includeBcc: Bool) -> Data {
        var fields = ["Date: " + MailDate.format(message.date)]
        if let from = addressField("From", [message.from]) { fields.append(from) }
        if let to = addressField("To", message.to) { fields.append(to) }
        if let cc = addressField("Cc", message.cc) { fields.append(cc) }
        if includeBcc, let bcc = addressField("Bcc", message.bcc) { fields.append(bcc) }
        if let replyTo = addressField("Reply-To", message.replyTo) { fields.append(replyTo) }
        let subject = singleLine(message.subject)
        if !subject.isEmpty { fields.append(fold("Subject", subjectTokens(subject))) }
        if let id = cleanMessageID(message.messageID) { fields.append("Message-ID: " + id) }
        let inReplyTo = message.inReplyTo.flatMap(cleanMessageID)
        if let inReplyTo { fields.append("In-Reply-To: " + inReplyTo) }
        // A reply without References still names its parent there, so every mail program threads it.
        var references = message.references.compactMap(cleanMessageID)
        if references.isEmpty, let inReplyTo { references = [inReplyTo] }
        if !references.isEmpty { fields.append(fold("References", references)) }
        fields.append("MIME-Version: 1.0")

        let body = bodyEntity(for: message)
        var output = [UInt8]()
        output.reserveCapacity(body.content.count + 2048)
        for field in fields + body.headers {
            output.append(contentsOf: Array(field.utf8))
            output.append(contentsOf: crlf)
        }
        output.append(contentsOf: crlf)
        output.append(contentsOf: body.content)
        if !output.ends(with: crlf) { output.append(contentsOf: crlf) }
        return Data(output)
    }

    // MARK: Structure

    /// A MIME entity being written: its header fields (folded, without line ends) and its encoded content.
    private struct Entity {
        var headers: [String]
        var content: [UInt8]

        var rendered: [UInt8] {
            var bytes = [UInt8]()
            bytes.reserveCapacity(content.count + 512)
            for header in headers {
                bytes.append(contentsOf: Array(header.utf8))
                bytes.append(contentsOf: crlf)
            }
            bytes.append(contentsOf: crlf)
            bytes.append(contentsOf: content)
            return bytes
        }
    }

    private static func bodyEntity(for message: OutgoingMessage) -> Entity {
        let html = message.htmlBody.flatMap { $0.isEmpty ? nil : $0 }
        let pictures = html == nil ? [] : message.attachments.filter { cleanContentID($0.contentID) != nil }
        let files = html == nil ? message.attachments : message.attachments.filter { cleanContentID($0.contentID) == nil }
        var text = message.textBody
        if text.allSatisfy(\.isWhitespace), let html {
            text = HTMLText.plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body = textEntity(text, subtype: "plain")
        if let html {
            var htmlPart = textEntity(html, subtype: "html")
            if !pictures.isEmpty {
                htmlPart = multipartEntity("related", parts: [htmlPart] + pictures.map { attachmentEntity($0, inline: true) },
                                           parameters: ["type=\"text/html\";"])
            }
            body = multipartEntity("alternative", parts: [body, htmlPart])
        }
        if !files.isEmpty {
            body = multipartEntity("mixed", parts: [body] + files.map { attachmentEntity($0, inline: false) })
        }
        return body
    }

    /// UTF-8 text: 7bit when it is plain ASCII in short lines, quoted-printable otherwise.
    private static func textEntity(_ text: String, subtype: String) -> Entity {
        let bytes = Array(crlfLines(text).utf8)
        let contentType = "Content-Type: text/\(subtype); charset=utf-8"
        if isSevenBitSafe(bytes) {
            return Entity(headers: [contentType, "Content-Transfer-Encoding: 7bit"], content: bytes)
        }
        return Entity(headers: [contentType, "Content-Transfer-Encoding: quoted-printable"],
                      content: TransferEncoding.encodeQuotedPrintable(bytes))
    }

    private static func attachmentEntity(_ attachment: OutgoingAttachment, inline: Bool) -> Entity {
        var filename = singleLine(MIMEParser.sanitizedFilename(attachment.filename))
        if filename.isEmpty { filename = "Attachment" }
        var headers = [
            fold("Content-Type", ["\(cleanMIMEType(attachment.mimeType));"] + nameParameterTokens(filename)),
            "Content-Transfer-Encoding: base64",
            fold("Content-Disposition", [inline ? "inline;" : "attachment;"] + filenameParameterTokens(filename)),
        ]
        if let contentID = cleanContentID(attachment.contentID) { headers.append("Content-ID: <\(contentID)>") }
        return Entity(headers: headers, content: TransferEncoding.encodeBase64Lines(attachment.data))
    }

    /// A multipart around `parts`, with a random boundary checked not to occur anywhere inside them.
    private static func multipartEntity(_ subtype: String, parts: [Entity], parameters: [String] = []) -> Entity {
        let rendered = parts.map(\.rendered)
        var boundary = newBoundary()
        while rendered.contains(where: { contains($0, Array(boundary.utf8)) }) { boundary = newBoundary() }
        var content = [UInt8]()
        content.reserveCapacity(rendered.reduce(0) { $0 + $1.count } + 64 * (rendered.count + 1))
        for part in rendered {
            content.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            content.append(contentsOf: part)
            content.append(contentsOf: crlf)
        }
        content.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return Entity(headers: [fold("Content-Type", ["multipart/\(subtype);"] + parameters + ["boundary=\"\(boundary)\""])],
                      content: content)
    }

    /// "=_" and 32 random hex digits. "=_" can't occur in base64 or quoted-printable text, and the rest is random.
    private static func newBoundary() -> String {
        "=_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, needle.count <= haystack.count else { return false }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<(index + needle.count)].elementsEqual(needle) { return true }
            index += 1
        }
        return false
    }

    // MARK: Header fields

    /// "Name: token token…", folded before a token whenever the line would pass 78 octets.
    static func fold(_ name: String, _ tokens: [String]) -> String {
        var result = name + ":"
        var lineLength = result.utf8.count
        var isFirst = true
        for token in tokens where !token.isEmpty {
            let length = token.utf8.count
            if !isFirst, lineLength + 1 + length > 78 {
                result += "\r\n " + token
                lineLength = 1 + length
            } else {
                result += " " + token
                lineLength += 1 + length
            }
            isFirst = false
        }
        return result
    }

    /// The subject as words and encoded words: runs of words that aren't plain ASCII become encoded words (with the
    /// spaces between them inside, so they survive), plain words stay readable.
    private static func subjectTokens(_ subject: String) -> [String] {
        var tokens: [String] = []
        var run: [String] = []
        func flushRun() {
            if !run.isEmpty { tokens += EncodedWords.encode(run.joined(separator: " ")) }
            run.removeAll()
        }
        for word in subject.split(separator: " ").map(String.init) {
            if word.utf8.contains(where: { $0 >= 0x80 }) || word.contains("=?") || word.utf8.count > 76 {
                run.append(word)
            } else {
                flushRun()
                tokens.append(word)
            }
        }
        flushRun()
        return tokens
    }

    /// An address header, folded between addresses; nil when none of the addresses can be written.
    private static func addressField(_ name: String, _ addresses: [MailAddress]) -> String? {
        let written = addresses.compactMap(addressTokens)
        guard !written.isEmpty else { return nil }
        var tokens: [String] = []
        for (index, var pieces) in written.enumerated() {
            if index < written.count - 1 { pieces[pieces.count - 1] += "," }
            tokens += pieces
        }
        return fold(name, tokens)
    }

    /// One address as header tokens: a quoted or plain ASCII name, or encoded words for any other name, then
    /// `<address>`. An address that isn't ASCII goes as UTF-8 (RFC 6532), since it can't be encoded.
    private static func addressTokens(_ address: MailAddress) -> [String]? {
        let email = String(String.UnicodeScalarView(address.email.unicodeScalars.filter {
            $0.value > 0x20 && $0.value != 0x7F && $0 != "<" && $0 != ">"
        }))
        guard !email.isEmpty, email.utf8.count <= 900 else { return nil }
        let name = singleLine(address.name ?? "")
        guard !name.isEmpty else { return [email] }
        if name.utf8.contains(where: { $0 >= 0x80 }) || name.contains("=?") || name.utf8.count > 200 {
            return EncodedWords.encode(name) + ["<\(email)>"]
        }
        guard name.contains(where: { "()<>[]:;@\\,.\"".contains($0) }) else { return [name, "<\(email)>"] }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["\"\(escaped)\"", "<\(email)>"]
    }

    /// `filename="report.pdf"`, or RFC 2231 `filename*=utf-8''…` (in numbered pieces when long) for any name that
    /// isn't short, plain ASCII.
    private static func filenameParameterTokens(_ filename: String) -> [String] {
        if isPlainParameterText(filename) { return ["filename=\"\(filename)\""] }
        var segments: [String] = []
        var current = ""
        for byte in filename.utf8 {
            let piece = isAttributeCharacter(byte) ? String(UnicodeScalar(byte)) : "%" + TransferEncoding.hexDigits(byte)
            if current.count + piece.count > 60 {
                segments.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { segments.append(current) }
        if segments.count == 1 { return ["filename*=utf-8''\(segments[0])"] }
        return segments.enumerated().map { index, segment in
            "filename*\(index)*=" + (index == 0 ? "utf-8''" : "") + segment + (index < segments.count - 1 ? ";" : "")
        }
    }

    /// The Content-Type `name`, for programs that look there: RFC 2047 encoded words when it isn't plain ASCII.
    private static func nameParameterTokens(_ filename: String) -> [String] {
        if isPlainParameterText(filename) { return ["name=\"\(filename)\""] }
        var words = EncodedWords.encode(filename)
        guard !words.isEmpty else { return [] }
        words[0] = "name=\"" + words[0]
        words[words.count - 1] += "\""
        return words
    }

    private static func isPlainParameterText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 60 && !text.contains("=?")
            && text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }
    }

    /// RFC 2231 attribute characters, which go into a parameter without percent-encoding.
    private static func isAttributeCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$&+-.^_`|~".utf8.contains(byte)
        }
    }

    // MARK: Cleaning

    /// Header text on one line: line breaks, tabs and other control characters become spaces, and runs of spaces
    /// become one, so nothing can start a header line of its own.
    static func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isSpace = scalar.value < 0x20 || scalar.value == 0x7F || scalar.properties.isWhitespace
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
            lastWasSpace = isSpace
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// A message ID with its angle brackets and nothing that could break the header; nil if nothing is left.
    private static func cleanMessageID(_ id: String) -> String? {
        let inner = String(String.UnicodeScalarView(id.unicodeScalars.filter {
            $0.value > 0x20 && $0.value != 0x7F && $0 != "<" && $0 != ">"
        }))
        guard !inner.isEmpty, inner.utf8.count <= 900 else { return nil }
        return "<\(inner)>"
    }

    private static func cleanContentID(_ id: String?) -> String? {
        guard let id else { return nil }
        let inner = String(String.UnicodeScalarView(id.unicodeScalars.filter {
            $0.value > 0x20 && $0.value < 0x7F && $0 != "<" && $0 != ">"
        }))
        return inner.isEmpty || inner.utf8.count > 900 ? nil : inner
    }

    /// "type/subtype" in lowercase, or application/octet-stream when the given type isn't one.
    private static func cleanMIMEType(_ mimeType: String) -> String {
        let value = mimeType.trimmingCharacters(in: .whitespaces).lowercased()
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        let tokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&-^_.+")
        guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(tokenCharacters.contains) }) else {
            return "application/octet-stream"
        }
        return value
    }

    /// Text with every line break as CRLF.
    private static func crlfLines(_ text: String) -> String {
        // "\r\n" is one Character in Swift, so look for the scalars.
        guard text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Whether text can go as 7bit: printable ASCII and tabs, CRLF line ends, no line over 78 octets.
    private static func isSevenBitSafe(_ bytes: [UInt8]) -> Bool {
        var lineLength = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                lineLength = 0
                index += 2
                continue
            }
            guard (byte >= 0x20 && byte < 0x7F) || byte == 0x09 else { return false }
            lineLength += 1
            if lineLength > 78 { return false }
            index += 1
        }
        return true
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }
}
