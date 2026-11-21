import Foundation

/// Writes vCards: new cards in vCard 3.0, and rewrites of existing cards that change only what the person changed
/// and keep every line PMail doesn't understand (social profiles, related names, other programs' own lines). A
/// vCard 4.0 card stays 4.0, so the lines kept from it still make sense.
enum VCardWriter {
    static let productID = "-//PuggleSoft//PMail//EN"

    /// The properties PMail writes itself; everything else on a card passes through untouched.
    private static let understood: Set<String> = [
        "VERSION", "PRODID", "N", "FN", "NICKNAME", "ORG", "TITLE", "EMAIL", "TEL", "ADR", "URL", "BDAY", "NOTE", "PHOTO",
        "CATEGORIES", "UID", "REV", "X-PMAIL-STARRED",
    ]

    /// A new card for a contact. `categories` are the labels that go in CATEGORIES (the caller leaves out labels that
    /// are server groups).
    static func newCard(for contact: Contact, uid: String, categories: [String], now: Date = Date()) -> String {
        card(updating: VCardCard(lines: []), with: contact, uid: uid, categories: categories, now: now)
    }

    /// A card rewritten with a contact's details.
    static func card(updating card: VCardCard, with contact: Contact, uid: String?, categories: [String], now: Date = Date()) -> String {
        let isNew = card.lines.isEmpty
        let version4 = !isNew && card.isVersion4
        let old = card.contact(id: "", etag: nil)
        var lines = [ICalendarLine("VERSION", value: version4 ? "4.0" : "3.0"), ICalendarLine("PRODID", value: productID)]
        func keep(_ name: String, unchanged: Bool, _ make: () -> [ICalendarLine]) {
            lines += !isNew && unchanged ? card.all(name) : make()
        }

        let names = [contact.familyName, contact.givenName, contact.middleName, contact.prefix, contact.suffix]
        let namesUnchanged = names == [old.familyName, old.givenName, old.middleName, old.prefix, old.suffix]
        keep("N", unchanged: namesUnchanged && card.first("N") != nil) {
            [ICalendarLine("N", value: names.map(ICalendarText.escape).joined(separator: ";"))]
        }
        keep("FN", unchanged: namesUnchanged && old.company == contact.company && card.first("FN") != nil) {
            [.text("FN", contact.displayName)]
        }
        keep("NICKNAME", unchanged: old.nickname == contact.nickname) {
            contact.nickname.isEmpty ? [] : [.text("NICKNAME", contact.nickname)]
        }
        keep("ORG", unchanged: old.company == contact.company && old.department == contact.department) {
            guard !contact.company.isEmpty || !contact.department.isEmpty else { return [] }
            var value = ICalendarText.escape(contact.company)
            if !contact.department.isEmpty { value += ";" + ICalendarText.escape(contact.department) }
            return [ICalendarLine("ORG", value: value)]
        }
        keep("TITLE", unchanged: old.jobTitle == contact.jobTitle) {
            contact.jobTitle.isEmpty ? [] : [.text("TITLE", contact.jobTitle)]
        }

        var nextItem = (card.lines.compactMap { itemNumber($0.group) }.max() ?? 0) + 1
        var emitted = Set<String>()
        func labeled(_ name: String, kind: VCardCard.Kind, _ values: [LabeledValue]) -> [ICalendarLine] {
            let originals = card.all(name).compactMap { line in
                card.value(of: line, kind: kind).map { value in
                    (line: line, value: LabeledValue(label: card.label(for: line, kind: kind), value: value))
                }
            }
            return multiValued(originals, new: values, card: card, isNew: isNew, emitted: &emitted) { value in
                labeledLines(name, kind: kind, label: value.label, value: value.value, version4: version4, nextItem: &nextItem)
            }
        }
        func filled(_ values: [LabeledValue]) -> [LabeledValue] {
            values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        lines += labeled("EMAIL", kind: .email, filled(contact.emails))
        lines += labeled("TEL", kind: .phone, filled(contact.phones))
        let addresses = card.all("ADR").compactMap { line in card.address(of: line).map { (line: line, value: $0) } }
        let newAddresses = contact.addresses.filter { !$0.isEmpty }
        lines += multiValued(addresses, new: newAddresses, card: card, isNew: isNew, emitted: &emitted) { address in
            let value = ";;" + [address.street, address.city, address.region, address.postalCode, address.country]
                .map(ICalendarText.escape).joined(separator: ";")
            return labeledLines("ADR", kind: .address, label: address.label, rawValue: value, version4: version4, nextItem: &nextItem)
        }
        lines += labeled("URL", kind: .url, filled(contact.urls))

        keep("BDAY", unchanged: sameDay(old.birthday, contact.birthday)) {
            guard let birthday = contact.birthday, let month = birthday.month, let day = birthday.day else { return [] }
            if let year = birthday.year { return [ICalendarLine("BDAY", value: String(format: "%04d-%02d-%02d", year, month, day))] }
            if version4 { return [ICalendarLine("BDAY", value: String(format: "--%02d%02d", month, day))] }
            // vCard 3 has no way to leave the year out; iCloud's cards use the year 1604 marked X-APPLE-OMIT-YEAR.
            return [ICalendarLine("BDAY", parameters: [ICalendarParameter("X-APPLE-OMIT-YEAR", "1604")],
                                  value: String(format: "1604-%02d-%02d", month, day))]
        }
        keep("NOTE", unchanged: old.notes == contact.notes) {
            contact.notes.isEmpty ? [] : [.text("NOTE", contact.notes)]
        }
        keep("PHOTO", unchanged: old.photoData == contact.photoData) {
            guard let data = contact.photoData, !data.isEmpty else { return [] }
            let type = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "PNG" : "JPEG"
            if version4 { return [ICalendarLine("PHOTO", value: "data:image/\(type.lowercased());base64," + data.base64EncodedString())] }
            return [ICalendarLine("PHOTO", parameters: [ICalendarParameter("ENCODING", "b"), ICalendarParameter("TYPE", type)],
                                  value: data.base64EncodedString())]
        }
        keep("CATEGORIES", unchanged: Set(card.categories) == Set(categories)) {
            categories.isEmpty ? [] : [ICalendarLine("CATEGORIES", value: categories.map(ICalendarText.escape).joined(separator: ","))]
        }
        keep("X-PMAIL-STARRED", unchanged: old.isStarred == contact.isStarred) {
            contact.isStarred ? [ICalendarLine("X-PMAIL-STARRED", value: "TRUE")] : []
        }
        if let existing = card.first("UID") {
            lines.append(existing)
        } else if let uid {
            lines.append(.text("UID", uid))
        }
        if isNew && contact.givenName.isEmpty && contact.familyName.isEmpty && !contact.company.isEmpty {
            // Shows the card under the company's name in iCloud contacts.
            lines.append(ICalendarLine("X-ABShowAs", value: "COMPANY"))
        }
        lines.append(ICalendarLine("REV", value: revision(now)))

        // Everything PMail doesn't understand, in the order it came, groups and all.
        for line in card.lines {
            if understood.contains(line.name) { continue }
            if let group = line.group?.lowercased(), emitted.contains(group) { continue }
            lines.append(line)
        }
        return serialize(lines)
    }

    /// A group card with one more member, or nil if it already lists them.
    static func addingMember(_ uid: String, to card: VCardCard, now: Date = Date()) -> String? {
        let bare = VCardCard.bareUID(uid)
        guard !card.memberUIDs.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) else { return nil }
        let name = card.first("MEMBER") != nil || (card.isVersion4 && card.first("X-ADDRESSBOOKSERVER-MEMBER") == nil)
            ? "MEMBER" : "X-ADDRESSBOOKSERVER-MEMBER"
        var lines = card.lines
        lines.append(ICalendarLine(name, value: "urn:uuid:" + bare))
        setRevision(&lines, now)
        return serialize(lines)
    }

