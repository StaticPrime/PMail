import Foundation
import Testing
@testable import PMailKit

/// What a runner said, kept for a test to look at.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TorEvent] = []

    func add(_ event: TorEvent) { lock.withLock { events.append(event) } }
    var all: [TorEvent] { lock.withLock { events } }

    /// Waits (up to five seconds) until `condition` holds for what's been said.
    func wait(until condition: ([TorEvent]) -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(all)
    }
}

/// A stand-in for tor: a shell script that prints what's given, the way tor prints, then does what's asked.
private func standIn(printing lines: [String], then ending: String, in folder: URL) throws -> URL {
    let script = folder.appendingPathComponent("stand-in.sh")
    let body = lines.map { "echo '\($0)'" }.joined(separator: "\n")
    try "#!/bin/sh\necho \"$@\" > \"$(dirname \"$0\")/arguments.txt\"\n\(body)\n\(ending)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

struct TorProcessTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailTor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theCommandLineHasEverythingAndReadsNoFiles() {
        let settings = TorProcess.Settings(executable: URL(fileURLWithPath: "/Applications/PMail.app/Contents/Helpers/tor"),
                                           dataDirectory: URL(fileURLWithPath: "/tmp/PMail Tor"), socksPort: 49152, owner: 4242)
        let arguments = settings.arguments
        func value(_ option: String) -> String? { arguments.firstIndex(of: option).map { arguments[$0 + 1] } }
        #expect(value("-f") == "/dev/null" && value("--defaults-torrc") == "/dev/null", "no torrc from anywhere on the Mac")
        #expect(value("--DataDirectory") == "/tmp/PMail Tor")
        #expect(value("--GeoIPFile") == "/tmp/PMail Tor/geoip" && value("--GeoIPv6File") == "/tmp/PMail Tor/geoip6", "nothing outside its folder")
        #expect(value("--SocksPort") == "127.0.0.1:49152 IsolateDestAddr", "only on the loopback address, a circuit per server")
        #expect(value("--ClientOnly") == "1" && value("--Log") == "notice stdout")
        #expect(value("--__OwningControllerProcess") == "4242", "it quits when PMail does")
    }

    @Test func linesTorPrints() {
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:01.000 [notice] Bootstrapped 45% (loading_descriptors): Loading relay descriptors")
                == .progress(45, "Loading relay descriptors"))
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:02.000 [notice] Bootstrapped 100% (done): Done") == .progress(100, "Done"))
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:02.000 [notice] Bootstrapped 80%: Connecting to the Tor network") == .progress(80, "Connecting to the Tor network"),
                "as older versions print it")
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:03.000 [warn] Could not bind to 127.0.0.1:9050: Address already in use.")
                == .problem("Could not bind to 127.0.0.1:9050: Address already in use."))
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:03.000 [err] Reading config failed--see warnings above.") == .problem("Reading config failed--see warnings above."))
        #expect(TorProcess.event(fromLine: "Nov 22 00:00:00.000 [notice] Tor 0.4.9.16 running on Darwin.") == nil)
    }

    @Test func followsTorConnectingAndStopsIt() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = try standIn(printing: ["Nov 22 00:00:00.000 [notice] Tor 0.4.9.16 running on Darwin.",
                                            "Nov 22 00:00:00.100 [notice] Bootstrapped 0% (starting): Starting",
                                            "Nov 22 00:00:00.200 [notice] Bootstrapped 45% (loading_descriptors): Loading relay descriptors",
                                            "Nov 22 00:00:00.300 [notice] Bootstrapped 100% (done): Done"],
                                 then: "exec sleep 30", in: folder)
        let log = EventLog()
        let data = folder.appendingPathComponent("Data", isDirectory: true)
        let tor = TorProcess(settings: TorProcess.Settings(executable: script, dataDirectory: data, socksPort: 49152), onEvent: log.add)
        try tor.start()
        #expect(await log.wait { $0.contains(.progress(100, "Done")) })
        #expect(log.all == [.progress(0, "Starting"), .progress(45, "Loading relay descriptors"), .progress(100, "Done")])
        let permissions = try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700, "a data directory only PMail can read")
        let arguments = try String(contentsOf: folder.appendingPathComponent("arguments.txt"), encoding: .utf8)
        #expect(arguments.contains("--SocksPort 127.0.0.1:49152 IsolateDestAddr"))

        #expect(tor.isRunning)
        tor.stop()
        #expect(await log.wait { $0.contains { if case .exited = $0 { true } else { false } } })
        #expect(!tor.isRunning)
    }

    @Test func aTorThatGivesUpSaysWhy() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = try standIn(printing: ["Nov 22 00:00:00.000 [warn] Could not bind to 127.0.0.1:9050: Address already in use. Is Tor already running?"],
                                 then: "printf 'Nov 22 00:00:00.100 [err] Reading config failed--see warnings above.'\nexit 1", in: folder)
        let log = EventLog()
        let tor = TorProcess(settings: TorProcess.Settings(executable: script, dataDirectory: folder.appendingPathComponent("Data"), socksPort: 9050),
                             onEvent: log.add)
        try tor.start()
        #expect(await log.wait { $0.last == .exited(1) })
        #expect(log.all == [.problem("Could not bind to 127.0.0.1:9050: Address already in use. Is Tor already running?"),
                            .problem("Reading config failed--see warnings above."), .exited(1)],
                "its last words, even without a line break, before it's said to have stopped")
    }

    @Test func freePortsAreOnesNothingUses() throws {
        let port = try #require(TorProcess.freePort())
        #expect((1024...65_535).contains(port))
    }

    @Test func pendingRequestsWaitForTorThenGoThroughIt() async throws {
        let pending = PendingFetcher(waitingReason: "Tor is still connecting.", timeout: 5)
        let request = URLRequest(url: URL(string: "https://pics.example/a.png")!)
        let waiting = Task { try await pending.fetch(request, limit: 100) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!pending.isReady)
        pending.resolve(AnsweringFetcher())
        let (data, response) = try await waiting.value
        #expect(String(decoding: data, as: UTF8.self) == "via Tor" && response.statusCode == 200)

        pending.fail("Tor couldn’t connect.")
        await #expect(throws: RemoteContentError.notSetUp("Tor couldn’t connect.")) { try await pending.fetch(request, limit: 100) }

        let slow = PendingFetcher(waitingReason: "Tor is still connecting.", timeout: 0.3)
        await #expect(throws: RemoteContentError.notSetUp("Tor is still connecting.")) { try await slow.fetch(request, limit: 100) }
    }
}

private struct AnsweringFetcher: RemoteFetcher {
    func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        (Data("via Tor".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
