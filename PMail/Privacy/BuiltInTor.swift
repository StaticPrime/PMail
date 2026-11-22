import Foundation
import Observation
import PMailKit

/// The Tor client built into PMail, for Settings ▸ Privacy ▸ Hide IP address with Tor chosen: started while that's on,
/// stopped when it's off or PMail quits. Remote content waits for it to connect and then goes only through it; if it
/// can't connect, nothing loads.
@Observable
final class BuiltInTor {
    enum State: Equatable {
        case off
        case connecting(percent: Int, step: String)
        case connected
        case failed(String)
    }

    static let shared = BuiltInTor()

    private(set) var state: State = .off

    /// Requests for remote content, held until Tor connects and then passed through it.
    @ObservationIgnored let fetcher = PendingFetcher(waitingReason: "Tor is still connecting.")

    /// Makes what runs Tor at each start: the Tor Project's program, or (in sample runs) a stand-in.
    @ObservationIgnored var makeRunner: (TorProcess.Settings, @escaping @Sendable (TorEvent) -> Void) -> any TorRunner = { settings, onEvent in
        TorProcess(settings: settings, onEvent: onEvent)
    }

    /// The way to the internet once Tor is connected on a port.
    @ObservationIgnored var connectedFetcher: (Int) -> any RemoteFetcher = { port in
        PrivateFetcher(proxy: RemoteContentProxy(kind: .socks5, host: "127.0.0.1", port: port), password: nil)
            ?? RefusingFetcher(reason: "Tor’s port couldn’t be used.")
    }

    @ObservationIgnored private var runner: (any TorRunner)?
    /// Counts starts and stops, so word from a Tor that was stopped is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var port = 0
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var lastProblem: String?

    /// The tor program inside the app.
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tor") }

    /// Where Tor keeps what it learns about the network, so it connects faster next time.
    static var dataDirectory: URL { AppDelegate.supportFolder.appendingPathComponent("Tor", isDirectory: true) }

    /// Starts Tor, unless it's running or starting already.
    func start() {
        wanted = true
        guard runner == nil, state == .off || isFailed else { return }
        restarts = 0
        launch()
    }

    /// Stops Tor. Requests wait again until it starts, or go elsewhere once Settings sends them elsewhere.
    func stop() {
        wanted = false
        generation += 1
        runner?.stop()
        runner = nil
        fetcher.hold()
        state = .off
    }

    /// Starts again after Tor gave up.
    func retry() {
        stop()
        start()
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    private func launch() {
        generation += 1
        let generation = generation
        lastProblem = nil
        fetcher.hold()
        state = .connecting(percent: 0, step: "Starting")
        guard let port = TorProcess.freePort() else { return giveUp("No port on this Mac was free for Tor.") }
        self.port = port
        let settings = TorProcess.Settings(executable: Self.executable, dataDirectory: Self.dataDirectory, socksPort: port)
        let runner = makeRunner(settings) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event, generation: generation) }
        }
        self.runner = runner
        do {
            try runner.start()
        } catch {
            self.runner = nil
            giveUp("Tor couldn’t start: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    private func handle(_ event: TorEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case let .progress(percent, step):
            guard percent >= 100 else {
                state = .connecting(percent: percent, step: step)
                return
            }
            restarts = 0
            state = .connected
            fetcher.resolve(connectedFetcher(port))
        case let .problem(text):
            lastProblem = text
        case let .exited(status):
            runner = nil
            fetcher.hold()
            guard wanted else {
                state = .off
                return
            }
            // It stopped by itself. Start it again a few times (a Tor left over from before may still be letting go
            // of its data directory), then say why.
            guard restarts < 3 else {
                return giveUp(lastProblem.map { "Tor stopped: \($0)" } ?? "Tor stopped (status \(status)).")
            }
            restarts += 1
            state = .connecting(percent: 0, step: "Starting again")
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 2) { [weak self] in
                guard let self, wanted, runner == nil, generation == self.generation else { return }
                launch()
            }
        }
    }

    private func giveUp(_ reason: String) {
        state = .failed(reason)
        fetcher.fail(reason)
    }
}
