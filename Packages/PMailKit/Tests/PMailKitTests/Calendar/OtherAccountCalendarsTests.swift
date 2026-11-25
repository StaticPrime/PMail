import Foundation
import Testing
@testable import PMailKit

/// The person's other accounts' calendars beside the account showing: which show, read-only, kept apart by account.
@Suite struct OtherAccountCalendarsTests {
    private let icloud = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let work = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func anotherAccountsOwnCalendarsShowReadOnly() {
        let theirs = [
            CalendarInfo(id: "/12/calendars/home/", name: "Home", colorHex: "#34A853", isPrimary: true, nativeConference: .faceTime),
            CalendarInfo(id: "/12/calendars/work/", name: "Work"),
            CalendarInfo(id: "follow:priya@example.com", name: "Priya", isReadOnly: true, isOther: true, canUnsubscribe: true),
            CalendarInfo(id: "tasks:list-1", name: "My Tasks"),
        ]
        let shown = OtherAccountCalendars.calendars(theirs, of: icloud)
        #expect(shown.map(\.name) == ["Home", "Work"], "not the calendars it follows, nor its task lists")
        #expect(shown.allSatisfy { $0.isReadOnly && !$0.isPrimary && $0.nativeConference == nil && !$0.isOther })
        #expect(shown.first?.colorHex == "#34A853")
        let origin = OtherAccountCalendars.origin(of: shown[0].id)
        #expect(origin?.account == icloud && origin?.calendarID == "/12/calendars/home/", "its account and its ID there, slashes and all")
        #expect(OtherAccountCalendars.origin(of: "/12/calendars/home/") == nil, "the account's own calendars come from nowhere else")
        #expect(OtherAccountCalendars.origin(of: "account:not-a-uuid/home") == nil)
        // The same ID in two accounts stays two calendars.
        #expect(OtherAccountCalendars.id("primary", of: icloud) != OtherAccountCalendars.id("primary", of: work))
    }

    @Test func theirEventsMoveOntoThoseCalendars() {
        let calendars = OtherAccountCalendars.calendars([CalendarInfo(id: "home", name: "Home"),
                                                         CalendarInfo(id: "follow:priya", name: "Priya", isOther: true)], of: icloud)
        let events = [
            CalendarEvent(id: "e1", calendarID: "home", title: "Dentist", start: start, end: start.addingTimeInterval(3600)),
            CalendarEvent(id: "e2", calendarID: "follow:priya", title: "Priya's flight", start: start, end: start.addingTimeInterval(3600)),
        ]
        let shown = OtherAccountCalendars.events(events, on: calendars, of: icloud)
        #expect(shown.map(\.title) == ["Dentist"], "only events on the calendars that show")
        #expect(shown.first?.calendarID == OtherAccountCalendars.id("home", of: icloud))
        #expect(OtherAccountCalendars.original(of: shown[0]) == events[0], "and back as its account has it")
    }

    @Test func aMeetingOnTwoAccountsShowsOnce() {
        func meeting(_ id: String, on calendar: String, uid: String?, hours: Double = 0) -> CalendarEvent {
            var event = CalendarEvent(id: id, calendarID: calendar, title: "Design review", start: start.addingTimeInterval(hours * 3600),
                                      end: start.addingTimeInterval(hours * 3600 + 1800))
            event.uid = uid
            return event
        }
        let own = [meeting("mine", on: "primary", uid: "review@example.com")]
        let others = [
            meeting("theirs", on: OtherAccountCalendars.id("work", of: work), uid: "review@example.com"),
            meeting("next-week", on: OtherAccountCalendars.id("work", of: work), uid: "review@example.com", hours: 168),
            meeting("again", on: OtherAccountCalendars.id("home", of: icloud), uid: "review@example.com", hours: 168),
            meeting("no-uid", on: OtherAccountCalendars.id("home", of: icloud), uid: nil),
        ]
        #expect(OtherAccountCalendars.withoutRepeats(others, besides: own).map(\.id) == ["next-week", "no-uid"],
                "the account's own copy wins, then the first other account's; another time of it is its own")
    }
}
