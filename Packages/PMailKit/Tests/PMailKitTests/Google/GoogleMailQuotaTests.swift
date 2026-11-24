import Foundation
import Testing
@testable import PMailKit

/// Staying within what Google lets each person spend with its mail API in a minute.
@Suite struct GoogleMailQuotaTests {
    static let api = GoogleMailServiceTests.api

    @Test func requestsCostWhatGoogleCountsForThem() throws {
        func cost(_ method: String, _ path: String) throws -> Int {
            GoogleMailService.quotaCost(method, try #require(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)))
        }
        #expect(try cost("GET", "threads?maxResults=50") == 10)
        #expect(try cost("GET", "threads/t1?format=metadata&metadataHeaders=From") == 40)
        #expect(try cost("GET", "threads/t1?format=minimal") == 40)
        #expect(try cost("GET", "threads/t1?format=full") == 120)
        #expect(try cost("GET", "messages?q=rfc822msgid:abc") == 5)
        #expect(try cost("GET", "messages/m1?format=metadata") == 20)
        #expect(try cost("GET", "messages/m1?format=raw") == 60)
        #expect(try cost("GET", "history?startHistoryId=1") == 2)
        #expect(try cost("GET", "labels") == 1)
        #expect(try cost("GET", "labels/INBOX") == 1)
        #expect(try cost("GET", "profile") == 1)
        #expect(try cost("POST", "messages/send") == 100)
        #expect(try cost("POST", "messages/batchModify") == 50)
        #expect(try cost("POST", "messages/m1/trash") == 20)
        #expect(try cost("POST", "drafts") == 10)
        #expect(try cost("PUT", "drafts/d1") == 15)
        #expect(try cost("GET", "somethingNew") == 20)
    }

    @Test func signedInAccountsKeepUnderGooglesLimitForTheMinute() async {
        let mail = GoogleMailService(email: "jamie@gmail.com", tokens: WebTestTokens(), transport: StubTransport())
        let capacity = await mail.client.budget?.capacity
        #expect(capacity == 5_500)
        let limit = await mail.client.gate?.limit
        #expect(limit == 6, "and has only a few requests going at once")
    }

    @Test func messagesKeptFromBeforeArentFetchedAgain() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/threads/t1") { _ in
            // Read on another device since: m1 has lost UNREAD and gained STARRED. m2 is new.
            .json(#"""
            {"id": "t1", "messages": [
                {"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "STARRED"]},
                {"id": "m2", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"]}]}
            """#)
        }
        let raw = WebFixtures.base64url(GoogleMailServiceTests.rawText)
        transport.on("GET", "\(Self.api)/messages/m2") { _ in
            .json(#"{"id": "m2", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "internalDate": "1795446000000", "raw": "\#(raw)"}"#)
        }
        let kept = MailMessage(summary: MessageSummary(id: "m1", threadID: "t1", labelIDs: ["INBOX", "UNREAD"], subject: "Lunch?",
                                                       isUnread: true),
                               textBody: "Shall we get lunch?")
        let unread = MailMessage(summary: MessageSummary(id: "m2", threadID: "t1"))  // Kept without a body: fetched.
        let mail = GoogleMailService(email: "jamie@gmail.com", client: .test(transport))
        let messages = try await mail.loadConversation(id: "t1", hint: nil, known: [kept, unread])
        #expect(transport.sent("GET", "\(Self.api)/messages/m1").isEmpty, "a message never changes, so the kept one is used")
        #expect(transport.sent("GET", "\(Self.api)/messages/m2").count == 1)
        let first = try #require(messages.first { $0.id == "m1" })
        #expect(first.textBody == "Shall we get lunch?")
        #expect(first.summary.labelIDs == ["INBOX", "STARRED"] && !first.summary.isUnread && first.summary.isStarred,
                "with its labels as they are now")
        #expect(messages.first { $0.id == "m2" }?.textBody?.contains("Shall we get lunch???") == true)
    }

    @Test func threadsTheListShowsUnchangedArentFetchedAgain() async throws {
        let transport = StubTransport()
        let list = "\(Self.api)/threads"
        transport.on("GET", list) { _ in
            // The second time, t1 has changed (a new message, say) and t2 hasn't.
            let lists = transport.sent("GET", list).filter { $0.url?.path == list }.count
            let t1 = lists == 1 ? "9001" : "9005"
            return .json(#"{"threads": [{"id": "t1", "historyId": "\#(t1)"}, {"id": "t2", "historyId": "77"}]}"#)
        }
        transport.on("GET", "\(list)/t1") { _ in .json(GoogleMailServiceTests.threadOne) }
        transport.on("GET", "\(list)/t2") { _ in .json(GoogleMailServiceTests.threadTwo) }
        let mail = GoogleMailService(email: "jamie@gmail.com", client: .test(transport))
        let first = try await mail.listConversations(ListRequest(folderID: "INBOX"))
        let second = try await mail.listConversations(ListRequest(folderID: "INBOX"))
        #expect(transport.sent("GET", "\(list)/t1").count == 2, "fetched again: its history ID moved on")
        #expect(transport.sent("GET", "\(list)/t2").count == 1, "unchanged, so the row from before is used")
        #expect(first.conversations.map(\.id) == ["t1", "t2"])
        #expect(second.conversations.map(\.id) == ["t1", "t2"])
        #expect(second.conversations[1].messages.map(\.subject) == ["Waffles 🐶"])
    }
}
