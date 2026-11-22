import Foundation
import Testing
@testable import PMailKit

/// A pretend internet for the loader: answers from a table of addresses, and records what was asked for.
private final class StubFetcher: RemoteFetcher, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = Data()
        var contentType: String?
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private(set) var requests: [URLRequest] = []

    subscript(url: String) -> Answer? {
        get { lock.withLock { answers[url] } }
        set { lock.withLock { answers[url] = newValue } }
    }

    var asked: [String] { lock.withLock { requests.compactMap(\.url?.absoluteString) } }

    func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { () -> Answer? in
            requests.append(request)
            return answers[request.url!.absoluteString]
        }
        guard let answer else { throw PMailError.connectionFailed("no such server") }
        guard answer.body.count <= limit else { throw RemoteContentError.tooLarge }
        let headers = answer.contentType.map { ["Content-Type": $0] } ?? [:]
        return (answer.body, HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

struct RemoteContentLoaderTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func temporaryCache() -> RemoteContentCache {
        RemoteContentCache(folder: FileManager.default.temporaryDirectory.appendingPathComponent("PMailRemote-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func loadsOnceThenFromTheCopy() async throws {
        let internet = StubFetcher()
        internet["https://pics.example/a.png"] = .init(body: png)
        let cache = temporaryCache()
        defer { Task { await cache.removeAll() } }
        let loader = RemoteContentLoader(fetcher: internet)
        let reference = RemoteReference(URL(string: "https://pics.example/a.png")!)

        let first = try await loader.load(reference, cache: cache)
        #expect(first.data == png && first.mimeType == "image/png", "a type the server didn't give comes from the content")
        let second = try await loader.load(reference, cache: cache)
        #expect(second == first)
        #expect(internet.asked == ["https://pics.example/a.png"], "opening it again asks the internet for nothing")

        let request = try #require(internet.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == PrivateSession.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == PrivateSession.acceptLanguage)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test func refusalsAreKeptButPassingTroubleIsNot() async throws {
        let internet = StubFetcher()
        internet["https://pics.example/gone.png"] = .init(status: 404)
        internet["https://pics.example/busy.png"] = .init(status: 503)
        let cache = temporaryCache()
        defer { Task { await cache.removeAll() } }
        let loader = RemoteContentLoader(fetcher: internet)
        for _ in 0..<2 {
            await #expect(throws: PMailError.http(status: 404, message: "")) {
                try await loader.load(RemoteReference(URL(string: "https://pics.example/gone.png")!), cache: cache)
            }
            await #expect(throws: PMailError.http(status: 503, message: "")) {
                try await loader.load(RemoteReference(URL(string: "https://pics.example/busy.png")!), cache: cache)
            }
        }
        #expect(internet.asked == ["https://pics.example/gone.png", "https://pics.example/busy.png", "https://pics.example/busy.png"],
                "a 404 isn't asked for again; a busy server is")
    }

    @Test func styleSheetsArePointedAtTheLoaderToo() async throws {
        let internet = StubFetcher()
        internet["https://styles.example/css/main.css"] = .init(body: Data(#"@import "more.css"; .a { background: url(../img/a.png) }"#.utf8),
                                                              contentType: "text/plain")
        internet["https://styles.example/css/more.css"] = .init(body: Data(#"@font-face { src: url("https://fonts.example/inter.woff2") }"#.utf8))
        internet["https://styles.example/img/a.png"] = .init(body: png)
        internet["https://fonts.example/inter.woff2"] = .init(body: Data([0x77, 0x4F, 0x46, 0x32]), contentType: "font/woff2")
        let cache = temporaryCache()
        defer { Task { await cache.removeAll() } }
        let loader = RemoteContentLoader(fetcher: internet)

        let sheet = try await loader.load(RemoteReference(URL(string: "https://styles.example/css/main.css")!, kind: .style), cache: cache)
        let css = String(decoding: sheet.data, as: UTF8.self)
        #expect(sheet.mimeType == "text/css", "served as a style sheet whatever the server said")
        #expect(css.contains(RemoteContent.address(for: RemoteReference(URL(string: "https://styles.example/css/more.css")!, kind: .style))))
        #expect(css.contains(RemoteContent.address(for: RemoteReference(URL(string: "https://styles.example/img/a.png")!))))
        #expect(!css.contains("https://"))

        // Ahead of time: the sheet (already kept), what it imports, and what that asks for.
        let html = #"<link rel="stylesheet" href="https://styles.example/css/main.css"><img src="https://pics.example/missing.png">"#
        let loaded = await loader.prefetch(html: html, into: cache)
        #expect(loaded == 3, "the import, its font and the sheet's picture; the sheet was kept and the missing picture failed")
        for url in ["https://styles.example/css/more.css", "https://styles.example/img/a.png", "https://fonts.example/inter.woff2"] {
            #expect(await cache.contains(URL(string: url)!), "\(url)")
        }
        #expect(internet.asked.filter { $0 == "https://styles.example/css/main.css" }.count == 1)
        #expect(await loader.prefetch(html: html, into: cache) == 0, "nothing new the second time")
    }

    @Test func neverTheLocalNetworkAndNeverAroundTheProxy() async throws {
        let internet = StubFetcher()
        internet["http://192.168.1.1/reboot"] = .init(body: png)
        internet["http://printer/status.png"] = .init(body: png)
        let loader = RemoteContentLoader(fetcher: internet)
        await #expect(throws: RemoteContentError.refusedAddress) {
            try await loader.load(RemoteReference(URL(string: "http://192.168.1.1/reboot")!), cache: nil)
        }
        loader.use(internet, throughProxy: true)
        #expect(loader.isThroughProxy)
        await #expect(throws: RemoteContentError.refusedAddress) {
            try await loader.load(RemoteReference(URL(string: "http://printer/status.png")!), cache: nil)
        }
        #expect(internet.asked.isEmpty)

        loader.use(RefusingFetcher(reason: "The proxy isn’t set up."), throughProxy: true)
        await #expect(throws: RemoteContentError.notSetUp("The proxy isn’t set up.")) {
            try await loader.data(from: URL(string: "https://pics.example/a.png")!)
        }
    }

    @Test func tooLargeIsNotLoaded() async throws {
        let internet = StubFetcher()
        internet["https://pics.example/huge.png"] = .init(body: Data(count: 2048))
        var limits = RemoteContentLoader.Limits()
        limits.maxBytes = 1024
        let loader = RemoteContentLoader(fetcher: internet, limits: limits)
        await #expect(throws: RemoteContentError.tooLarge) {
            try await loader.load(RemoteReference(URL(string: "https://pics.example/huge.png")!), cache: nil)
        }
    }

    @Test func theCacheKeepsAndPrunes() async throws {
        let cache = temporaryCache()
        defer { Task { await cache.removeAll() } }
        let old = URL(string: "https://pics.example/old.png")!, recent = URL(string: "https://pics.example/recent.png")!
        let newest = URL(string: "https://pics.example/newest.png")!, gone = URL(string: "https://pics.example/gone.png")!
        let now = Date()
        await cache.save(RemoteResource(url: old, data: Data(count: 10), mimeType: "image/png"), at: now.addingTimeInterval(-200 * 86_400))
        await cache.save(RemoteResource(url: recent, data: Data(count: 600), mimeType: "image/gif"), at: now.addingTimeInterval(-60))
        await cache.save(RemoteResource(url: newest, data: Data(count: 600), mimeType: "image/jpeg", textEncoding: nil), at: now)
        await cache.saveRefusal(status: 410, for: gone, at: now)
        #expect(await cache.lookup(recent) == .resource(RemoteResource(url: recent, data: Data(count: 600), mimeType: "image/gif")))
        #expect(await cache.lookup(gone) == .refused(status: 410))
        #expect(await cache.lookup(URL(string: "https://pics.example/never.png")!) == nil)

        await cache.prune(savedBefore: now.addingTimeInterval(-90 * 86_400), maxBytes: 1000)
        #expect(await !cache.contains(old), "too old")
        #expect(await !cache.contains(recent), "the oldest of the rest, to fit")
        #expect(await cache.contains(newest))
        #expect(await cache.contains(gone))
    }
}
