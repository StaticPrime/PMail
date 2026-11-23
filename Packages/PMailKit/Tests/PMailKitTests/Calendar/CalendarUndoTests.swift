import Foundation
import Testing
@testable import PMailKit

/// Undo puts an event back exactly as its calendar had it before PMail changed or deleted it: a calendar server's
/// resource or the Mac's file is written back as it was, a copy a move made in another calendar goes, and what PMail
/// kept of the event on this Mac comes back with it.
struct CalendarUndoTests {
    private func november(_ service: CalDAVCalendarService) async throws -> [CalendarEvent] {
        try await service.loadEvents(in: ["/123456/calendars/work/", "/123456/calendars/home/"], from: ICS.moment("2026-11-01 00:00"),
                                     to: ICS.moment("2026-12-01 00:00"))
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PMailKitTests-undo-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aDeletedEventIsPutBackExactly() async throws {
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("DELETE", "/123456/calendars/work") { _ in .status(204) }
        transport.on("PUT", "/123456/calendars/work/lunch.ics") { _ in DAVStub.saved(etag: "\"l9\"", status: 201) }
        let service = try CalDAVTests.service(transport)
        let lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        let snapshot = try #require(await service.snapshot(of: lunch))
        #expect(transport.sent("GET", "/").isEmpty, "the listing's copy is the version the event came from")
        try await service.delete(lunch, scope: .allEvents)
        try await service.restore(snapshot, removing: nil)
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/lunch.ics").last)
        #expect(DAVStub.header(put, "If-Match") == nil && DAVStub.header(put, "If-None-Match") == nil, "written over whatever is there")
        #expect(put.bodyText.contains("UID:lunch\r\n") && put.bodyText.contains("SUMMARY:Lunch\r\n") && put.bodyText.contains("X-EXAMPLE-TAG:also kept\r\n"),
                "with everything it held")
        #expect(put.bodyText.contains("ORGANIZER;CN=Jamie:mailto:jamie@example.com"))
    }

    @Test func aMovedEventIsPutBackAndItsCopyGoes() async throws {
        let transport = CalDAVTests.iCloudLikeServer()
        transport.on("PUT", "/123456/calendars/home") { _ in DAVStub.saved(etag: "\"h1\"") }
        transport.on("DELETE", "/123456/calendars") { _ in .status(204) }
        transport.on("PUT", "/123456/calendars/work/lunch.ics") { _ in DAVStub.saved(etag: "\"l2\"", status: 201) }
        let service = try CalDAVTests.service(transport)
        var lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        let snapshot = try #require(await service.snapshot(of: lunch))
        lunch.calendarID = "/123456/calendars/home/"
        lunch.title = "Lunch elsewhere"
        let moved = try await service.update(lunch, scope: .allEvents, addingConference: false)
        try await service.restore(snapshot, removing: moved)
        #expect(transport.sent("DELETE", "/123456/calendars/home/lunch.ics").count == 1, "the copy in the other calendar goes")
        let put = try #require(transport.sent("PUT", "/123456/calendars/work/lunch.ics").last)
        #expect(put.bodyText.contains("SUMMARY:Lunch\r\n") && !put.bodyText.contains("elsewhere"))
    }

    @Test func aVersionTheListingDidntHaveIsReadAgain() async throws {
        let transport = CalDAVTests.iCloudLikeServer()
        let service = try CalDAVTests.service(transport)
        var lunch = try #require(try await november(service).first { $0.title == "Lunch" })
        transport.on("GET", "/123456/calendars/work/lunch.ics") { _ in
            StubTransport.Response(status: 200, body: Data(ICS.calendar("BEGIN:VEVENT\nUID:lunch\nSUMMARY:Lunch, later\nEND:VEVENT").utf8),
                                   headers: ["ETag": "\"l5\""])
        }
        lunch.etag = "\"l5\""
        let snapshot = try #require(await service.snapshot(of: lunch))
        #expect(transport.sent("GET", "/123456/calendars/work/lunch.ics").count == 1 && snapshot.data.contains("Lunch, later"))
    }

    @Test func anEventOnTheMacIsPutBackAfterAChangeOrDeletion() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = LocalCalendarService(folder: folder, ownerEmail: "me@example.com")
        let start = ICS.moment("2026-11-30 15:00")
        let window = (ICS.moment("2026-11-29 00:00"), ICS.moment("2026-12-02 00:00"))
        let made = try await service.create(CalendarEvent(calendarID: LocalCalendarService.calendarID, title: "Dentist", start: start,
                                                          end: start.addingTimeInterval(3_600)), addingConference: false)
        let beforeChange = try #require(await service.snapshot(of: made))
        var changed = made
        changed.title = "Dentist, moved"
        changed.start = start.addingTimeInterval(7_200)
        changed.end = start.addingTimeInterval(10_800)
        _ = try await service.update(changed, scope: .thisEvent, addingConference: false)
        try await service.restore(beforeChange, removing: nil)
        let back = try await service.loadEvents(in: [LocalCalendarService.calendarID], from: window.0, to: window.1)
        #expect(back.map(\.title) == ["Dentist"] && back.first?.start == start, "changed back")

        let event = try #require(back.first)
        let beforeDeletion = try #require(await service.snapshot(of: event))
        try await service.delete(event, scope: .allEvents)
        #expect(try await service.loadEvents(in: [LocalCalendarService.calendarID], from: window.0, to: window.1).isEmpty)
        try await service.restore(beforeDeletion, removing: nil)
        #expect(try await service.loadEvents(in: [LocalCalendarService.calendarID], from: window.0, to: window.1).map(\.title) == ["Dentist"],
                "made again")
    }

    @Test func whatPMailKeptOfAnEventComesBackWithIt() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let types = EventTypeBook(file: folder.appendingPathComponent(EventTypeBook.fileName))
        let declines = DeclineBook(file: folder.appendingPathComponent(DeclineBook.fileName))
        let wrapper = CalendarWithTasks(calendars: LocalCalendarService(folder: folder.appendingPathComponent("cal"), ownerEmail: "me@example.com"),
                                        tasks: nil, types: types, declines: declines)
        let start = ICS.moment("2026-11-30 00:00")
        let away = CalendarEvent(calendarID: LocalCalendarService.calendarID, title: "Away", start: start, end: start.addingTimeInterval(86_400),
                                 isAllDay: true, type: .outOfOffice, declinesInvitations: true, declineMessage: "Back Tuesday")
        let saved = try await wrapper.create(away, addingConference: false)
        let snapshot = try #require(await wrapper.snapshot(of: saved))
        try await wrapper.delete(saved, scope: .allEvents)
        let kind = await types.type(for: saved)
        let declining = await declines.entry(for: saved)
        #expect(kind == nil && declining == nil, "deleting forgets it")
        try await wrapper.restore(snapshot, removing: nil)
        let back = try await wrapper.loadEvents(in: [LocalCalendarService.calendarID], from: ICS.moment("2026-11-29 00:00"),
                                                to: ICS.moment("2026-12-02 00:00"))
        #expect(back.first?.type == .outOfOffice && back.first?.declinesInvitations == true && back.first?.declineMessage == "Back Tuesday")
    }
}
