import Foundation
import Testing
@testable import PMailKit

/// Out of office and focus time on Google calendars, and Google Tasks.
@Suite struct GoogleEventTypesTests {
    static let primary = "jamie@acme.example"
    static let events = "/calendar/v3/calendars/jamie@acme.example/events"

    private func service(_ transport: StubTransport) -> GoogleCalendarService {
        GoogleCalendarService(client: .test(transport))
    }

    private let start = WebFixtures.date("2026-11-23T15:00:00Z")

    /// Answers a new event with what was sent and an ID, or turns down Google's own kinds when `refusingKinds`.
    private func stubCreating(_ transport: StubTransport, refusingKinds: Bool = false) {
        transport.on("POST", Self.events) { request in
            var echo = request.bodyJSONValue.object ?? [:]
            if refusingKinds, echo["eventType"] != nil {
                return .json(#"{"error": {"code": 400, "message": "Focus time and out of office events aren't available for this calendar."}}"#,
                             status: 400)
            }
            echo["id"] = .string("made\(transport.sent("POST", Self.events).count)")
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
    }

    @Test func kindsAreReadFromGoogle() async throws {
        let transport = StubTransport()
        transport.on("GET", Self.events) { _ in
            .json(#"""
            {"items": [
              {"id": "away", "summary": "Out of office", "eventType": "outOfOffice",
               "start": {"date": "2026-11-26"}, "end": {"date": "2026-11-28"},
               "outOfOfficeProperties": {"autoDeclineMode": "declineAllConflictingInvitations", "declineMessage": "Back Monday"}},
              {"id": "focus", "summary": "Write", "eventType": "focusTime",
               "start": {"dateTime": "2026-11-24T14:00:00Z"}, "end": {"dateTime": "2026-11-24T16:00:00Z"},
               "focusTimeProperties": {"autoDeclineMode": "declineNone", "chatStatus": "available"}},
              {"id": "office", "summary": "Office", "eventType": "workingLocation",
               "start": {"date": "2026-11-25"}, "end": {"date": "2026-11-26"}}
            ]}
            """#)
        }
        let events = try await service(transport).loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                             to: WebFixtures.date("2026-11-30T00:00:00Z"))
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        #expect(byID["away"]?.type == .outOfOffice && byID["away"]?.declinesInvitations == true && byID["away"]?.declineMessage == "Back Monday")
        #expect(byID["away"]?.declinesExisting == true, "declining all conflicting invitations includes the meetings already planned")
        #expect(byID["focus"]?.type == .focusTime && byID["focus"]?.declinesInvitations == false)
        #expect(byID["office"]?.type == .event, "a working location is an ordinary event to PMail")
    }

    @Test func outOfOfficeIsMadeAsGooglesOwnKind() async throws {
        let transport = StubTransport()
        stubCreating(transport)
        let event = CalendarEvent(calendarID: Self.primary, title: "Out of office", start: start, end: start.addingTimeInterval(4 * 86_400),
                                  type: .outOfOffice, declinesInvitations: true, declineMessage: "Back on the 30th", declinesExisting: true)
        let saved = try await service(transport).create(event, addingConference: false)
        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body["eventType"] == "outOfOffice" && body["transparency"] == "opaque")
        #expect(body["outOfOfficeProperties"] == ["autoDeclineMode": "declineAllConflictingInvitations", "declineMessage": "Back on the 30th"])
        #expect(saved.type == .outOfOffice && saved.declinesInvitations && saved.declineMessage == "Back on the 30th" && saved.declinesExisting)

        // Only new invitations, leaving the meetings already planned.
        var onlyNew = event
        onlyNew.declinesExisting = false
        _ = try await service(transport).create(onlyNew, addingConference: false)
        #expect(transport.requests.last?.bodyJSONValue["outOfOfficeProperties"]["autoDeclineMode"] == "declineOnlyNewConflictingInvitations")

        let focus = CalendarEvent(calendarID: Self.primary, title: "Focus time", start: start, end: start.addingTimeInterval(7_200), type: .focusTime)
        _ = try await service(transport).create(focus, addingConference: false)
        let focusBody = try #require(transport.requests.last?.bodyJSONValue)
        #expect(focusBody["eventType"] == "focusTime" && focusBody["focusTimeProperties"] == ["autoDeclineMode": "declineNone", "chatStatus": "available"])
    }

    @Test func whereGoogleSaysNoItsAnOrdinaryEvent() async throws {
        let transport = StubTransport()
        stubCreating(transport, refusingKinds: true)
        let calendar = service(transport)
        let focus = CalendarEvent(calendarID: Self.primary, title: "Focus time", start: start, end: start.addingTimeInterval(7_200), type: .focusTime)
        let saved = try await calendar.create(focus, addingConference: false)
        #expect(saved.type == .event, "saved as an ordinary event, for the kind to be kept on the Mac")
        #expect(transport.sent("POST", Self.events).map { $0.bodyJSONValue["eventType"].isNull } == [false, true])
        _ = try await calendar.create(focus, addingConference: false)
        #expect(transport.sent("POST", Self.events).count == 3, "a calendar that said no isn't asked again")
        #expect(transport.sent("POST", Self.events).last?.bodyJSONValue["eventType"].isNull == true)

        let allDay = CalendarEvent(calendarID: "other@acme.example", title: "Focus", start: WebFixtures.localMidnight(2026, 11, 24),
                                   end: WebFixtures.localMidnight(2026, 11, 25), isAllDay: true, type: .focusTime)
        transport.on("POST", "/calendar/v3/calendars/other@acme.example/events") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "made-all-day"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        _ = try await calendar.create(allDay, addingConference: false)
        #expect(transport.sent("POST", "/calendar/v3/calendars/other@acme.example/events").first?.bodyJSONValue["eventType"].isNull == true,
                "focus time all day, which Google doesn't have, isn't asked for")
    }

    @Test func changingAnEventsKindMakesItAgain() async throws {
        let transport = StubTransport()
        transport.on("GET", Self.events) { _ in
            .json(#"{"items": [{"id": "plain", "summary": "Trip", "start": {"date": "2026-11-26"}, "end": {"date": "2026-11-28"}}]}"#)
        }
        stubCreating(transport)
        transport.on("DELETE", "\(Self.events)/plain") { _ in .status(204) }
        let calendar = service(transport)
        let loaded = try await calendar.loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                   to: WebFixtures.date("2026-11-30T00:00:00Z"))
        var trip = try #require(loaded.first)
        trip.type = .outOfOffice
        let saved = try await calendar.update(trip, scope: .thisEvent, addingConference: false)
        #expect(saved.type == .outOfOffice && saved.id != "plain", "Google keeps a kind for good, so it's made again")
        #expect(transport.sent("POST", Self.events).first?.bodyJSONValue["eventType"] == "outOfOffice")
        #expect(transport.sent("DELETE", "\(Self.events)/plain").count == 1, "and the old one goes")
    }

    @Test func decliningChangesOnAnOutOfOfficeEvent() async throws {
        let transport = StubTransport()
        transport.on("GET", Self.events) { _ in
            .json(#"""
            {"items": [{"id": "away", "summary": "Out of office", "eventType": "outOfOffice", "start": {"date": "2026-11-26"},
              "end": {"date": "2026-11-28"}, "outOfOfficeProperties": {"autoDeclineMode": "declineNone"}}]}
            """#)
        }
        transport.on("PATCH", "\(Self.events)/away") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "away"
            echo["eventType"] = "outOfOffice"
            echo["start"] = ["date": "2026-11-26"]
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let calendar = service(transport)
        var away = try #require(try await calendar.loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                              to: WebFixtures.date("2026-11-30T00:00:00Z")).first)
        away.declinesInvitations = true
        away.declineMessage = "Away"
        let declining = try await calendar.update(away, scope: .thisEvent, addingConference: false)
        let body = try #require(transport.sent("PATCH", "\(Self.events)/away").first?.bodyJSONValue)
        #expect(body == ["outOfOfficeProperties": ["autoDeclineMode": "declineOnlyNewConflictingInvitations", "declineMessage": "Away"]],
                "only what changed")
        // The meetings already planned too.
        var everything = declining
        everything.declinesExisting = true
        _ = try await calendar.update(everything, scope: .thisEvent, addingConference: false)
        #expect(transport.sent("PATCH", "\(Self.events)/away").last?.bodyJSONValue["outOfOfficeProperties"]["autoDeclineMode"]
                == "declineAllConflictingInvitations")
    }

    // MARK: Google Tasks

    private func tasks(_ transport: StubTransport) -> GoogleTasksService {
        GoogleTasksService(client: .test(transport))
    }

    @Test func taskListsAndTasksOnTheirDays() async throws {
        let transport = StubTransport()
        transport.on("GET", "/tasks/v1/users/@me/lists") { _ in
            .json(#"{"items": [{"id": "L1", "title": "My Tasks"}, {"id": "L2", "title": "Groceries"}]}"#)
        }
        transport.on("GET", "/tasks/v1/lists/L1/tasks") { _ in
            .json(#"""
            {"items": [
              {"id": "t1", "title": "Pay rent", "notes": "Before noon", "due": "2026-11-23T00:00:00.000Z", "status": "needsAction", "etag": "\"e1\""},
              {"id": "t2", "title": "Call Sam", "due": "2026-11-24T00:00:00.000Z", "status": "completed", "completed": "2026-11-24T10:00:00.000Z"},
              {"id": "t3", "title": "Someday", "status": "needsAction"},
              {"id": "t4", "title": "Gone", "due": "2026-11-24T00:00:00.000Z", "deleted": true}
            ]}
            """#)
        }
        let service = tasks(transport)
        let lists = try await service.loadTaskLists()
        #expect(lists == [TaskList(id: "L1", name: "My Tasks", isDefault: true), TaskList(id: "L2", name: "Groceries")])
        let found = try await service.loadTasks(in: ["L1"], from: WebFixtures.localMidnight(2026, 11, 22), to: WebFixtures.localMidnight(2026, 11, 29))
        #expect(found.map(\.id) == ["t1", "t2"], "dated tasks, done or not")
        #expect(found.first?.start == WebFixtures.localMidnight(2026, 11, 23) && found.first?.calendarID == "tasks:L1" && found.first?.isTask == true)
        #expect(found.first?.notes == "Before noon" && found.last?.isCompleted == true)
        let request = try #require(transport.sent("GET", "/tasks/v1/lists/L1/tasks").first)
        #expect(request.query("showCompleted") == "true" && request.query("showHidden") == "true" && request.query("dueMin") != nil)
    }

    @Test func tasksAreMadeChangedAndDeleted() async throws {
        let transport = StubTransport()
        let echo: (URLRequest) -> StubTransport.Response = { request in
            var body = request.bodyJSONValue.object ?? [:]
            body["id"] = "t9"
            return .json(String(decoding: JSONValue.object(body).encoded(), as: UTF8.self))
        }
        transport.on("POST", "/tasks/v1/lists/L1/tasks", echo)
        transport.on("PATCH", "/tasks/v1/lists/L1/tasks/t9", echo)
        transport.on("DELETE", "/tasks/v1/lists/L1/tasks/t9") { _ in .status(204) }
        let service = tasks(transport)
        let task = TaskDates.event(id: "", listID: "L1", title: "Book flights", notes: nil, day: WebFixtures.localMidnight(2026, 11, 24), isCompleted: false)
        let made = try await service.create(task)
        #expect(transport.requests.first?.bodyJSONValue == ["title": "Book flights", "notes": "", "due": "2026-11-24T00:00:00.000Z", "status": "needsAction"])
        #expect(made.id == "t9" && made.start == WebFixtures.localMidnight(2026, 11, 24))
        var done = made
        done.isCompleted = true
        #expect(try await service.update(done).isCompleted)
        done.isCompleted = false
        _ = try await service.update(done)
        #expect(transport.sent("PATCH", "/tasks/v1/lists/L1/tasks/t9").last?.bodyJSONValue["completed"].isNull == true, "undone, its completion goes")
        try await service.delete(made)
        #expect(transport.sent("DELETE", "/tasks/v1/lists/L1/tasks/t9").count == 1)
    }
}

/// Out of office on Microsoft calendars, and Microsoft To Do.
@Suite struct MicrosoftEventTypesTests {
    static let api = "/v1.0/me"

    @Test func outOfOfficeIsHowAnEventShows() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/calendars/AAMkCal1=/calendarView") { _ in
            .json(#"""
            {"value": [{"id": "AAMkAway=", "subject": "Vacation", "isAllDay": true, "showAs": "oof",
                        "start": {"dateTime": "2026-11-26T00:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-28T00:00:00.0000000", "timeZone": "UTC"}}]}
            """#)
        }
        transport.on("PATCH", "\(Self.api)/events/AAMkAway=") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "AAMkAway="
            echo["start"] = ["dateTime": "2026-11-26T00:00:00.0000000", "timeZone": "UTC"]
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        transport.on("POST", "\(Self.api)/calendars/AAMkCal1=/events") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "AAMkNew="
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        let loaded = try await calendar.loadEvents(in: ["AAMkCal1="], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                   to: WebFixtures.date("2026-11-30T00:00:00Z"))
        var away = try #require(loaded.first)
        #expect(away.type == .outOfOffice)
        away.type = .event
        _ = try await calendar.update(away, scope: .thisEvent, addingConference: false)
        #expect(transport.sent("PATCH", "\(Self.api)/events/AAMkAway=").first?.bodyJSONValue["showAs"] == "busy", "no longer out of office")

        let start = WebFixtures.date("2026-12-01T15:00:00Z")
        let made = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "Out", start: start, end: start.addingTimeInterval(3_600),
                                                           type: .outOfOffice), addingConference: false)
        #expect(transport.sent("POST", "\(Self.api)/calendars/AAMkCal1=/events").first?.bodyJSONValue["showAs"] == "oof")
        #expect(made.type == .outOfOffice)
        let focus = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "Focus", start: start, end: start.addingTimeInterval(3_600),
                                                            type: .focusTime), addingConference: false)
        #expect(focus.type == .event, "Microsoft has no focus time: it's kept on the Mac")
    }

    @Test func toDoListsAndTasksOnTheirDays() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/todo/lists") { _ in
            .json(#"""
            {"value": [{"id": "AQL2", "displayName": "Groceries", "wellknownListName": "none"},
                       {"id": "AQL1", "displayName": "Tasks", "wellknownListName": "defaultList"}]}
            """#)
        }
        transport.on("GET", "\(Self.api)/todo/lists/AQL1/tasks") { _ in
            .json(#"""
            {"value": [
              {"id": "T1", "title": "Midnight UTC", "status": "notStarted",
               "dueDateTime": {"dateTime": "2026-11-23T00:00:00.0000000", "timeZone": "UTC"}},
              {"id": "T2", "title": "Done", "status": "completed", "body": {"contentType": "html", "content": "<p>Signed</p>"},
               "dueDateTime": {"dateTime": "2026-11-24T00:00:00.0000000", "timeZone": "Eastern Standard Time"}},
              {"id": "T3", "title": "No date", "status": "notStarted"}
            ]}
            """#)
        }
        transport.on("POST", "\(Self.api)/todo/lists/AQL1/tasks") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "T9"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let service = MicrosoftTasksService(client: .test(transport))
        let lists = try await service.loadTaskLists()
        #expect(lists.map(\.name) == ["Groceries", "Tasks"] && lists.last?.isDefault == true)
        let range = (WebFixtures.localMidnight(2026, 11, 22), WebFixtures.localMidnight(2026, 11, 29))
        let found = try await service.loadTasks(in: ["AQL1"], from: range.0, to: range.1)
        #expect(found.map(\.id) == ["T1", "T2"])
        #expect(found.first?.start == WebFixtures.localMidnight(2026, 11, 23), "midnight UTC is the date")
        #expect(found.last?.start == WebFixtures.localMidnight(2026, 11, 24) && found.last?.isCompleted == true && found.last?.notes == "Signed")
        _ = try await service.loadTasks(in: ["AQL1"], from: range.0, to: range.1)
        #expect(transport.sent("GET", "\(Self.api)/todo/lists/AQL1/tasks").count == 1, "kept a couple of minutes")

        let made = try await service.create(TaskDates.event(id: "", listID: "AQL1", title: "Groceries", notes: "Milk",
                                                            day: WebFixtures.localMidnight(2026, 11, 25), isCompleted: false))
        let body = try #require(transport.sent("POST", "\(Self.api)/todo/lists/AQL1/tasks").first?.bodyJSONValue)
        #expect(body["dueDateTime"] == ["dateTime": "2026-11-25T12:00:00", "timeZone": "UTC"], "noon UTC on its date")
        #expect(body["status"] == "notStarted" && body["body"] == ["contentType": "text", "content": "Milk"])
        #expect(made.start == WebFixtures.localMidnight(2026, 11, 25), "and read back as that day")
        _ = try await service.loadTasks(in: ["AQL1"], from: range.0, to: range.1)
        #expect(transport.sent("GET", "\(Self.api)/todo/lists/AQL1/tasks").count == 2, "fetched again after a change")
    }
}
