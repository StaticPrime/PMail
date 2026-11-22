import CryptoKit
import Foundation

/// A remote picture, style sheet or font, as PMail loaded it.
public struct RemoteResource: Sendable, Equatable {
    public var url: URL
    public var data: Data
    public var mimeType: String
    public var textEncoding: String?

    public init(url: URL, data: Data, mimeType: String, textEncoding: String? = nil) {
        self.url = url
        self.data = data
        self.mimeType = mimeType
        self.textEncoding = textEncoding
    }
}

/// PMail's own copies of the remote content in an account's mail, so a message's pictures come from the internet once
/// (as it arrives, with Protect Mail Activity on) and not again when it's opened.
///
/// Each address keeps a file named for its SHA-256, with a small JSON file beside it saying what it is, or that the
/// server turned it down, so it isn't asked for again.
public actor RemoteContentCache {
    struct Entry: Codable {
        var url: String
        var mimeType: String?
        var textEncoding: String?
        /// The server's error, when it turned the address down.
        var refusedStatus: Int?
        var savedAt: Date
        var size: Int
    }

    public enum Lookup: Sendable, Equatable {
        case resource(RemoteResource)
        /// The server turned it down, with this status, when it was loaded.
        case refused(status: Int)
    }

    public let folder: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(folder: URL) {
        self.folder = folder
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    /// What's kept for an address, if anything.
    public func lookup(_ url: URL) -> Lookup? {
        let name = Self.name(for: url)
        guard let entry = entry(named: name), entry.url == url.absoluteString else { return nil }
        if let status = entry.refusedStatus { return .refused(status: status) }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return .resource(RemoteResource(url: url, data: data, mimeType: entry.mimeType ?? "application/octet-stream", textEncoding: entry.textEncoding))
    }

    /// Whether anything is kept for an address (its content, or that it was turned down).
    public func contains(_ url: URL) -> Bool {
        entry(named: Self.name(for: url))?.url == url.absoluteString
    }

    public func save(_ resource: RemoteResource, at date: Date = Date()) {
        let name = Self.name(for: resource.url)
        let entry = Entry(url: resource.url.absoluteString, mimeType: resource.mimeType, textEncoding: resource.textEncoding, savedAt: date,
                          size: resource.data.count)
        write(entry, named: name, data: resource.data)
    }

    /// Notes that a server turned an address down for good (a 404, say), so it isn't asked again.
    public func saveRefusal(status: Int, for url: URL, at date: Date = Date()) {
        write(Entry(url: url.absoluteString, refusedStatus: status, savedAt: date, size: 0), named: Self.name(for: url), data: nil)
    }

    /// Throws away what was saved before `date`, then the oldest of the rest until it takes no more than `maxBytes`.
    public func prune(savedBefore date: Date, maxBytes: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var kept: [(name: String, entry: Entry)] = []
        for file in names where file.hasSuffix(".json") {
            let name = String(file.dropLast(5))
            guard let entry = entry(named: name), entry.savedAt >= date else {
                remove(named: name)
                continue
            }
            kept.append((name, entry))
        }
        var total = kept.reduce(0) { $0 + $1.entry.size }
        for item in kept.sorted(by: { $0.entry.savedAt < $1.entry.savedAt }) where total > maxBytes {
            remove(named: item.name)
            total -= item.entry.size
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Files

    private func entry(named name: String) -> Entry? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name + ".json")) else { return nil }
        return try? decoder.decode(Entry.self, from: data)
    }

    private func write(_ entry: Entry, named name: String, data: Data?) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            // The content first: an entry only ever describes a file that's all there.
            if let data { try data.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            try encoder.encode(entry).write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        } catch {
            // Not kept: it's loaded again next time.
        }
    }

    private func remove(named name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".json"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    static func name(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}
