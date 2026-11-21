import Foundation

/// Reads RFC 5322 / MIME messages.
public enum MIMEParser {
    /// How deep multiparts may nest before the rest is read as plain text. Real mail stays under ten levels.
    static let maximumDepth = 40

    /// Reads a whole message (headers and body, CRLF or LF line ends). Never throws: damaged parts are kept as
    /// well as they can be, so a broken message still shows something.
    public static func parse(_ data: Data) -> ParsedMessage {
        let bytes = [UInt8](data)
        let root = MIMEPart.read(bytes[...], number: "", depth: 0, defaultType: "text/plain")
        var message = ParsedMessage(headers: root.fields)

        message.subject = unstructured(message.header("Subject"))
        message.from = addresses(named: "From", in: root.fields).first
        message.sender = addresses(named: "Sender", in: root.fields).first
        message.to = addresses(named: "To", in: root.fields)
        message.cc = addresses(named: "Cc", in: root.fields)
        message.bcc = addresses(named: "Bcc", in: root.fields)
        message.replyTo = addresses(named: "Reply-To", in: root.fields)
        message.date = message.header("Date").flatMap(MailDate.parse) ?? receivedDate(root.fields)
        message.messageID = messageIDs(in: message.header("Message-ID") ?? "").first
        message.inReplyTo = messageIDs(in: message.header("In-Reply-To") ?? "").first
        message.references = messageIDs(in: message.header("References") ?? "")
        if let unsubscribe = message.header("List-Unsubscribe")?.trimmingCharacters(in: .whitespaces), !unsubscribe.isEmpty {
            message.listUnsubscribe = unsubscribe
        }

        var collector = BodyCollector()
        let bodies = collector.bodies(of: root, lenient: true)
        message.textBody = bodies.text
        message.htmlBody = bodies.html

        // Pictures the HTML shows go with the body; everything else is a file under the message.
        let referenced = cidReferences(in: bodies.html ?? "")
        for part in collector.resources {
            var attachment = attachment(from: part)
            if let contentID = attachment.contentID, referenced.contains(contentID.lowercased()) {
                attachment.isInline = true
                message.inlineParts.append(attachment)
            } else {
                message.attachments.append(attachment)
            }
        }
        return message
    }

    // MARK: Header fields

    /// Unstructured header text (a subject) for showing: encoded words decoded, on one line.
    static func unstructured(_ value: String?) -> String {
        guard let value else { return "" }
        let decoded = EncodedWords.decode(value)
        return String(decoded.map { $0.isNewline || $0 == "\t" ? " " : $0 }).trimmingCharacters(in: .whitespaces)
    }

