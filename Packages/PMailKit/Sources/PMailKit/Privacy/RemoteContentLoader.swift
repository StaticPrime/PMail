import Foundation
import os

/// Loads the remote content in messages privately: as an anonymous browser that keeps nothing (see `PrivateSession`),
/// through the person's own proxy when they set one up, never from the Mac itself or its network, and from PMail's own
/// copy whenever there is one.
public final class RemoteContentLoader: Sendable {
    public struct Limits: Sendable {
        /// The most one picture, style sheet or font may be.
        public var maxBytes = 10 * 1024 * 1024
        /// The most addresses loaded ahead for one message.
        public var maxPerMessage = 150
        /// How many load at once.
        public var concurrent = 4

        public init() {}
    }

    private struct Route: Sendable {
        var fetcher: any RemoteFetcher
        var throughProxy: Bool
    }

    private let route: OSAllocatedUnfairLock<Route>
    public let limits: Limits

    public init(fetcher: any RemoteFetcher, throughProxy: Bool = false, limits: Limits = Limits()) {
        route = OSAllocatedUnfairLock(initialState: Route(fetcher: fetcher, throughProxy: throughProxy))
        self.limits = limits
    }

    /// Starts going to the internet another way (Settings ▸ Privacy changed). Loads under way finish the old way;
    /// every one asked for after this goes the new way.
    public func use(_ fetcher: any RemoteFetcher, throughProxy: Bool) {
        route.withLock { $0 = Route(fetcher: fetcher, throughProxy: throughProxy) }
    }

    /// Whether loads go through a proxy.
    public var isThroughProxy: Bool { route.withLock { $0.throughProxy } }

    /// A reference's content: the copy `cache` keeps, or else loaded now and kept there. A style sheet comes back
    /// with its own addresses pointed at the loader.
    public func load(_ reference: RemoteReference, cache: RemoteContentCache?) async throws -> RemoteResource {
        var resource = try await raw(reference, cache: cache)
        if reference.kind == .style {
            resource.data = Data(RemoteContent.rewrite(css: Self.text(of: resource), base: reference.url).css.utf8)
            resource.mimeType = "text/css"
            resource.textEncoding = "utf-8"
        }
        return resource
    }

    /// Loads what a message asks for from the internet that `cache` doesn't have yet (its pictures, its style sheets
    /// and what those ask for in turn), so opening the message later asks the internet for nothing. Returns how many
    /// addresses it loaded.
    @discardableResult
    public func prefetch(html: String, into cache: RemoteContentCache) async -> Int {
        var wanted = Array(RemoteContent.references(in: html).prefix(limits.maxPerMessage))
        var seen = Set(wanted)
        var loaded = 0
        // Style sheets can import more: three rounds at most.
        for _ in 0..<3 where !wanted.isEmpty {
            let results = await load(wanted, into: cache)
            wanted = []
            for result in results {
                loaded += result.fetched ? 1 : 0
                guard let resource = result.resource, result.reference.kind == .style else { continue }
                for reference in RemoteContent.rewrite(css: Self.text(of: resource), base: result.reference.url).references
                where seen.count < limits.maxPerMessage && seen.insert(reference).inserted {
                    wanted.append(reference)
                }
            }
        }
        return loaded
    }

    /// A picture from the web, privately and not kept (one in a signature, say).
    public func data(from url: URL) async throws -> Data {
        try await fetch(RemoteReference(url), cache: nil).data
    }

    // MARK: Loading

    private struct Loaded: Sendable {
        var reference: RemoteReference
        var resource: RemoteResource?
        var fetched: Bool
    }

    /// Loads references a few at a time, each from `cache` when it has it.
    private func load(_ references: [RemoteReference], into cache: RemoteContentCache) async -> [Loaded] {
        await withTaskGroup(of: Loaded.self) { group in
            var results: [Loaded] = []
            var pending = references[...]
            func start() {
                guard let reference = pending.popFirst() else { return }
                group.addTask {
                    let wasKept = await cache.contains(reference.url)
                    let resource = try? await self.raw(reference, cache: cache)
                    return Loaded(reference: reference, resource: resource, fetched: !wasKept && resource != nil)
                }
            }
            for _ in 0..<max(1, limits.concurrent) { start() }
            for await result in group {
                results.append(result)
                start()
            }
            return results
        }
    }

    /// The content as the server sent it, from the cache when it's there.
    private func raw(_ reference: RemoteReference, cache: RemoteContentCache?) async throws -> RemoteResource {
        switch await cache?.lookup(reference.url) {
        case let .resource(kept)?: kept
        case let .refused(status)?: throw PMailError.http(status: status, message: "")
        case nil: try await fetch(reference, cache: cache)
        }
    }

    private func fetch(_ reference: RemoteReference, cache: RemoteContentCache?) async throws -> RemoteResource {
        let route = route.withLock { $0 }
        guard RemoteAddressPolicy.allows(reference.url, throughProxy: route.throughProxy) else { throw RemoteContentError.refusedAddress }
        var request = URLRequest(url: reference.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(PrivateSession.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(PrivateSession.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(reference.kind == .style ? "text/css,*/*;q=0.1" : "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await route.fetcher.fetch(request, limit: limits.maxBytes)
        guard response.isSuccess else {
            // A refusal that won't change is kept, so the address isn't asked for again when the message is opened.
            if (400..<500).contains(response.statusCode), ![408, 429].contains(response.statusCode) {
                await cache?.saveRefusal(status: response.statusCode, for: reference.url)
            }
            throw PMailError.http(status: response.statusCode, message: "")
        }
        let resource = RemoteResource(url: reference.url, data: data, mimeType: Self.mimeType(of: response, data: data, kind: reference.kind),
                                      textEncoding: response.textEncodingName)
        await cache?.save(resource)
        return resource
    }

    /// The type to serve content as: the server's, unless it named none useful, when the content's first bytes say.
    static func mimeType(of response: HTTPURLResponse, data: Data, kind: RemoteReference.Kind) -> String {
        if kind == .style { return "text/css" }
        let given = response.mimeType?.lowercased() ?? ""
        if !given.isEmpty, !["application/octet-stream", "binary/octet-stream", "text/plain"].contains(given) { return given }
        let bytes = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if starts([0x52, 0x49, 0x46, 0x46]), starts([0x57, 0x45, 0x42, 0x50], at: 8) { return "image/webp" }
        if String(decoding: data.prefix(512), as: UTF8.self).contains("<svg") { return "image/svg+xml" }
        return given.isEmpty ? "application/octet-stream" : given
    }

    /// A style sheet's text, in the encoding the server named (UTF-8 otherwise).
    private static func text(of resource: RemoteResource) -> String {
        if let name = resource.textEncoding {
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name as CFString))
            if encoding != UInt(kCFStringEncodingInvalidId), let text = String(data: resource.data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        return String(decoding: resource.data, as: UTF8.self)
    }
}
