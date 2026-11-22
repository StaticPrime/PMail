import Foundation
import os

/// An account's calendars with its task lists beside them, each list a calendar of tasks. Changes to a task go to the
/// task service, everything else to the calendars. An event's kind (out of office, focus time) that its calendar
/// can't hold is kept on this Mac (`EventTypeBook`), and the event shows as that kind there.
public final class CalendarWithTasks: CalendarService {
    public let calendars: any CalendarService
    public let tasks: (any TaskService)?
    public let types: EventTypeBook
    private let problem = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init(calendars: any CalendarService, tasks: (any TaskService)?, types: EventTypeBook) {
        self.calendars = calendars
        self.tasks = tasks
        self.types = types
    }

    /// Why the tasks couldn't be loaded the last time they were asked for (signing in again may be needed), if they
    /// couldn't. The calendars load either way.
    public var tasksProblem: String? { problem.withLock { $0 } }

    public func loadCalendars() async throws -> [CalendarInfo] {
        var calendars = try await self.calendars.loadCalendars()
        guard let tasks else { return calendars }
        do {
            let lists = try await tasks.loadTaskLists()
            problem.withLock { $0 = nil }
            calendars += lists.map {
                CalendarInfo(id: TaskLists.calendarID(for: $0.id), name: $0.name, colorHex: TaskLists.colorHex, isPrimary: $0.isDefault)
            }
        } catch {
            note(error)
        }
        return calendars
    }

    public func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let listIDs = calendarIDs.compactMap(TaskLists.listID(from:))
        let calendarOnly = calendarIDs.filter { TaskLists.listID(from: $0) == nil }
        var events = calendarOnly.isEmpty ? [] : try await calendars.loadEvents(in: calendarOnly, from: start, to: end)
        events = await types.applying(to: events)
        if let tasks, !listIDs.isEmpty {
            do {
                events += try await tasks.loadTasks(in: listIDs, from: start, to: end)
            } catch {
                note(error)
            }
        }
        return events
    }

    public func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        if event.isTask { return try await requireTasks().create(Self.asTask(event)) }
        let saved = try await calendars.create(event, addingConference: addingConference)
        return await reconciled(saved, wanted: event)
    }

    public func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        if event.isTask { return try await requireTasks().update(Self.asTask(event)) }
        let saved = try await calendars.update(event, scope: scope, addingConference: addingConference)
        return await reconciled(saved, wanted: event)
    }

    public func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws {
        if event.isTask { return try await requireTasks().delete(event) }
        try await calendars.delete(event, scope: scope)
        if scope == .allEvents || !event.isRecurring { await types.set(nil, for: event) }
    }

    public func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {
        try await calendars.respond(to: event, with: response)
    }

    public func freeBusy(for addresses: [String], from start: Date, to end: Date) async throws -> [String: FreeBusy] {
        try await calendars.freeBusy(for: addresses, from: start, to: end)
    }

    public var emailsInvitations: Bool { calendars.emailsInvitations }

    public func invitationText(for event: CalendarEvent, method: Invitation.Method, attendees: [MailAddress]?) async throws -> String? {
        guard !event.isTask else { return nil }
        return try await calendars.invitationText(for: event, method: method, attendees: attendees)
    }

    public func receive(_ invitation: Invitation) async throws {
        try await calendars.receive(invitation)
    }

    /// The event as saved, as the kind the person chose: kept on this Mac when the calendar saved it as another kind,
    /// and forgotten here when the calendar holds it itself.
    private func reconciled(_ saved: CalendarEvent, wanted: CalendarEvent) async -> CalendarEvent {
        let kind = wanted.type == .task ? .event : wanted.type
        var result = saved
        if saved.type == kind {
            await types.set(nil, for: saved)
            result.isTypeLocal = false
        } else {
            await types.set(kind, for: saved)
            result.type = kind
            result.isTypeLocal = true
        }
        return result
    }

    private func requireTasks() throws -> any TaskService {
        guard let tasks else { throw PMailError.notSupported("This account doesn’t have tasks.") }
        return tasks
    }

    private static func asTask(_ event: CalendarEvent) -> CalendarEvent {
        var task = event
        task.type = .task
        return task
    }

    private func note(_ error: any Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        problem.withLock { $0 = text }
    }
}