    private static func addresses(named name: String, in fields: [MIMEHeader]) -> [MailAddress] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.flatMap { AddressParser.parse($0.value) }
    }

    /// The time the first server got the message, for mail without a Date.
    private static func receivedDate(_ fields: [MIMEHeader]) -> Date? {
        guard let received = fields.first(where: { $0.name.caseInsensitiveCompare("Received") == .orderedSame })?.value,
              let semicolon = received.lastIndex(of: ";") else { return nil }
        return MailDate.parse(String(received[received.index(after: semicolon)...]))
    }

    /// The message IDs in a Message-ID, In-Reply-To or References header, each with its angle brackets. IDs a sender
    /// wrote without brackets get them, so they compare equal to the same ID written properly.
    static func messageIDs(in value: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let inner = rest[rest.index(after: open)..<close].filter { !$0.isWhitespace }
            if !inner.isEmpty { ids.append("<\(inner)>") }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            for token in value.split(whereSeparator: { $0.isWhitespace || $0 == "," }) where token.contains("@") {
                let inner = token.filter { $0 != "<" && $0 != ">" }
                if !inner.isEmpty { ids.append("<\(inner)>") }
            }
        }
        return ids
    }

    // MARK: Attachments

    private static func attachment(from part: MIMEPart) -> Attachment {
        let data = part.decodedData()
        return Attachment(id: part.number.isEmpty ? "1" : part.number, filename: filename(for: part, data: data),
                          mimeType: part.mimeType, size: data.count, contentID: part.contentID, isInline: false, data: data)
    }

    /// The file name a part gives (RFC 2231 and RFC 2047 forms included), or one made up from what it is: an
    /// attached message is named after its subject.
    static func filename(for part: MIMEPart, data: Data) -> String {
        let isMessage = part.mimeType == "message/rfc822" || part.mimeType == "message/global"
        if let given = part.givenFilename {
            let name = sanitizedFilename(given)
            if !name.isEmpty {
                return isMessage && !name.contains(".") ? name + ".eml" : name
            }
        }
        if isMessage {
            let fields = MIMEHeaderReader.read([UInt8](data)[...]).fields
            let subject = unstructured(fields.first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value)
            let name = sanitizedFilename(String(subject.prefix(120)))
            return (name.isEmpty ? "Message" : name) + ".eml"
        }
        return defaultFilename(for: part.mimeType)
    }

    /// A file name without folders (only what follows the last slash or backslash) or control characters. Empty when
    /// nothing is left, for the caller to replace.
    static func sanitizedFilename(_ name: String) -> String {
        var name = EncodedWords.decode(name)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func defaultFilename(for mimeType: String) -> String {
        switch mimeType {
        case "text/calendar", "application/ics": return "invite.ics"
        case "message/delivery-status", "message/global-delivery-status": return "Delivery Status.txt"
        case "message/disposition-notification": return "Disposition Notification.txt"
        case "text/rfc822-headers", "message/rfc822-headers": return "Message Headers.txt"
        default:
            let base = mimeType.hasPrefix("image/") ? "Image" : "Attachment"
            return extensions[mimeType].map { "\(base).\($0)" } ?? base
        }
    }

    private static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/pjpeg": "jpg", "image/gif": "gif",
        "image/heic": "heic", "image/heif": "heif", "image/webp": "webp", "image/tiff": "tiff", "image/bmp": "bmp",
        "image/svg+xml": "svg", "application/pdf": "pdf", "text/plain": "txt", "text/html": "html", "text/csv": "csv",
        "text/vcard": "vcf", "text/x-vcard": "vcf", "text/directory": "vcf", "application/zip": "zip",
        "application/json": "json", "application/xml": "xml", "text/xml": "xml", "audio/mpeg": "mp3", "audio/mp4": "m4a",
        "video/mp4": "mp4", "video/quicktime": "mov", "application/pgp-signature": "asc", "application/pgp-keys": "asc",
        "application/pkcs7-signature": "p7s", "application/x-pkcs7-signature": "p7s", "application/pkcs7-mime": "p7m",
        "application/x-pkcs7-mime": "p7m", "application/ms-tnef": "dat", "application/vnd.ms-tnef": "dat",
        "application/msword": "doc", "application/vnd.ms-excel": "xls", "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/rtf": "rtf", "text/rtf": "rtf", "text/css": "css",
    ]

    /// Every Content-ID the HTML points to with `cid:`, lowercased and percent-decoded.
    static func cidReferences(in html: String) -> Set<String> {
        var references = Set<String>()
        var searchStart = html.startIndex
        func endsReference(_ character: Character) -> Bool {
            character.isWhitespace || character == "\"" || character == "'" || character == ">" || character == "<" || character == ")"
        }
        while let found = html.range(of: "cid:", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            var end = found.upperBound
            while end < html.endIndex, !endsReference(html[end]) { end = html.index(after: end) }
            let raw = String(html[found.upperBound..<end])
            if !raw.isEmpty { references.insert((raw.removingPercentEncoding ?? raw).lowercased()) }
            searchStart = end
        }
        return references
    }
}

// MARK: - Parts

/// One entity of a message: the whole message, or a part of a multipart, with its body still encoded.
struct MIMEPart {
    /// The IMAP section number ("1", "1.2"); empty for the whole message.
    var number: String
    var fields: [MIMEHeader]
    var contentType: ParameterizedValue
    var type: String
    var subtype: String
    var disposition: ParameterizedValue?
    /// The Content-Transfer-Encoding, lowercased.
    var encoding: String
    /// The Content-ID, without angle brackets.
    var contentID: String?
    var body: ArraySlice<UInt8>
    var children: [MIMEPart] = []

    var mimeType: String { "\(type)/\(subtype)" }
    var isMultipart: Bool { !children.isEmpty }
    var isAttachmentDisposition: Bool { disposition?.value == "attachment" }

