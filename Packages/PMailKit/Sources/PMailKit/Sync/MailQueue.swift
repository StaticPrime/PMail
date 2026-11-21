import Foundation

/// A message waiting on the Mac to be sent: scheduled for a time, or in the Outbox until the server can be reached.
public struct QueuedMessage: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var message: OutgoingMessage
    /// When to send it; nil sends it as soon as it can (the Outbox).
    public var sendAt: Date?
    public var queuedAt: Date
    /// How many times sending it has failed.
    public var attempts: Int
    /// Why the last try failed.
    public var lastError: String?
    /// When sending it last failed; the wait before trying again counts from here.
    public var lastAttempt: Date?
    /// A draft of it saved on the server, deleted once it's sent.
    public var draft: MessageSummary?

    public init(id: UUID = UUID(), message: OutgoingMessage, sendAt: Date? = nil, queuedAt: Date = Date(), attempts: Int = 0,
                lastError: String? = nil, lastAttempt: Date? = nil, draft: MessageSummary? = nil) {
        self.id = id
        self.message = message
        self.sendAt = sendAt
        self.queuedAt = queuedAt
        self.attempts = attempts
        self.lastError = lastError
        self.lastAttempt = lastAttempt
        self.draft = draft
    }

    /// The folder PMail lists it in.
    public static let scheduledFolderID = "pmail:scheduled"
    public static let outboxFolderID = "pmail:outbox"

    /// Whether it's scheduled for later rather than waiting in the Outbox.
    public var isScheduled: Bool { sendAt != nil }

    /// The ID it has in lists: "queue:" and its UUID.
    public var summaryID: String { "queue:\(id.uuidString)" }

    /// A row for the Scheduled or Outbox list, dated when it will go (or when it was written).
    public var summary: MessageSummary {
        MessageSummary(id: summaryID, threadID: summaryID, folderID: isScheduled ? Self.scheduledFolderID : Self.outboxFolderID,
                       from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                       snippet: HTMLText.snippet(from: message.textBody), date: sendAt ?? queuedAt,
                       hasAttachments: !message.attachments.isEmpty, messageIDHeader: message.messageID,
                       inReplyTo: message.inReplyTo, references: message.references)
    }

    /// The queued message's ID, from a list row's ID.
    public static func id(fromSummaryID summaryID: String) -> UUID? {
        guard summaryID.hasPrefix("queue:") else { return nil }
        return UUID(uuidString: String(summaryID.dropFirst("queue:".count)))
    }

    /// How long to wait before trying again after `attempts` failures: half a minute, doubling, at most an hour.
    public static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(3600, 30 * pow(2, Double(max(0, attempts - 1))))
    }
}

/// An account's scheduled messages and Outbox, one file per message, so nothing is lost if PMail quits.
public actor MailQueue {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Everything waiting, soonest first (the Outbox before anything scheduled).
    public func all() -> [QueuedMessage] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(QueuedMessage.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.sendAt ?? .distantPast, $0.queuedAt) < ($1.sendAt ?? .distantPast, $1.queuedAt) }
    }

    public func item(_ id: UUID) -> QueuedMessage? {
        try? JSONDecoder().decode(QueuedMessage.self, from: Data(contentsOf: url(id)))
    }

    /// Adds a message, or replaces one with the same ID.
    public func save(_ item: QueuedMessage) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(item).write(to: url(item.id), options: .atomic)
        } catch {
            throw PMailError.server("The message couldn’t be kept on this Mac: \(error.localizedDescription)")
        }
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Messages whose time has come, and Outbox messages whose wait after a failure is over.
    public func due(at date: Date) -> [QueuedMessage] {
        all().filter { item in
            if let sendAt = item.sendAt, sendAt > date { return false }
            guard item.attempts > 0 else { return true }
            let lastTry = item.lastAttempt ?? item.sendAt.map { max($0, item.queuedAt) } ?? item.queuedAt
            return date.timeIntervalSince(lastTry) >= QueuedMessage.retryDelay(afterAttempts: item.attempts)
        }
    }

    public var scheduled: [QueuedMessage] { all().filter(\.isScheduled) }
    public var outbox: [QueuedMessage] { all().filter { !$0.isScheduled } }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }
}
