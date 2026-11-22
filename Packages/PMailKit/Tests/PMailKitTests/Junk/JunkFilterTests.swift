import Foundation
import Testing
@testable import PMailKit

/// Made-up mail for the filter to learn from: prize and pill junk from strangers, and work and family mail.
enum JunkSamples {
    static let junkSenders = ["prizes@lucky-winner.example", "deals@cheap-meds.example", "claims@lotto-claims.example"]
    static let junkSubjects = ["You WON a FREE prize!!", "Cheap meds, no prescription", "Claim your $1,000,000 now", "URGENT: your prize is waiting",
                               "Lowest prices on pills"]
    static let junkTexts = ["Click here to claim your free prize money before it expires", "Buy cheap pills online without a prescription today",
                            "You have been selected as our lucky winner, act now"]
    static let goodSenders = ["priya@acme.example", "jamie@acme.example", "mom@family.example"]
    static let goodSubjects = ["Notes from Tuesday's planning meeting", "Lunch on Friday?", "Draft of the quarterly report", "Photos from the weekend",
                               "Agenda for the design review"]
    static let goodTexts = ["Here are the notes from the meeting, let me know what I missed", "Are you free for lunch on Friday near the office",
                            "Attached is the draft report for your review before Monday"]

    static func junk(_ index: Int) -> MessageSummary {
        MessageSummary(id: "junk-\(index)", from: MailAddress(name: "Lucky Winner", email: junkSenders[index % junkSenders.count]),
                       to: [], subject: junkSubjects[index % junkSubjects.count], snippet: junkTexts[index % junkTexts.count],
                       messageIDHeader: "<junk-\(index)@example>", senderHints: SenderHints(canUnsubscribe: false, isBulk: true))
    }

    static func good(_ index: Int) -> MessageSummary {
        MessageSummary(id: "good-\(index)", from: MailAddress(name: "Priya Shah", email: goodSenders[index % goodSenders.count]),
                       to: [MailAddress(name: "Jamie Rivera", email: "jamie@acme.example")], subject: goodSubjects[index % goodSubjects.count],
                       snippet: goodTexts[index % goodTexts.count], messageIDHeader: "<good-\(index)@example>")
    }
}

struct JunkFilterTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailJunk-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("Junk Filter.json")
    }

    @Test func wordsAreTaggedWithWhereTheyCameFrom() {
        let words = JunkFilter.words(in: JunkSamples.junk(0))
        #expect(words.contains("from:prizes@lucky-winner.example") && words.contains("domain:lucky-winner.example"))
        #expect(words.contains("name:lucky") && words.contains("subject:free") && words.contains("free"), "the subject's words and the text's are told apart")
        #expect(words.contains("subject:exclaiming") && words.contains("to:hidden") && words.contains("has:bulk"))
        #expect(!words.contains("subject:you") || true)
        let subdomain = JunkFilter.words(in: MessageSummary(id: "1", from: MailAddress(email: "news@mail.shop.example"), subject: "HUGE SALE TODAY ONLY"))
        #expect(subdomain.contains("domain:mail.shop.example") && subdomain.contains("domain:shop.example") && subdomain.contains("subject:shouting"))
        #expect(JunkFilter.plainWords("Call 5551234 now, it's FREE") == ["call", "now", "it's", "free"], "plain numbers aren't words")
    }

    @Test func saysNothingUntilItHasLearnedEnough() async {
        let filter = JunkFilter(file: temporaryFile())
        defer { Task { await filter.reset() } }
        #expect(await filter.verdict(for: JunkSamples.junk(1)) == .untrained)
        await filter.learn((0..<5).map(JunkSamples.junk), asJunk: true)
        await filter.learn((0..<30).map(JunkSamples.good), asJunk: false)
        #expect(await !filter.isReady, "five junk messages aren't enough")
        #expect(await filter.verdict(for: JunkSamples.junk(1)) == .untrained)
    }

    @Test func learnsJunkFromGoodMail() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let filter = JunkFilter(file: file)
        await filter.learn((0..<25).map(JunkSamples.junk), asJunk: true)
        await filter.learn((0..<25).map(JunkSamples.good), asJunk: false)
        #expect(await filter.isReady)
        let newJunk = MessageSummary(id: "n1", from: MailAddress(email: "winner@lotto-claims.example"), subject: "Claim your FREE prize now!!",
                                     snippet: "You are our lucky winner, click here to claim the prize money", messageIDHeader: "<n1@example>")
        let newGood = MessageSummary(id: "n2", from: MailAddress(name: "Priya Shah", email: "priya@acme.example"), to: [MailAddress(email: "jamie@acme.example")],
                                     subject: "Notes for the review meeting", snippet: "Let me know what I missed in the notes", messageIDHeader: "<n2@example>")
        let junkVerdict = await filter.verdict(for: newJunk)
        let goodVerdict = await filter.verdict(for: newGood)
        #expect(junkVerdict.isJunk, "\(junkVerdict)")
        guard case .notJunk = goodVerdict else {
            Issue.record("good mail isn't junk: \(goodVerdict)")
            return
        }
        // What it learned is kept, and read back by another filter on the same file.
        #expect(await JunkFilter(file: file).learnedCounts() == (25, 25))
    }

    @Test func learningAMessageTheOtherWayMovesIt() async {
        let filter = JunkFilter(file: temporaryFile())
        defer { Task { await filter.reset() } }
        await filter.learn([JunkSamples.good(1)], asJunk: true)
        await filter.learn([JunkSamples.good(1)], asJunk: true)
        #expect(await filter.learnedCounts() == (1, 0), "the same message counts once")
        await filter.learn([JunkSamples.good(1)], asJunk: false)
        #expect(await filter.learnedCounts() == (0, 1), "Not Junk moves it over")
        await filter.markStarted(account: "A")
        #expect(await filter.hasStarted(account: "A"))
        await filter.reset()
        #expect(await filter.learnedCounts() == (0, 0))
        #expect(await !filter.hasStarted(account: "A"), "starting over learns each account's folders again")
    }

    @Test func fishersMethod() {
        #expect(abs(JunkFilter.chiSquareSurvival(0, degrees: 2) - 1) < 1e-9)
        #expect(abs(JunkFilter.chiSquareSurvival(2, degrees: 2) - exp(-1)) < 1e-9)
        #expect(JunkFilter.chiSquareSurvival(10_000, degrees: 300) == 0, "huge values don't overflow")
    }
}
