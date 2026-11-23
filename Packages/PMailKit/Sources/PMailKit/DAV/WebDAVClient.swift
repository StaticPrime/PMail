import Foundation

/// Talks WebDAV (RFC 4918) and its calendar and contacts extensions over an `HTTPTransport`: signs each request in,
/// follows redirects itself, and turns HTTP failures into `PMailError`s (401 is a refused sign-in, 404 is gone,
/// 412 means someone else changed it first).
struct WebDAVClient: Sendable {
    /// Most redirects followed for one request.
    static let maximumRedirects = 5

    let credential: Credential
    let transport: any HTTPTransport

    /// A server's answer.
    struct Response: Sendable {
        var status: Int
        var body: Data
        /// The address that answered, after redirects: hrefs in the body are relative to it.
        var url: URL
        var etag: String?
    }

    /// Sends a request, following up to five redirects (re-sending the same method and body to the new address) and
    /// trying once more with a fresh token when a token is turned down. Throws for anything but a 2xx answer.
    func send(_ method: String, to url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> Response {
        var address = url
        var redirects = 0
        var refreshedToken = false
        while true {
            var allHeaders = headers
            allHeaders["Authorization"] = try await credential.authorizationHeader()
            let request = URLRequest(url: address, method: method, headers: allHeaders, body: body)
            let (data, response) = try await perform(request)
            let status = response.statusCode
            if [301, 302, 307, 308].contains(status) {
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: address)?.absoluteURL else {
                    throw PMailError.protocolError("the server sent PMail elsewhere without saying where")
                }
                guard redirects < Self.maximumRedirects else { throw PMailError.protocolError("the server kept sending PMail elsewhere") }
                if address.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https" {
                    throw PMailError.connectionFailed("The server tried to move the connection off a secure one.")
                }
                redirects += 1
                address = next
                continue
            }
            if status == 401, !refreshedToken, case let .oauth(_, tokens) = credential {
                refreshedToken = true
                await tokens.invalidateAccessToken()
                continue
            }
            guard (200..<300).contains(status) else { throw Self.error(status: status) }
            return Response(status: status, body: data, url: response.url ?? address,
                            etag: response.value(forHTTPHeaderField: "ETag").flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as PMailError {
            throw error
        } catch is CancellationError {
            throw PMailError.cancelled
        } catch {
            throw PMailError.connectionFailed(error.localizedDescription)
        }
    }

    static func error(status: Int) -> PMailError {
        switch status {
        case 401: .authenticationFailed("")
        case 404, 410: .notFound
        case 412: .conflict
        default:
            .http(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status).capitalizingFirstLetter)
        }
    }

    // MARK: Methods

    /// PROPFIND for some properties, on the resource itself (depth 0) or its members too (depth 1).
    func propfind(_ url: URL, depth: Int, properties: [DAVProperty]) async throws -> DAVMultistatus {
        let body = DAVRequestBody.propfind(properties)
        let response = try await send("PROPFIND", to: url, headers: Self.xmlHeaders(depth: depth), body: body)
        return try DAVMultistatus(parsing: response.body, baseURL: response.url)
    }

    func report(_ url: URL, depth: Int, body: Data) async throws -> DAVMultistatus {
        let response = try await send("REPORT", to: url, headers: Self.xmlHeaders(depth: depth), body: body)
        return try DAVMultistatus(parsing: response.body, baseURL: response.url)
    }

    func get(_ url: URL) async throws -> (data: Data, etag: String?) {
        let response = try await send("GET", to: url)
        return (response.body, response.etag)
    }

    /// Saves a resource. With `ifNoneMatch` it must not exist yet; with `ifMatch` it must still be that version.
    /// Returns the new ETag, when the server gives one.
    func put(_ url: URL, data: Data, contentType: String, ifMatch: String? = nil, ifNoneMatch: Bool = false,
             extraHeaders: [String: String] = [:]) async throws -> String? {
        var headers = extraHeaders.merging(["Content-Type": contentType]) { $1 }
        if let ifMatch { headers["If-Match"] = ifMatch }
        if ifNoneMatch { headers["If-None-Match"] = "*" }
        return try await send("PUT", to: url, headers: headers, body: data).etag
    }

    func delete(_ url: URL, ifMatch: String?, extraHeaders: [String: String] = [:]) async throws {
        var headers = extraHeaders
        if let ifMatch { headers["If-Match"] = ifMatch }
        _ = try await send("DELETE", to: url, headers: headers)
    }

    /// Sets properties of a resource (a calendar's name, description and color). The server answers for each one; if
    /// it refused any, it set none (the change is all or nothing), and that's an error.
    func proppatch(_ url: URL, _ values: [(DAVProperty, String)]) async throws {
        let response = try await send("PROPPATCH", to: url, headers: ["Content-Type": "application/xml; charset=utf-8"],
                                      body: DAVRequestBody.propertyUpdate(values))
        guard let answer = try? DAVMultistatus(parsing: response.body, baseURL: response.url), let result = answer.responses.first else { return }
        guard values.allSatisfy({ result.property($0.0) != nil }) else {
            throw PMailError.notSupported("The server didn’t accept these settings, so it kept the ones it had.")
        }
    }

    /// A resource's current ETag, for servers that don't send one back when saving.
    func etag(of url: URL) async throws -> String? {
        try await propfind(url, depth: 0, properties: [.getETag]).responses.lazy.compactMap { $0.property(.getETag)?.trimmedText }.first
    }

    private static func xmlHeaders(depth: Int) -> [String: String] {
        ["Depth": String(depth), "Content-Type": "application/xml; charset=utf-8", "Prefer": "return-minimal"]
    }
}

/// A file name for a new calendar or contacts resource: the UID when it's safe in a URL, else a fresh UUID.
enum DAVResourceName {
    static func name(for uid: String, fileExtension: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let isSafe = !uid.isEmpty && uid.count <= 200 && !uid.hasPrefix(".") && uid.unicodeScalars.allSatisfy { allowed.contains($0) }
        return (isSafe ? uid : UUID().uuidString) + "." + fileExtension
    }
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
