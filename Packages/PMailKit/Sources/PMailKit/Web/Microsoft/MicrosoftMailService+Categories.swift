import Foundation

// Labels on a Microsoft account: Outlook categories. The account's master categories are its labels, with their colors,
// and a message's categories, which it keeps by name, are its labels. A label's ID is "category:" and the category's
// name. Master categories need the MailboxSettings permission; without it the account just has no labels to list.
extension MicrosoftMailService {
    static let categoryPrefix = "category:"

    /// Outlook's category colors, preset0 to preset24 (red, orange, brown, yellow, green, teal, olive, blue, purple,
    /// cranberry, steel, dark steel, gray, dark gray, black, then the dark shades of the first ten), near enough to how
    /// Outlook shows them.
    static let categoryColors: [(preset: String, hex: String)] = [
        ("preset0", "#D6252E"), ("preset1", "#F06C15"), ("preset2", "#FFCA4C"), ("preset3", "#FFFE3D"),
        ("preset4", "#4AB63F"), ("preset5", "#40BD95"), ("preset6", "#859A52"), ("preset7", "#3267B8"),
        ("preset8", "#613DB4"), ("preset9", "#A34E78"), ("preset10", "#C4CCDD"), ("preset11", "#8C9CBD"),
        ("preset12", "#C4C4C4"), ("preset13", "#A5A5A5"), ("preset14", "#1C1C1C"), ("preset15", "#AF1E25"),
        ("preset16", "#B14F0D"), ("preset17", "#AB7B05"), ("preset18", "#999400"), ("preset19", "#35792B"),
        ("preset20", "#2E7D64"), ("preset21", "#5F6C3A"), ("preset22", "#2A5191"), ("preset23", "#50328F"),
        ("preset24", "#82375F"),
    ]

    /// The label ID for a category.
    static func categoryLabelID(_ name: String) -> String { categoryPrefix + name }

    /// The category a label ID names; nil for an ID that isn't a category's.
    static func categoryName(fromLabelID id: String?) -> String? {
        guard let id, id.hasPrefix(categoryPrefix) else { return nil }
        let name = String(id.dropFirst(categoryPrefix.count))
        return name.isEmpty ? nil : name
    }

    /// Whether two category names are the same one: Outlook doesn't tell them apart by case.
    static func sameCategory(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }

    /// The color a preset stands for ("preset7" is blue); nil for "none" and anything unknown.
    static func categoryColor(_ preset: String?) -> String? {
        guard let preset = preset?.lowercased() else { return nil }
        return categoryColors.first { $0.preset == preset }?.hex
    }

    /// The preset closest to a color; nil for a color that can't be read.
    static func categoryPreset(nearest hex: String?) -> String? {
        guard let match = WebColor.nearest(to: hex, in: categoryColors.map(\.hex)) else { return nil }
        return categoryColors.first { $0.hex == match }?.preset
    }

    /// A master category as the folder list shows it.
    static func categoryFolder(_ json: JSONValue) -> MailFolder? {
        guard let name = json["displayName"].nonEmpty else { return nil }
        return MailFolder(id: categoryLabelID(name), name: name, kind: .label, colorHex: categoryColor(json["color"].string))
    }

    /// The master categories as labels, in name order; none when they can't be read.
    func categoryFolders() async -> [MailFolder] {
        let categories = (try? await masterCategories()) ?? []
        return categories.compactMap(Self.categoryFolder).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func masterCategories() async throws -> [JSONValue] {
        try await client.graphItems(Self.url("outlook/masterCategories"), headers: Self.headers)
    }

    /// The master category with a name.
    func masterCategory(named name: String, in categories: [JSONValue]) -> JSONValue? {
        categories.first { Self.sameCategory($0["displayName"].string ?? "", name) }
    }

    /// Adds a category to messages or takes it off, keeping the other categories their summaries list.
    func setCategory(_ labelID: String, on messages: [MessageSummary], adding: Bool) async throws {
        let name = Self.categoryName(fromLabelID: labelID) ?? labelID
        var seen = Set<String>()
        let requests = messages.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map { message in
            var names = message.labelIDs.compactMap(Self.categoryName(fromLabelID:)).filter { !Self.sameCategory($0, name) }
            if adding { names.append(name) }
            return GraphBatchRequest(method: "PATCH", url: Self.batchPath(message.id), body: ["categories": JSONValue(names)],
                                     headers: Self.headers)
        }
        try await client.graphBatch(requests)
    }

    // MARK: Making, changing and deleting labels

    /// Makes a master category in the preset color closest to `colorHex` (no color without one).
    public func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        let clean = try LabelName.clean(name)
        var body: [String: JSONValue] = ["displayName": .string(clean)]
        if let preset = Self.categoryPreset(nearest: colorHex) { body["color"] = .string(preset) }
        let created = try await client.post(Self.url("outlook/masterCategories"), .object(body), headers: Self.headers)
        return Self.categoryFolder(created) ?? MailFolder(id: Self.categoryLabelID(clean), name: clean, kind: .label)
    }

