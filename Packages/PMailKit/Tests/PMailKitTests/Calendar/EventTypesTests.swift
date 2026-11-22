import Foundation
import Testing
@testable import PMailKit

/// A pretend calendar that holds some kinds of event itself and saves the rest as ordinary events.
private actor KindedCalendar: CalendarService {
    let holds: Set<EventType>
    private(set) var events: [String: CalendarEvent] = [:]
    private var counter = 0

    init(holds: Set<EventType>) {
        self.holds = holds
    }

    func loadCalendars() async throws -> [CalendarInfo] { [CalendarInfo(id: "cal", name: "Calendar", isPrimary: true)] }

    func loadEvents(in calendarIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        events.values.filter { calendarIDs.contains($0.calendarID) && $0.start < end && $0.end > start }.sorted { $0.id < $1.id }
    }

    func create(_ event: CalendarEvent, addingConference: Bool) async throws -> CalendarEvent {
        counter += 1
        var saved = event
        saved.id = "e\(counter)"
        if !holds.contains(saved.type) { saved.type = .event }
        events[saved.id] = saved
        return saved
    }

    func update(_ event: CalendarEvent, scope: RecurrenceScope, addingConference: Bool) async throws -> CalendarEvent {
        var saved = event
        if !holds.contains(saved.type) { saved.type = .event }
        saved.isTypeLocal = false
        events[saved.id] = saved
        return saved
    }

    func delete(_ event: CalendarEvent, scope: RecurrenceScope) async throws { events[event.id] = nil }

    func respond(to event: CalendarEvent, with response: AttendeeResponse) async throws {}
}

/// Task lists that can't be reached (signing in again would fix it).
private final class UnreachableTasks: TaskService, @unchecked Sendable {
    func loadTaskLists() async throws -> [TaskList] { throw PMailError.http(status: 403, message: "Insufficient permission") }
    func loadTasks(in listIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] { throw PMailError.notSignedIn }
    func create(_ task: CalendarEvent) async throws -> CalendarEvent { throw PMailError.notSignedIn }
    func update(_ task: CalendarEvent) async throws -> CalendarEvent { throw PMailError.notSignedIn }
    func delete(_ task: CalendarEvent) async throws {}
}

