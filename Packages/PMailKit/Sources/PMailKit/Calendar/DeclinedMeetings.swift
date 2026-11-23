import Foundation

/// Canceled invitations deleted from PMail, on a calendar that keeps listing canceled events (Google's, asked for
/// them), so a deleted one stays gone. Kept in the account's folder.
public actor DismissedEvents {
    /// The file's name in the account's folder.
    public static let fileName = "Dismissed Events.json"

    let file: URL?
    private var ids: Set<String>?

    public init(file: URL?) {
        self.file = file
    }

    public func contains(_ id: String) -> Bool { load().contains(id) }

    public func add(_ id: String) {
        var all = load()
        guard all.insert(id).inserted else { return }
        ids = all
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all.sorted()).write(to: file, options: .atomic)
    }

    private func load() -> Set<String> {
        if let ids { return ids }
        let loaded = Set(file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        ids = loaded
        return loaded
    }
}