    /// The file name from Content-Disposition, or else the Content-Type's `name`.
    var givenFilename: String? {
        let name = disposition?.parameters["filename"] ?? contentType.parameters["name"]
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    func header(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Reads an entity and, for a multipart, its parts. `defaultType` is the type a part without a Content-Type has
    /// (message/rfc822 inside a digest).
    static func read(_ bytes: ArraySlice<UInt8>, number: String, depth: Int, defaultType: String) -> MIMEPart {
        let (fields, bodyStart) = MIMEHeaderReader.read(bytes)
        func field(_ name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let contentType = field("Content-Type").map(ParameterizedValue.init(parsing:)) ?? ParameterizedValue(value: defaultType)
        let (type, subtype) = splitType(contentType.value, default: defaultType)
        let encoding = field("Content-Transfer-Encoding").map {
            String($0.split(whereSeparator: { $0 == ";" || $0.isWhitespace }).first ?? "").lowercased()
        } ?? ""
        let contentID = field("Content-ID").map { $0.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" } }
        var part = MIMEPart(number: number, fields: fields, contentType: contentType, type: type, subtype: subtype,
                            disposition: field("Content-Disposition").map(ParameterizedValue.init(parsing:)),
                            encoding: encoding, contentID: (contentID?.isEmpty ?? true) ? nil : contentID,
                            body: bytes[min(bodyStart, bytes.endIndex)..<bytes.endIndex])

        if type == "multipart" {
            if depth < MIMEParser.maximumDepth, let boundary = contentType.parameters["boundary"].flatMap({ $0.isEmpty ? nil : $0 })
                ?? guessBoundary(part.body) {
                // Encoding a multipart isn't allowed, but some senders do it anyway.
                var content = part.body
                if encoding == "base64" || encoding == "quoted-printable" { content = [UInt8](part.decodedData())[...] }
                let childType = subtype == "digest" ? "message/rfc822" : "text/plain"
                part.children = splitMultipart(content, boundary: Array(boundary.utf8)).enumerated().map { index, piece in
                    read(piece, number: number.isEmpty ? "\(index + 1)" : "\(number).\(index + 1)", depth: depth + 1,
                         defaultType: childType)
                }
            }
            if part.children.isEmpty {
                // Nothing readable inside (no boundary, no parts, or nested too deep): show the body as text.
                part.type = "text"
                part.subtype = "plain"
            }
        }
        return part
    }

    /// "text/plain" as ("text", "plain"); a value without a subtype gets a sensible one.
    private static func splitType(_ value: String, default defaultType: String) -> (String, String) {
        let pieces = value.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty { return (pieces[0], pieces[1]) }
        switch pieces.first ?? "" {
        case "text": return ("text", "plain")
        case "multipart": return ("multipart", "mixed")
        case "": return splitType(defaultType, default: "text/plain")
        default: return ("application", "octet-stream")
        }
    }

    /// The boundary of a multipart that forgot to say: the first line that looks like one.
    private static func guessBoundary(_ body: ArraySlice<UInt8>) -> String? {
        var index = body.startIndex
        while index < body.endIndex {
            let lineEnd = body[index..<body.endIndex].firstIndex(of: 0x0A) ?? body.endIndex
            var line = body[index..<lineEnd]
            while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line = line.dropLast() }
            if line.count > 2, line.count < 200, line.starts(with: [0x2D, 0x2D]) {
                return String(decoding: line.dropFirst(2), as: UTF8.self)
            }
            index = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
        }
        return nil
    }

    /// The pieces between boundary lines. The preamble and epilogue are left out, a missing final boundary ends the
    /// last part at the end of the body, and a line only counts as a boundary when nothing but whitespace (or the
    /// closing "--") follows the boundary on it, so a nested multipart whose boundary starts the same way isn't cut.
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: [UInt8]) -> [ArraySlice<UInt8>] {
        let delimiter = [0x2D, 0x2D] + boundary
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var index = body.startIndex
        while index < body.endIndex {
            let lineEnd = body[index..<body.endIndex].firstIndex(of: 0x0A) ?? body.endIndex
            let next = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
            if body[index..<lineEnd].starts(with: delimiter) {
                var rest = body[(index + delimiter.count)..<lineEnd]
                let isClose = rest.starts(with: [0x2D, 0x2D])
                if isClose { rest = rest.dropFirst(2) }
                if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = partStart {
                        // The line break before a boundary belongs to the boundary.
                        var end = index
                        if end > start, body[end - 1] == 0x0A { end -= 1 }
                        if end > start, body[end - 1] == 0x0D { end -= 1 }
                        parts.append(body[start..<max(start, end)])
                    }
                    if isClose { return parts }
                    partStart = next
                }
            }
            index = next
        }
        if let start = partStart, start <= body.endIndex { parts.append(body[start..<body.endIndex]) }
        return parts
    }

    /// The body with its Content-Transfer-Encoding undone.
    func decodedData() -> Data {
        switch encoding {
        case "base64": TransferEncoding.decodeBase64(Data(body)) ?? Data()
        case "quoted-printable": TransferEncoding.decodeQuotedPrintable(Data(body))
        default: Data(body)
        }
    }

    /// A text part's body as a string: decoded, in its character set, with LF line ends. Plain text is also unwrapped
    /// if it is format=flowed, and loses the line breaks at its very end.
    func decodedText() -> String {
        let data = decodedData()
        var charset = contentType.parameters["charset"]
        if charset == nil, subtype == "html" { charset = Self.htmlCharset(in: data) }
        var text = Charsets.decode(data, charset: charset)
        // "\r\n" is one Character in Swift, so look for the scalar.
        if text.unicodeScalars.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if subtype == "plain" {
            if contentType.parameters["format"]?.lowercased() == "flowed" {
                text = FormatFlowed.unwrap(text, deleteSpace: contentType.parameters["delsp"]?.lowercased() == "yes")
            }
            // Line breaks at the very end only end the last line; they aren't text to show or quote.
            while text.hasSuffix("\n") { text.removeLast() }
        }
        return text
    }

    /// The character set an HTML body names in a `<meta>` tag, for a part whose Content-Type doesn't say.
    private static func htmlCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let found = head.range(of: "charset=") else { return nil }
        let value = head[found.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
        let name = value.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }
        return name.isEmpty ? nil : String(name)
    }
}