struct EventTypesTests {
    private let day = WebFixtures.localMidnight(2026, 11, 23)

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKinds-\(UUID().uuidString)", isDirectory: true)
    }

    private func range() -> (Date, Date) { (day.addingTimeInterval(-7 * 86_400), day.addingTimeInterval(7 * 86_400)) }

    @Test func eventsSavedBeforeKindsReadAsEvents() throws {
        var event = CalendarEvent(calendarID: "cal", title: "Standup", start: day, end: day.addingTimeInterval(900))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        for key in ["type", "isCompleted", "isTypeLocal", "declinesInvitations"] { json[key] = nil }
        let old = try JSONDecoder().decode(CalendarEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.type == .event && !old.isCompleted && !old.isTypeLocal && old.title == "Standup")
        event.type = .focusTime
        event.declinesInvitations = true
        #expect(try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func kindsACalendarCantHoldAreKeptOnThisMac() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = KindedCalendar(holds: [.event, .outOfOffice])
        let calendar = CalendarWithTasks(calendars: server, tasks: nil, types: EventTypeBook(file: folder.appendingPathComponent("EventTypes.json")))
        let (start, end) = range()

        let away = try await calendar.create(CalendarEvent(calendarID: "cal", title: "Away", start: day, end: day.addingTimeInterval(86_400),
                                                           isAllDay: true, type: .outOfOffice), addingConference: false)
        #expect(away.type == .outOfOffice && !away.isTypeLocal, "the calendar holds out of office itself")
        let focus = try await calendar.create(CalendarEvent(calendarID: "cal", title: "Write", start: day.addingTimeInterval(3_600),
                                                            end: day.addingTimeInterval(7_200), type: .focusTime), addingConference: false)
        #expect(focus.type == .focusTime && focus.isTypeLocal, "focus time is kept on this Mac")
        #expect(await server.events[focus.id]?.type == .event, "and saved as an ordinary event")

        var loaded = try await calendar.loadEvents(in: ["cal"], from: start, to: end)
        #expect(loaded.first { $0.id == focus.id }?.type == .focusTime && loaded.first { $0.id == focus.id }?.isTypeLocal == true)
        // A book made again from the same file still knows.
        let again = CalendarWithTasks(calendars: server, tasks: nil, types: EventTypeBook(file: folder.appendingPathComponent("EventTypes.json")))
        #expect(try await again.loadEvents(in: ["cal"], from: start, to: end).first { $0.id == focus.id }?.type == .focusTime)

        var plain = try #require(loaded.first { $0.id == focus.id })
        plain.type = .event
        let changed = try await calendar.update(plain, scope: .thisEvent, addingConference: false)
        #expect(changed.type == .event && !changed.isTypeLocal)
        loaded = try await calendar.loadEvents(in: ["cal"], from: start, to: end)
        #expect(loaded.first { $0.id == focus.id }?.type == .event, "changed back, nothing is kept here")

        let kept = try await calendar.create(CalendarEvent(calendarID: "cal", title: "Deep work", start: day, end: day.addingTimeInterval(3_600),
                                                           type: .focusTime), addingConference: false)
        try await calendar.delete(kept, scope: .thisEvent)
        #expect(await calendar.types.type(for: kept) == nil, "deleting forgets it")
    }

    @Test func taskListsSitBesideTheCalendars() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tasks = LocalTaskService(file: folder.appendingPathComponent("Tasks.json"))
        let calendar = CalendarWithTasks(calendars: KindedCalendar(holds: [.event]), tasks: tasks,
                                         types: EventTypeBook(file: folder.appendingPathComponent("EventTypes.json")))
        let calendars = try await calendar.loadCalendars()
        #expect(calendars.map(\.id) == ["cal", "tasks:local"])
        #expect(calendars.last?.isTaskList == true && calendars.last?.name == "Tasks" && calendars.last?.isPrimary == true)

        let made = try await calendar.create(CalendarEvent(calendarID: "tasks:local", title: "Pay rent", start: day.addingTimeInterval(9 * 3_600),
                                                           end: day.addingTimeInterval(10 * 3_600), notes: "Before noon"), addingConference: false)
        #expect(made.isTask && made.type == .task && made.isAllDay && made.start == day && !made.isCompleted, "a task is on its day")
        var done = made
        done.isCompleted = true
        _ = try await calendar.update(done, scope: .thisEvent, addingConference: false)
        let (start, end) = range()
        let loaded = try await calendar.loadEvents(in: ["cal", "tasks:local"], from: start, to: end)
        #expect(loaded.map(\.title) == ["Pay rent"] && loaded.first?.isCompleted == true && loaded.first?.notes == "Before noon")
        #expect(try await calendar.loadEvents(in: ["tasks:local"], from: day.addingTimeInterval(86_400), to: end).isEmpty, "only its day")
        try await calendar.delete(made, scope: .thisEvent)
        #expect(try await calendar.loadEvents(in: ["tasks:local"], from: start, to: end).isEmpty)
    }

    @Test func tasksThatCantBeReachedLeaveTheCalendarsBe() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let calendar = CalendarWithTasks(calendars: KindedCalendar(holds: [.event]), tasks: UnreachableTasks(),
                                         types: EventTypeBook(file: folder.appendingPathComponent("EventTypes.json")))
        #expect(try await calendar.loadCalendars().map(\.id) == ["cal"])
        #expect(calendar.tasksProblem == "Insufficient permission (error 403)", "\(calendar.tasksProblem ?? "")")
    }

    @Test func dayStrings() {
        #expect(TaskDates.dayString(WebFixtures.localMidnight(2026, 3, 8).addingTimeInterval(22 * 3_600)) == "2026-03-08", "late on a day the clocks change")
        #expect(TaskDates.day("2026-11-21T00:00:00.000Z") == WebFixtures.localMidnight(2026, 11, 21), "the date it names, wherever the Mac is")
        #expect(TaskDates.day("soon") == nil)
    }
}