    /// A group card without a member, or nil if it doesn't list them.
    static func removingMember(_ uid: String, from card: VCardCard, now: Date = Date()) -> String? {
        let bare = VCardCard.bareUID(uid)
        var lines = card.lines
        lines.removeAll { line in
            (line.name == "X-ADDRESSBOOKSERVER-MEMBER" || line.name == "MEMBER")
                && VCardCard.bareUID(ICalendarText.unescape(line.value)).caseInsensitiveCompare(bare) == .orderedSame
        }
        guard lines.count != card.lines.count else { return nil }
        setRevision(&lines, now)
        return serialize(lines)
    }

    static func serialize(_ lines: [ICalendarLine]) -> String {
        ICalendarComponent(name: "VCARD", properties: lines).serialized
    }

    // MARK: Helpers

    /// Writes a labeled list (emails, phones, addresses, web addresses): unchanged entries keep their original lines
    /// (and their groups); new or changed ones are written fresh.
    private static func multiValued<Value: Equatable>(_ originals: [(line: ICalendarLine, value: Value)], new values: [Value],
                                                      card: VCardCard, isNew: Bool, emitted: inout Set<String>,
                                                      make: (Value) -> [ICalendarLine]) -> [ICalendarLine] {
        func original(_ line: ICalendarLine) -> [ICalendarLine] {
            guard let group = line.group?.lowercased() else { return [line] }
            guard emitted.insert(group).inserted else { return [] }
            return card.linesInGroup(of: line)
        }
        if !isNew && originals.map(\.value) == values { return originals.flatMap { original($0.line) } }
        var used = Set<Int>()
        var lines: [ICalendarLine] = []
        for value in values {
            if let index = originals.indices.first(where: { !used.contains($0) && originals[$0].value == value }) {
                used.insert(index)
                lines += original(originals[index].line)
            } else {
                lines += make(value)
            }
        }
        // Groups of entries that were dropped mustn't come back with the lines PMail doesn't understand.
        for index in originals.indices where !used.contains(index) {
            if let group = originals[index].line.group?.lowercased() { emitted.insert(group) }
        }
        return lines
    }

