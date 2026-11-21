import Foundation

/// A folder of files for an account kept on this Mac, one file per event or contact. Every file is written
/// atomically (to a temporary file, then moved into place), so a crash never leaves half a file behind.
struct LocalFileStore: Sendable {
    let folder: URL
    /// The extension of the files the store owns ("ics", "vcf"); other files in the folder are left alone.
    let fileExtension: String

    /// The names of the store's files, sorted.
    func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { isValid($0) }
                .sorted()
        } catch {
            throw PMailError.server("The folder couldn’t be read: \(error.localizedDescription)")
        }
    }

    func exists(_ name: String) -> Bool {
        isValid(name) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// A file's contents and an ETag for this version of it.
    func read(_ name: String) throws -> (data: Data, etag: String) {
        guard isValid(name) else { throw PMailError.notFound }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PMailError.notFound }
        do {
            let data = try Data(contentsOf: url)
            return (data, Self.etag(of: data))
        } catch {
            throw PMailError.server("The file couldn’t be read: \(error.localizedDescription)")
        }
    }

    /// Writes a file atomically and returns the ETag of what was written.
    @discardableResult
    func write(_ data: Data, to name: String) throws -> String {
        guard isValid(name) else { throw PMailError.notFound }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            throw PMailError.server("The change couldn’t be saved: \(error.localizedDescription)")
        }
        return Self.etag(of: data)
    }

    func delete(_ name: String) throws {
        guard exists(name) else { throw PMailError.notFound }
        do {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        } catch {
            throw PMailError.server("It couldn’t be deleted: \(error.localizedDescription)")
        }
    }

    /// Only plain file names with the store's extension: never a path that could reach outside the folder.
    private func isValid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && name.lowercased().hasSuffix("." + fileExtension)
    }

    /// A file name for a UID: the UID itself when it's safe in a file name, else a name made from a hash of it, so
    /// the same UID always gets the same file.
    static func fileName(for uid: String, fileExtension: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        if !uid.isEmpty, uid.count <= 150, !uid.hasPrefix("."), uid.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return uid + "." + fileExtension
        }
        return "item-" + hash(Data(uid.utf8)) + "." + fileExtension
    }

    /// An ETag for some contents: a hash of the bytes with their length.
    static func etag(of data: Data) -> String {
        "\"\(hash(data))-\(data.count)\""
    }

    /// FNV-1a, 64 bits, in hexadecimal.
    private static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return String(value, radix: 16)
    }
}
