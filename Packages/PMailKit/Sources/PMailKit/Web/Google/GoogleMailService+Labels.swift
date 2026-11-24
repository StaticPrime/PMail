import Foundation

// Labels on a Google account. Google keeps them (`loadFolders` lists them, `perform` puts them on messages), so making,
// changing and deleting them goes straight to its mail API.
extension GoogleMailService {
    /// The only colors Google's mail API takes for a label, for its background and its text alike.
    static let labelPalette: [String] = [
        "#000000", "#434343", "#666666", "#999999", "#cccccc", "#efefef", "#f3f3f3", "#ffffff",
        "#fb4c2f", "#ffad47", "#fad165", "#16a766", "#43d692", "#4a86e8", "#a479e2", "#f691b3",
        "#f6c5be", "#ffe6c7", "#fef1d1", "#b9e4d0", "#c6f3de", "#c9daf8", "#e4d7f5", "#fcdee8",
        "#efa093", "#ffd6a2", "#fce8b3", "#89d3b2", "#a0eac9", "#a4c2f4", "#d0bcf1", "#fbc8d9",
        "#e66550", "#ffbc6b", "#fcda83", "#44b984", "#68dfa9", "#6d9eeb", "#b694e8", "#f7a7c0",
        "#cc3a21", "#eaa041", "#f2c960", "#149e60", "#3dc789", "#3c78d8", "#8e63ce", "#e07798",
        "#ac2b16", "#cf8933", "#d5ae49", "#0b804b", "#2a9c68", "#285bac", "#653e9b", "#b65775",
        "#822111", "#a46a21", "#aa8831", "#076239", "#1a764d", "#1c4587", "#41236d", "#83334c",
        "#464646", "#e7e7e7", "#0d3472", "#b6cff5", "#0d3b44", "#98d7e4", "#3d188e", "#e3d7ff",
        "#711a36", "#fbd3e0", "#8a1c0a", "#f2b2a8", "#7a2e0b", "#ffc8af", "#7a4706", "#ffdeb5",
        "#594c05", "#fbe983", "#684e07", "#fdedc1", "#0b4f30", "#b3efd3", "#04502e", "#a2dcc1",
        "#c2c2c2", "#4986e7", "#2da2bb", "#b99aff", "#994a64", "#f691b2", "#ff7537", "#ffad46",
        "#662e37", "#ebdbde", "#cca6ac", "#094228", "#42d692", "#16a765",
    ]

    /// A label's `color`: the palette's closest background to the color asked for, with black or white text,
    /// whichever reads better on it. Nil for a color that can't be read.
    static func labelColor(for hex: String?) -> JSONValue? {
        guard let background = WebColor.nearest(to: hex, in: labelPalette) else { return nil }
        return ["backgroundColor": .string(background), "textColor": .string(WebColor.readableText(on: background))]
    }

    /// Makes a label, shown in the label list and on messages, in the palette color closest to `colorHex`.
    public func createLabel(named name: String, colorHex: String?) async throws -> MailFolder {
        let clean = try LabelName.clean(name)
        var body: [String: JSONValue] = ["name": .string(clean), "labelListVisibility": "labelShow", "messageListVisibility": "show"]
        if let color = Self.labelColor(for: colorHex) { body["color"] = color }
        return try Self.labelFolder(try await client.post(Self.url("labels"), .object(body)), name: clean)
    }

    /// Renames or recolors a label (a nil color leaves its color as it is). `name` takes the place of the name the
    /// folder list shows, so a nested label stays where it is, and the labels nested inside it are renamed to match.
    public func updateLabel(_ label: MailFolder, name: String, colorHex: String?) async throws -> MailFolder {
        let clean = try LabelName.clean(name)
        let address = try Self.url("labels/\(WebURL.segment(label.id))")
        let oldName = try await client.get(address)["name"].nonEmpty ?? label.name
        let newName = (oldName.hasSuffix(label.name) ? String(oldName.dropLast(label.name.count)) : "") + clean
        var body: [String: JSONValue] = ["name": .string(newName)]
        if let color = Self.labelColor(for: colorHex) { body["color"] = color }
        let updated = try await client.patch(address, .object(body))
        if newName != oldName {
            let labels = try await client.get(Self.url("labels"))["labels"].array
            for nested in labels where nested["type"].string == "user" {
                guard let id = nested["id"].nonEmpty, let full = nested["name"].string, full.hasPrefix(oldName + "/") else { continue }
                let renamed = newName + full.dropFirst(oldName.count)
                _ = try await client.patch(Self.url("labels/\(WebURL.segment(id))"), ["name": .string(renamed)])
            }
        }
        return try Self.labelFolder(updated, name: clean, parentID: label.parentID)
    }

    /// Deletes a label; Google takes it off its messages.
    public func deleteLabel(_ label: MailFolder) async throws {
        do {
            try await client.delete(Self.url("labels/\(WebURL.segment(label.id))"))
        } catch PMailError.notFound {
            // Already gone.
        }
    }

    /// The account's own labels by their full names ("Work/Projects"), with their IDs and colors: for mail reached
    /// over IMAP, where a label is a mailbox with its name.
    public func userLabels() async throws -> [String: (id: String, colorHex: String?)] {
        var found: [String: (id: String, colorHex: String?)] = [:]
        for label in try await client.get(Self.url("labels"))["labels"].array where label["type"].string == "user" {
            guard let id = label["id"].nonEmpty, let name = label["name"].nonEmpty else { continue }
            found[name] = (id, WebColor.hex(label["color"]["backgroundColor"].string))
        }
        return found
    }

    /// A label from Google's answer as the folder list shows it, with the name to show.
    static func labelFolder(_ json: JSONValue, name: String, parentID: String? = nil) throws -> MailFolder {
        guard let id = json["id"].nonEmpty else { throw PMailError.protocolError("the label had no ID") }
        return MailFolder(id: id, name: name, kind: .label, parentID: parentID,
                          colorHex: WebColor.hex(json["color"]["backgroundColor"].string))
    }
}