    private static func labeledLines(_ name: String, kind: VCardCard.Kind, label: String, value: String, version4: Bool,
                                     nextItem: inout Int) -> [ICalendarLine] {
        labeledLines(name, kind: kind, label: label, rawValue: kind == .url ? value : ICalendarText.escape(value), version4: version4,
                     nextItem: &nextItem)
    }

    private static func labeledLines(_ name: String, kind: VCardCard.Kind, label: String, rawValue: String, version4: Bool,
                                     nextItem: inout Int) -> [ICalendarLine] {
        let (types, customLabel) = typeParameters(for: label, kind: kind, version4: version4)
        let parameters = types.isEmpty ? [] : [ICalendarParameter("TYPE", types)]
        guard let customLabel else { return [ICalendarLine(name, parameters: parameters, value: rawValue)] }
        let group = "item\(nextItem)"
        nextItem += 1
        return [ICalendarLine(group: group, name, parameters: parameters, value: rawValue), .text("X-ABLabel", customLabel, group: group)]
    }

    /// The TYPE values for a label, and the X-ABLabel to give it when TYPE can't say it.
    private static func typeParameters(for label: String, kind: VCardCard.Kind, version4: Bool) -> (types: [String], customLabel: String?) {
        let key = label.trimmingCharacters(in: .whitespaces).lowercased()
        let internet = kind == .email && !version4 ? ["INTERNET"] : []
        let voice = kind == .phone ? ["VOICE"] : []
        switch (kind, key) {
        case (_, ""): return (internet + voice, nil)
        case (.phone, "mobile"), (.phone, "cell"): return (["CELL", "VOICE"], nil)
        case (.phone, "iphone"): return (["IPHONE", "CELL", "VOICE"], nil)
        case (.phone, "main"): return (["MAIN"], nil)
        case (.phone, "home fax"): return (["HOME", "FAX"], nil)
        case (.phone, "work fax"): return (["WORK", "FAX"], nil)
        case (.phone, "fax"): return (["FAX"], nil)
        case (.phone, "pager"): return (["PAGER"], nil)
        case (_, "home"): return (internet + ["HOME"] + voice, nil)
        case (_, "work"): return (internet + ["WORK"] + voice, nil)
        case (_, "other"): return (internet + voice, "_$!<Other>!$_")
        case (.url, "homepage"): return ([], "_$!<HomePage>!$_")
        default: return (internet + voice, label.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func itemNumber(_ group: String?) -> Int? {
        guard let group = group?.lowercased(), group.hasPrefix("item") else { return nil }
        return Int(group.dropFirst(4))
    }

    private static func sameDay(_ first: DateComponents?, _ second: DateComponents?) -> Bool {
        first?.year == second?.year && first?.month == second?.month && first?.day == second?.day
    }

    private static func revision(_ date: Date) -> String {
        let wall = ICalendarZone.utc.wall(from: date)
        let (year, month, day) = wall.date
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, wall.hour, wall.minute, wall.second)
    }

    private static func setRevision(_ lines: inout [ICalendarLine], _ date: Date) {
        if let index = lines.firstIndex(where: { $0.name == "REV" }) {
            lines[index] = ICalendarLine("REV", value: revision(date))
        } else {
            lines.append(ICalendarLine("REV", value: revision(date)))
        }
    }
}
