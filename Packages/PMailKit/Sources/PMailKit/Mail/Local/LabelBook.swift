import Foundation

/// A label as an account keeps it on this Mac: its name and color. Its ID is the IMAP keyword that marks its messages
/// on a server that allows keywords (see `LabelKeyword`); POP accounts use the same IDs.
public struct LabelDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// "#RRGGBB", or nil for the default color.
    public var colorHex: String?

    public init(id: String, name: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    /// The label as the folder list shows it.
    public var folder: MailFolder { MailFolder(id: id, name: name, kind: .label, colorHex: colorHex) }
}

/// Label names as IMAP keywords: "PMail_" and then the name, with ASCII letters, digits, "-" and "." kept, spaces as
/// "_", and every other byte of its UTF-8 as "&" and two hex digits. "Trips 2026" is "PMail_Trips_2026" and "Café" is
/// "PMail_Caf&C3&A9". Keywords can't hold spaces, `(){%*"\]`, control characters or anything beyond ASCII, so every
/// name makes a keyword a server takes, and the name can be read back from it on another Mac.
enum LabelKeyword {
    static let prefix = "PMail_"

    /// The keyword for a label name.
    static func keyword(for name: String) -> String {
        var keyword = prefix
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."):
                keyword.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                keyword += "_"
            default:
                keyword += "&" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return keyword
    }

    /// The label name a keyword spells, or nil for a flag that isn't a label keyword. An "&" without two hex digits
    /// after it stays itself, and a keyword whose bytes don't make UTF-8 reads as it's spelled.
    static func name(from keyword: String) -> String? {
        guard isLabel(keyword) else { return nil }
        let body = Array(keyword.utf8.dropFirst(prefix.utf8.count))
        var bytes: [UInt8] = []
        var index = 0
        while index < body.count {
            let byte = body[index]
            if byte == UInt8(ascii: "_") {
                bytes.append(UInt8(ascii: " "))
            } else if byte == UInt8(ascii: "&"), let value = hexByte(body, at: index + 1) {
                bytes.append(value)
                index += 3
                continue
            } else {
                bytes.append(byte)
            }
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }

    /// Whether a flag is a label keyword: the prefix (in any case), something after it, and nothing a keyword can't hold.
    static func isLabel(_ flag: String) -> Bool {
        flag.utf8.count > prefix.utf8.count && flag.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
            && IMAPArgument.isAtom(flag)
    }

    /// Whether two keywords are the same one: servers may change their case.
    static func same(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }

    /// The byte two hex digits at `index` spell, if they do.
    private static func hexByte(_ bytes: [UInt8], at index: Int) -> UInt8? {
        guard index + 1 < bytes.count else { return nil }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        guard let high = digit(bytes[index]), let low = digit(bytes[index + 1]) else { return nil }
        return high << 4 | low
    }
}

/// Label names as people type them, for every kind of account.
enum LabelName {
    /// A name without space around it; throws for one with nothing in it.
    static func clean(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PMailError.server("A label needs a name.") }
        return clean
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// An account's labels kept on this Mac, in a JSON file: their names and colors (colors are only ever kept here), and,
/// for messages on a server that can't keep labels itself, which labels each has, by Message-ID. It also notes whether
/// the server has let PMail keep labels as keywords. Every change is written straight away; a missing or damaged file
/// reads as an empty book.
public actor LabelBook {
    public nonisolated let file: URL

    /// The labels the book keeps for one message, and its date, for listing a label newest first.
    struct Assignment: Codable, Sendable, Hashable {
        var labels: [String]
        var date: Date
    }

    /// A message the book keeps a label for: its Message-ID in the form `key(forMessageID:)` gives, and its date.
    struct Labeled: Sendable, Hashable {
        var key: String
        var date: Date
    }

    private struct Contents: Codable {
        var version = 1
        var labels: [LabelDefinition] = []
        /// Labels kept on this Mac for messages, by Message-ID (`key(forMessageID:)`).
        var assignments: [String: Assignment] = [:]
        /// Keywords of labels deleted or renamed here: a server may go on listing a keyword in a mailbox's FLAGS after
        /// the last message loses it, and these mustn't come back as labels.
        var forgotten: [String] = []
        /// Whether the server has taken label keywords (nil until PMail has asked to change a message's flags).
        var keywordsAllowed: Bool?
        /// The server said it takes keywords but a label keyword didn't stay on the message: labels are kept here.
        var keywordsIgnored: Bool?
        /// Where messages with each label were last seen (their IDs on the server), newest first, so listing a label
        /// fetches them without needing the server's searches.
        var places: [String: [String]] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decode(Int.self, forKey: .version)) ?? 1
            labels = (try? container.decode([LabelDefinition].self, forKey: .labels)) ?? []
            assignments = (try? container.decode([String: Assignment].self, forKey: .assignments)) ?? [:]
            forgotten = (try? container.decode([String].self, forKey: .forgotten)) ?? []
            keywordsAllowed = try? container.decodeIfPresent(Bool.self, forKey: .keywordsAllowed)
            keywordsIgnored = try? container.decodeIfPresent(Bool.self, forKey: .keywordsIgnored)
            places = (try? container.decode([String: [String]].self, forKey: .places)) ?? [:]
        }
    }

