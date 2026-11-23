import Foundation

/// Finds where an account's calendars or address books live on a server (RFC 6764 and RFC 5397): the signed-in
/// person's principal, then its home set, which may be on another host (iCloud's are).
enum DAVDiscovery {
    /// The home collection that holds the account's calendars (with `.calendarHomeSet`) or address books (with
    /// `.addressbookHomeSet`). Tries the address given, then `/.well-known/caldav` or `/.well-known/carddav`; a
    /// server that names no principal is taken to be the home itself.
    static func home(client: WebDAVClient, serverURL: URL, wellKnown: String, homeSet: DAVProperty) async throws -> URL {
        try await locate(client: client, serverURL: serverURL, wellKnown: wellKnown, homeSet: homeSet).home
    }

    /// The home collection, and the signed-in person's principal where the server names one.
    static func locate(client: WebDAVClient, serverURL: URL, wellKnown: String, homeSet: DAVProperty) async throws -> (home: URL, principal: URL?) {
        var candidates = [serverURL]
        if let wellKnownURL = URL(string: "/.well-known/\(wellKnown)", relativeTo: serverURL)?.absoluteURL,
           wellKnownURL.path != serverURL.path {
            candidates.append(wellKnownURL)
        }
        var principal: URL?
        var lastError: PMailError?
        for candidate in candidates {
            do {
                let answer = try await client.propfind(candidate, depth: 0, properties: [.currentUserPrincipal, homeSet])
                if let home = answer.firstURL(of: homeSet) { return (home, answer.firstURL(of: .currentUserPrincipal)) }
                if let found = answer.firstURL(of: .currentUserPrincipal) {
                    principal = found
                    break
                }
            } catch let error as PMailError {
                if error.needsSignIn || error == .cancelled { throw error }
                lastError = error
            }
        }
        if let principal {
            let answer = try await client.propfind(principal, depth: 0, properties: [homeSet])
            // A principal without a home set: some servers keep the collections right under it.
            return (answer.firstURL(of: homeSet) ?? principal, principal)
        }
        switch lastError {
        case .connectionFailed?, .timedOut?: throw lastError ?? PMailError.timedOut
        default: return (serverURL, nil)
        }
    }
}
