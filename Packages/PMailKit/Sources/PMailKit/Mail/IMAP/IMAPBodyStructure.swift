import Foundation

/// One part of a message's BODYSTRUCTURE: a multipart with its parts, or a single part with its type, encoding and
/// size. Every part knows its section number ("1", "2.1"), for fetching just that part.
public struct IMAPBodyPart: Sendable, Hashable {
    /// The part's section number for `BODY[section]`. The top-level multipart of a message is "", and a message
    /// that isn't multipart has a single part, "1".
    public var section: String
    /// The media type and subtype, lowercased ("text", "plain").
    public var type: String
    public var subtype: String
    /// Content-Type parameters, lowercased names, with RFC 2231 and encoded-word values decoded ("charset", "name").
    public var parameters: [String: String]
    /// The Content-ID, as it came (usually with angle brackets).
    public var contentID: String?
    public var contentDescription: String?
    /// The Content-Transfer-Encoding, lowercased ("base64", "quoted-printable", "7bit").
    public var encoding: String?
    /// The size of the encoded content, in bytes.
    public var size: Int
    /// The number of lines, for text parts and attached messages.
    public var lines: Int?
    public var md5: String?
    /// The Content-Disposition, lowercased ("attachment", "inline").
    public var disposition: String?
    public var dispositionParameters: [String: String]
    public var languages: [String]
    public var location: String?
    /// A multipart's parts, or an attached message's (message/rfc822) own body.
    public var parts: [IMAPBodyPart]
    /// An attached message's envelope.
    public var envelope: IMAPEnvelope?

    public init(section: String, type: String, subtype: String, parameters: [String: String] = [:], contentID: String? = nil,
                contentDescription: String? = nil, encoding: String? = nil, size: Int = 0, lines: Int? = nil, md5: String? = nil,
                disposition: String? = nil, dispositionParameters: [String: String] = [:], languages: [String] = [],
                location: String? = nil, parts: [IMAPBodyPart] = [], envelope: IMAPEnvelope? = nil) {
        self.section = section
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.contentID = contentID
        self.contentDescription = contentDescription
        self.encoding = encoding
        self.size = size
        self.lines = lines
        self.md5 = md5
        self.disposition = disposition
        self.dispositionParameters = dispositionParameters
        self.languages = languages
        self.location = location
        self.parts = parts
        self.envelope = envelope
    }

    public var mimeType: String { "\(type)/\(subtype)" }
    public var isMultipart: Bool { type == "multipart" }
    public var charset: String? { parameters["charset"] }

    /// Whether this is an attached email message.
    public var isAttachedMessage: Bool { type == "message" && (subtype == "rfc822" || subtype == "global") }