// MARK: - Choosing the bodies

/// Walks the parts, choosing the text and HTML bodies and collecting everything else as files or pictures.
private struct BodyCollector {
    struct Bodies {
        var text: String?
        var html: String?

        var isBlank: Bool {
            (text?.allSatisfy(\.isWhitespace) ?? true) && (html?.allSatisfy(\.isWhitespace) ?? true)
        }
    }

    /// Parts that aren't body text, in order: files, pictures and attached messages.
    var resources: [MIMEPart] = []

    /// `lenient` says a text part with a file name still counts as body text: true for the whole message, a
    /// related part's root, and alternatives, where a file name is a sender's quirk rather than a file.
    mutating func bodies(of part: MIMEPart, lenient: Bool) -> Bodies {
        if part.isMultipart {
            switch part.subtype {
            case "alternative": return alternative(part)
            case "related": return related(part)
            case "signed": return signed(part)
            default: return mixed(part)  // mixed, report, digest, parallel and anything unknown
            }
        }
        if part.type == "text", part.subtype == "plain" || part.subtype == "html", !part.isAttachmentDisposition,
           lenient || part.givenFilename == nil {
            return leaf(part)
        }
        resources.append(part)
        return Bodies()
    }

    private func leaf(_ part: MIMEPart) -> Bodies {
        part.subtype == "html" ? Bodies(html: part.decodedText()) : Bodies(text: part.decodedText())
    }

    /// The best of each: the last HTML, and the last plain text (preferring a part that is only text over text
    /// that came along with HTML). Other renderings of the same text are skipped, except calendar invitations.
    private mutating func alternative(_ part: MIMEPart) -> Bodies {
        var html: String?
        var text: String?
        var pureText: String?
        for child in part.children {
            let found: Bodies
            if child.isMultipart {
                found = bodies(of: child, lenient: true)
            } else if child.type == "text", child.subtype == "plain" || child.subtype == "html", !child.isAttachmentDisposition {
                found = leaf(child)
            } else if child.type == "text", child.subtype != "calendar" {
                continue  // another rendering of the same text (for watches and the like)
            } else {
                resources.append(child)
                continue
            }
            if let value = found.html { html = value }
            if let value = found.text {
                text = value
                if found.html == nil { pureText = value }
            }
        }
        return Bodies(text: pureText ?? text, html: html)
    }