/// Kinds of events their calendars can't hold (an iCloud event shown as focus time, say), kept on this Mac by event: a
/// repeating event's kind is its series'. Kept in a JSON file in the account's folder.
public actor EventTypeBook {
    /// The file's name in the account's folder.
    public static let fileName = "EventTypes.json"
    public nonisolated let file: URL
    private var entries: [String: EventType]?

    public init(file: URL) {
        self.file = file
    }

    /// The kind kept here for an event, if any.
    public func type(for event: CalendarEvent) -> EventType? {
        loaded()[Self.key(for: event)]
    }

    /// Keeps a kind for an event (and its series), or forgets it with nil.
    public func set(_ type: EventType?, for event: CalendarEvent) {
        var current = loaded()
        let key = Self.key(for: event)
        guard current[key] != type else { return }
        current[key] = type
        save(current)
    }

    /// Events with the kinds kept here.
    public func applying(to events: [CalendarEvent]) -> [CalendarEvent] {
        let current = loaded()
        guard !current.isEmpty else { return events }
        return events.map { event in
            guard let type = current[Self.key(for: event)] else { return event }
            var shown = event
            shown.type = type
            shown.isTypeLocal = true
            return shown
        }
    }

    static func key(for event: CalendarEvent) -> String {
        event.calendarID + "\n" + (event.seriesID ?? event.id)
    }

    private func loaded() -> [String: EventType] {
        if let entries { return entries }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: EventType].self, from: $0) } ?? [:]
        entries = read
        return read
    }

    private func save(_ new: [String: EventType]) {
        entries = new
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            // Kept in memory; written with the next change.
        }
    }
}

/// Tasks kept on this Mac, for an account whose servers have none (iCloud, which keeps reminders out of reach, and
/// other accounts): one list, "Tasks", in a JSON file in the account's folder.
public actor LocalTaskService: TaskService {
    public static let listID = "local"
    /// The file's name in the account's folder.
    public static let fileName = "Tasks.json"

    struct StoredTask: Codable {
        var id: String
        var title: String
        var notes: String?
        /// The day it's due, "yyyy-MM-dd", so it stays on that day wherever the Mac is.
        var due: String
        var isCompleted: Bool
    }

    public nonisolated let file: URL
    private var tasks: [StoredTask]?

    public init(file: URL) {
        self.file = file
    }

    public func loadTaskLists() async throws -> [TaskList] {
        [TaskList(id: Self.listID, name: "Tasks", isDefault: true)]
    }

    public func loadTasks(in listIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard listIDs.contains(Self.listID) else { return [] }
        return loaded().compactMap(Self.event(from:)).filter { $0.start < end && $0.start >= Calendar.current.startOfDay(for: start) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    public func create(_ task: CalendarEvent) async throws -> CalendarEvent {
        var current = loaded()
        let stored = Self.stored(task, id: "task-" + UUID().uuidString.lowercased())
        current.append(stored)
        try save(current)
        return Self.event(from: stored) ?? task
    }

    public func update(_ task: CalendarEvent) async throws -> CalendarEvent {
        var current = loaded()
        guard let index = current.firstIndex(where: { $0.id == task.id }) else { throw PMailError.notFound }
        current[index] = Self.stored(task, id: task.id)
        try save(current)
        return Self.event(from: current[index]) ?? task
    }

    public func delete(_ task: CalendarEvent) async throws {
        var current = loaded()
        current.removeAll { $0.id == task.id }
        try save(current)
    }

    static func stored(_ task: CalendarEvent, id: String) -> StoredTask {
        StoredTask(id: id, title: task.title, notes: task.notes, due: TaskDates.dayString(task.start), isCompleted: task.isCompleted)
    }

    static func event(from task: StoredTask) -> CalendarEvent? {
        guard let day = TaskDates.day(task.due) else { return nil }
        return TaskDates.event(id: task.id, listID: listID, title: task.title, notes: task.notes, day: day, isCompleted: task.isCompleted)
    }

    private func loaded() -> [StoredTask] {
        if let tasks { return tasks }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([StoredTask].self, from: $0) } ?? []
        tasks = read
        return read
    }

    private func save(_ new: [StoredTask]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: file, options: .atomic)
        } catch {
            throw PMailError.server("PMail couldn’t save tasks on this Mac: \(error.localizedDescription)")
        }
        tasks = new
    }
}

/// Days for tasks, which are due on a day rather than at a time.
public enum TaskDates {
    /// A day as "yyyy-MM-dd", in the Mac's calendar.
    public static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Midnight on the day a "yyyy-MM-dd" (or the start of a longer date-time string) names, in the Mac's calendar.
    public static func day(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A task as the calendar shows it: all day on the day it's due.
    public static func event(id: String, listID: String, title: String, notes: String?, day: Date, isCompleted: Bool,
                             etag: String? = nil, webLink: URL? = nil) -> CalendarEvent {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        return CalendarEvent(id: id, calendarID: TaskLists.calendarID(for: listID), title: title, start: day, end: next, isAllDay: true,
                             notes: notes, availability: .free, webLink: webLink, etag: etag, type: .task, isCompleted: isCompleted)
    }
}