    /// The file name, from the disposition's `filename` or else the type's `name`.
    public var filename: String? {
        let name = dispositionParameters["filename"] ?? parameters["name"]
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the part is a file attached to the message, rather than its text or a picture its HTML shows.
    public var isAttachment: Bool {
        if isMultipart { return false }
        // Signatures and encryption wrappers are part of how the message was sent, not files.
        if ["application/pkcs7-signature", "application/x-pkcs7-signature", "application/pgp-signature",
            "application/pgp-encrypted"].contains(mimeType) { return false }
        if disposition == "attachment" || isAttachedMessage { return true }
        if filename != nil { return disposition != "inline" || contentID == nil }
        if type == "text" { return false }
        return disposition == nil && contentID == nil
    }

    /// Every part that isn't a multipart, in order. Attached messages count as one part (their insides aren't
    /// listed).
    public var leafParts: [IMAPBodyPart] {
        isMultipart ? parts.flatMap(\.leafParts) : [self]
    }

    /// Whether any part is an attachment.
    public var hasAttachments: Bool { leafParts.contains { $0.isAttachment } }

    /// The part with a section number, searching inside attached messages too. An attached message and the
    /// multipart inside it share a number; the message itself is the one found.
    public func part(atSection section: String) -> IMAPBodyPart? {
        if self.section == section { return self }
        for part in parts {
            if let found = part.part(atSection: section) { return found }
        }
        return nil
    }

    /// The part to take a message list's snippet from: the first plain text part that isn't an attachment, else
    /// the first HTML part.
    public var snippetPart: IMAPBodyPart? {
        let candidates = leafParts.filter { $0.type == "text" && !$0.isAttachment }
        return candidates.first { $0.subtype == "plain" } ?? candidates.first { $0.subtype == "html" }
    }

    // MARK: Reading

    /// Reads a BODYSTRUCTURE (or BODY) value, numbering the parts.
    public static func parse(_ value: IMAPValue) -> IMAPBodyPart? {
        body(value, messageSection: "", depth: 0)
    }

    /// Reads the body of a message whose section is `messageSection` ("" for the message itself): a multipart
    /// takes the message's number and numbers its parts below it; a single part is part 1 of the message.
    private static func body(_ value: IMAPValue, messageSection: String, depth: Int) -> IMAPBodyPart? {
        guard let items = value.items, !items.isEmpty else { return nil }
        if items[0].items != nil { return part(value, section: messageSection, depth: depth) }
        return part(value, section: child(of: messageSection, number: 1), depth: depth)
    }

    private static func child(of section: String, number: Int) -> String {
        section.isEmpty ? "\(number)" : "\(section).\(number)"
    }

    private static func part(_ value: IMAPValue, section: String, depth: Int) -> IMAPBodyPart? {
        guard depth < 50, let items = value.items, !items.isEmpty else { return nil }
        if items[0].items != nil {
            // multipart: (part)(part)… "subtype" [params [disposition [language [location …]]]]
            let childValues = items.prefix(while: { $0.items != nil })
            var children: [IMAPBodyPart] = []
            for (index, childValue) in childValues.enumerated() {
                if let parsed = part(childValue, section: child(of: section, number: index + 1), depth: depth + 1) {
                    children.append(parsed)
                }
            }
            let rest = Array(items.dropFirst(childValues.count))
            func field(_ index: Int) -> IMAPValue { index < rest.count ? rest[index] : .null }
            var multipart = IMAPBodyPart(section: section, type: "multipart", subtype: field(0).text?.lowercased() ?? "mixed",
                                         parameters: parameters(field(1)), parts: children)
            readExtension(into: &multipart, disposition: field(2), language: field(3), location: field(4))
            return multipart
        }
        // single part: type subtype params id description encoding size [text: lines | message: envelope body lines]
        func field(_ index: Int) -> IMAPValue { index < items.count ? items[index] : .null }
        var single = IMAPBodyPart(section: section, type: field(0).text?.lowercased() ?? "application",
                                  subtype: field(1).text?.lowercased() ?? "octet-stream", parameters: parameters(field(2)),
                                  contentID: field(3).text, contentDescription: field(4).text.map(EncodedWords.decode),
                                  encoding: field(5).text?.lowercased(), size: field(6).number ?? 0)
        var next = 7
        if single.type == "message", field(7).items != nil, field(8).items != nil {
            single.envelope = IMAPEnvelope(field(7))
            if let inner = body(field(8), messageSection: section, depth: depth + 1) { single.parts = [inner] }
            single.lines = field(9).number
            next = 10
        } else if single.type == "text", let lines = field(7).number {
            single.lines = lines
            next = 8
        }
        single.md5 = field(next).text
        readExtension(into: &single, disposition: field(next + 1), language: field(next + 2), location: field(next + 3))
        return single
    }

    private static func readExtension(into part: inout IMAPBodyPart, disposition: IMAPValue, language: IMAPValue,
                                      location: IMAPValue) {
        if let items = disposition.items, let kind = items.first?.text {
            part.disposition = kind.lowercased()
            part.dispositionParameters = parameters(items.count > 1 ? items[1] : .null)
        } else if let kind = disposition.text {
            part.disposition = kind.lowercased()
        }
        if let items = language.items {
            part.languages = items.compactMap(\.text)
        } else if let single = language.text {
            part.languages = [single]
        }
        part.location = location.text
    }

    /// Reads `("name" "value" …)`, joining RFC 2231 continuations (`name*0*`, `name*1*`) and decoding their
    /// charset and percent escapes, and decoding encoded words that some mail programs put in names.
    static func parameters(_ value: IMAPValue) -> [String: String] {
        guard let items = value.items else { return [:] }
        var plain: [String: String] = [:]
        var pieces: [String: [(index: Int, encoded: Bool, value: String)]] = [:]
        var index = 0
        while index + 1 < items.count {
            defer { index += 2 }
            guard let rawName = items[index].text?.lowercased(), let rawValue = items[index + 1].data else { continue }
            let text = Charsets.decode(rawValue, charset: "utf-8")
            guard let star = rawName.firstIndex(of: "*") else {
                plain[rawName] = EncodedWords.decode(text)
                continue
            }
            let name = String(rawName[..<star])
            let suffix = rawName[rawName.index(after: star)...]
            let encoded = suffix.hasSuffix("*") || suffix.isEmpty
            let number = Int(suffix.replacingOccurrences(of: "*", with: "")) ?? 0
            pieces[name, default: []].append((number, encoded, text))
        }
        for (name, parts) in pieces {
            var bytes = Data()
            var charset: String?
            for (position, piece) in parts.sorted(by: { $0.index < $1.index }).enumerated() {
                var text = piece.value
                if piece.encoded, position == 0 {
                    // charset'language'value
                    let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = String(fields[0])
                        text = String(fields[2])
                    }
                }
                bytes.append(piece.encoded ? percentDecoded(text) : Data(text.utf8))
            }
            plain[name] = Charsets.decode(bytes, charset: charset ?? "utf-8")
        }
        return plain
    }

