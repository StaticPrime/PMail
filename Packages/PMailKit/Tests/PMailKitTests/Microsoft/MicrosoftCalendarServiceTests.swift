import Foundation
import Testing
@testable import PMailKit

@Suite struct MicrosoftCalendarServiceTests {
    static let api = "/v1.0/me"
    static let utcPreference = "outlook.timezone=\"UTC\""

    private func service(_ transport: StubTransport, pauses: WebTestPauses = WebTestPauses(), declinedFile: URL? = nil) -> MicrosoftCalendarService {
        MicrosoftCalendarService(client: .test(transport, pauses: pauses), declinedFile: declinedFile)
    }

    // MARK: Calendars

    @Test func calendarsMapColorsOwnershipAndTeams() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/calendars") { _ in
            .json(#"""
            {"value": [
                {"id": "AAMkCal1=", "name": "Calendar", "color": "auto", "hexColor": "", "isDefaultCalendar": true,
                 "changeKey": "fJKVL07sbkmIfHqjbDnRgQAAAAACVg==",
                 "canShare": true, "canViewPrivateItems": true, "canEdit": true,
                  "allowedOnlineMeetingProviders": ["teamsForBusiness"],
                 "defaultOnlineMeetingProvider": "teamsForBusiness", "isTallyingResponses": true, "isRemovable": false,
                 "owner": {"name": "Jamie Rivera", "address": "jamie@contoso.com"}},
                {"id": "AAMkCal2=", "name": "Birthdays", "color": "lightGreen", "hexColor": "", "isDefaultCalendar": false,
                 "canEdit": false,
                 "allowedOnlineMeetingProviders": [], "owner": {"name": "Jamie Rivera", "address": "jamie@contoso.com"}},
                {"id": "AAMkCal3=", "name": "Alex's calendar", "color": "auto", "hexColor": "#8764b8",
                 "isDefaultCalendar": false, "canEdit": true,
                 "allowedOnlineMeetingProviders": ["teamsForBusiness"], "owner": {"name": "Alex Kim",
                  "address": "ALEX@contoso.com"}},
                {"id": "AAMkCal4=", "name": "Pugs", "color": "lightTeal", "hexColor": "", "isDefaultCalendar": false,
                 "canEdit": true,
                 "allowedOnlineMeetingProviders": ["teamsForBusiness"], "owner": {"name": "Jamie Rivera",
                  "address": "Jamie@Contoso.com"}}
            ]}
            """#)
        }
        let calendars = try await service(transport).loadCalendars()
        #expect(calendars == [
            CalendarInfo(id: "AAMkCal1=", name: "Calendar", colorHex: "#0078D4", isPrimary: true, nativeConference: .teams),
            CalendarInfo(id: "AAMkCal2=", name: "Birthdays", colorHex: "#5DB761", isReadOnly: true, isOther: true),
            CalendarInfo(id: "AAMkCal3=", name: "Alex's calendar", colorHex: "#8764B8", nativeConference: .teams, isOther: true),
            CalendarInfo(id: "AAMkCal4=", name: "Pugs", colorHex: "#3EB5B0", nativeConference: .teams),
        ])
    }

    // MARK: Events

    static let teamsEvent = #"""
    {"@odata.etag": "W/\"DwAAABYAAAA1\"", "id": "AAMkEv1=", "changeKey": "DwAAABYAAAA1", "subject": "Weekly sync",
     "bodyPreview": "Agenda", "body": {"contentType": "html",
        "content": "<html><head><style>p{margin:0}</style></head><body><div>Agenda</div><div>Notes &amp; next steps</div></body></html>"},
     "start": {"dateTime": "2026-11-23T18:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-11-23T18:30:00.0000000",
      "timeZone": "UTC"},
     "isAllDay": false, "location": {"displayName": "Conf Room 1", "locationType": "default"},
     "attendees": [
        {"type": "required", "status": {"response": "accepted", "time": "2026-11-20T10:00:00Z"},
         "emailAddress": {"name": "Sam Lee", "address": "sam@contoso.com"}},
        {"type": "optional", "status": {"response": "none", "time": "0001-01-01T00:00:00Z"},
         "emailAddress": {"name": "Pat Doe", "address": "pat@contoso.com"}},
        {"type": "required", "status": {"response": "tentativelyAccepted", "time": "2026-11-20T11:00:00Z"},
         "emailAddress": {"name": "Jamie Rivera", "address": "jamie@contoso.com"}}
     ],
     "organizer": {"emailAddress": {"name": "Sam Lee", "address": "sam@contoso.com"}},
     "isOnlineMeeting": true, "onlineMeetingProvider": "teamsForBusiness",
     "onlineMeeting": {
        "joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM4%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d",
                       "conferenceId": "987654321", "tollNumber": "+1 555-0150", "phones": [{"number": "+1 555-0150",
                        "type": "toll"}]},
     "onlineMeetingUrl": null,
     "seriesMasterId": "AAMkSeries=", "originalStart": "2026-11-23T18:00:00Z", "type": "occurrence", "showAs": "busy",
     "isReminderOn": true, "reminderMinutesBeforeStart": 15,
     "webLink": "https://outlook.office365.com/owa/?itemid=AAMkEv1%3D&exvsurl=1&path=/calendar/item",
     "iCalUId": "040000008200E00074C5B7101A82E0080000000001", "responseStatus": {"response": "tentativelyAccepted",
      "time": "2026-11-20T11:00:00Z"},
     "isCancelled": false, "originalStartTimeZone": "Pacific Standard Time"}
    """#

    private func stubEvents(_ transport: StubTransport) {
        transport.on("GET", "\(Self.api)/calendars/AAMkCal1=/calendarView") { request in
            request.query("$skip") == nil ? .json(#"""
            {"value": [\#(Self.teamsEvent),
                {"id": "AAMkEv2=", "subject": "Out of office", "isAllDay": true,
                 "start": {"dateTime": "2026-11-26T00:00:00.0000000", "timeZone": "UTC"},
                  "end": {"dateTime": "2026-11-28T00:00:00.0000000", "timeZone": "UTC"},
                 "showAs": "free", "isReminderOn": false, "responseStatus": {"response": "organizer"},
                  "body": {"contentType": "text", "content": ""}}
             ],
             "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendars/AAMkCal1=/calendarView?%24top=500&%24skip=2"}
            """#) : .json(#"""
            {"value": [{"id": "AAMkEv3=", "subject": "Coffee", "start": {"dateTime": "2026-11-24T14:00:00.0000000",
             "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-24T14:30:00.0000000", "timeZone": "UTC"},
                        "location": {"displayName": "https://meet.google.com/xyz-abcd-efg"},
                         "responseStatus": {"response": "notResponded"},
                        "isCancelled": true}]}
            """#)
        }
    }

    private func loadEvents(_ calendar: MicrosoftCalendarService) async throws -> [CalendarEvent] {
        try await calendar.loadEvents(in: ["AAMkCal1="], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                      to: WebFixtures.date("2026-11-30T00:00:00Z"))
    }

    @Test func eventsMapTeamsMeetingsAllDayDatesAndAnswers() async throws {
        let transport = StubTransport()
        stubEvents(transport)
        let events = try await loadEvents(service(transport))

        let requests = transport.sent("GET", "\(Self.api)/calendars/AAMkCal1=/calendarView")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer") == Self.utcPreference })
        #expect(requests[0].query("startDateTime") == "2026-11-22T00:00:00Z" && requests[0].query("endDateTime") == "2026-11-30T00:00:00Z")
        #expect(requests[0].query("$top") == "500")
        #expect(events.map(\.id) == ["AAMkEv1=", "AAMkEv3=", "AAMkEv2="])

        let sync = events[0]
        #expect(sync.title == "Weekly sync" && sync.calendarID == "AAMkCal1=")
        #expect(sync.start == WebFixtures.date("2026-11-23T18:00:00Z") && sync.end == WebFixtures.date("2026-11-23T18:30:00Z"))
        #expect(sync.notes == "Agenda\nNotes & next steps")
        #expect(sync.location == "Conf Room 1")
        #expect(sync.organizer == MailAddress(name: "Sam Lee", email: "sam@contoso.com"))
        #expect(sync.attendees == [
            Attendee(address: MailAddress(name: "Sam Lee", email: "sam@contoso.com"), response: .accepted, isOrganizer: true),
            Attendee(address: MailAddress(name: "Pat Doe", email: "pat@contoso.com"), response: .needsAction, isOptional: true),
            Attendee(address: MailAddress(name: "Jamie Rivera", email: "jamie@contoso.com"), response: .tentative),
        ])
        #expect(sync.myResponse == .tentative)
        let joinURL = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM4%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d"
        #expect(sync.conference == Conference(kind: .teams, joinURL: try #require(URL(string: joinURL)),
                                              phoneNumbers: ["+1 555-0150 PIN: 987654321#"]))
        #expect(sync.seriesID == "AAMkSeries=" && sync.occurrenceDate == WebFixtures.date("2026-11-23T18:00:00Z"))
        #expect(sync.reminderMinutes == [15] && sync.availability == .busy && sync.status == .confirmed)
        #expect(sync.etag == "DwAAABYAAAA1" && sync.uid == "040000008200E00074C5B7101A82E0080000000001")
        #expect(sync.webLink?.host == "outlook.office365.com")
        #expect(sync.timeZone == nil)  // Graph's own zone name, which the Mac doesn't know.

        let coffee = events[1]
        #expect(coffee.conference?.kind == .meet && coffee.myResponse == .needsAction && coffee.status == .cancelled)

        let away = events[2]
        #expect(away.isAllDay && away.availability == .free && away.myResponse == nil && away.notes == nil)
        #expect(away.start == WebFixtures.localMidnight(2026, 11, 26) && away.end == WebFixtures.localMidnight(2026, 11, 28))
        #expect(away.reminderMinutes.isEmpty)
    }

    // MARK: Creating

    @Test func creatingWithTeamsWaitsForTheJoinLink() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("POST", "\(Self.api)/calendars/AAMkCal1=/events") { _ in
            .json(#"""
            {"id": "AAMkNew=", "subject": "Pug playdate", "start": {"dateTime": "2026-11-24T15:00:00.0000000", "timeZone": "UTC"},
             "end": {"dateTime": "2026-11-24T16:00:00.0000000", "timeZone": "UTC"}, "isOnlineMeeting": true,
             "onlineMeetingProvider": "teamsForBusiness", "onlineMeeting": null}
            """#, status: 201)
        }
        transport.on("GET", "\(Self.api)/events/AAMkNew=") { _ in
            .json(#"""
            {"id": "AAMkNew=", "subject": "Pug playdate", "start": {"dateTime": "2026-11-24T15:00:00.0000000", "timeZone": "UTC"},
             "end": {"dateTime": "2026-11-24T16:00:00.0000000", "timeZone": "UTC"}, "isOnlineMeeting": true,
             "onlineMeetingProvider": "teamsForBusiness", "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/pug"}}
            """#)
        }
        let event = CalendarEvent(calendarID: "AAMkCal1=", title: "Pug playdate", start: WebFixtures.date("2026-11-24T15:00:00Z"),
                                  end: WebFixtures.date("2026-11-24T16:00:00Z"), location: "Dog park",
                                  attendees: [Attendee(address: MailAddress(name: "Sam Lee", email: "sam@contoso.com")),
                                              Attendee(address: MailAddress(email: "pat@contoso.com"), isOptional: true)],
                                  reminderMinutes: [30])
        let saved = try await service(transport, pauses: pauses).create(event, addingConference: true)

        let post = try #require(transport.sent("POST", "\(Self.api)/calendars/AAMkCal1=/events").first)
        #expect(post.value(forHTTPHeaderField: "Prefer") == Self.utcPreference)
        #expect(post.bodyJSONValue == [
            "subject": "Pug playdate",
            "location": ["displayName": "Dog park"],
            "isAllDay": false,
            "start": ["dateTime": "2026-11-24T15:00:00", "timeZone": "UTC"],
            "end": ["dateTime": "2026-11-24T16:00:00", "timeZone": "UTC"],
            "attendees": [
                ["emailAddress": ["address": "sam@contoso.com", "name": "Sam Lee"], "type": "required"],
                ["emailAddress": ["address": "pat@contoso.com"], "type": "optional"],
            ],
            "showAs": "busy",
            "isReminderOn": true, "reminderMinutesBeforeStart": 30,
            "isOnlineMeeting": true, "onlineMeetingProvider": "teamsForBusiness",
        ])
        #expect(transport.sent("GET", "\(Self.api)/events/AAMkNew=").count == 1)
        #expect(pauses.waits == [1])
        #expect(saved.conference?.kind == .teams)
        #expect(saved.conference?.joinURL.absoluteString == "https://teams.microsoft.com/l/meetup-join/pug")
    }

    @Test func allDayEventsAreCreatedAtMidnightInTheMacsZone() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/calendars/AAMkCal1=/events") { _ in
            .json(#"""
            {"id": "AAMkTrip=", "subject": "Trip", "isAllDay": true,
             "start": {"dateTime": "2026-11-26T00:00:00.0000000", "timeZone": "UTC"},
             "end": {"dateTime": "2026-11-27T00:00:00.0000000", "timeZone": "UTC"}, "showAs": "free"}
            """#, status: 201)
        }
        let event = CalendarEvent(calendarID: "AAMkCal1=", title: "Trip", start: WebFixtures.localMidnight(2026, 11, 26),
                                  end: WebFixtures.localMidnight(2026, 11, 27), isAllDay: true, availability: .free)
        let saved = try await service(transport).create(event, addingConference: false)
        let body = try #require(transport.requests.first?.bodyJSONValue)
        let zone = JSONValue.string(TimeZone.current.identifier)
        #expect(body["isAllDay"] == true)
        #expect(body["start"] == ["dateTime": "2026-11-26T00:00:00", "timeZone": zone])
        #expect(body["end"] == ["dateTime": "2026-11-27T00:00:00", "timeZone": zone])
        #expect(body["isOnlineMeeting"].isNull)
        #expect(saved.isAllDay && saved.start == WebFixtures.localMidnight(2026, 11, 26))
        #expect(saved.end == WebFixtures.localMidnight(2026, 11, 27))
    }

    // MARK: Changing

    @Test func updatesPatchTheOccurrenceOrTheSeries() async throws {
        let transport = StubTransport()
        stubEvents(transport)
        let calendar = service(transport)
        let sync = try #require(try await loadEvents(calendar).first)
        transport.on("PATCH", "\(Self.api)/events/") { request in
            var echo = (try? JSONValue.parse(Data(Self.teamsEvent.utf8)))?.object ?? [:]
            echo["subject"] = request.bodyJSONValue["subject"]
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        transport.on("GET", "\(Self.api)/events/AAMkEv1=") { _ in .json(Self.teamsEvent) }

        var edited = sync
        edited.title = "Weekly sync (moved)"
        edited.start = edited.start.addingTimeInterval(3600)
        edited.end = edited.end.addingTimeInterval(3600)
        let one = try await calendar.update(edited, scope: .thisEvent, addingConference: false)
        let first = try #require(transport.sent("PATCH", "\(Self.api)/events/").first)
        #expect(first.url?.path == "\(Self.api)/events/AAMkEv1=")
        #expect(first.bodyJSONValue == ["subject": "Weekly sync (moved)", "isAllDay": false,
                                        "start": ["dateTime": "2026-11-23T19:00:00", "timeZone": "UTC"],
                                        "end": ["dateTime": "2026-11-23T19:30:00", "timeZone": "UTC"]])
        #expect(one.title == "Weekly sync (moved)")

        var everyWeek = sync
        everyWeek.title = "Team sync"
        everyWeek.start = everyWeek.start.addingTimeInterval(3600)
        everyWeek.end = everyWeek.end.addingTimeInterval(3600)
        let all = try await calendar.update(everyWeek, scope: .allEvents, addingConference: false)
        let second = try #require(transport.sent("PATCH", "\(Self.api)/events/").last)
        #expect(second.url?.path == "\(Self.api)/events/AAMkSeries=")
        #expect(second.bodyJSONValue == ["subject": "Team sync"])
        #expect(all.id == "AAMkEv1=")  // The occurrence, fetched again.
        #expect(transport.sent("GET", "\(Self.api)/events/AAMkEv1=").count == 1)
    }

    @Test func deletesPickTheOccurrenceOrTheSeries() async throws {
        let transport = StubTransport()
        transport.on("DELETE", "\(Self.api)/events/") { _ in .status(204) }
        let calendar = service(transport)
        let occurrence = CalendarEvent(id: "AAMkEv1=", calendarID: "AAMkCal1=", start: Date(), end: Date(), seriesID: "AAMkSeries=")
        try await calendar.delete(occurrence, scope: .thisEvent)
        try await calendar.delete(occurrence, scope: .allEvents)
        #expect(transport.requests.compactMap { $0.url?.path } == ["\(Self.api)/events/AAMkEv1=", "\(Self.api)/events/AAMkSeries="])
    }

    @Test func answersUseAcceptTentativelyAcceptAndDecline() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/events/AAMkEv1=/") { _ in .status(202) }
        let calendar = service(transport)
        let event = CalendarEvent(id: "AAMkEv1=", calendarID: "AAMkCal1=", start: Date(), end: Date())
        try await calendar.respond(to: event, with: .accepted)
        try await calendar.respond(to: event, with: .tentative)
        try await calendar.respond(to: event, with: .declined)
        #expect(transport.requests.compactMap { $0.url?.lastPathComponent } == ["accept", "tentativelyAccept", "decline"])
        #expect(transport.requests.allSatisfy { $0.bodyJSONValue == ["sendResponse": true] })
        await #expect(throws: PMailError.notSupported("An answered invitation can’t be set back to unanswered.")) {
            try await calendar.respond(to: event, with: .needsAction)
        }
    }

    /// Deleting a meeting you organized calls it off, so everyone invited gets a cancellation; deleting one you were
    /// invited to just takes it off your calendar.
    @Test func deletingAMeetingYouOrganizedCallsItOff() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/events/AAMkMine=/cancel") { _ in .status(202) }
        transport.on("DELETE", "\(Self.api)/events/AAMkTheirs=") { _ in .status(204) }
        let calendar = service(transport)
        let guests = [Attendee(address: MailAddress(email: "alex@contoso.com"))]
        try await calendar.delete(CalendarEvent(id: "AAMkMine=", calendarID: "AAMkCal1=", start: Date(), end: Date(), attendees: guests),
                                  scope: .thisEvent)
        try await calendar.delete(CalendarEvent(id: "AAMkTheirs=", calendarID: "AAMkCal1=", start: Date(), end: Date(), attendees: guests,
                                                myResponse: .accepted), scope: .thisEvent)
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["POST \(Self.api)/events/AAMkMine=/cancel", "DELETE \(Self.api)/events/AAMkTheirs="])
        #expect(transport.requests.first?.bodyJSONValue == ["comment": ""])
    }

    /// Outlook takes a declined meeting off the calendar, so it's kept and still shown, declined, until the calendar has
    /// it again. Once it's gone from there, the answer can't be changed.
    @Test func declinedMeetingsStayOnTheCalendar() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-declined-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(DeclinedMeetings.fileName)
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/events/AAMkInvite=/decline") { _ in .status(202) }
        transport.on("POST", "\(Self.api)/events/AAMkInvite=/accept") { _ in
            .json(#"{"error": {"code": "ErrorItemNotFound", "message": "The specified object was not found in the store."}}"#, status: 404)
        }
        let listsItAgain = Switch()
        transport.on("GET", "\(Self.api)/calendars/AAMkCal1=/calendarView") { _ in
            guard listsItAgain.isOn else { return .json(#"{"value": []}"#) }
            return .json(#"""
            {"value": [{"id": "AAMkResent=", "subject": "Budget review", "iCalUId": "uid-budget",
                        "start": {"dateTime": "2026-11-25T15:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-25T16:00:00.0000000", "timeZone": "UTC"},
                        "responseStatus": {"response": "notResponded"}}]}
            """#)
        }
        let start = WebFixtures.date("2026-11-25T15:00:00Z")
        let invite = CalendarEvent(id: "AAMkInvite=", calendarID: "AAMkCal1=", title: "Budget review", start: start,
                                   end: start.addingTimeInterval(3_600), myResponse: .needsAction, uid: "uid-budget")
        try await service(transport, declinedFile: file).respond(to: invite, with: .declined)

        // After relaunching: Outlook has taken it off the calendar, and PMail still shows it, declined.
        let calendar = service(transport, declinedFile: file)
        let week = (WebFixtures.date("2026-11-22T00:00:00Z"), WebFixtures.date("2026-11-29T00:00:00Z"))
        let shown = try await calendar.loadEvents(in: ["AAMkCal1="], from: week.0, to: week.1)
        #expect(shown.map(\.id) == ["AAMkInvite="] && shown.first?.myResponse == .declined && shown.first?.title == "Budget review")
        #expect(try await calendar.loadEvents(in: ["AAMkCal2="], from: week.0, to: week.1).isEmpty, "only on its own calendar")
        await #expect(throws: PMailError.self) { try await calendar.respond(to: invite, with: .accepted) }
        #expect(try await calendar.loadEvents(in: ["AAMkCal1="], from: week.0, to: week.1).first?.myResponse == .declined, "still declined")

        // The organizer sends it again: the calendar's own copy shows, waiting for an answer, and the kept one goes.
        listsItAgain.isOn = true
        let resent = try await calendar.loadEvents(in: ["AAMkCal1="], from: week.0, to: week.1)
        #expect(resent.map(\.id) == ["AAMkResent="] && resent.first?.myResponse == .needsAction)
        listsItAgain.isOn = false
        #expect(try await calendar.loadEvents(in: ["AAMkCal1="], from: week.0, to: week.1).isEmpty)
    }

    @Test func throttledCalendarRequestsAreRetried() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "\(Self.api)/calendars") { _ in
            transport.requests.count == 1
                ? StubTransport.Response(status: 429, body: Data(#"""
                {"error": {"code": "TooManyRequests", "message": "Please retry again later."}}
                """#.utf8),
                                         headers: ["Retry-After": "4"])
                : .json(#"{"value": [{"id": "AAMkCal1=", "name": "Calendar", "isDefaultCalendar": true, "canEdit": true}]}"#)
        }
        let calendars = try await service(transport, pauses: pauses).loadCalendars()
        #expect(calendars.map(\.id) == ["AAMkCal1="] && pauses.waits == [4])
    }
}

/// A switch a test flips while a stub reads it.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
