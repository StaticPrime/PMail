import Foundation

extension GoogleMailService {
    /// The signature of the account's own send-as address (its primary one), as Google keeps it: HTML, which Google
    /// cleans when it's saved. Nil when there's none.
    public func loadSignature() async throws -> String? {
        let entry = try await primarySendAs()
        let signature = entry["signature"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return signature.isEmpty ? nil : signature
    }

    /// Saves the signature on the account's own send-as address.
    public func saveSignature(html: String) async throws {
        let entry = try await primarySendAs()
        guard let address = entry["sendAsEmail"].nonEmpty else { throw PMailError.notFound }
        _ = try await client.patch(Self.url("settings/sendAs/\(WebURL.segment(address))"), ["signature": .string(html)])
    }

    /// The account's own send-as entry: the primary one, else the one with its address.
    private func primarySendAs() async throws -> JSONValue {
        let list = try await client.get(Self.url("settings/sendAs"))["sendAs"].array
        if let primary = list.first(where: { $0["isPrimary"].bool == true }) { return primary }
        if let own = list.first(where: { $0["sendAsEmail"].string?.caseInsensitiveCompare(email) == .orderedSame }) { return own }
        throw PMailError.notFound
    }
}
