import Foundation

/// PMail's own junk mail filter. It learns what junk looks like from the messages the person reports as spam and the
/// ones they say aren't junk (and, to start with, from what's already in each account's inbox and spam folder), then
/// judges new mail by its words: the sender's address, name and domain, the subject, the opening of the text, and
/// signs such as a mailing list's unsubscribe link.
///
/// It's a naive Bayes filter: each word's chance of meaning junk comes from how often it was in junk and in good mail,
/// and a message's most telling words are combined with Fisher's method into one score from 0 (good) to 1 (junk). It
/// says nothing until it has learned from enough of both kinds. What it learned is kept in a JSON file.
public actor JunkFilter {
    public enum Verdict: Sendable, Equatable {
        /// It hasn't learned from enough mail yet to say.
        case untrained
        case junk(Double)
        case unsure(Double)
        case notJunk(Double)

        public var isJunk: Bool {
            if case .junk = self { true } else { false }
        }
    }

    /// The score from which a message is junk, and the one below which it's surely not.
    public static let junkCutoff = 0.9
    public static let goodCutoff = 0.2
    /// How many messages of each kind it must have learned from before it judges anything.
    public static let minimumLearned = 20

    struct Store: Codable {
        var junkMessages = 0
        var goodMessages = 0
        /// For each word, how many junk and how many good messages it was in.
        var words: [String: [Int]] = [:]
        /// How each message was learned (true for junk), by its Message-ID, so learning it the other way moves it
        /// rather than counting it twice.
        var learned: [String: Bool] = [:]
        /// Accounts whose inbox and spam folder it has learned from.
        var startedAccounts: [String] = []
    }

    public let file: URL
    private var store: Store?

    public init(file: URL) {
        self.file = file
    }

    /// Whether it has learned from enough junk and good mail to judge new mail.
    public var isReady: Bool {
        let store = loaded()
        return store.junkMessages >= Self.minimumLearned && store.goodMessages >= Self.minimumLearned
    }

    /// How many junk and good messages it has learned from.
    public func learnedCounts() -> (junk: Int, good: Int) {
        let store = loaded()
        return (store.junkMessages, store.goodMessages)
    }

    public func verdict(for summary: MessageSummary) -> Verdict {
        guard isReady else { return .untrained }
        let score = Self.score(Self.words(in: summary), in: loaded())
        if score >= Self.junkCutoff { return .junk(score) }
        if score <= Self.goodCutoff { return .notJunk(score) }
        return .unsure(score)
    }

    /// Learns from messages as junk, or as good mail. A message it learned the other way before is moved over.
    public func learn(_ summaries: [MessageSummary], asJunk: Bool) {
        guard !summaries.isEmpty else { return }
        var store = loaded()
        for summary in summaries {
            let key = Self.key(for: summary)
            if let before = store.learned[key] {
                if before == asJunk { continue }
                Self.count(Self.words(in: summary), asJunk: before, by: -1, in: &store)
            }
            Self.count(Self.words(in: summary), asJunk: asJunk, by: 1, in: &store)
            store.learned[key] = asJunk
        }
        // A cap on what's kept: words seen in only one message go first.
        if store.words.count > 200_000 { store.words = store.words.filter { $0.value[0] + $0.value[1] > 1 } }
        if store.learned.count > 50_000 { store.learned = Dictionary(uniqueKeysWithValues: store.learned.prefix(25_000).map { ($0.key, $0.value) }) }
        save(store)
    }

    /// Whether it has learned from an account's inbox and spam folder yet.
    public func hasStarted(account: String) -> Bool {
        loaded().startedAccounts.contains(account)
    }

    public func markStarted(account: String) {
        var store = loaded()
        guard !store.startedAccounts.contains(account) else { return }
        store.startedAccounts.append(account)
        save(store)
    }

    /// Forgets everything it learned, so it starts again (from each account's inbox and spam folder).
    public func reset() {
        save(Store())
    }

    // MARK: Words

    /// What a message is learned and judged by. Words are lowercased and tagged with where they came from, so "free"
    /// in a subject and "free" in the text count separately.
    static func words(in summary: MessageSummary) -> Set<String> {
        var words = Set<String>()
        if let from = summary.from {
            let email = from.email.lowercased()
            words.insert("from:" + email)
            if let at = email.lastIndex(of: "@") {
                let domain = String(email[email.index(after: at)...])
                words.insert("domain:" + domain)
                let parts = domain.split(separator: ".")
                if parts.count > 2 { words.insert("domain:" + parts.suffix(2).joined(separator: ".")) }
                if email[..<at].filter(\.isNumber).count >= 4 { words.insert("from:numbers") }
            }
            let name = from.name ?? ""
            if name.isEmpty { words.insert("name:none") }
            for word in plainWords(name) { words.insert("name:" + word) }
        } else {
            words.insert("from:none")
        }
        let subject = summary.subject
        if subject.isEmpty { words.insert("subject:none") }
        for word in plainWords(subject) { words.insert("subject:" + word) }
        let letters = subject.filter(\.isLetter)
        if letters.count >= 8, letters.filter(\.isUppercase).count * 10 >= letters.count * 7 { words.insert("subject:shouting") }
        if subject.contains("!!") { words.insert("subject:exclaiming") }
        if subject.contains(where: { "$€£¥".contains($0) }) { words.insert("subject:money") }
        for word in plainWords(summary.snippet) { words.insert(word) }
        let recipients = summary.to.count + summary.cc.count
        words.insert(recipients == 0 ? "to:hidden" : recipients == 1 ? "to:one" : recipients <= 5 ? "to:few" : "to:many")
        if summary.hasAttachments { words.insert("has:attachment") }
        if let hints = summary.senderHints {
            if hints.canUnsubscribe { words.insert("has:unsubscribe") }
            if hints.listID != nil { words.insert("has:list") }
            if hints.isBulk { words.insert("has:bulk") }
            if hints.isAutomatic { words.insert("has:automatic") }
        }
        return words
    }

    /// Words of 3 to 24 letters or digits, lowercased, without plain numbers.
    static func plainWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "$" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { (3...24).contains($0.count) && !$0.allSatisfy(\.isNumber) }
    }

    // MARK: Scoring

    /// A message's score from 0 (good) to 1 (junk): each word's chance of meaning junk (pulled towards an even chance
    /// while it's been seen only a few times), the strongest 150 of those that lean either way, combined with Fisher's
    /// method.
    static func score(_ words: Set<String>, in store: Store) -> Double {
        let junkTotal = Double(max(store.junkMessages, 1)), goodTotal = Double(max(store.goodMessages, 1))
        var clues: [Double] = []
        for word in words {
            guard let counts = store.words[word] else { continue }
            let junk = Double(counts[0]), good = Double(counts[1])
            let junkShare = junk / junkTotal, goodShare = good / goodTotal
            guard junkShare + goodShare > 0 else { continue }
            let chance = junkShare / (junkShare + goodShare)
            let seen = junk + good
            let strength = 0.45
            let adjusted = (strength * 0.5 + seen * chance) / (strength + seen)
            if abs(adjusted - 0.5) >= 0.1 { clues.append(adjusted) }
        }
        guard !clues.isEmpty else { return 0.5 }
        let strongest = clues.sorted { abs($0 - 0.5) > abs($1 - 0.5) }.prefix(150)
        var junkLog = 0.0, goodLog = 0.0
        for chance in strongest {
            junkLog += log(max(1 - chance, 1e-12))
            goodLog += log(max(chance, 1e-12))
        }
        let degrees = 2 * strongest.count
        let junkEvidence = 1 - chiSquareSurvival(-2 * junkLog, degrees: degrees)
        let goodEvidence = 1 - chiSquareSurvival(-2 * goodLog, degrees: degrees)
        return (junkEvidence - goodEvidence + 1) / 2
    }

    /// The chance of a chi-squared value at least this big, for an even number of degrees of freedom.
    static func chiSquareSurvival(_ value: Double, degrees: Int) -> Double {
        let half = value / 2
        var term = exp(-half)
        var sum = term
        if degrees / 2 > 1 {
            for index in 1..<(degrees / 2) {
                term *= half / Double(index)
                sum += term
            }
        }
        return min(sum, 1)
    }

    // MARK: Keeping it

    static func key(for summary: MessageSummary) -> String {
        summary.messageIDHeader?.lowercased() ?? "id:" + summary.id
    }

    private static func count(_ words: Set<String>, asJunk: Bool, by delta: Int, in store: inout Store) {
        let side = asJunk ? 0 : 1
        for word in words {
            var counts = store.words[word] ?? [0, 0]
            counts[side] = max(0, counts[side] + delta)
            if counts[0] == 0, counts[1] == 0 { store.words[word] = nil } else { store.words[word] = counts }
        }
        if asJunk { store.junkMessages = max(0, store.junkMessages + delta) } else { store.goodMessages = max(0, store.goodMessages + delta) }
    }

    private func loaded() -> Store {
        if let store { return store }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        store = read
        return read
    }

    private func save(_ new: Store) {
        store = new
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            // Kept in memory; written with the next change.
        }
    }
}
