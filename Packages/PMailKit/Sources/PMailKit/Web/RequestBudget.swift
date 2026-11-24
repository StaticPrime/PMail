import Foundation
import os

/// How fast one account may go with a service that counts what each request costs in a minute (Google's mail API
/// allows each person 6,000 units a minute). PMail keeps its own count and makes a request wait, when it must, until
/// the last minute's requests leave room for it, so the service doesn't have to refuse. Background work
/// (`BackgroundWork`) only fills part of the minute, so what the person is waiting for always has room.
actor RequestBudget {
    /// What a request costs, from its method and URL.
    typealias Cost = @Sendable (_ method: String, _ url: URL) -> Int

    /// The units PMail lets itself spend in a minute.
    let capacity: Int
    /// The units background work may fill.
    let backgroundCapacity: Int
    private let window: TimeInterval
    private let cost: Cost
    private let now: @Sendable () -> Date
    private let pause: @Sendable (Double) async throws -> Void
    /// From 0 to 1, for spreading out the pauses after refusals.
    private let jitter: @Sendable () -> Double
    /// What was spent in the last minute, oldest first.
    private var spent: [(at: Date, units: Int)] = []
    /// Until when every request waits, after the service refused all the same.
    private var pausedUntil: Date?
    /// Refusals a minute or less apart, for how long the next pause lasts.
    private var refusals = 0
    private var lastRefusal: Date?

    init(capacity: Int, backgroundShare: Double = 0.25, window: TimeInterval = 60, cost: @escaping Cost,
         now: @escaping @Sendable () -> Date = { Date() },
         pause: @escaping @Sendable (Double) async throws -> Void = { try await WebClient.sleep($0) },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.capacity = max(capacity, 1)
        backgroundCapacity = max(Int(Double(self.capacity) * min(max(backgroundShare, 0), 1)), 1)
        self.window = window
        self.cost = cost
        self.now = now
        self.pause = pause
        self.jitter = jitter
    }

    /// Waits until a request fits in the last minute's spending, then counts it.
    func spend(_ method: String, _ url: URL, inBackground: Bool) async throws {
        let units = max(cost(method, url), 0)
        let limit = inBackground ? backgroundCapacity : capacity
        var waited = 0.0
        defer {
            if waited >= 1 {
                WebClient.log.notice("Waited \(waited, format: .fixed(precision: 1)) s for room in the minute (\(units) units\(inBackground ? ", background" : ""))")
            }
        }
        while true {
            let moment = now()
            if let pausedUntil, pausedUntil > moment {
                let wait = pausedUntil.timeIntervalSince(moment)
                waited += wait
                try await pause(wait)
                continue
            }
            spent.removeAll { moment.timeIntervalSince($0.at) >= window }
            let used = spent.reduce(0) { $0 + $1.units }
            // With nothing spent, even a request costing more than the limit goes.
            if used + units <= limit || spent.isEmpty {
                spent.append((moment, units))
                return
            }
            let wait = wait(toFit: units, under: limit, used: used, at: moment)
            waited += wait
            try await pause(wait)
        }
    }

    /// The service refused all the same, having seen spending that PMail's count didn't (the same account in PMail on
    /// another Mac, say): every request waits a few seconds, longer each time it happens again within the minute.
    /// Returns how long.
    @discardableResult
    func refused() -> Double {
        let moment = now()
        if let lastRefusal, moment.timeIntervalSince(lastRefusal) > window { refusals = 0 }
        refusals += 1
        lastRefusal = moment
        let delay = WebClient.backoff(attempt: refusals, base: 5, cap: window, jitter: jitter())
        let until = moment.addingTimeInterval(delay)
        if (pausedUntil ?? .distantPast) < until { pausedUntil = until }
        WebClient.log.notice("Refused for going too fast for the minute; pausing requests for \(delay, format: .fixed(precision: 1)) s")
        return delay
    }

    /// How long until enough of the minute's spending is a minute old for a request to fit.
    private func wait(toFit units: Int, under limit: Int, used: Int, at moment: Date) -> Double {
        var remaining = used
        for entry in spent {
            remaining -= entry.units
            if remaining + units <= limit { return max(window - moment.timeIntervalSince(entry.at), 0.05) }
        }
        return window
    }
}

/// How many requests one account has under way at once, for a service that limits that (Google's mail API refuses
/// an account that has too many going). Requests past the limit wait their turn, the person's before background
/// work's, and background work never takes the last places, so what the person asks for starts at once.
actor RequestGate {
    nonisolated let limit: Int
    /// The most background requests under way at once.
    nonisolated let backgroundLimit: Int
    private var running = 0
    private var runningBackground = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var waitingBackground: [CheckedContinuation<Void, Never>] = []

    init(limit: Int, keptForThePerson: Int = 2) {
        self.limit = max(limit, 1)
        backgroundLimit = max(self.limit - max(keptForThePerson, 0), 1)
    }

    /// Waits for a place, and takes it. Every `enter` is followed by a `leave`.
    func enter(inBackground: Bool) async {
        if inBackground {
            if waiting.isEmpty, waitingBackground.isEmpty, canStartBackground {
                running += 1
                runningBackground += 1
                return
            }
            await withCheckedContinuation { waitingBackground.append($0) }
        } else {
            if waiting.isEmpty, running < limit {
                running += 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }
        // Whoever let this request in counted it.
    }

    /// Gives a place back, to the next one waiting.
    func leave(inBackground: Bool) {
        running -= 1
        if inBackground { runningBackground -= 1 }
        while running < limit, !waiting.isEmpty {
            running += 1
            waiting.removeFirst().resume()
        }
        while waiting.isEmpty, canStartBackground, !waitingBackground.isEmpty {
            running += 1
            runningBackground += 1
            waitingBackground.removeFirst().resume()
        }
    }

    private var canStartBackground: Bool { running < limit && runningBackground < backgroundLimit }

    /// How many requests are under way and how many are waiting (for tests).
    var counts: (running: Int, waiting: Int) { (running, waiting.count + waitingBackground.count) }
}

/// Work PMail does on its own in the background (learning what junk looks like from an account's folders, fetching
/// new mail's pictures ahead of time), as against what the person is waiting for. A service that limits how fast an
/// account may go gives background work only part of the room, so it never holds up what the person asked for.
public enum BackgroundWork {
    /// Whether the work running now is background work.
    @TaskLocal public static var isRunning = false

    /// Runs some work, and every request it makes, as background work. The work runs where its caller does.
    public nonisolated(nonsending) static func run<T>(_ work: nonisolated(nonsending) () async throws -> T) async rethrows -> T {
        try await $isRunning.withValue(true, operation: work)
    }
}
