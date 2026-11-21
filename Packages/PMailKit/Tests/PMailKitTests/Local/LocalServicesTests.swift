import Foundation
import Testing
@testable import PMailKit

/// A folder of its own for one test, removed afterwards.
private final class TemporaryFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

@Suite struct LocalCalendarServiceTests {
    private let zone = ICS.timeZone("Europe/London")

    private func service(_ folder: TemporaryFolder) -> LocalCalendarService {
        LocalCalendarService(folder: folder.url, ownerEmail: "me@example.com", timeZone: zone)
    }

    private func december(_ service: LocalCalendarService) async throws -> [CalendarEvent] {
        try await service.loadEvents(in: [LocalCalendarService.calendarID], from: ICS.moment("2026-12-01 00:00", "Europe/London"),
                                     to: ICS.moment("2027-01-01 00:00", "Europe/London"))
    }

    @Test func oneWritablePrimaryCalendar() async throws {
        let folder = TemporaryFolder()
        let calendars = try await service(folder).loadCalendars()
        #expect(calendars == [CalendarInfo(id: "local", name: "Calendar", isPrimary: true)])
        #expect(try await december(service(folder)).isEmpty)
    }

    @Test func eventsPersistAcrossInstances() async throws {
        let folder = TemporaryFolder()
        let start = ICS.moment("2026-12-07 09:00", "Europe/London")
        let weekly = CalendarEvent(calendarID: "local", title: "Swim", start: start, end: start.addingTimeInterval(3600),
                                   timeZone: "Europe/London", recurrence: ["RRULE:FREQ=WEEKLY;COUNT=3"], reminderMinutes: [30])
        let created = try await service(folder).create(weekly, addingConference: false)
        #expect(created.seriesID != nil && created.resourceHref != nil && created.etag != nil)
        let single = CalendarEvent(calendarID: "local", title: "Party", start: ICS.moment("2026-12-24 19:00", "Europe/London"),
                                   end: ICS.moment("2026-12-24 23:00", "Europe/London"), uid: "party-1")
        _ = try await service(folder).create(single, addingConference: false)
        #expect(folder.files().count == 2 && folder.files().contains("party-1.ics"))
        await #expect(throws: PMailError.conflict) { _ = try await service(folder).create(single, addingConference: false) }

        // A new instance reads what the first one saved.
        let events = try await december(service(folder))
        try #require(events.count == 4)
        #expect(events.map(\.title) == ["Swim", "Swim", "Swim", "Party"])
        #expect(events.map { ICS.wall($0.start, "Europe/London") } == ["2026-12-07 09:00", "2026-12-14 09:00", "2026-12-21 09:00",
                                                                      "2026-12-24 19:00"])
        #expect(events[0].reminderMinutes == [30] && events[3].id == "party-1.ics")
    }

    @Test func changesWithScopesAndAnswers() async throws {
        let folder = TemporaryFolder()
        let start = ICS.moment("2026-12-07 09:00", "Europe/London")
        let swim = CalendarEvent(calendarID: "local", title: "Swim", start: start, end: start.addingTimeInterval(3600),
                                 recurrence: ["RRULE:FREQ=WEEKLY;COUNT=3"])
        _ = try await service(folder).create(swim, addingConference: false)
        var events = try await december(service(folder))
        try #require(events.count == 3)

        // One occurrence moves.
        var second = events[1]
        second.title = "Swim (pool closed early)"
        second.start = second.start.addingTimeInterval(-3600)
        second.end = second.end.addingTimeInterval(-3600)
        let moved = try await service(folder).update(second, scope: .thisEvent, addingConference: false)
        #expect(moved.title == "Swim (pool closed early)" && ICS.wall(moved.start, "Europe/London") == "2026-12-14 08:00")
        events = try await december(service(folder))
        try #require(events.count == 3)
        #expect(events.map(\.title) == ["Swim", "Swim (pool closed early)", "Swim"])

        // The whole series gets a new name, which the moved occurrence keeps its own of.
        var first = events[0]
        first.location = "Leisure centre"
        _ = try await service(folder).update(first, scope: .allEvents, addingConference: false)
        events = try await december(service(folder))
        try #require(events.count == 3)
        #expect(events.map(\.location) == ["Leisure centre", "Leisure centre", "Leisure centre"])
        #expect(events.map(\.title) == ["Swim", "Swim (pool closed early)", "Swim"])

        // One occurrence goes.
        try await service(folder).delete(events[2], scope: .thisEvent)
        events = try await december(service(folder))
        try #require(events.count == 2)

        // A stale copy is refused.
        var stale = events[0]
        stale.etag = "\"stale\""
        await #expect(throws: PMailError.conflict) { _ = try await service(folder).update(stale, scope: .allEvents, addingConference: false) }

        // And everything goes.
        try await service(folder).delete(events[0], scope: .allEvents)
        #expect(try await december(service(folder)).isEmpty && folder.files().isEmpty)
    }

    @Test func invitationsCanBeAnswered() async throws {
        let folder = TemporaryFolder()
        let me = Attendee(address: MailAddress(name: "Me", email: "ME@example.com"))
        let boss = Attendee(address: MailAddress(email: "boss@example.com"), response: .accepted, isOrganizer: true)
        let invitation = CalendarEvent(calendarID: "local", title: "Review", start: ICS.moment("2026-12-02 14:00"),
                                       end: ICS.moment("2026-12-02 15:00"), attendees: [me, boss], organizer: boss.address)
        _ = try await service(folder).create(invitation, addingConference: false)
        var event = try #require(try await december(service(folder)).first)
        #expect(event.myResponse == .needsAction)
        try await service(folder).respond(to: event, with: .tentative)
        event = try #require(try await december(service(folder)).first)
        #expect(event.myResponse == .tentative)
    }
}