    /// The root part (named by `start`, or the first) is the body; the rest are the pictures and files it uses.
    private mutating func related(_ part: MIMEPart) -> Bodies {
        let start = part.contentType.parameters["start"].map { $0.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" } }
        let rootIndex = start.flatMap { start in part.children.firstIndex { $0.contentID == start } } ?? 0
        var result = Bodies()
        for (index, child) in part.children.enumerated() {
            if index == rootIndex {
                result = bodies(of: child, lenient: true)
            } else {
                collectAll(child)
            }
        }
        return result
    }

    /// The first part is the message; the signature after it isn't shown as a file.
    private mutating func signed(_ part: MIMEPart) -> Bodies {
        let signatureType = part.contentType.parameters["protocol"]?.lowercased()
        var result = Bodies()
        for (index, child) in part.children.enumerated() {
            if index == 0 {
                result = bodies(of: child, lenient: true)
            } else if !child.isMultipart, child.mimeType == signatureType || Self.signatureTypes.contains(child.mimeType) {
                continue
            } else {
                collectAll(child)
            }
        }
        return result
    }

    private static let signatureTypes: Set<String> = ["application/pgp-signature", "application/pkcs7-signature",
                                                      "application/x-pkcs7-signature"]

    /// The first body part, then any later inline text parts appended in order; other parts are files.
    private mutating func mixed(_ part: MIMEPart) -> Bodies {
        var pieces: [Bodies] = []
        for child in part.children {
            let found = bodies(of: child, lenient: false)
            if found.text != nil || found.html != nil { pieces.append(found) }
        }
        return Self.combine(pieces)
    }

    private mutating func collectAll(_ part: MIMEPart) {
        if part.isMultipart {
            for child in part.children { collectAll(child) }
        } else {
            resources.append(part)
        }
    }

    /// Joins body pieces into one text body and one HTML body. When some pieces are only text and others only HTML,
    /// each body gets every piece: text turned into HTML, or HTML into text.
    static func combine(_ pieces: [Bodies]) -> Bodies {
        let useful = pieces.filter { !$0.isBlank }
        guard useful.count > 1 else { return useful.first ?? pieces.first ?? Bodies() }
        var result = Bodies()
        if useful.contains(where: { $0.text != nil }) {
            var text = ""
            for piece in useful {
                let addition = piece.text ?? piece.html.map(HTMLText.plainText(fromHTML:)) ?? ""
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += addition
            }
            result.text = text
        }
        if useful.contains(where: { $0.html != nil }) {
            result.html = useful.map { $0.html ?? $0.text.map(htmlFromText) ?? "" }.joined()
        }
        return result
    }

    private static func htmlFromText(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<div style=\"white-space: pre-wrap\">\(escaped)</div>"
    }
}

// MARK: - format=flowed

/// Unwraps RFC 3676 format=flowed text: lines ending in a space join the next line of the same quote depth.
enum FormatFlowed {
    static func unwrap(_ text: String, deleteSpace: Bool) -> String {
        var output: [String] = []
        var paragraph = ""
        var isInParagraph = false
        var paragraphDepth = 0

        func finishParagraph() {
            output.append((paragraphDepth > 0 ? String(repeating: ">", count: paragraphDepth) + " " : "") + paragraph)
            paragraph = ""
            isInParagraph = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            var depth = 0
            while line.first == ">" {
                depth += 1
                line = line.dropFirst()
            }
            if line.first == " " { line = line.dropFirst() }  // space-stuffing
            let isFlowed = line.hasSuffix(" ") && line != "-- "
            if isFlowed, deleteSpace { line = line.dropLast() }

            // A change of quote depth ends a paragraph even after a flowed line.
            if isInParagraph, depth != paragraphDepth { finishParagraph() }
            if !isInParagraph {
                isInParagraph = true
                paragraphDepth = depth
            }
            paragraph += line
            if !isFlowed { finishParagraph() }
        }
        if isInParagraph { finishParagraph() }
        return output.joined(separator: "\n")
    }
}
