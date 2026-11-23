import Foundation

/// IDs for events and contacts made on the Mac that haven't reached their server yet.
public enum LocalID {
    public static let prefix = "pmail-local-"

    public static func make() -> String { prefix + UUID().uuidString.lowercased() }

    public static func isLocal(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

extension PMailError {
    /// Whether an error means the server couldn't be reached (so a change can wait and be tried again).
    public static func isConnectionProblem(_ error: any Error) -> Bool {
        switch error as? PMailError {
        case .connectionFailed?, .timedOut?: true
        default: false
        }
    }
}

/// A change to a calendar made while its server couldn't be reached, waiting to be sent.
public enum CalendarChange: Codable, Sendable, Hashable {
    case create(CalendarEvent, addingConference: Bool)
    case update(CalendarEvent, scope: RecurrenceScope, addingConference: Bool)
    case delete(CalendarEvent, scope: RecurrenceScope)
    /// An answer as kept before answers had a scope: for the provider's own default (one time on Google and Microsoft,
    /// the whole series elsewhere). Still read; new answers are `answer`.
    case respond(CalendarEvent, response: AttendeeResponse)
    /// An answer to one time of a repeating meeting, or the whole of it.
    case answer(CalendarEvent, response: AttendeeResponse, scope: RecurrenceScope)

    public var event: CalendarEvent {
        switch self {
        case let .create(event, _), let .update(event, _, _), let .delete(event, _), let .respond(event, _), let .answer(event, _, _): event
        }
    }

    /// The answer a change gives, if it's one.
    var answer: AttendeeResponse? {
        switch self {
        case let .respond(_, response), let .answer(_, response, _): response
        default: nil
        }
    }

    /// The waiting changes with another added: changes to something made here go into making it, a later change
    /// replaces an earlier one to the same event, and deleting something made here means nothing about it is sent.
    public static func adding(_ change: CalendarChange, to queue: [CalendarChange]) -> [CalendarChange] {
        let id = change.event.id
        var result = queue
        let creating = result.firstIndex { if case let .create(made, _) = $0 { made.id == id } else { false } }
        switch change {
        case .create:
            result.append(change)
        case let .update(event, scope, conference):
            if let creating, case let .create(_, adding) = result[creating] {
                result[creating] = .create(event, addingConference: adding || conference)
            } else if let index = result.firstIndex(where: { if case let .update(old, oldScope, _) = $0 { old.id == id && oldScope == scope } else { false } }),
                      case let .update(_, _, adding) = result[index] {
                result[index] = .update(event, scope: scope, addingConference: adding || conference)
            } else {
                result.append(change)
            }
        case .delete:
            if creating != nil { return result.filter { $0.event.id != id } }
            result.removeAll { $0.event.id == id }
            result.append(change)
        case .respond, .answer:
            if let creating, case let .create(made, adding) = result[creating], let response = change.answer {
                var answered = made
                answered.myResponse = response
                result[creating] = .create(answered, addingConference: adding)
            } else {
                result.removeAll { $0.answer != nil && $0.event.id == id }
                result.append(change)
            }
        }
        return result
    }

    /// Events as loaded, with the waiting changes made to them, so the window shows what the person did.
    public static func applying(_ queue: [CalendarChange], to events: [CalendarEvent]) -> [CalendarEvent] {
        var result = events
        for change in queue {
            switch change {
            case let .create(event, _):
                if !result.contains(where: { $0.id == event.id }) { result.append(event) }
            case let .update(event, _, _):
                if let index = result.firstIndex(where: { $0.id == event.id }) { result[index] = event }
            case let .delete(event, scope):
                result.removeAll { $0.id == event.id || (scope == .allEvents && event.seriesID != nil && $0.seriesID == event.seriesID) }
            case let .respond(event, response):
                if let index = result.firstIndex(where: { $0.id == event.id }) { result[index].myResponse = response }
            case let .answer(event, response, scope):
                for index in result.indices where result[index].id == event.id
                    || (scope == .allEvents && event.seriesID != nil && result[index].seriesID == event.seriesID) {
                    result[index].myResponse = response
                }
            }
        }
        return result
    }
}

/// A change to contacts made while their server couldn't be reached, waiting to be sent.
public enum ContactChange: Codable, Sendable, Hashable {
    case create(Contact)
    case update(Contact)
    case delete(Contact)

    public var contact: Contact {
        switch self {
        case let .create(contact), let .update(contact), let .delete(contact): contact
        }
    }

    /// The waiting changes with another added, merged as calendar changes are.
    public static func adding(_ change: ContactChange, to queue: [ContactChange]) -> [ContactChange] {
        let id = change.contact.id
        var result = queue
        let creating = result.firstIndex { if case let .create(made) = $0 { made.id == id } else { false } }
        switch change {
        case .create:
            result.append(change)
        case let .update(contact):
            if let creating {
                result[creating] = .create(contact)
            } else if let index = result.firstIndex(where: { if case let .update(old) = $0 { old.id == id } else { false } }) {
                result[index] = change
            } else {
                result.append(change)
            }
        case .delete:
            if creating != nil { return result.filter { $0.contact.id != id } }
            result.removeAll { $0.contact.id == id }
            result.append(change)
        }
        return result
    }

    /// Contacts as loaded, with the waiting changes made to them.
    public static func applying(_ queue: [ContactChange], to contacts: [Contact]) -> [Contact] {
        var result = contacts
        for change in queue {
            switch change {
            case let .create(contact):
                if !result.contains(where: { $0.id == contact.id }) { result.append(contact) }
            case let .update(contact):
                if let index = result.firstIndex(where: { $0.id == contact.id }) { result[index] = contact }
            case let .delete(contact):
                result.removeAll { $0.id == contact.id }
            }
        }
        return result
    }
}

/// A draft kept on the Mac while its server couldn't be reached: the message to save as a draft (replacing the
/// server's copy, if it has one), or, with no message, a draft on the server to delete (one thrown away offline).
public struct WaitingDraft: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var message: OutgoingMessage?
    /// The draft on the server it replaces, or deletes.
    public var replaces: MessageSummary?
    public var savedAt: Date

    public init(id: UUID = UUID(), message: OutgoingMessage?, replaces: MessageSummary?, savedAt: Date = Date()) {
        self.id = id
        self.message = message
        self.replaces = replaces
        self.savedAt = savedAt
    }

    public static let summaryPrefix = "waiting-draft:"

    /// The ID its row has in Drafts.
    public var summaryID: String { Self.summaryPrefix + id.uuidString }

    /// Its row at the top of Drafts; none for a draft to delete.
    public var summary: MessageSummary? {
        guard let message else { return nil }
        return MessageSummary(id: summaryID, threadID: summaryID, from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                              snippet: HTMLText.snippet(from: message.textBody), date: savedAt, isDraft: true,
                              hasAttachments: !message.attachments.isEmpty, messageIDHeader: message.messageID,
                              inReplyTo: message.inReplyTo, references: message.references)
    }

    /// The waiting drafts with another kept: a later save of the same draft (from the same window) replaces the earlier.
    public static func adding(_ draft: WaitingDraft, to queue: [WaitingDraft]) -> [WaitingDraft] {
        queue.filter { $0.id != draft.id } + [draft]
    }
}

/// A waiting change the server turned down once it could be reached, which was dropped.
public struct PendingRefusal: Sendable, Hashable {
    /// The event's title or the contact's name.
    public let title: String
    public let reason: String
}

/// What sending the waiting changes did.
public struct PendingResult<Item: Sendable>: Sendable {
    /// Events or contacts as their server saved them, by the ID they had here (a new one's local ID).
    public var saved: [String: Item] = [:]
    /// The IDs of what was deleted on the server.
    public var deleted: Set<String> = []
    public var refused: [PendingRefusal] = []
    /// How many changes went.
    public var sent = 0
    /// Whether it stopped because the server couldn't be reached; the rest still wait.
    public var stoppedOffline = false
}

/// Changes waiting to be sent, oldest first, kept in a JSON file (in the account's folder) so they survive quitting.
public actor PendingChanges<Change: Codable & Sendable> {
    public nonisolated let file: URL
    private var changes: [Change]?
    /// Whether the first change is on its way, so nothing merges into it.
    private var sendingFirst = false
    private var isSending = false

    public init(file: URL) {
        self.file = file
    }

    public func all() -> [Change] { loaded() }

    /// Adds a change, merged with what's waiting (but never with a change already on its way).
    public func add(_ change: Change, merging: @Sendable (Change, [Change]) -> [Change]) {
        var current = loaded()
        if sendingFirst, !current.isEmpty {
            let first = current.removeFirst()
            current = [first] + merging(change, current)
        } else {
            current = merging(change, current)
        }
        save(current)
    }

    /// Takes waiting changes out (a waiting draft sent, or thrown away, from its window), never the one on its way.
    public func remove(where shouldGo: @Sendable (Change) -> Bool) {
        var current = loaded()
        if sendingFirst, !current.isEmpty {
            let first = current.removeFirst()
            current = [first] + current.filter { !shouldGo($0) }
        } else {
            current.removeAll(where: shouldGo)
        }
        save(current)
    }

    /// Starts sending, unless it's already under way.
    private func beginSending() -> Bool {
        guard !isSending else { return false }
        isSending = true
        return true
    }

    private func finishSending() {
        isSending = false
        sendingFirst = false
    }

    private func dropFirst() {
        var current = loaded()
        if !current.isEmpty { current.removeFirst() }
        sendingFirst = false
        save(current)
    }

    private func loaded() -> [Change] {
        if let changes { return changes }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Change].self, from: $0) } ?? []
        changes = read
        return read
    }

    private func save(_ new: [Change]) {
        changes = new
        do {
            if new.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(new).write(to: file, options: .atomic)
            }
        } catch {
            // Kept in memory; written with the next change.
        }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension PendingChanges where Change == CalendarChange {
    /// Sends what's waiting, oldest first, until it has all gone or the server can't be reached. A change the server
    /// turns down for another reason is dropped and said why; deleting something already gone counts as done.
    public func send(using service: any CalendarService) async -> PendingResult<CalendarEvent> {
        var result = PendingResult<CalendarEvent>()
        guard beginSending() else { return result }
        defer { finishSending() }
        while let change = loaded().first {
            sendingFirst = true
            do {
                switch change {
                case let .create(event, adding):
                    let saved = try await service.create(event, addingConference: adding)
                    result.saved[event.id] = saved
                    renamed(event.id, to: saved.id)
                case let .update(event, scope, adding):
                    result.saved[event.id] = try await service.update(event, scope: scope, addingConference: adding)
                case let .delete(event, scope):
                    do {
                        try await service.delete(event, scope: scope)
                    } catch PMailError.notFound {
                        // Already gone.
                    }
                    result.deleted.insert(event.id)
                case let .respond(event, response):
                    try await service.respond(to: event, with: response)
                case let .answer(event, response, scope):
                    try await service.respond(to: event, with: response, comment: nil, scope: scope)
                }
                result.sent += 1
                dropFirst()
            } catch let error where PMailError.isConnectionProblem(error) {
                result.stoppedOffline = true
                break
            } catch {
                result.refused.append(PendingRefusal(title: change.event.title, reason: Self.reason(error)))
                dropFirst()
            }
        }
        return result
    }

    /// Later changes to an event made here go to it by its new ID.
    private func renamed(_ localID: String, to id: String) {
        let current = loaded()
        guard current.count > 1 else { return }
        let rest = current.dropFirst().map { change -> CalendarChange in
            guard change.event.id == localID else { return change }
            var event = change.event
            event.id = id
            switch change {
            case let .create(_, adding): return .create(event, addingConference: adding)
            case let .update(_, scope, adding): return .update(event, scope: scope, addingConference: adding)
            case let .delete(_, scope): return .delete(event, scope: scope)
            case let .respond(_, response): return .respond(event, response: response)
            case let .answer(_, response, scope): return .answer(event, response: response, scope: scope)
            }
        }
        save([current[0]] + rest)
    }
}

