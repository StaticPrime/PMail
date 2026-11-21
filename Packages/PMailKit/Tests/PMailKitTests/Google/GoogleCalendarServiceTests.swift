import Foundation
import Testing
@testable import PMailKit

@Suite struct GoogleCalendarServiceTests {
    static let api = "/calendar/v3"
    static let primary = "jamie@gmail.com"
    static let events = "/calendar/v3/calendars/jamie@gmail.com/events"

    private func service(_ transport: StubTransport, pauses: WebTestPauses = WebTestPauses(),
                         tokens: WebTestTokens = WebTestTokens()) -> GoogleCalendarService {
        GoogleCalendarService(client: .test(transport, tokens: tokens, pauses: pauses))
    }

    // MARK: Calendars

    @Test func calendarListMapsColorsAccessAndMeet() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/users/me/calendarList") { request in
            request.query("pageToken") == nil ? .json(#"""
            {"kind": "calendar#calendarList", "nextPageToken": "p2", "items": [
                {"kind": "calendar#calendarListEntry", "id": "jamie@gmail.com", "summary": "jamie@gmail.com",
                 "timeZone": "America/New_York",
                 "colorId": "14", "backgroundColor": "#9fe1e7", "foregroundColor": "#000000", "selected": true,
                  "accessRole": "owner",
                 "defaultReminders": [{"method": "popup", "minutes": 10}, {"method": "email", "minutes": 60}],
                 "conferenceProperties": {"allowedConferenceSolutionTypes": ["hangoutsMeet"]}, "primary": true},
                {"id": "family123@group.calendar.google.com", "summary": "Family", "summaryOverride": "Rivera family",
                 "backgroundColor": "#f83a22", "accessRole": "writer",
                 "conferenceProperties": {"allowedConferenceSolutionTypes": ["hangoutsMeet"]}},
                {"id": "en.usa#holiday@group.v.calendar.google.com", "summary": "Holidays in United States",
                 "backgroundColor": "#16a765", "accessRole": "reader",
                  "conferenceProperties": {"allowedConferenceSolutionTypes": []}}
            ]}
            """#) : .json(##"""
            {"items": [{"id": "alex@example.com", "summary": "Alex Kim", "accessRole": "freeBusyReader", "backgroundColor": "#cabdbf"}]}
            """##)
        }
        let calendars = try await service(transport).loadCalendars()
        #expect(calendars == [
            CalendarInfo(id: "jamie@gmail.com", name: "jamie@gmail.com", colorHex: "#9FE1E7", isPrimary: true, nativeConference: .meet),
            CalendarInfo(id: "family123@group.calendar.google.com", name: "Rivera family", colorHex: "#F83A22", nativeConference: .meet),
            CalendarInfo(id: "en.usa#holiday@group.v.calendar.google.com", name: "Holidays in United States", colorHex: "#16A765",
                         isReadOnly: true, isOther: true),
            CalendarInfo(id: "alex@example.com", name: "Alex Kim", colorHex: "#CABDBF", isReadOnly: true, isOther: true),
        ])
        #expect(transport.requests.map { $0.query("pageToken") } == [nil, "p2"])
    }

    // MARK: Events

    static let eventList = #"""
    {"kind": "calendar#events", "summary": "jamie@gmail.com", "timeZone": "America/New_York",
     "defaultReminders": [{"method": "popup", "minutes": 10}, {"method": "email", "minutes": 30}],
     "items": [
        {"kind": "calendar#event", "etag": "\"3461234567890000\"", "id": "meet1", "status": "confirmed",
         "htmlLink": "https://www.google.com/calendar/event?eid=bWVldDE", "summary": "Design review",
         "description": "<p>Agenda:</p><ul><li>Icons</li></ul><br>Notes &amp; links", "location": "Room 4", "colorId": "5",
         "creator": {"email": "alex@example.com"}, "organizer": {"email": "alex@example.com", "displayName": "Alex Kim"},
         "start": {"dateTime": "2026-11-23T10:00:00-05:00", "timeZone": "America/New_York"},
         "end": {"dateTime": "2026-11-23T11:00:00-05:00", "timeZone": "America/New_York"},
         "iCalUID": "meet1@google.com", "sequence": 0,
         "attendees": [
            {"email": "alex@example.com", "displayName": "Alex Kim", "organizer": true, "responseStatus": "accepted"},
            {"email": "jamie@gmail.com", "self": true, "responseStatus": "tentative"},
            {"email": "sam@example.com", "optional": true, "responseStatus": "needsAction"}
         ],
         "hangoutLink": "https://meet.google.com/abc-defg-hij",
         "conferenceData": {
            "entryPoints": [
                {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij",
                 "label": "meet.google.com/abc-defg-hij"},
                {"entryPointType": "phone", "uri": "tel:+1-612-555-0100", "label": "+1 612-555-0100", "pin": "123456789",
                 "regionCode": "US"},
                {"entryPointType": "more", "uri": "https://tel.meet/abc-defg-hij?pin=123456789", "pin": "123456789"}
            ],
            "conferenceSolution": {"key": {"type": "hangoutsMeet"}, "name": "Google Meet"},
            "conferenceId": "abc-defg-hij"
         },
         "reminders": {"useDefault": true}},
        {"id": "allday1", "status": "confirmed", "summary": "Thanksgiving trip", "start": {"date": "2026-11-26"},
         "end": {"date": "2026-11-29"},
         "transparency": "transparent",
         "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 1440}, {"method": "email",
          "minutes": 2880}]}},
        {"id": "standup_20261124T140000Z", "status": "confirmed", "summary": "Standup", "recurringEventId": "standup",
         "originalStartTime": {"dateTime": "2026-11-24T09:00:00-05:00", "timeZone": "America/New_York"},
         "start": {"dateTime": "2026-11-24T14:00:00Z"}, "end": {"dateTime": "2026-11-24T14:15:00Z"},
         "location": "https://zoom.us/j/123456789", "reminders": {"useDefault": false}},
        {"id": "broken", "summary": "No start at all"}
     ]}
    """#

    private func stubEvents(_ transport: StubTransport) {
        transport.on("GET", Self.events) { _ in .json(Self.eventList) }
        transport.on("GET", "\(Self.events)/standup") { _ in
            .json(#"{"id": "standup", "summary": "Standup", "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]}"#)
        }
        transport.on("GET", "\(Self.api)/colors") { _ in
            .json(#"""
            {"kind": "calendar#colors", "calendar": {"1": {"background": "#ac725e", "foreground": "#1d1d1d"}},
             "event": {"5": {"background": "#fbd75b", "foreground": "#1d1d1d"}, "11": {"background": "#dc2127", "foreground": "#1d1d1d"}}}
            """#)
        }
    }

    @Test func eventsMapTimesGuestsMeetAndReminders() async throws {
        let transport = StubTransport()
        stubEvents(transport)
        let calendar = service(transport)
        let events = try await calendar.loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                   to: WebFixtures.date("2026-11-30T00:00:00Z"))

        let list = try #require(transport.sent("GET", Self.events).first)
        #expect(list.query("timeMin") == "2026-11-22T00:00:00Z" && list.query("timeMax") == "2026-11-30T00:00:00Z")
        #expect(list.query("singleEvents") == "true" && list.query("orderBy") == "startTime" && list.query("maxResults") == "2500")
        #expect(events.map(\.id) == ["meet1", "standup_20261124T140000Z", "allday1"])

        let review = events[0]
        #expect(review.calendarID == Self.primary && review.title == "Design review")
        #expect(review.start == WebFixtures.date("2026-11-23T15:00:00Z") && review.end == WebFixtures.date("2026-11-23T16:00:00Z"))
        #expect(!review.isAllDay && review.timeZone == "America/New_York")
        #expect(review.notes == "Agenda:\nIcons\n\nNotes & links")
        #expect(review.location == "Room 4")
        #expect(review.colorHex == "#FBD75B")
        #expect(review.organizer == MailAddress(name: "Alex Kim", email: "alex@example.com"))
        #expect(review.attendees == [
            Attendee(address: MailAddress(name: "Alex Kim", email: "alex@example.com"), response: .accepted, isOrganizer: true),
            Attendee(address: MailAddress(email: "jamie@gmail.com"), response: .tentative),
            Attendee(address: MailAddress(email: "sam@example.com"), response: .needsAction, isOptional: true),
        ])
        #expect(review.myResponse == .tentative)
        #expect(review.conference == Conference(kind: .meet, joinURL: try #require(URL(string: "https://meet.google.com/abc-defg-hij")),
                                                meetingCode: "abc-defg-hij", phoneNumbers: ["+1 612-555-0100 PIN: 123456789#"]))
        #expect(review.reminderMinutes == [10])  // The calendar's pop-up default.
        #expect(review.webLink?.absoluteString == "https://www.google.com/calendar/event?eid=bWVldDE")
        #expect(review.uid == "meet1@google.com" && review.etag == "\"3461234567890000\"")
        #expect(review.status == .confirmed && review.availability == .busy && !review.isRecurring)

        let standup = events[1]
        #expect(standup.seriesID == "standup" && standup.occurrenceDate == WebFixtures.date("2026-11-24T14:00:00Z"))
        #expect(standup.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
        #expect(standup.conference?.kind == .zoom)
        #expect(standup.reminderMinutes.isEmpty)

        let trip = events[2]
        #expect(trip.isAllDay)
        #expect(trip.start == WebFixtures.localMidnight(2026, 11, 26) && trip.end == WebFixtures.localMidnight(2026, 11, 29))
        #expect(trip.availability == .free && trip.reminderMinutes == [1440] && trip.myResponse == nil)

        // The colors and each series are fetched once, however often events load.
        _ = try await calendar.loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                          to: WebFixtures.date("2026-11-30T00:00:00Z"))
        #expect(transport.sent("GET", "\(Self.api)/colors").count == 1)
        #expect(transport.sent("GET", "\(Self.events)/standup").count == 1)
    }

    @Test func calendarIDsAreEscapedInPaths() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/calendars/") { _ in .json(#"{"items": []}"#) }
        _ = try await service(transport).loadEvents(in: ["en.usa#holiday@group.v.calendar.google.com"], from: Date(),
                                                    to: Date().addingTimeInterval(86_400))
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/en.usa%23holiday@group.v.calendar.google.com/events?"))
    }

    // MARK: Creating

    @Test func creatingWithMeetWaitsForTheJoinLink() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        let pending = #"{"id": "new1", "summary": "Pug playdate", "start": {"dateTime": "2026-11-24T15:00:00Z"}, "#
            + #""end": {"dateTime": "2026-11-24T16:00:00Z"}, "conferenceData": {"createRequest": {"requestId": "r", "#
            + #""conferenceSolutionKey": {"type": "hangoutsMeet"}, "status": {"statusCode": "pending"}}}}"#
        transport.on("POST", Self.events) { _ in .json(pending) }
        transport.on("GET", "\(Self.events)/new1") { _ in
            transport.sent("GET", "\(Self.events)/new1").count < 2 ? .json(pending) : .json(#"""
            {"id": "new1", "summary": "Pug playdate", "start": {"dateTime": "2026-11-24T15:00:00Z"},
             "end": {"dateTime": "2026-11-24T16:00:00Z"},
             "hangoutLink": "https://meet.google.com/pug-play-date",
             "conferenceData": {"createRequest": {"requestId": "r", "conferenceSolutionKey": {"type": "hangoutsMeet"},
              "status": {"statusCode": "success"}},
                "entryPoints": [{"entryPointType": "video", "uri": "https://meet.google.com/pug-play-date",
                 "label": "meet.google.com/pug-play-date"}],
                "conferenceSolution": {"key": {"type": "hangoutsMeet"}, "name": "Google Meet"}, "conferenceId": "pug-play-date"}}
            """#)
        }
        let event = CalendarEvent(calendarID: Self.primary, title: "Pug playdate", start: WebFixtures.date("2026-11-24T15:00:00Z"),
                                  end: WebFixtures.date("2026-11-24T16:00:00Z"), timeZone: "America/New_York",
                                  attendees: [Attendee(address: MailAddress(name: "Sam Lee", email: "sam@example.com"), isOptional: true)])
        let saved = try await service(transport, pauses: pauses).create(event, addingConference: true)

        let post = try #require(transport.sent("POST", Self.events).first)
        #expect(post.query("conferenceDataVersion") == "1" && post.query("sendUpdates") == "all")
        let body = post.bodyJSONValue
        #expect(body["conferenceData"]["createRequest"]["conferenceSolutionKey"] == ["type": "hangoutsMeet"])
        #expect(UUID(uuidString: body["conferenceData"]["createRequest"]["requestId"].string ?? "") != nil)
        #expect(body["summary"].string == "Pug playdate")
        #expect(body["start"] == ["dateTime": "2026-11-24T15:00:00Z", "timeZone": "America/New_York"])
        #expect(body["end"] == ["dateTime": "2026-11-24T16:00:00Z", "timeZone": "America/New_York"])
        #expect(body["attendees"] == [["email": "sam@example.com", "displayName": "Sam Lee", "optional": true,
                                       "responseStatus": "needsAction"]])
        #expect(body["reminders"] == ["useDefault": true])
        #expect(body["location"].isNull && body["description"].isNull)

        #expect(transport.sent("GET", "\(Self.events)/new1").count == 2)
        #expect(pauses.waits == [1, 1])
        #expect(saved.id == "new1")
        #expect(saved.conference?.kind == .meet && saved.conference?.joinURL.absoluteString == "https://meet.google.com/pug-play-date")
        #expect(saved.conference?.meetingCode == "pug-play-date")
    }

    @Test func creatingAnAllDayEventSendsDatesAndAPastedLink() async throws {
        let transport = StubTransport()
        transport.on("POST", Self.events) { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "trip2"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let faceTime = try #require(URL(string: "https://facetime.apple.com/join#v=1&p=abc&k=def"))
        let event = CalendarEvent(calendarID: Self.primary, title: "Trip", start: WebFixtures.localMidnight(2026, 11, 26),
                                  end: WebFixtures.localMidnight(2026, 11, 29), isAllDay: true,
                                  conference: Conference(kind: .faceTime, joinURL: faceTime), availability: .free,
                                  reminderMinutes: [60, 1440])
        let saved = try await service(transport).create(event, addingConference: false)
        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body["start"] == ["date": "2026-11-26"] && body["end"] == ["date": "2026-11-29"])
        #expect(body["transparency"] == "transparent")
        #expect(body["reminders"] == ["useDefault": false,
                                      "overrides": [["method": "popup", "minutes": 60], ["method": "popup", "minutes": 1440]]])
        #expect(body["location"].string == faceTime.absoluteString)
        #expect(body["conferenceData"].isNull)
        #expect(saved.isAllDay && saved.start == WebFixtures.localMidnight(2026, 11, 26) && saved.conference?.kind == .faceTime)
    }

    // MARK: Changing

    private func loadedStandup(_ transport: StubTransport) async throws -> (GoogleCalendarService, CalendarEvent) {
        stubEvents(transport)
        let calendar = service(transport)
        let events = try await calendar.loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                   to: WebFixtures.date("2026-11-30T00:00:00Z"))
        return (calendar, try #require(events.first { $0.seriesID == "standup" }))
    }

    @Test func changingOneOccurrencePatchesItsOwnIDWithOnlyWhatChanged() async throws {
        let transport = StubTransport()
        let (calendar, standup) = try await loadedStandup(transport)
        transport.on("PATCH", "\(Self.events)/standup_20261124T140000Z") { _ in
            .json(#"{"id": "standup_20261124T140000Z", "summary": "Standup (short)", "recurringEventId": "standup", "#
                  + #""start": {"dateTime": "2026-11-24T14:30:00Z"}, "end": {"dateTime": "2026-11-24T14:45:00Z"}}"#)
        }
        var edited = standup
        edited.title = "Standup (short)"
        edited.start = WebFixtures.date("2026-11-24T14:30:00Z")
        edited.end = WebFixtures.date("2026-11-24T14:45:00Z")
        let saved = try await calendar.update(edited, scope: .thisEvent, addingConference: false)

        let patch = try #require(transport.sent("PATCH", "\(Self.events)/standup_20261124T140000Z").first)
        #expect(patch.query("sendUpdates") == "all")
        #expect(patch.bodyJSONValue == [
            "summary": "Standup (short)",
            "start": ["dateTime": "2026-11-24T14:30:00Z", "timeZone": .string(TimeZone.current.identifier), "date": .null],
            "end": ["dateTime": "2026-11-24T14:45:00Z", "timeZone": .string(TimeZone.current.identifier), "date": .null],
        ])
        #expect(saved.title == "Standup (short)" && saved.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
    }

    @Test func changingEveryOccurrencePatchesTheSeriesWithoutTimes() async throws {
        let transport = StubTransport()
        let (calendar, standup) = try await loadedStandup(transport)
        transport.on("PATCH", "\(Self.events)/standup") { _ in
            .json(#"{"id": "standup", "summary": "Team standup", "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"]}"#)
        }
        transport.on("GET", "\(Self.events)/standup_20261124T140000Z") { _ in
            .json(#"{"id": "standup_20261124T140000Z", "summary": "Team standup", "recurringEventId": "standup", "#
                  + #""start": {"dateTime": "2026-11-24T14:00:00Z"}, "end": {"dateTime": "2026-11-24T14:15:00Z"}}"#)
        }
        var edited = standup
        edited.title = "Team standup"
        edited.start = edited.start.addingTimeInterval(1800)
        edited.end = edited.end.addingTimeInterval(1800)
        let saved = try await calendar.update(edited, scope: .allEvents, addingConference: false)

        let patch = try #require(transport.sent("PATCH", "\(Self.events)/standup").first)
        #expect(patch.url?.path == "\(Self.events)/standup")
        #expect(patch.bodyJSONValue == ["summary": "Team standup"])
        #expect(saved.id == "standup_20261124T140000Z" && saved.title == "Team standup")
        #expect(saved.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
    }

    @Test func deletingPicksTheOccurrenceOrTheSeries() async throws {
        let transport = StubTransport()
        transport.on("DELETE", "\(Self.events)/") { _ in .status(204) }
        transport.on("DELETE", "\(Self.events)/gone") { _ in .json(#"""
        {"error": {"code": 410, "message": "Resource has been deleted"}}
        """#, status: 410) }
        let calendar = service(transport)
        let occurrence = CalendarEvent(id: "standup_20261124T140000Z", calendarID: Self.primary, start: Date(), end: Date(),
                                       seriesID: "standup")
        try await calendar.delete(occurrence, scope: .thisEvent)
        try await calendar.delete(occurrence, scope: .allEvents)
        try await calendar.delete(CalendarEvent(id: "gone", calendarID: Self.primary, start: Date(), end: Date()), scope: .allEvents)
        #expect(transport.requests.compactMap { $0.url?.path } == ["\(Self.events)/standup_20261124T140000Z", "\(Self.events)/standup",
                                                                    "\(Self.events)/gone"])
        #expect(transport.requests.allSatisfy { $0.query("sendUpdates") == "all" })
    }

    @Test func respondingChangesOnlyTheOwnersAnswer() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.events)/meet1") { _ in
            .json(#"""
            {"id": "meet1", "attendees": [
                {"email": "alex@example.com", "displayName": "Alex Kim", "organizer": true, "responseStatus": "accepted"},
                {"email": "jamie@gmail.com", "self": true, "responseStatus": "needsAction"},
                {"email": "room4@resource.calendar.google.com", "displayName": "Room 4", "resource": true,
                 "responseStatus": "accepted"}
            ]}
            """#)
        }
        transport.on("PATCH", "\(Self.events)/meet1") { _ in .json(#"{"id": "meet1"}"#) }
        let event = CalendarEvent(id: "meet1", calendarID: Self.primary, start: Date(), end: Date())
        try await service(transport).respond(to: event, with: .accepted)
        let patch = try #require(transport.sent("PATCH", "\(Self.events)/meet1").first)
        #expect(patch.query("sendUpdates") == "all")
        #expect(patch.bodyJSONValue == ["attendees": [
            ["email": "alex@example.com", "displayName": "Alex Kim", "organizer": true, "responseStatus": "accepted"],
            ["email": "jamie@gmail.com", "self": true, "responseStatus": "accepted"],
            ["email": "room4@resource.calendar.google.com", "displayName": "Room 4", "resource": true, "responseStatus": "accepted"],
        ]])
    }

    @Test func busyCalendarAnswersAreRetried() async throws {
        let transport = StubTransport()
        let pauses = WebTestPauses()
        transport.on("GET", "\(Self.api)/users/me/calendarList") { _ in
            transport.requests.count == 1 ? StubTransport.Response(status: 429, body: Data(), headers: ["Retry-After": "1"])
                : .json(#"{"items": [{"id": "jamie@gmail.com", "summary": "Jamie", "accessRole": "owner", "primary": true}]}"#)
        }
        let calendars = try await service(transport, pauses: pauses).loadCalendars()
        #expect(calendars.map(\.id) == ["jamie@gmail.com"])
        #expect(pauses.waits == [1])
    }
}
