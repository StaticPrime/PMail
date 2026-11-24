import Foundation
import Testing
@testable import PMailKit

/// A clock that only moves when a budget waits on it (or a test moves it), recording the waits.
final class BudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_795_000_000)
    private var recorded: [Double] = []

    var now: Date { lock.withLock { moment } }
    var waits: [Double] { lock.withLock { recorded } }

    func wait(_ seconds: Double) {
        lock.withLock {
            recorded.append(seconds)
            moment = moment.addingTimeInterval(seconds)
        }
    }

    func advance(_ seconds: Double) {
        lock.withLock { moment = moment.addingTimeInterval(seconds) }
    }
}

extension RequestBudget {
    /// A budget on a test clock, where every request costs the same.
    static func test(_ clock: BudgetClock, capacity: Int = 100, backgroundShare: Double = 0.4, costing units: Int = 40) -> RequestBudget {
        RequestBudget(capacity: capacity, backgroundShare: backgroundShare, cost: { _, _ in units }, now: { clock.now },
                      pause: { clock.wait($0) }, jitter: { 1 })
    }
}

@Suite struct RequestBudgetTests {
    private let url = URL(string: "https://api.example.com/thing")!

    @Test func requestsGoAtOnceUntilTheMinuteIsSpentThenWaitForRoom() async throws {
        let clock = BudgetClock()
        let budget = RequestBudget.test(clock)
        try await budget.spend("GET", url, inBackground: false)
        clock.advance(10)
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits.isEmpty, "80 of the 100 spent")
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits == [50], "until the first is a minute old")
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits == [50, 10], "then until the second is")
    }

    @Test func backgroundWorkOnlyFillsItsShareLeavingRoomForThePerson() async throws {
        let clock = BudgetClock()
        let budget = RequestBudget.test(clock)  // Background work may fill 40 of the 100.
        try await budget.spend("GET", url, inBackground: true)
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits.isEmpty, "the person's request goes at once beside the background one")
        try await budget.spend("GET", url, inBackground: true)
        #expect(clock.waits == [60], "more background work waits until the minute has room for it")
    }

    @Test func aRefusalPausesEveryRequestLongerEachTimeWithinTheMinute() async throws {
        let clock = BudgetClock()
        let budget = RequestBudget.test(clock, costing: 1)
        #expect(await budget.refused() == 5)
        try await budget.spend("GET", url, inBackground: false)
        try await budget.spend("GET", url, inBackground: true)
        #expect(clock.waits == [5], "both wait out the one pause")
        #expect(await budget.refused() == 10)
        #expect(await budget.refused() == 20)
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits == [5, 20], "a later, longer pause covers an earlier one")
        clock.advance(61)
        #expect(await budget.refused() == 5, "a minute without refusals starts over")
    }

    @Test func aRequestCostingMoreThanTheMinuteStillGoesWhenNothingElseHas() async throws {
        let clock = BudgetClock()
        let budget = RequestBudget.test(clock, costing: 500)
        try await budget.spend("GET", url, inBackground: false)
        #expect(clock.waits.isEmpty)
    }

    @Test func requestsMadeInBackgroundWorkAreCountedAsBackground() async throws {
        let transport = StubTransport()
        transport.on("GET", "/thing") { _ in .json(#"{"ok": true}"#) }
        let clock = BudgetClock()
        let client = WebClient(tokens: WebTestTokens(), transport: transport, budget: .test(clock), pause: { _ in })
        let url = self.url
        _ = try await client.get(url)
        #expect(clock.waits.isEmpty)
        _ = try await BackgroundWork.run { try await client.get(url) }
        #expect(clock.waits == [60], "background work waits for room the person's request left")
        #expect(transport.requests.count == 2)
    }
}

/// Requests going at once for an account, with the person's first.
@Suite struct RequestGateTests {
    /// Waits until the gate has this many waiting (the tasks asking have reached it).
    private func waitUntil(_ gate: RequestGate, hasWaiting count: Int) async {
        for _ in 0..<10_000 where await gate.counts.waiting < count { await Task.yield() }
    }

    @Test func requestsPastTheLimitWaitAndThePersonsGoFirst() async throws {
        let gate = RequestGate(limit: 3)
        for _ in 0..<3 { await gate.enter(inBackground: false) }
        let order = Recorded()
        let background = Task { await gate.enter(inBackground: true); order.add("background") }
        await waitUntil(gate, hasWaiting: 1)
        let person = Task { await gate.enter(inBackground: false); order.add("person") }
        await waitUntil(gate, hasWaiting: 2)
        #expect(order.items.isEmpty, "all three places are taken")
        await gate.leave(inBackground: false)
        await person.value
        #expect(order.items == ["person"], "the person's request goes first, though it came later")
        await gate.leave(inBackground: false)
        await background.value
        #expect(order.items == ["person", "background"])
        let counts = await gate.counts
        #expect(counts.running == 3 && counts.waiting == 0)
    }

    @Test func backgroundWorkLeavesTwoPlacesForThePerson() async throws {
        let gate = RequestGate(limit: 4)
        #expect(gate.backgroundLimit == 2)
        await gate.enter(inBackground: true)
        await gate.enter(inBackground: true)
        let third = Task { await gate.enter(inBackground: true) }
        await waitUntil(gate, hasWaiting: 1)
        await gate.enter(inBackground: false)
        await gate.enter(inBackground: false)
        var counts = await gate.counts
        #expect(counts.running == 4 && counts.waiting == 1, "the person's two start at once; more background waits")
        await gate.leave(inBackground: false)
        #expect(await gate.counts.waiting == 1, "a place the person gave back isn't background work's while two are going")
        await gate.leave(inBackground: true)
        await third.value
        counts = await gate.counts
        #expect(counts.running == 3 && counts.waiting == 0)
    }

    @Test func aClientNeverHasMoreGoingThanTheLimit() async throws {
        let transport = SlowTransport()
        let client = WebClient(tokens: WebTestTokens(), transport: transport, gate: RequestGate(limit: 3), pause: { _ in })
        let url = try #require(URL(string: "https://api.example.com/thing"))
        _ = try await WebClient.concurrentMap(Array(1...12), limit: 12) { _ in try await client.get(url) }
        #expect(await transport.peak <= 3)
        #expect(await transport.count == 12)
    }
}

/// Answers every request after a moment, counting how many it has going at once.
private actor SlowTransport: HTTPTransport {
    private var running = 0
    private(set) var peak = 0
    private(set) var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        running += 1
        count += 1
        peak = max(peak, running)
        try await Task.sleep(nanoseconds: 2_000_000)
        running -= 1
        let answer = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(#"{"ok": true}"#.utf8), answer)
    }
}

/// What happened, in order, from any task.
final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var items: [String] { lock.withLock { recorded } }
    func add(_ item: String) { lock.withLock { recorded.append(item) } }
}