extension PendingChanges where Change == ContactChange {
    /// Sends what's waiting, as calendar changes are sent.
    public func send(using service: any ContactsService) async -> PendingResult<Contact> {
        var result = PendingResult<Contact>()
        guard beginSending() else { return result }
        defer { finishSending() }
        while let change = loaded().first {
            sendingFirst = true
            do {
                switch change {
                case let .create(contact):
                    let saved = try await service.create(contact)
                    result.saved[contact.id] = saved
                    renamed(contact.id, to: saved.id)
                case let .update(contact):
                    result.saved[contact.id] = try await service.update(contact)
                case let .delete(contact):
                    do {
                        try await service.delete(contact)
                    } catch PMailError.notFound {
                        // Already gone.
                    }
                    result.deleted.insert(contact.id)
                }
                result.sent += 1
                dropFirst()
            } catch let error where PMailError.isConnectionProblem(error) {
                result.stoppedOffline = true
                break
            } catch {
                result.refused.append(PendingRefusal(title: change.contact.displayName, reason: Self.reason(error)))
                dropFirst()
            }
        }
        return result
    }

    private func renamed(_ localID: String, to id: String) {
        let current = loaded()
        guard current.count > 1 else { return }
        let rest = current.dropFirst().map { change -> ContactChange in
            guard change.contact.id == localID else { return change }
            var contact = change.contact
            contact.id = id
            switch change {
            case .create: return .create(contact)
            case .update: return .update(contact)
            case .delete: return .delete(contact)
            }
        }
        save([current[0]] + rest)
    }
}

