import Foundation

/// One vCard (3.0 or 4.0, and most of 2.1) as its content lines, with what PMail reads from it.
struct VCardCard: Sendable, Hashable {
    /// The kinds of labeled values a card holds.
    enum Kind: Sendable {
        case email, phone, address, url
    }

    /// The lines between BEGIN:VCARD and END:VCARD, in order.
    var lines: [ICalendarLine]

    /// Every card in a file.
    static func parse(_ data: Data) -> [VCardCard] {
        ICalendarComponent.parse(data).filter { $0.name == "VCARD" }.map { VCardCard(lines: $0.properties) }
    }

    func first(_ name: String) -> ICalendarLine? {
        lines.first { $0.name == name }
    }

    func all(_ name: String) -> [ICalendarLine] {
        lines.filter { $0.name == name }
    }

    var version: String { first("VERSION")?.value.trimmingCharacters(in: .whitespaces) ?? "3.0" }
    var isVersion4: Bool { version.hasPrefix("4") }

    var uid: String? {
        first("UID").map { text(of: $0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A UID without the "urn:uuid:" that group member lists put in front of it.
    static func bareUID(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("urn:uuid:") ? String(trimmed.dropFirst(9)) : trimmed
    }

    // MARK: Groups

    /// Whether the card is a group (iCloud's X-ADDRESSBOOKSERVER-KIND, or vCard 4's KIND) rather than a person.
    var isGroup: Bool {
        let kind = first("X-ADDRESSBOOKSERVER-KIND") ?? first("KIND")
        return kind.map { text(of: $0).trimmingCharacters(in: .whitespaces).lowercased() } == "group"
    }

    var groupName: String {
        if let name = first("FN").map({ text(of: $0).trimmingCharacters(in: .whitespaces) }), !name.isEmpty { return name }
        return first("N").map { components(of: $0, joiner: " ").filter { !$0.isEmpty }.joined(separator: " ") } ?? ""
    }

    /// The UIDs of a group's members.
    var memberUIDs: [String] {
        lines.filter { $0.name == "X-ADDRESSBOOKSERVER-MEMBER" || $0.name == "MEMBER" }.map { Self.bareUID(text(of: $0)) }
    }

    // MARK: Values

    /// A line's value with quoted-printable undone (for old cards), still escaped.
    func rawValue(of line: ICalendarLine) -> String {
        let isQuotedPrintable = line.parameter("ENCODING")?.uppercased() == "QUOTED-PRINTABLE"
            || line.parameterValues("TYPE").contains { $0.uppercased() == "QUOTED-PRINTABLE" }
        guard isQuotedPrintable else { return line.value }
        var bytes: [UInt8] = []
        let source = Array(line.value.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "="), index + 2 < source.count,
               let byte = UInt8(String(decoding: source[index + 1...index + 2], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        if let charset = line.parameter("CHARSET") {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(bytes: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    func text(of line: ICalendarLine) -> String {
        ICalendarText.unescape(rawValue(of: line))
    }

    /// The parts of a structured value (N, ORG, ADR), each with its own list of values joined.
    func components(of line: ICalendarLine, joiner: String) -> [String] {
        ICalendarText.split(rawValue(of: line), at: ";").map { part in
            ICalendarText.split(part, at: ",").map { ICalendarText.unescape($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: joiner)
        }
    }

    /// The categories the card lists.
    var categories: [String] {
        var seen = Set<String>()
        return all("CATEGORIES").flatMap { ICalendarText.split(rawValue(of: $0), at: ",") }
            .map { ICalendarText.unescape($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The lines that belong together with a line: every line in its group (`item1.EMAIL` and `item1.X-ABLabel`),
    /// or just the line itself.
    func linesInGroup(of line: ICalendarLine) -> [ICalendarLine] {
        guard let group = line.group?.lowercased() else { return [line] }
        return lines.filter { $0.group?.lowercased() == group }
    }

    // MARK: Contact

    /// The person the card describes. Labels come from CATEGORIES; group membership is added by the caller.
    func contact(id: String, etag: String?) -> Contact {
        var contact = Contact(id: id, etag: etag, uid: uid)
        if let name = first("N") {
            let parts = components(of: name, joiner: " ")
            func part(_ index: Int) -> String { parts.indices.contains(index) ? parts[index] : "" }
            contact.familyName = part(0)
            contact.givenName = part(1)
            contact.middleName = part(2)
            contact.prefix = part(3)
            contact.suffix = part(4)
        }
        if let organization = first("ORG") {
            let parts = components(of: organization, joiner: " ")
            contact.company = parts.first ?? ""
            contact.department = parts.dropFirst().filter { !$0.isEmpty }.joined(separator: ", ")
        }
        contact.nickname = first("NICKNAME").map { components(of: $0, joiner: ", ").joined(separator: " ") } ?? ""
        contact.jobTitle = first("TITLE").map { text(of: $0).trimmingCharacters(in: .whitespaces) } ?? ""
        let hasName = ![contact.prefix, contact.givenName, contact.middleName, contact.familyName, contact.suffix].allSatisfy(\.isEmpty)
        if !hasName, let fullName = first("FN").map({ text(of: $0).trimmingCharacters(in: .whitespaces) }), !fullName.isEmpty,
           fullName != contact.company {
            contact.givenName = fullName
        }
        contact.emails = all("EMAIL").compactMap { line in
            value(of: line, kind: .email).map { LabeledValue(label: label(for: line, kind: .email), value: $0) }
        }
        contact.phones = all("TEL").compactMap { line in
            value(of: line, kind: .phone).map { LabeledValue(label: label(for: line, kind: .phone), value: $0) }
        }
        contact.urls = all("URL").compactMap { line in
            value(of: line, kind: .url).map { LabeledValue(label: label(for: line, kind: .url), value: $0) }
        }
        contact.addresses = all("ADR").compactMap { address(of: $0) }
        contact.birthday = first("BDAY").flatMap { birthday(from: $0) }
        contact.notes = first("NOTE").map { text(of: $0) } ?? ""
        contact.photoData = all("PHOTO").lazy.compactMap { photoData(from: $0) }.first
        contact.labels = categories
        contact.isStarred = first("X-PMAIL-STARRED").map { text(of: $0).trimmingCharacters(in: .whitespaces).uppercased() } == "TRUE"
        return contact
    }

    /// An email address, phone number or web address, without the URI scheme vCard 4 may put in front.
    func value(of line: ICalendarLine, kind: Kind) -> String? {
        var value = text(of: line).trimmingCharacters(in: .whitespaces)
        switch kind {
        case .email where value.lowercased().hasPrefix("mailto:"): value = String(value.dropFirst(7))
        case .phone where value.lowercased().hasPrefix("tel:"): value = String(value.dropFirst(4))
        default: break
        }
        return value.isEmpty ? nil : value
    }

    func address(of line: ICalendarLine) -> PostalAddress? {
        let parts = components(of: line, joiner: ", ")
        func part(_ index: Int) -> String { parts.indices.contains(index) ? parts[index] : "" }
        // PO box, extended address (an apartment) and street all go on the street lines.
        let street = [part(2), part(1), part(0)].filter { !$0.isEmpty }.joined(separator: "\n")
        let address = PostalAddress(label: label(for: line, kind: .address), street: street, city: part(3), region: part(4),
                                    postalCode: part(5), country: part(6))
        return address.isEmpty ? nil : address
    }

    func birthday(from line: ICalendarLine) -> DateComponents? {
        if line.parameter("VALUE")?.lowercased() == "text" { return nil }
        let value = text(of: line).trimmingCharacters(in: .whitespaces)
        func valid(_ month: Int, _ day: Int) -> Bool { (1...12).contains(month) && (1...31).contains(day) }
        if value.hasPrefix("--") {
            let digits = value.dropFirst(2).filter { $0.isASCII && $0.isNumber }
            guard digits.count >= 4, let month = Int(digits.prefix(2)), let day = Int(digits.dropFirst(2).prefix(2)),
                  valid(month, day) else { return nil }
            return DateComponents(month: month, day: day)
        }
        let digits = (value.split(separator: "T").first ?? "").filter { $0.isASCII && $0.isNumber }
        guard digits.count == 8, let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.suffix(2)), valid(month, day) else { return nil }
        if let omitted = line.parameter("X-APPLE-OMIT-YEAR").flatMap({ Int($0) }), omitted == year {
            return DateComponents(month: month, day: day)
        }
        return DateComponents(year: year, month: month, day: day)
    }

    /// An inline picture: base64 with ENCODING=b (or BASE64 in old cards), or a `data:` URI. Pictures on the web
    /// aren't fetched.
    func photoData(from line: ICalendarLine) -> Data? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let data: Data?
        if value.lowercased().hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ","), value[..<comma].lowercased().hasSuffix(";base64") else { return nil }
            data = Data(base64Encoded: String(value[value.index(after: comma)...]), options: .ignoreUnknownCharacters)
        } else {
            let encoding = line.parameter("ENCODING")?.lowercased()
            let isBase64 = encoding == "b" || encoding == "base64" || line.parameterValues("TYPE").contains { $0.uppercased() == "BASE64" }
            guard isBase64 else { return nil }
            data = Data(base64Encoded: value, options: .ignoreUnknownCharacters)
        }
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    // MARK: Labels

    /// The label PMail shows for an email, phone, address or web address: the X-ABLabel of its group if it has one
    /// (as iCloud writes labels), else from its TYPE parameters ("home", "work", "mobile"…), else "other".
    func label(for line: ICalendarLine, kind: Kind) -> String {
        if let group = line.group?.lowercased(),
           let custom = lines.first(where: { $0.group?.lowercased() == group && $0.name == "X-ABLABEL" }) {
            let label = Self.label(fromGroupLabel: text(of: custom).trimmingCharacters(in: .whitespaces))
            if !label.isEmpty { return label }
        }
        let types = Set(line.parameterValues("TYPE").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if kind == .phone {
            if types.contains("fax") {
                if types.contains("home") { return "home fax" }
                if types.contains("work") { return "work fax" }
                return "fax"
            }
            if types.contains("iphone") { return "iPhone" }
            if types.contains("cell") || types.contains("mobile") { return "mobile" }
            if types.contains("main") { return "main" }
            if types.contains("pager") { return "pager" }
        }
        if types.contains("home") { return "home" }
        if types.contains("work") { return "work" }
        return "other"
    }

    /// The built-in labels iCloud's cards use ("_$!<Mobile>!$_") in PMail's words; custom labels as they are.
    static func label(fromGroupLabel text: String) -> String {
        guard text.hasPrefix("_$!<"), text.hasSuffix(">!$_"), text.count > 8 else { return text }
        let inner = String(text.dropFirst(4).dropLast(4))
        switch inner.lowercased() {
        case "homefax": return "home fax"
        case "workfax": return "work fax"
        case "otherfax": return "other fax"
        case "iphone": return "iPhone"
        case "homepage": return "homepage"
        default: return inner.lowercased()
        }
    }
}
