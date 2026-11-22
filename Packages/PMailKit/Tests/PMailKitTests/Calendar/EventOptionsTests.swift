import Foundation
import Testing
@testable import PMailKit

/// Repeating, visibility, guest permissions and busy times on Google calendars.
@Suite struct GoogleEventOptionsTests {
    static let primary = "jamie@acme.example"
    static let events = "/calendar/v3/calendars/jamie@acme.example/events"
    private let start = WebFixtures.date("2026-11-23T15:00:00Z")

    private func echoing(_ transport: StubTransport) {
        transport.on("POST", Self.events) { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "made"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
    }

    @Test func visibilityAndGuestPermissionsAreReadAndSent() async throws {
        let transport = StubTransport()
        transport.on("GET", Self.events) { _ in
            .json(#"""
            {"items": [
              {"id": "private", "summary": "Interview", "visibility": "private", "guestsCanModify": true, "guestsCanInviteOthers": false,
               "guestsCanSeeOtherGuests": false, "start": {"dateTime": "2026-11-24T14:00:00Z"}, "end": {"dateTime": "2026-11-24T15:00:00Z"}},
              {"id": "secret", "summary": "Board", "visibility": "confidential",
               "start": {"dateTime": "2026-11-25T14:00:00Z"}, "end": {"dateTime": "2026-11-25T15:00:00Z"}},
              {"id": "plain", "summary": "Lunch", "start": {"dateTime": "2026-11-26T14:00:00Z"}, "end": {"dateTime": "2026-11-26T15:00:00Z"}}
            ]}
            """#)
        }
        let events = try await GoogleCalendarService(client: .test(transport))
            .loadEvents(in: [Self.primary], from: WebFixtures.date("2026-11-22T00:00:00Z"), to: WebFixtures.date("2026-11-30T00:00:00Z"))
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        #expect(byID["private"]?.visibility == .private && byID["private"]?.guestsCanModify == true)
        #expect(byID["private"]?.guestsCanInviteOthers == false && byID["private"]?.guestsCanSeeOtherGuests == false)
        #expect(byID["secret"]?.visibility == .private, "confidential shows as private")
        let plain = try #require(byID["plain"])
        #expect(plain.visibility == .default && !plain.guestsCanModify && plain.guestsCanInviteOthers && plain.guestsCanSeeOtherGuests)

        echoing(transport)
        let calendar = GoogleCalendarService(client: .test(transport))
        _ = try await calendar.create(CalendarEvent(calendarID: Self.primary, title: "Usual", start: start, end: start.addingTimeInterval(3_600)),
                                      addingConference: false)
        let usual = try #require(transport.sent("POST", Self.events).last?.bodyJSONValue)
        #expect(usual["visibility"].isNull && usual["guestsCanModify"].isNull && usual["guestsCanInviteOthers"].isNull
                && usual["guestsCanSeeOtherGuests"].isNull, "the usual settings aren't sent")
        _ = try await calendar.create(CalendarEvent(calendarID: Self.primary, title: "Quiet", start: start, end: start.addingTimeInterval(3_600),
                                                    visibility: .private, guestsCanModify: true, guestsCanInviteOthers: false,
                                                    guestsCanSeeOtherGuests: false), addingConference: false)
        let quiet = try #require(transport.sent("POST", Self.events).last?.bodyJSONValue)
        #expect(quiet["visibility"] == "private" && quiet["guestsCanModify"] == true && quiet["guestsCanInviteOthers"] == false
                && quiet["guestsCanSeeOtherGuests"] == false)
    }

    @Test func aRepeatingEventSendsItsRule() async throws {
        let transport = StubTransport()
        echoing(transport)
        _ = try await GoogleCalendarService(client: .test(transport))
            .create(CalendarEvent(calendarID: Self.primary, title: "Standup", start: start, end: start.addingTimeInterval(900),
                                  recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10"]), addingConference: false)
        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10"])
        #expect(body["start"]["timeZone"].string == TimeZone.current.identifier, "in its time zone, which repeating events need")
    }

    @Test func busyTimesComeFromTheFreeBusyLookup() async throws {
        let transport = StubTransport()
        transport.on("POST", "/calendar/v3/freeBusy") { _ in
            .json(#"""
            {"calendars": {
              "alex@acme.example": {"busy": [{"start": "2026-11-23T17:00:00Z", "end": "2026-11-23T18:00:00Z"},
                                             {"start": "2026-11-23T14:00:00Z", "end": "2026-11-23T15:00:00Z"}]},
              "sam@elsewhere.example": {"errors": [{"domain": "global", "reason": "notFound"}], "busy": []}
            }}
            """#)
        }
        let found = try await GoogleCalendarService(client: .test(transport))
            .freeBusy(for: ["Alex@acme.example", "sam@elsewhere.example", "kim@acme.example"], from: start, to: start.addingTimeInterval(86_400))
        let request = try #require(transport.requests.first)
        #expect(request.bodyJSONValue["items"] == [["id": "Alex@acme.example"], ["id": "sam@elsewhere.example"], ["id": "kim@acme.example"]])
        #expect(found["Alex@acme.example"]?.busy.map(\.start) == [WebFixtures.date("2026-11-23T14:00:00Z"), WebFixtures.date("2026-11-23T17:00:00Z")],
                "in order, whatever the address's case")
        #expect(found["sam@elsewhere.example"]?.problem == "Their calendar isn’t shared with you.")
        #expect(found["kim@acme.example"]?.problem != nil, "someone missing from the answer isn't known")
    }
}

/// Repeating, visibility, the guest list and busy times on Microsoft calendars.
@Suite struct MicrosoftEventOptionsTests {
    static let api = "/v1.0/me"
    private let start = WebFixtures.date("2026-11-23T15:00:00Z")

    @Test func graphsPatternsBecomeRules() {
        func lines(_ json: String, allDay: Bool = true) -> [String] {
            MicrosoftCalendarService.recurrenceLines(from: (try? JSONValue.parse(Data(json.utf8))) ?? .null, start: start, isAllDay: allDay)
        }
        #expect(lines(#"{"pattern": {"type": "weekly", "interval": 2, "daysOfWeek": ["monday", "wednesday"]}, "range": {"type": "numbered", "numberOfOccurrences": 13}}"#)
                == ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=13"])
        #expect(lines(#"{"pattern": {"type": "relativeMonthly", "interval": 1, "daysOfWeek": ["friday"], "index": "last"}, "range": {"type": "noEnd"}}"#)
                == ["RRULE:FREQ=MONTHLY;BYDAY=-1FR"])
        #expect(lines(#"{"pattern": {"type": "absoluteYearly", "interval": 1, "month": 11, "dayOfMonth": 23}, "range": {"type": "endDate", "endDate": "2030-11-23"}}"#)
                == ["RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=23;UNTIL=20301123"])
        #expect(lines(#"{"pattern": {"type": "daily", "interval": 3}, "range": {"type": "noEnd"}}"#) == ["RRULE:FREQ=DAILY;INTERVAL=3"])
        #expect(lines("null").isEmpty)
    }

    @Test func rulesBecomeGraphsPatterns() throws {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let weekly = try #require(MicrosoftCalendarService.recurrenceJSON(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=13"], start: start,
                                                                          isAllDay: false, zone: zone))
        #expect(weekly["pattern"] == ["interval": 2, "type": "weekly", "daysOfWeek": ["monday", "wednesday"], "firstDayOfWeek": "sunday"])
        #expect(weekly["range"] == ["type": "numbered", "numberOfOccurrences": 13, "startDate": "2026-11-23", "recurrenceTimeZone": "America/New_York"])
        let lastFriday = try #require(MicrosoftCalendarService.recurrenceJSON(["RRULE:FREQ=MONTHLY;BYDAY=-1FR"], start: start, isAllDay: false, zone: zone))
        #expect(lastFriday["pattern"]["type"] == "relativeMonthly" && lastFriday["pattern"]["index"] == "last"
                && lastFriday["pattern"]["daysOfWeek"] == ["friday"])
        #expect(MicrosoftCalendarService.recurrenceJSON(["RRULE:FREQ=HOURLY"], start: start, isAllDay: false, zone: zone) == nil)
    }

    @Test func occurrencesSayHowTheirSeriesRepeats() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/calendars/AAMkCal1=/calendarView") { _ in
            .json(#"""
            {"value": [{"id": "AAMkOcc1=", "subject": "Sync", "seriesMasterId": "AAMkSeries=", "type": "occurrence",
                        "start": {"dateTime": "2026-11-23T15:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-23T15:30:00.0000000", "timeZone": "UTC"}},
                       {"id": "AAMkOcc2=", "subject": "Sync", "seriesMasterId": "AAMkSeries=", "type": "occurrence",
                        "start": {"dateTime": "2026-11-30T15:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-11-30T15:30:00.0000000", "timeZone": "UTC"}}]}
            """#)
        }
        transport.on("GET", "\(Self.api)/events/AAMkSeries=") { _ in
            .json(#"""
            {"id": "AAMkSeries=", "isAllDay": false, "start": {"dateTime": "2026-11-16T15:00:00.0000000", "timeZone": "UTC"},
             "recurrence": {"pattern": {"type": "weekly", "interval": 1, "daysOfWeek": ["monday"]}, "range": {"type": "noEnd"}}}
            """#)
        }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        let range = (WebFixtures.date("2026-11-22T00:00:00Z"), WebFixtures.date("2026-12-07T00:00:00Z"))
        let events = try await calendar.loadEvents(in: ["AAMkCal1="], from: range.0, to: range.1)
        #expect(events.map(\.recurrence) == [["RRULE:FREQ=WEEKLY;BYDAY=MO"], ["RRULE:FREQ=WEEKLY;BYDAY=MO"]])
        _ = try await calendar.loadEvents(in: ["AAMkCal1="], from: range.0, to: range.1)
        #expect(transport.sent("GET", "\(Self.api)/events/AAMkSeries=").count == 1, "each series is asked about once")

        // Changing the rule for all of them starts it where the series starts.
        transport.on("PATCH", "\(Self.api)/events/AAMkSeries=") { _ in .json(#"{"id": "AAMkSeries="}"#) }
        transport.on("GET", "\(Self.api)/events/AAMkOcc2=") { _ in
            .json(#"{"id": "AAMkOcc2=", "subject": "Sync", "seriesMasterId": "AAMkSeries=", "start": {"dateTime": "2026-11-30T15:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-11-30T15:30:00.0000000", "timeZone": "UTC"}}"#)
        }
        var second = try #require(events.last)
        second.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=6"]
        _ = try await calendar.update(second, scope: .allEvents, addingConference: false)
        let patch = try #require(transport.sent("PATCH", "\(Self.api)/events/AAMkSeries=").first?.bodyJSONValue)
        #expect(patch["recurrence"]["range"]["type"] == "numbered" && patch["recurrence"]["range"]["numberOfOccurrences"] == 6)
        #expect(patch["recurrence"]["range"]["startDate"].string == WebDate.dateTimeString(WebFixtures.date("2026-11-16T15:00:00Z"), in: .current)
            .prefix(10).description, "from the series' own start, not the occurrence's")
    }

    @Test func aRepeatingEventIsMadeInTheMacsTimeZone() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/calendars/AAMkCal1=/events") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "AAMkNew="
            echo["start"] = ["dateTime": "2026-11-23T15:00:00.0000000", "timeZone": "UTC"]
            echo["end"] = ["dateTime": "2026-11-23T16:00:00.0000000", "timeZone": "UTC"]
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        _ = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "Review", start: start, end: start.addingTimeInterval(3_600),
                                                    recurrence: ["RRULE:FREQ=MONTHLY;BYDAY=4MO"], visibility: .private,
                                                    guestsCanSeeOtherGuests: false), addingConference: false)
        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body["start"]["timeZone"].string == TimeZone.current.identifier, "so its time of day stays put across daylight saving changes")
        #expect(body["recurrence"]["pattern"]["type"] == "relativeMonthly" && body["recurrence"]["pattern"]["index"] == "fourth")
        #expect(body["sensitivity"] == "private" && body["hideAttendees"] == true)
        _ = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "One-off", start: start, end: start.addingTimeInterval(3_600)),
                                      addingConference: false)
        let plain = try #require(transport.requests.last?.bodyJSONValue)
        #expect(plain["start"]["timeZone"] == "UTC" && plain["recurrence"].isNull && plain["sensitivity"].isNull && plain["hideAttendees"].isNull)
    }

    @Test func visibilityAndTheGuestListAreRead() {
        let json = (try? JSONValue.parse(Data(#"""
        {"id": "AAMkP=", "subject": "Private", "sensitivity": "private", "hideAttendees": true,
         "start": {"dateTime": "2026-11-23T15:00:00.0000000", "timeZone": "UTC"}, "end": {"dateTime": "2026-11-23T16:00:00.0000000", "timeZone": "UTC"}}
        """#.utf8))) ?? .null
        let event = MicrosoftCalendarService.event(from: json, calendarID: "AAMkCal1=")
        #expect(event?.visibility == .private && event?.guestsCanSeeOtherGuests == false)
    }

    @Test func busyTimesComeFromSchedules() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/calendar/getSchedule") { _ in
            .json(#"""
            {"value": [
              {"scheduleId": "alex@contoso.example", "scheduleItems": [
                 {"status": "busy", "start": {"dateTime": "2026-11-23T17:00:00.0000000", "timeZone": "UTC"},
                  "end": {"dateTime": "2026-11-23T18:00:00.0000000", "timeZone": "UTC"}},
                 {"status": "free", "start": {"dateTime": "2026-11-23T19:00:00.0000000", "timeZone": "UTC"},
                  "end": {"dateTime": "2026-11-23T20:00:00.0000000", "timeZone": "UTC"}},
                 {"status": "oof", "start": {"dateTime": "2026-11-24T00:00:00.0000000", "timeZone": "UTC"},
                  "end": {"dateTime": "2026-11-25T00:00:00.0000000", "timeZone": "UTC"}}]},
              {"scheduleId": "kim@fabrikam.example", "error": {"message": "Free/busy isn't shared.", "responseCode": "ErrorFreeBusyAccess"}}
            ]}
            """#)
        }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        let found = try await calendar.freeBusy(for: ["alex@contoso.example", "kim@fabrikam.example"], from: start, to: start.addingTimeInterval(2 * 86_400))
        #expect(found["alex@contoso.example"]?.busy.count == 2, "busy and out of office, not free")
        #expect(found["kim@fabrikam.example"]?.problem == "Free/busy isn't shared.")
        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body["schedules"] == ["alex@contoso.example", "kim@fabrikam.example"] && body["startTime"]["timeZone"] == "UTC")

        let personal = StubTransport()
        personal.on("POST", "\(Self.api)/calendar/getSchedule") { _ in
            .json(#"{"error": {"code": "ErrorInvalidRequest", "message": "Not supported for personal accounts."}}"#, status: 400)
        }
        let refused = try await MicrosoftCalendarService(client: .test(personal)).freeBusy(for: ["a@b.example"], from: start, to: start.addingTimeInterval(3_600))
        #expect(refused["a@b.example"]?.problem?.contains("work and school") == true)
    }
}

/// Visibility in iCalendar files (CLASS).
struct ICalendarVisibilityTests {
    @Test func classIsReadAndWritten() throws {
        let text = ICS.calendar("""
        BEGIN:VEVENT
        UID:private-1
        DTSTART:20261124T150000Z
        DTEND:20261124T160000Z
        SUMMARY:Doctor
        CLASS:PRIVATE
        END:VEVENT
        BEGIN:VEVENT
        UID:secret-1
        DTSTART:20261125T150000Z
        DTEND:20261125T160000Z
        SUMMARY:Board
        CLASS:CONFIDENTIAL
        END:VEVENT
        BEGIN:VEVENT
        UID:plain-1
        DTSTART:20261126T150000Z
        DTEND:20261126T160000Z
        SUMMARY:Lunch
        END:VEVENT
        """)
        let events = ICS.events(text, from: "2026-11-22 00:00", to: "2026-11-30 00:00")
        #expect(events.map(\.visibility) == [.private, .private, .default])

        let writer = ICalendarWriter(ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("UTC"), now: ICS.moment("2026-11-21 12:00"))
        var event = CalendarEvent(calendarID: "cal", title: "Doctor", start: ICS.moment("2026-11-24 15:00"), end: ICS.moment("2026-11-24 16:00"),
                                  visibility: .private)
        var file = writer.newCalendar(for: event, uid: "new-1")
        #expect(file.serialized.contains("\r\nCLASS:PRIVATE\r\n"))
        var loaded = try #require(ICS.events(file.serialized, from: "2026-11-22 00:00", to: "2026-11-30 00:00").first)
        #expect(loaded.visibility == .private)
        loaded.visibility = .default
        _ = try writer.update(&file, with: loaded, scope: .thisEvent)
        #expect(!file.serialized.contains("CLASS"), "the default takes the line off")
        event.visibility = .public
        #expect(writer.newCalendar(for: event, uid: "new-2").serialized.contains("\r\nCLASS:PUBLIC\r\n"))
    }
}
