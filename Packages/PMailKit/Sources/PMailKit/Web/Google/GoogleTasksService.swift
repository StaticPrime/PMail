import Foundation

/// A Google account's tasks, through the Google Tasks API: each task list a calendar of tasks, each task on the day
/// it's due. Google keeps a task's date but not its time.
public actor GoogleTasksService: TaskService {
    let client: WebClient

    static let base = "https://tasks.googleapis.com/tasks/v1/"

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(client: WebClient(tokens: tokens, transport: transport))
    }

    init(client: WebClient) {
        self.client = client
    }

    static func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try WebURL.make(base + path, query: query)
    }

    static func tasksURL(_ listID: String, _ taskID: String? = nil, _ query: [(String, String)] = []) throws -> URL {
        try url("lists/\(WebURL.segment(listID))/tasks" + (taskID.map { "/\(WebURL.segment($0))" } ?? ""), query)
    }

    /// The lists, the first (Google's own "My Tasks") taking new tasks.
    public func loadTaskLists() async throws -> [TaskList] {
        let pages = try await client.pages { token in
            try Self.url("users/@me/lists", [("maxResults", "100")] + (token.map { [("pageToken", $0)] } ?? []))
        }
        return pages.flatMap { $0["items"].array }.enumerated().compactMap { index, item in
            guard let id = item["id"].nonEmpty else { return nil }
            return TaskList(id: id, name: item["title"].nonEmpty ?? "Tasks", isDefault: index == 0)
        }
    }

    public func loadTasks(in listIDs: [String], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let first = Calendar.current.startOfDay(for: start)
        // Google keeps due dates as midnight UTC, so a day more either side catches every day in the range.
        let query = [("showCompleted", "true"), ("showHidden", "true"), ("maxResults", "100"),
                     ("dueMin", WebDate.utcString(first.addingTimeInterval(-86_400))), ("dueMax", WebDate.utcString(end.addingTimeInterval(86_400)))]
        var tasks: [CalendarEvent] = []
        for listID in listIDs {
            let pages = try await client.pages { token in
                try Self.tasksURL(listID, nil, query + (token.map { [("pageToken", $0)] } ?? []))
            }
            for item in pages.flatMap({ $0["items"].array }) {
                guard let task = Self.task(from: item, listID: listID), task.start >= first, task.start < end else { continue }
                tasks.append(task)
            }
        }
        return tasks
    }

    public func create(_ task: CalendarEvent) async throws -> CalendarEvent {
        guard let listID = TaskLists.listID(from: task.calendarID) else { throw PMailError.notFound }
        let saved = try await client.post(Self.tasksURL(listID), .object(Self.body(for: task)))
        guard let result = Self.task(from: saved, listID: listID) else { throw PMailError.protocolError("the new task couldn’t be read") }
        return result
    }

    public func update(_ task: CalendarEvent) async throws -> CalendarEvent {
        guard let listID = TaskLists.listID(from: task.calendarID) else { throw PMailError.notFound }
        var body = Self.body(for: task)
        // Taking a task back out of done clears when it was done.
        if !task.isCompleted { body["completed"] = .null }
        let saved = try await client.patch(Self.tasksURL(listID, task.id), .object(body))
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
    }

    /// A task from Google, on the day it's due (the date Google keeps, whatever the Mac's time zone); nil for one
    /// that's deleted or has no due date.
    static func task(from item: JSONValue, listID: String) -> CalendarEvent? {
        guard let id = item["id"].nonEmpty, item["deleted"].bool != true, let due = item["due"].nonEmpty, let day = TaskDates.day(due) else {
            return nil
        }
        return TaskDates.event(id: id, listID: listID, title: item["title"].string ?? "", notes: item["notes"].nonEmpty, day: day,
                               isCompleted: item["status"].string == "completed", etag: item["etag"].nonEmpty,
                               webLink: WebURL.webLink(item["webViewLink"].string))
    }

    /// What Google keeps of a task: its title, notes, the day it's due (as midnight UTC) and whether it's done.
    static func body(for task: CalendarEvent) -> [String: JSONValue] {
        ["title": .string(task.title), "notes": .string(task.notes ?? ""),
         "due": .string(TaskDates.dayString(task.start) + "T00:00:00.000Z"),
         "status": .string(task.isCompleted ? "completed" : "needsAction")]
    }
}