extension PendingChanges where Change == WaitingDraft {
    /// Saves the waiting drafts to the server, each replacing its earlier copy there (or saved anew when that copy is
    /// gone), and deletes the drafts thrown away offline, oldest first, as calendar changes are sent.
    public func send(using service: any MailService) async -> PendingResult<MessageSummary> {
        var result = PendingResult<MessageSummary>()
        guard beginSending() else { return result }
        defer { finishSending() }
        while let draft = loaded().first {
            sendingFirst = true
            do {
                if let message = draft.message {
                    let saved: MessageSummary?
                    do {
                        saved = try await service.saveDraft(message, replacing: draft.replaces)
                    } catch PMailError.notFound where draft.replaces != nil {
                        saved = try await service.saveDraft(message, replacing: nil)
                    }
                    if let saved { result.saved[draft.summaryID] = saved }
                } else if let replaces = draft.replaces {
                    do {
                        try await service.deleteDraft(replaces)
                    } catch PMailError.notFound {
                        // Already gone.
                    }
                    result.deleted.insert(draft.summaryID)
                }
                result.sent += 1
                dropFirst()
            } catch let error where PMailError.isConnectionProblem(error) {
                result.stoppedOffline = true
                break
            } catch {
                result.refused.append(PendingRefusal(title: draft.message?.subject ?? "", reason: Self.reason(error)))
                dropFirst()
            }
        }
        return result
    }
}
