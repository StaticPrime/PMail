import Foundation
import Testing
@testable import PMailKit

/// A calendar's settings, kept by its provider where it can: Google keeps nearly all of them (on the calendar itself,
/// and on its place in the account's list), Outlook a name and the nearest of its colors, a CalDAV server a name,
/// description and color. And exporting a calendar writes each series once, as it is.
struct CalendarSettingsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-settings-\(UUID().uuidString).json")
    }

    @Test func googleKeepsTheCalendarsOwnSettingsAndItsPlaceOnTheList() async throws {
        let transport = StubTransport()
        transport.on("GET", "/calendar/v3/users/me/calendarList") { _ in
            .json(##"""
            {"items": [{"id": "pug@gmail.com", "summary": "pug@gmail.com", "primary": true, "accessRole": "owner",
                        "defaultReminders": [{"method": "popup", "minutes": 30}, {"method": "email", "minutes": 60}]},
                       {"id": "fam@group.calendar.google.com", "summary": "Family", "accessRole": "owner", "defaultReminders": []},
                       {"id": "team@group.calendar.google.com", "summary": "Team", "accessRole": "writer"}]}
            """##)
        }
        transport.on("GET", "/calendar/v3/users/me/calendarList/") { request in
            if request.url?.path.hasSuffix("/primary") == true {
                return .json(##"""
                {"id": "pug@gmail.com", "summary": "pug@gmail.com", "description": "Everything", "timeZone": "America/New_York",
                 "backgroundColor": "#9fe1e7", "accessRole": "owner",
                 "defaultReminders": [{"method": "popup", "minutes": 10}, {"method": "email", "minutes": 60}],
                 "notificationSettings": {"notifications": [{"type": "eventChange", "method": "email"}, {"type": "agenda", "method": "email"}]}}
                """##)
            }
            return .json(##"{"id": "alex@acme.example", "summary": "Alex Kim", "summaryOverride": "Alex", "backgroundColor": "#cd74e6", "accessRole": "reader"}"##)
        }
        transport.on("PATCH", "/calendar/v3/") { _ in .json("{}") }
        let service = GoogleCalendarService(client: .test(transport))
        let primary = CalendarInfo(id: "primary", name: "pug@gmail.com", isPrimary: true)
        let alex = CalendarInfo(id: "alex@acme.example", name: "Alex", isReadOnly: true, isOther: true, canUnsubscribe: true)
        #expect(service.settingsSupport(for: primary) == CalendarSettingsSupport(name: true, description: true, timeZone: true, color: true,
                                                                                 eventReminders: true, emailNotices: true))
        #expect(!service.settingsSupport(for: alex).description && service.settingsSupport(for: alex).color)
        // Only a calendar's owner can change its own description and time zone; new events start with its notifications.
        let listed = try await service.loadCalendars()
        #expect(listed.map(\.defaultReminders) == [[30], [], []], "email reminders aren't notifications")
        #expect(listed.map { service.settingsSupport(for: $0).description } == [true, true, false])

        var settings = try await service.loadSettings(for: primary)
        #expect(settings.name == "pug@gmail.com" && settings.description == "Everything" && settings.timeZone == "America/New_York")
        #expect(settings.colorHex == "#9FE1E7" && settings.owner == "You" && settings.eventReminders == [10], "email reminders aren't notifications")
        #expect(settings.emailNotices == [.changedEvents, .dailyAgenda])

        settings.name = "Pug"
        settings.colorHex = "#8E24AA"
        settings.eventReminders = [30, 1_440]
        settings.emailNotices = [.newEvents]
        try await service.saveSettings(settings, for: primary)
        let calendarPatch = try #require(transport.sent("PATCH", "/calendar/v3/calendars/primary").first)
        #expect(calendarPatch.bodyJSONValue["summary"] == "Pug" && calendarPatch.bodyJSONValue["description"] == .null
                && calendarPatch.bodyJSONValue["timeZone"] == .null, "only what changed")
        let listPatch = try #require(transport.sent("PATCH", "/calendar/v3/users/me/calendarList/primary").first)
        #expect(listPatch.queryValues(named: "colorRgbFormat") == ["true"])
        let entry = listPatch.bodyJSONValue
        #expect(entry["backgroundColor"] == "#8e24aa" && entry["foregroundColor"] == "#ffffff")
        #expect(entry["defaultReminders"].array.map { $0["minutes"].int } == [30, 1_440]
                && entry["defaultReminders"].array.allSatisfy { $0["method"] == "popup" })
        #expect(entry["notificationSettings"]["notifications"].array.map { $0["type"].string } == ["eventCreation"]
                && entry["notificationSettings"]["notifications"].array.first?["method"] == "email")
        #expect(entry["summaryOverride"] == .null, "the account's own calendar is renamed itself")
        settings.name = "pug@gmail.com"
        settings.colorHex = "#039BE5"
        try await service.saveSettings(settings, for: primary)
        #expect(transport.sent("PATCH", "/calendar/v3/calendars/primary").count == 1, "nothing of the calendar's own changed")

        // Someone else's calendar: renamed only as it shows in this account, its own settings left alone.
        var theirs = try await service.loadSettings(for: alex)
        #expect(theirs.name == "Alex" && theirs.owner == "alex@acme.example" && theirs.colorHex == "#CD74E6")
        theirs.name = "Alex K."
        try await service.saveSettings(theirs, for: alex)
        #expect(transport.sent("PATCH", "/calendar/v3/calendars/alex@acme.example").isEmpty)
        #expect(transport.sent("PATCH", "/calendar/v3/users/me/calendarList/alex@acme.example").first?.bodyJSONValue["summaryOverride"] == "Alex K.")
    }

    @Test func outlookKeepsANameAndTheNearestOfItsColors() async throws {
        #expect(MicrosoftCalendarService.nearestColorName("#5B9BD5") == "lightBlue")
        #expect(MicrosoftCalendarService.nearestColorName("#E53935") == "lightRed")
        #expect(MicrosoftCalendarService.nearestColorName("#43A047") == "lightGreen")
        #expect(MicrosoftCalendarService.nearestColorName("#FDD835") == "lightYellow")
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubTransport()
        transport.on("GET", "/v1.0/me/calendars/") { _ in
            .json(##"{"id": "AAMkCal1=", "name": "Calendar", "hexColor": "#8764b8", "canEdit": true, "owner": {"name": "Jamie", "address": "jamie@contoso.example"}}"##)
        }
        transport.on("PATCH", "/v1.0/me/calendars/") { _ in .json("{}") }
        let service = MicrosoftCalendarService(client: .test(transport), followedFile: file)
        let main = CalendarInfo(id: "AAMkCal1=", name: "Calendar", isPrimary: true)
        let projects = CalendarInfo(id: "AAMkCal2=", name: "Projects")
        #expect(service.settingsSupport(for: projects) == CalendarSettingsSupport(name: true, color: true))
        #expect(service.settingsSupport(for: main) == CalendarSettingsSupport(color: true), "Outlook's default calendar keeps its name")

        var settings = try await service.loadSettings(for: main)
        #expect(settings.name == "Calendar" && settings.colorHex == "#8764B8" && settings.owner == "You")
        settings.colorHex = "#E53935"
        try await service.saveSettings(settings, for: main)
        let patch = try #require(transport.sent("PATCH", "/v1.0/me/calendars/AAMkCal1=").first)
        #expect(patch.bodyJSONValue["color"] == "lightRed" && patch.bodyJSONValue["name"] == .null)
        settings.name = "Work"
        try await service.saveSettings(settings, for: projects)
        #expect(transport.sent("PATCH", "/v1.0/me/calendars/AAMkCal2=").first?.bodyJSONValue["name"] == "Work")

        // A calendar followed from someone else's mailbox keeps nothing there.
        let followed = CalendarInfo(id: "person:alex@contoso.example", name: "Alex Kim", isReadOnly: true, isOther: true, canUnsubscribe: true)
        #expect(service.settingsSupport(for: followed) == CalendarSettingsSupport())
        try await service.saveSettings(settings, for: followed)
        #expect(transport.sent("PATCH", "/").count == 2)
    }

    @Test func calDAVServersKeepANameDescriptionAndColor() async throws {
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("PROPFIND", "/123456/calendars/home") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/calendars/home/", """
            <d:displayname>Home</d:displayname><c:calendar-description>Family things</c:calendar-description>\
            <ical:calendar-color>#1BADF8FF</ical:calendar-color>
            """))
        }
        transport.on("PROPPATCH", "/123456/calendars/home") { _ in
            DAVStub.multistatus(DAVStub.response("/123456/calendars/home/", "<d:displayname/><c:calendar-description/><ical:calendar-color/>"))
        }
        transport.on("PROPPATCH", "/123456/calendars/work") { _ in
            DAVStub.multistatus("""
            <d:response><d:href>/123456/calendars/work/</d:href>\
            <d:propstat><d:prop><c:calendar-description/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat>\
            <d:propstat><d:prop><d:displayname/><ical:calendar-color/></d:prop><d:status>HTTP/1.1 424 Failed Dependency</d:status></d:propstat>\
            </d:response>
            """)
        }
        let service = try CalDAVTests.service(transport)
        let calendars = try await service.loadCalendars()
        let home = try #require(calendars.first { $0.name == "Home" })
        let family = try #require(calendars.first { $0.name == "Family" })
        #expect(service.settingsSupport(for: home) == CalendarSettingsSupport(name: true, description: true, color: true))
        #expect(service.settingsSupport(for: family) == CalendarSettingsSupport(), "a calendar shared with the account is its owner's")

        var settings = try await service.loadSettings(for: home)
        #expect(settings.name == "Home" && settings.description == "Family things" && settings.colorHex == "#1BADF8" && settings.owner == "You")
        settings.name = "House"
        settings.description = "Kids & pets"
        settings.colorHex = "#8E24AA"
        try await service.saveSettings(settings, for: home)
        let body = try #require(transport.sent("PROPPATCH", "/123456/calendars/home").first).bodyText
        #expect(body.contains("<d:displayname>House</d:displayname>") && body.contains("<c:calendar-description>Kids &amp; pets</c:calendar-description>"))
        #expect(body.contains("<ic:calendar-color>#8E24AAFF</ic:calendar-color>"), "\(body)")

        // A server that refuses one of them sets none, and that's said.
        let work = try #require(calendars.first { $0.name == "Work" })
        await #expect(throws: PMailError.self) { try await service.saveSettings(settings, for: work) }
        try await service.saveSettings(settings, for: family)
        #expect(transport.sent("PROPPATCH", "/123456/calendars/family").isEmpty)
    }

    // MARK: Exporting

    /// A weekly standup as a provider lists it: from the first time in the window (a time before it isn't known), the
    /// third moved and renamed, the fourth deleted. The export reads back the same four times.
    @Test func exportingWritesEachSeriesOnceAsItIs() throws {
        let zone = "America/New_York"
        func at(_ text: String) -> Date { ICS.moment(text, zone) }
        func standup(_ original: String, start: String? = nil, title: String = "Standup") -> CalendarEvent {
            let begins = at(start ?? original)
            return CalendarEvent(id: "standup_\(original)", calendarID: "work", title: title, start: begins, end: begins.addingTimeInterval(900),
                                 timeZone: zone, recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=6"], seriesID: "standup",
                                 occurrenceDate: at(original), uid: "standup@example.com")
        }
        let lunch = CalendarEvent(calendarID: "work", title: "Lunch", start: at("2026-11-12 12:00"), end: at("2026-11-12 13:00"),
                                  location: "Cafe", uid: "lunch@example.com")
        let events = [standup("2026-11-09 09:30"), standup("2026-11-16 09:30", start: "2026-11-16 10:00", title: "Standup (late)"),
                      lunch, standup("2026-11-30 09:30"), standup("2026-12-07 09:30")]
        let text = ICalendar.exportDocument(for: events, timeZone: ICS.timeZone(zone), through: at("2027-11-01 00:00"))

        #expect(text.components(separatedBy: "BEGIN:VTIMEZONE").count == 2 && text.contains("TZID:America/New_York"), "each zone once")
        #expect(text.components(separatedBy: "RRULE:FREQ=WEEKLY").count == 2 && text.contains("UNTIL=20261207T143000Z") && !text.contains("COUNT="),
                "the rule ends at the last time known, since earlier ones aren't")
        #expect(text.contains("EXDATE;TZID=America/New_York:20261123T093000"), "the deleted time is left out")
        #expect(text.contains("RECURRENCE-ID;TZID=America/New_York:20261116T093000"), "the moved time is an override")

        let read = ICS.events(text, from: "2026-11-01 00:00", to: "2027-01-01 00:00", zone: zone)
        #expect(read.map(\.title) == ["Standup", "Lunch", "Standup (late)", "Standup", "Standup"])
        #expect(read.map(\.start) == [at("2026-11-09 09:30"), at("2026-11-16 10:00"), at("2026-11-12 12:00"), at("2026-11-30 09:30"),
                                      at("2026-12-07 09:30")].sorted())
        #expect(read.first { $0.title == "Lunch" }?.location == "Cafe")
    }

    /// Times that don't fit their rule (a provider's rule PMail reads differently) are written one by one, so none is lost.
    @Test func timesThatDontFitTheirRuleAreWrittenOneByOne() throws {
        let zone = "UTC"
        let first = ICS.moment("2026-11-10 15:00", zone)
        let odd = ICS.moment("2026-11-13 15:00", zone)
        let events = [first, odd].map { start in
            CalendarEvent(calendarID: "work", title: "Check-in", start: start, end: start.addingTimeInterval(1_800),
                          recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TU"], seriesID: "checkin", occurrenceDate: start, uid: "checkin@example.com")
        }
        let text = ICalendar.exportDocument(for: events, timeZone: ICS.timeZone(zone))
        let read = ICS.events(text, from: "2026-11-01 00:00", to: "2026-12-01 00:00", zone: zone)
        #expect(read.map(\.start) == [first, odd] && !text.contains("RRULE"))
        #expect(text.contains("UID:checkin@example.com-1") && text.contains("UID:checkin@example.com-2"))
    }
}