    private static func percentDecoded(_ text: String) -> Data {
        let bytes = [UInt8](text.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(value)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    // MARK: Content

    /// The part's content with its transfer encoding undone. A `partial` fetch (the first bytes only) may stop in
    /// the middle of a base64 group or a quoted-printable escape; those leftovers are dropped.
    public func decodedContent(_ data: Data, partial: Bool = false) -> Data {
        switch encoding {
        case "base64":
            var clean = [UInt8](data).filter { byte in
                switch byte {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="),
                     UInt8(ascii: "-"), UInt8(ascii: "_"):
                    return true
                default:
                    return false
                }
            }
            if partial { clean.removeLast(clean.count % 4) }
            return TransferEncoding.decodeBase64(Data(clean)) ?? Data()
        case "quoted-printable":
            var bytes = [UInt8](data)
            if partial {
                if bytes.last == UInt8(ascii: "=") {
                    bytes.removeLast()
                } else if bytes.count >= 2, bytes[bytes.count - 2] == UInt8(ascii: "=") {
                    bytes.removeLast(2)
                }
            }
            return TransferEncoding.decodeQuotedPrintable(Data(bytes))
        default:
            return data
        }
    }

    /// A one-line snippet from the first bytes of this text part: transfer encoding and charset decoded, HTML
    /// turned into text.
    public func snippet(from data: Data) -> String {
        var text = Self.text(from: decodedContent(data, partial: true), charset: charset)
        if subtype == "html" { text = HTMLText.plainText(fromHTML: Self.withoutCutOffHTML(text)) }
        return HTMLText.snippet(from: text)
    }

    /// Text in a charset, dropping up to three bytes from the end when a cut-off character there would otherwise
    /// spoil the whole text.
    static func text(from data: Data, charset: String?) -> String {
        let encoding = Charsets.encoding(named: charset) ?? .utf8
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(trim), encoding: encoding) { return text }
        }
        return Charsets.decode(data, charset: charset)
    }

    /// HTML that stopped partway: an element whose end is missing (a long style sheet), a comment, or a tag is cut
    /// off, so none of it turns up as text.
    static func withoutCutOffHTML(_ html: String) -> String {
        var text = html
        for element in ["head", "style", "script", "title"] {
            if let open = text.range(of: "<\(element)", options: [.caseInsensitive, .backwards]),
               text.range(of: "</\(element)", options: .caseInsensitive, range: open.upperBound..<text.endIndex) == nil {
                text = String(text[..<open.lowerBound])
            }
        }
        if let open = text.range(of: "<!--", options: .backwards),
           text.range(of: "-->", range: open.upperBound..<text.endIndex) == nil {
            text = String(text[..<open.lowerBound])
        }
        if let open = text.lastIndex(of: "<"), !text[open...].contains(">") {
            text = String(text[..<open])
        }
        return text
    }
}