@Suite struct LocalContactsServiceTests {
    @Test func contactsPersistAcrossInstances() async throws {
        let folder = TemporaryFolder()
        let created = try await LocalContactsService(folder: folder.url).create(Contact(givenName: "Alex", familyName: "Kim",
            emails: [LabeledValue(label: "home", value: "alex@example.com")], labels: ["Neighbors"], isStarred: true))
        #expect(created.id.hasSuffix(".vcf") && created.etag != nil && created.uid != nil)
        _ = try await LocalContactsService(folder: folder.url).create(Contact(givenName: "Sam", familyName: "Lee"))

        let contacts = try await LocalContactsService(folder: folder.url).loadContacts()
        try #require(contacts.count == 2)
        #expect(contacts.map(\.displayName) == ["Alex Kim", "Sam Lee"])
        #expect(contacts[0].labels == ["Neighbors"] && contacts[0].isStarred && contacts[0].emails == created.emails)
        #expect(contacts[0].id == created.id && contacts[0].etag == created.etag)
    }

    @Test func updatesKeepWhatOtherProgramsWrote() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Kim;Alex;;;\r\nFN:Alex Kim\r\nX-PET-NAME:Waffles\r\nUID:alex\r\nEND:VCARD\r\n"
        try Data(card.utf8).write(to: folder.url.appendingPathComponent("alex.vcf"))
        let service = LocalContactsService(folder: folder.url)
        var alex = try #require(try await service.loadContacts().first)
        alex.company = "Puggle & Co."
        let saved = try await service.update(alex)
        let text = try String(contentsOf: folder.url.appendingPathComponent("alex.vcf"), encoding: .utf8)
        #expect(text.contains("X-PET-NAME:Waffles\r\n") && text.contains("ORG:Puggle & Co.\r\n") && text.contains("UID:alex\r\n"))
        #expect(saved.etag != alex.etag)

        await #expect(throws: PMailError.conflict) { _ = try await service.update(alex) }
        try await service.delete(saved)
        #expect(try await service.loadContacts().isEmpty)
        await #expect(throws: PMailError.notFound) { try await service.delete(saved) }
    }

    @Test func idsCantReachOutsideTheFolder() async throws {
        let folder = TemporaryFolder()
        let service = LocalContactsService(folder: folder.url)
        await #expect(throws: PMailError.notFound) { try await service.delete(Contact(id: "../../etc/passwd.vcf")) }
        await #expect(throws: PMailError.notFound) { _ = try await service.update(Contact(id: "/tmp/elsewhere.vcf")) }
        #expect(LocalFileStore.fileName(for: "weird/uid", fileExtension: "vcf").hasPrefix("item-"))
        let name = LocalFileStore.fileName(for: "weird/uid", fileExtension: "vcf")
        #expect(name == LocalFileStore.fileName(for: "weird/uid", fileExtension: "vcf"))
    }
}