    private var contents = Contents()
    private var isLoaded = false

    public init(file: URL) {
        self.file = file
    }

    /// A Message-ID in the form the book keys messages by: without angle brackets or space around it, in lowercase.
    /// Nil when there's none.
    static func key(forMessageID header: String?) -> String? {
        guard let header else { return nil }
        let key = header.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
        return key.isEmpty ? nil : key
    }

    // MARK: Labels

    /// Every label, in name order.
    public func labels() -> [LabelDefinition] {
        loadIfNeeded()
        return contents.labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The label with an ID (whatever case a server gave the keyword in).
    public func label(withID id: String) -> LabelDefinition? {
        loadIfNeeded()
        return contents.labels.first { LabelKeyword.same($0.id, id) }
    }

    /// The labels as folders of kind `.label`, in name order.
    func folders() -> [MailFolder] {
        labels().map(\.folder)
    }

    /// Adds a label. Throws when the name is empty or another label already has it (names compare without regard to
    /// case, since a server's keywords may not either).
    func create(named name: String, colorHex: String?) throws -> LabelDefinition {
        loadIfNeeded()
        let clean = try LabelName.clean(name)
        let keyword = LabelKeyword.keyword(for: clean)
        if let existing = contents.labels.first(where: { LabelKeyword.same($0.id, keyword) }) {
            throw Self.duplicate(existing.name)
        }
        let label = LabelDefinition(id: keyword, name: clean, colorHex: WebColor.hex(colorHex))
        contents.labels.append(label)
        contents.forgotten.removeAll { LabelKeyword.same($0, keyword) }
        try save()
        return label
    }

    /// The ID a label takes when renamed: the new name's keyword, or its own ID when only the case of the name changes
    /// (a server may not tell keywords apart by case). Throws when the label isn't here, the name is empty or another
    /// label has it.
    func renamedID(_ id: String, to name: String) throws -> String {
        loadIfNeeded()
        guard let current = label(withID: id) else { throw PMailError.notFound }
        let keyword = LabelKeyword.keyword(for: try LabelName.clean(name))
        if LabelKeyword.same(keyword, current.id) { return current.id }
        if let other = contents.labels.first(where: { LabelKeyword.same($0.id, keyword) }) { throw Self.duplicate(other.name) }
        return keyword
    }

    /// Renames and recolors a label (a nil color leaves its color as it is). The labels kept here for messages move to
    /// its new ID, and the old keyword is forgotten.
    func update(_ id: String, name: String, colorHex: String?) throws -> LabelDefinition {
        let newID = try renamedID(id, to: name)
        let clean = try LabelName.clean(name)
        guard let index = contents.labels.firstIndex(where: { LabelKeyword.same($0.id, id) }) else { throw PMailError.notFound }
        let old = contents.labels[index]
        let label = LabelDefinition(id: newID, name: clean, colorHex: WebColor.hex(colorHex) ?? old.colorHex)
        contents.labels[index] = label
        if newID != old.id {
            for (key, var assignment) in contents.assignments where assignment.labels.contains(old.id) {
                assignment.labels = Self.replacing(old.id, with: newID, in: assignment.labels)
                contents.assignments[key] = assignment
            }
            if let places = contents.places.removeValue(forKey: old.id) { contents.places[newID] = places }
            forget(old.id)
            contents.forgotten.removeAll { LabelKeyword.same($0, newID) }
        }
        try save()
        return label
    }

    /// Deletes a label and the labels kept here for messages, and forgets its keyword.
    func remove(_ id: String) throws {
        loadIfNeeded()
        guard let label = label(withID: id) else { return }
        contents.labels.removeAll { $0.id == label.id }
        for (key, var assignment) in contents.assignments where assignment.labels.contains(label.id) {
            assignment.labels.removeAll { $0 == label.id }
            contents.assignments[key] = assignment.labels.isEmpty ? nil : assignment
        }
        contents.places[label.id] = nil
        forget(label.id)
        try save()
    }

    // MARK: Labels found on the server

    /// Adds the label keywords among `flags` the book doesn't know (and hasn't forgotten), named from the keyword:
    /// labels made on another Mac. Returns whether any were new. Keeping them is best effort.
    @discardableResult
    func discover(_ flags: [String]) -> Bool {
        loadIfNeeded()
        guard learn(flags) else { return false }
        try? save()
        return true
    }

    /// Messages with their labels as this Mac knows them: label keywords spelled as the book spells them (unknown ones
    /// joining it, forgotten ones left out), and the labels the book keeps for them added. `mailboxFlags` are the
    /// keywords the mailbox they came from says it has, which join the book too.
    func labeling(_ summaries: [MessageSummary], mailboxFlags: [String] = []) -> [MessageSummary] {
        loadIfNeeded()
        var changed = learn(mailboxFlags)
        var result = summaries
        for index in result.indices {
            let found = result[index].labelIDs
            if found.isEmpty && contents.assignments.isEmpty { continue }
            changed = learn(found) || changed
            var labels: [String] = []
            for id in found {
                let canonical = LabelKeyword.isLabel(id) ? label(withID: id)?.id : id
                if let canonical, !labels.contains(canonical) { labels.append(canonical) }
            }
            if let key = Self.key(forMessageID: result[index].messageIDHeader), let assignment = contents.assignments[key] {
                for id in assignment.labels where !labels.contains(id) { labels.append(id) }
            }
            result[index].labelIDs = labels
        }
        if changed { try? save() }
        return result
    }

    /// The labels a message has by its label keywords and by what the book keeps for it, as the book spells them.
    func labels(forKeywords keywords: [String], messageID: String?) -> [String] {
        let summary = MessageSummary(id: "", labelIDs: keywords, messageIDHeader: messageID)
        return labeling([summary]).first?.labelIDs ?? []
    }

    /// Notes what a writable mailbox said about keywords: once any mailbox takes them, the server keeps labels.
    func noteKeywords(allowed: Bool) throws {
        loadIfNeeded()
        guard allowed ? contents.keywordsAllowed != true : contents.keywordsAllowed == nil else { return }
        contents.keywordsAllowed = allowed
        try save()
    }

    /// Whether the server has taken label keywords: nil until a mailbox has been opened to change flags, and false
    /// once one didn't stay on a message even though the server said it would.
    func keywordsAllowed() -> Bool? {
        loadIfNeeded()
        return contents.keywordsIgnored == true ? false : contents.keywordsAllowed
    }

    /// Whether label keywords are known not to stay on this server's messages, whatever it says it takes.
    func keywordsIgnored() -> Bool {
        loadIfNeeded()
        return contents.keywordsIgnored == true
    }

    /// Notes that a label keyword didn't stay on a message: labels go in the book from now on.
    func noteKeywordsIgnored() throws {
        loadIfNeeded()
        guard contents.keywordsIgnored != true else { return }
        contents.keywordsIgnored = true
        try save()
    }

    // MARK: Labels kept on this Mac for messages

    /// Keeps a label for messages, by Message-ID. Returns how many had no Message-ID to keep it by.
    @discardableResult
    func assign(_ labelID: String, to messages: [MessageSummary]) throws -> Int {
        loadIfNeeded()
        var unkeyed = 0
        var changed = false
        for message in messages {
            guard let key = Self.key(forMessageID: message.messageIDHeader) else {
                unkeyed += 1
                continue
            }
            var assignment = contents.assignments[key] ?? Assignment(labels: [], date: message.date)
            guard !assignment.labels.contains(labelID) else { continue }
            assignment.labels.append(labelID)
            contents.assignments[key] = assignment
            changed = true
        }
        if changed { try save() }
        return unkeyed
    }

    /// Keeps labels for one message, by Message-ID, beside any kept for it already.
    func assign(_ labelIDs: [String], to message: MessageSummary) throws {
        for labelID in labelIDs { try assign(labelID, to: [message]) }
    }

    /// Stops keeping a label for messages.
    func unassign(_ labelID: String, from messages: [MessageSummary]) throws {
        loadIfNeeded()
        var changed = false
        for key in messages.compactMap({ Self.key(forMessageID: $0.messageIDHeader) }) {
            guard var assignment = contents.assignments[key], assignment.labels.contains(labelID) else { continue }
            assignment.labels.removeAll { $0 == labelID }
            contents.assignments[key] = assignment.labels.isEmpty ? nil : assignment
            changed = true
        }
        if changed { try save() }
    }

    // MARK: Where labeled messages are

    /// The most places kept for a label.
    static let placesKept = 500

    /// Where messages with a label were last seen, newest first.
    func places(withLabel labelID: String) -> [String] {
        loadIfNeeded()
        return contents.places[label(withID: labelID)?.id ?? labelID] ?? []
    }

    /// Notes that messages (by their IDs on the server) have a label.
    func notePlaces(_ ids: [String], forLabel labelID: String) {
        loadIfNeeded()
        if add(ids, toPlacesOf: label(withID: labelID)?.id ?? labelID) { try? save() }
    }

    /// Notes where messages with labels are, each under every label it has.
    func notePlaces(of summaries: [MessageSummary]) {
        loadIfNeeded()
        var changed = false
        for summary in summaries {
            for labelID in summary.labelIDs where LabelKeyword.isLabel(labelID) {
                changed = add([summary.id], toPlacesOf: label(withID: labelID)?.id ?? labelID) || changed
            }
        }
        if changed { try? save() }
    }

    /// Forgets places that no longer hold a message with the label.
    func dropPlaces(_ ids: [String], forLabel labelID: String) {
        loadIfNeeded()
        let key = label(withID: labelID)?.id ?? labelID
        guard let current = contents.places[key] else { return }
        let remaining = current.filter { !ids.contains($0) }
        guard remaining.count != current.count else { return }
        contents.places[key] = remaining.isEmpty ? nil : remaining
        try? save()
    }

    /// Puts places first in a label's list (the newest at the front), without saving. Returns whether any were new.
    private func add(_ ids: [String], toPlacesOf key: String) -> Bool {
        var current = contents.places[key] ?? []
        let new = ids.filter { !current.contains($0) }
        guard !new.isEmpty else { return false }
        current.insert(contentsOf: new, at: 0)
        contents.places[key] = Array(current.prefix(Self.placesKept))
        return true
    }

    /// The messages the book keeps a label for, newest first.
    func messages(withLabel labelID: String) -> [Labeled] {
        loadIfNeeded()
        return contents.assignments.filter { $0.value.labels.contains(labelID) }
            .map { Labeled(key: $0.key, date: $0.value.date) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.key < $1.key }
    }

    // MARK: Storage

    /// Adds label keywords the book doesn't know and hasn't forgotten, without saving. Returns whether any were new.
    private func learn(_ flags: [String]) -> Bool {
        var changed = false
        for flag in flags where LabelKeyword.isLabel(flag) {
            guard label(withID: flag) == nil, !contents.forgotten.contains(where: { LabelKeyword.same($0, flag) }),
                  let name = LabelKeyword.name(from: flag) else { continue }
            contents.labels.append(LabelDefinition(id: flag, name: name))
            changed = true
        }
        return changed
    }

    private func forget(_ keyword: String) {
        if !contents.forgotten.contains(where: { LabelKeyword.same($0, keyword) }) { contents.forgotten.append(keyword) }
    }

    private static func replacing(_ old: String, with new: String, in labels: [String]) -> [String] {
        var result: [String] = []
        for label in labels {
            let replaced = label == old ? new : label
            if !result.contains(replaced) { result.append(replaced) }
        }
        return result
    }

    static func duplicate(_ name: String) -> PMailError {
        .server("There’s already a label called “\(name)”.")
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode(Contents.self, from: data) else { return }
        contents = read
        // Labels without a usable ID (from a damaged file) are left out.
        contents.labels.removeAll { !LabelKeyword.isLabel($0.id) || $0.name.isEmpty }
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            throw PMailError.server("PMail couldn’t save labels on this Mac: \(error.localizedDescription)")
        }
    }
}
