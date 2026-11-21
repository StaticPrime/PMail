import Foundation
import Testing
@testable import PMailKit

/// Answers with the wrong shapes and types come out empty (or as much as can be read), never as a crash.
@Suite struct WebRobustnessTests {
    @Test func malformedGoogleAnswersAreSkipped() async throws {
        let transport = StubTransport()
        transport.on("GET", "/gmail/v1/users/me/labels") { _ in .json(#"{"labels": "none"}"#) }
        transport.on("GET", "/gmail/v1/users/me/threads") { _ in
            .json(#"""
            {"threads": [{"id": 5}, {"nope": true}, "x", {"id": "t1"}], "resultSizeEstimate": "many", "nextPageToken": 7}
            """#)
        }
        transport.on("GET", "/gmail/v1/users/me/threads/t1") { _ in
            .json(#"""
            {"id": "t1", "messages": [{"id": "m1", "labelIds": "INBOX", "payload": {"headers": [{"name": 3}, "x"]},
             "internalDate": [1]}, 4]}
            """#)
        }
        transport.on("GET", "/gmail/v1/users/me/messages/m1") { _ in .json(#"{"id": "m1", "raw": 12}"#) }
        let mail = GoogleMailService(email: "jamie@gmail.com", client: .test(transport))
        #expect(try await mail.loadFolders().isEmpty)
        let page = try await mail.listConversations(ListRequest(folderID: "INBOX"))
        #expect(page.totalCount == nil && page.nextPageToken == nil)
        #expect(page.conversations.map(\.id) == ["t1"])
        #expect(page.conversations.first?.messages.first?.labelIDs == [])
        let message = try await mail.loadMessage(MessageSummary(id: "m1", subject: "Kept from the list"))
        #expect(message.summary.subject == "Kept from the list" && message.rawSource == nil)

        transport.on("GET", "/calendar/v3/calendars/c/events") { _ in
            .json(#"""
            {"items": [{"id": "e1", "start": {"dateTime": 12}},
                       {"id": "e2", "start": {"date": "2026-11-26"}, "end": "soon", "attendees": "everyone", "reminders": [],
                        "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "not a url at all"}]},
                         "recurrence": "weekly"}],
             "defaultReminders": {"minutes": 5}}
            """#)
        }
        let events = try await GoogleCalendarService(client: .test(transport)).loadEvents(in: ["c"], from: Date(), to: Date())
        #expect(events.map(\.id) == ["e2"])
        #expect(events.first?.isAllDay == true && events.first?.end == WebFixtures.localMidnight(2026, 11, 27))
        #expect(events.first?.attendees.isEmpty == true && events.first?.conference == nil && events.first?.recurrence.isEmpty == true)

        transport.on("GET", "/v1/contactGroups") { _ in .json(#"{"contactGroups": {"oops": 1}}"#) }
        transport.on("GET", "/v1/people/me/connections") { _ in
            .json(#"""
            {"connections": [{"resourceName": "people/c1", "names": "Jamie", "birthdays": [{"date": {"month": 13, "day": 40}}]}]}
            """#)
        }
        let contacts = try await GoogleContactsService(client: .test(transport)).loadContacts()
        #expect(contacts.map(\.id) == ["people/c1"] && contacts.first?.birthday == nil)
    }

    @Test func malformedMicrosoftAnswersAreSkipped() async throws {
        let transport = StubTransport()
        transport.on("GET", "/v1.0/me/mailFolders") { _ in .json(#"""
        {"value": [{"id": "f1", "childFolderCount": "lots"}, 3], "@odata.nextLink": 9}
        """#) }
        transport.on("GET", "/v1.0/me/mailFolders/") { _ in .status(404) }
        transport.on("GET", "/v1.0/me/messages") { _ in
            .json(#"""
            {"value": [{"id": "m1", "from": "Alex", "toRecipients": {"a": 1}, "flag": "flagged",
             "receivedDateTime": "yesterday"}], "@odata.count": "x"}
            """#)
        }
        let mail = MicrosoftMailService(email: "jamie@example.com", client: .test(transport))
        #expect(try await mail.loadFolders().map(\.id) == ["f1", MicrosoftMailService.flaggedFolderID])
        let page = try await mail.listConversations(ListRequest(folderID: nil))
        #expect(page.conversations.first?.messages.first?.from == nil && page.totalCount == nil)

        transport.on("GET", "/v1.0/me/calendars/c/calendarView") { _ in
            .json(#"""
            {"value": [{"id": "e1", "start": "today"},
                       {"id": "e2", "isAllDay": "yes", "start": {"dateTime": "2026-11-23T18:00:00", "timeZone": 5},
                        "attendees": [{"emailAddress": "x"}], "onlineMeeting": {"joinUrl": 7}, "reminderMinutesBeforeStart": "15"}]}
            """#)
        }
        let events = try await MicrosoftCalendarService(client: .test(transport)).loadEvents(in: ["c"], from: Date(), to: Date())
        #expect(events.map(\.id) == ["e2"] && events.first?.start == WebFixtures.date("2026-11-23T18:00:00Z"))
        #expect(events.first?.attendees.isEmpty == true && events.first?.conference == nil)

        transport.on("GET", "/v1.0/me/contacts") { _ in .json(#"""
        {"value": [{"id": "p1", "homePhones": "555", "birthday": "soon", "categories": [1, "Dogs"]}]}
        """#) }
        let contacts = try await MicrosoftContactsService(client: .test(transport)).loadContacts()
        #expect(contacts.first?.phones.isEmpty == true && contacts.first?.birthday == nil && contacts.first?.labels == ["Dogs"])
    }
}