    /// Recolors a category (a nil color leaves it as it is), or renames it. Outlook can't rename a category, so a new
    /// name makes a new category (or takes the one already called that), moves every message with the old one to it and
    /// then deletes the old one. Calendar events and contacts with the old category keep it, without its color.
    public func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        guard let oldName = Self.categoryName(fromLabelID: label.id) else { throw PMailError.notFound }
        let newName = try LabelName.clean(name)
        let categories = try await masterCategories()
        guard let current = masterCategory(named: oldName, in: categories), let currentID = current["id"].nonEmpty else {
            throw PMailError.notFound
        }
        let preset = Self.categoryPreset(nearest: colorHex)
        if Self.sameCategory(newName, oldName) {
            guard let preset else { return Self.categoryFolder(current) ?? label }
            let updated = try await client.patch(Self.url("outlook/masterCategories/\(WebURL.segment(currentID))"),
                                                 ["color": .string(preset)], headers: Self.headers)
            return Self.categoryFolder(updated) ?? label
        }
        var target: JSONValue
        if let existing = masterCategory(named: newName, in: categories) {
            target = existing
            if let preset, let id = existing["id"].nonEmpty {
                target = try await client.patch(Self.url("outlook/masterCategories/\(WebURL.segment(id))"), ["color": .string(preset)],
                                                headers: Self.headers)
            }
        } else {
            var body: [String: JSONValue] = ["displayName": .string(newName)]
            if let color = preset ?? current["color"].nonEmpty { body["color"] = .string(color) }
            target = try await client.post(Self.url("outlook/masterCategories"), .object(body), headers: Self.headers)
        }
        let targetName = target["displayName"].nonEmpty ?? newName
        try await retagCategory(oldName, to: targetName)
        do {
            try await client.delete(Self.url("outlook/masterCategories/\(WebURL.segment(currentID))"), headers: Self.headers)
        } catch PMailError.notFound {
            // Already gone.
        }
        return Self.categoryFolder(target) ?? MailFolder(id: Self.categoryLabelID(targetName), name: targetName, kind: .label)
    }

    /// Deletes a master category. Its messages keep the category's name, as Outlook leaves them, so it no longer shows
    /// as a label but comes back on them if a category with that name is made again.
    public func deleteLabel(_ label: MailFolder) async throws {
        guard let name = Self.categoryName(fromLabelID: label.id) else { throw PMailError.notFound }
        guard let id = masterCategory(named: name, in: try await masterCategories())?["id"].nonEmpty else { return }
        do {
            try await client.delete(Self.url("outlook/masterCategories/\(WebURL.segment(id))"), headers: Self.headers)
        } catch PMailError.notFound {
            // Already gone.
        }
    }

    /// Moves every message with one category, in every folder, to another, keeping their other categories.
    func retagCategory(_ old: String, to new: String) async throws {
        let filter = "categories/any(c:c eq \(Graph.literal(old)))"
        let url = try Self.url("messages", [("$filter", filter), ("$select", "id,categories"), ("$top", "100")])
        var seen = Set<String>()
        let requests = try await client.graphItems(url, headers: Self.headers, maxPages: 100).compactMap { item -> GraphBatchRequest? in
            guard let id = item["id"].nonEmpty, seen.insert(id).inserted else { return nil }
            let names = item["categories"].strings.filter { !Self.sameCategory($0, old) && !Self.sameCategory($0, new) } + [new]
            return GraphBatchRequest(method: "PATCH", url: Self.batchPath(id), body: ["categories": JSONValue(names)],
                                     headers: Self.headers)
        }
        try await client.graphBatch(requests)
    }
}
