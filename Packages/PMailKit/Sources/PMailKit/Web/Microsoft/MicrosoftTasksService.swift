import Foundation

/// A Microsoft account's tasks, through Microsoft To Do (Graph): each list a calendar of tasks, each task on the day
/// it's due. Graph can't ask for a list's tasks by date, so a list's tasks are fetched whole and kept a couple of
/// minutes, until something changes.
public actor MicrosoftTasksService: TaskService {
    let client: WebClient
    private var fetched: [String: (at: Date, tasks: [CalendarEvent])] = [:]

    static let base = Graph.root + "me/todo/"
    /// Seconds a list's tasks are kept before they're fetched again.
    static let keptFor: TimeInterval = 120

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(client: WebClient(tokens: tokens, transport: transport))
    }

    init(client: WebClient) {
        self.client = client
    }

    static func listsURL() throws -> URL { try WebURL.make(base + "lists") }

    static func tasksURL(_ listID: String, _ taskID: String? = nil, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + "lists/\(WebURL.segment(listID))/tasks" + (taskID.map { "/\(WebURL.segment($0))" } ?? ""), query: query)
    }

    /// The lists, To Do's own "Tasks" list taking new tasks.
    public func loadTaskLists() async throws -> [TaskList] {
        let items = try await client.graphItems(Self.listsURL())
        var lists = items.compactMap { item -> TaskList? in
            guard let id = item["id"].nonEmpty else { return nil }
            return TaskList(id: id, name: item["displayName"].nonEmpty ?? "Tasks", isDefault: item["wellknownListName"].string == "defaultList")
        }
        if !lists.isEmpty, !lists.contains(where: \.isDefault) { lists[0].isDefault = true }
        return lists
    }

    public func loadTasks(in listIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let first = Calendar.current.startOfDay(for: start)
        var tasks: [CalendarEvent] = []
        for listID in listIDs {
            tasks += try await allTasks(in: listID).filter { $0.start >= first && $0.start < end }
        }
        return tasks
    }

    public func create(_ task: CalendarEvent) async throws -> CalendarEvent {
        guard let listID = TaskLists.listID(from: task.calendarID) else { throw PMailError.notFound }
        let saved = try await client.post(Self.tasksURL(listID), .object(Self.body(for: task)))
        fetched[listID] = nil
        guard let result = Self.task(from: saved, listID: listID) else { throw PMailError.protocolError("the new task couldn’t be read") }
        return result
    }

    public func update(_ task: CalendarEvent) async throws -> CalendarEvent {
        guard let listID = TaskLists.listID(from: task.calendarID) else { throw PMailError.notFound }
        let saved = try await client.patch(Self.tasksURL(listID, task.id), .object(Self.body(for: task)))
        fetched[listID] = nil
        guard let result = Self.task(from: saved, listID: listID) else { throw PMailError.protocolError("the saved task couldn’t be read") }
        return result
    }

    public func delete(_ task: CalendarEvent) async throws {
        guard let listID = TaskLists.listID(from: task.calendarID) else { throw PMailError.notFound }
        do {
            try await client.delete(Self.tasksURL(listID, task.id))
        } catch PMailError.notFound {
            // Already gone.
        }
        fetched[listID] = nil
    }

    /// Every task in a list with a due date, from the last couple of minutes or fetched now.
    private func allTasks(in listID: String) async throws -> [CalendarEvent] {
        if let kept = fetched[listID], Date().timeIntervalSince(kept.at) < Self.keptFor { return kept.tasks }
        let items = try await client.graphItems(Self.tasksURL(listID, nil, [("$top", "100")]))
        let tasks = items.compactMap { Self.task(from: $0, listID: listID) }
        fetched[listID] = (Date(), tasks)
        return tasks
    }

    /// A task from To Do, on the day it's due; nil for one without a due date. Apps keep that day different ways: as
    /// midnight UTC on the date (read as the date), as some other moment in UTC (read as the Mac's day it falls on, so
    /// midnight where the task was made lands on its date), or in another time zone (read as the date it names).
    static func task(from item: JSONValue, listID: String) -> CalendarEvent? {
        guard let id = item["id"].nonEmpty, let due = item["dueDateTime"]["dateTime"].nonEmpty else { return nil }
        let zone = item["dueDateTime"]["timeZone"].string ?? "UTC"
        let day: Date?
        if zone.uppercased() == "UTC", let moment = WebDate.parse(due), Calendar.current.dateComponents(in: .gmt, from: moment).hour != 0 {
            day = Calendar.current.startOfDay(for: moment)
        } else {
            day = TaskDates.day(due)
        }
        guard let day else { return nil }
        let content = item["body"]["content"].string ?? ""
        let notes = item["body"]["contentType"].string?.lowercased() == "html" ? WebText.plainText(fromPossibleHTML: content) : content
        return TaskDates.event(id: id, listID: listID, title: item["title"].string ?? "",
                               notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes, day: day,
                               isCompleted: item["status"].string == "completed", etag: item["@odata.etag"].nonEmpty)
    }

    /// What To Do keeps of a task: its title, notes, the day it's due and whether it's done. The day goes as noon UTC
    /// on its date, which is that date nearly everywhere, however an app reads it.
    static func body(for task: CalendarEvent) -> [String: JSONValue] {
        ["title": .string(task.title), "body": ["contentType": "text", "content": .string(task.notes ?? "")],
                "dueDateTime": ["dateTime": .string(TaskDates.dayString(task.start) + "T12:00:00"), "timeZone": "UTC"],
                "status": .string(task.isCompleted ? "completed" : "notStarted")]
    }
}
