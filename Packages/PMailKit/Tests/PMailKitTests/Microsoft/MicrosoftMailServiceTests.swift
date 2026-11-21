import Foundation
import Testing
@testable import PMailKit

@Suite struct MicrosoftMailServiceTests {
    static let api = "/v1.0/me"

    private func service(_ transport: StubTransport, tokens: WebTestTokens = WebTestTokens()) -> MicrosoftMailService {
        MicrosoftMailService(email: "jamie@outlook.com", client: .test(transport, tokens: tokens))
    }

    // MARK: Folders

    static let wellKnownIDs = ["inbox": "AAMkInbox=", "sentitems": "AAMkSent=", "drafts": "AAMkDrafts=", "deleteditems": "AAMkDeleted=",
                               "junkemail": "AAMkJunk=", "archive": "AAMkArchive="]

    private func stubFolders(_ transport: StubTransport) {
        transport.on("GET", "\(Self.api)/mailFolders") { request in
            request.query("$skip") == nil ? .json(#"""
            {"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('jamie%40outlook.com')/mailFolders",
             "value": [
                {"id": "AAMkInbox=", "displayName": "Inbox", "parentFolderId": "AAMkRoot=", "childFolderCount": 1,
                 "unreadItemCount": 7,
                 "totalItemCount": 230, "sizeInBytes": 4567, "isHidden": false},
                {"id": "AAMkArchive=", "displayName": "Archive", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 0,
                 "totalItemCount": 1500, "isHidden": false},
                {"id": "AAMkDeleted=", "displayName": "Deleted Items", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 0, "totalItemCount": 12},
                {"id": "AAMkDrafts=", "displayName": "Drafts", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 0,
                 "totalItemCount": 2},
                {"id": "AAMkJunk=", "displayName": "Junk Email", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 3,
                 "totalItemCount": 9}
             ],
             "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/mailFolders?%24top=100&%24skip=5"}
            """#) : .json(#"""
            {"value": [
                {"id": "AAMkSent=", "displayName": "Sent Items", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 0,
                 "totalItemCount": 80},
                {"id": "AAMkProjects=", "displayName": "Projects", "parentFolderId": "AAMkRoot=", "childFolderCount": 0,
                 "unreadItemCount": 2,
                 "totalItemCount": 40}
            ]}
            """#)
        }
        transport.on("GET", "\(Self.api)/mailFolders/") { request in
            let parts = request.url?.pathComponents ?? []
            let name = parts.count > 4 ? parts[4] : ""
            if parts.last == "childFolders" {
                return name == "AAMkInbox=" ? .json(#"""
                {"value": [{"id": "AAMkReceipts=", "displayName": "Receipts", "parentFolderId": "AAMkInbox=",
                 "childFolderCount": 0,
                            "unreadItemCount": 1, "totalItemCount": 12}]}
                """#) : .json(#"{"value": []}"#)
            }
            guard let id = Self.wellKnownIDs[name] else {
                return .json(#"""
                {"error": {"code": "ErrorFolderNotFound", "message": "The specified folder could not be found."}}
                """#, status: 404)
            }
            return .json(#"{"id": "\#(id)"}"#)
        }
    }

    @Test func foldersNestWithRolesCountsAndAStarredFolder() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        let folders = try await service(transport).loadFolders()
        #expect(folders.map(\.id) == ["AAMkInbox=", "AAMkReceipts=", "AAMkArchive=", "AAMkDeleted=", "AAMkDrafts=", "AAMkJunk=",
                                      "AAMkSent=", "AAMkProjects=", MicrosoftMailService.flaggedFolderID])
        #expect(folders.map(\.role) == [.inbox, nil, .archive, .trash, .drafts, .spam, .sent, nil, .starred])
        #expect(folders[0] == MailFolder(id: "AAMkInbox=", name: "Inbox", role: .inbox, unreadCount: 7, totalCount: 230))
        #expect(folders[1] == MailFolder(id: "AAMkReceipts=", name: "Receipts", unreadCount: 1, totalCount: 12, parentID: "AAMkInbox="))
        #expect(folders.allSatisfy { $0.kind == .folder })
        #expect(folders.last?.name == "Starred")
        // Only folders with folders inside are asked for their children.
        #expect(transport.requests.filter { $0.url?.lastPathComponent == "childFolders" }.count == 1)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer") == "IdType=\"ImmutableId\"" })
    }

    @Test func capabilitiesAndTabs() {
        let mail = service(StubTransport())
        #expect(mail.capabilities == MailCapabilities(usesLabels: false, canStar: true, canMarkImportant: true, hasInboxTabs: true,
                                                      searchesOnServer: true, canArchive: true, supportsDrafts: true, canMove: true))
        #expect(mail.inboxTabs.map(\.id) == ["focused", "other"])
        #expect(mail.inboxTabs.map(\.name) == ["Focused", "Other"])
    }

    // MARK: Listing

    static let messagePage = #"""
    {"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('jamie%40outlook.com')/mailFolders('AAMkInbox%3D')/messages",
     "@odata.count": 120,
     "value": [
        {"@odata.etag": "W/\"CQAAABYAAAA1\"", "id": "AAMkMsg3=", "conversationId": "AAQkConv1=", "subject": "RE: Lunch?",
         "bodyPreview": "Sounds good,\r\nsee you then", "importance": "high", "isRead": false, "isDraft": false,
          "hasAttachments": true,
         "internetMessageId": "<msg3@outlook.com>", "parentFolderId": "AAMkInbox=", "receivedDateTime": "2026-11-23T17:00:00Z",
         "from": {"emailAddress": {"name": "Alex Kim", "address": "alex@example.com"}},
         "toRecipients": [{"emailAddress": {"name": "Jamie Rivera", "address": "jamie@outlook.com"}}],
         "ccRecipients": [{"emailAddress": {"name": "sam@example.com", "address": "sam@example.com"}}],
         "flag": {"flagStatus": "flagged"}},
        {"id": "AAMkMsg2=", "conversationId": "AAQkConv2=", "subject": "Pug meetup", "bodyPreview": "Saturday at the park",
         "importance": "normal", "isRead": true, "isDraft": false, "hasAttachments": false,
          "internetMessageId": "<msg2@example.org>",
         "parentFolderId": "AAMkInbox=", "receivedDateTime": "2026-11-23T16:00:00Z",
         "from": {"emailAddress": {"name": "Pug Club", "address": "club@example.org"}}, "toRecipients": [], "ccRecipients": [],
         "flag": {"flagStatus": "notFlagged"}},
        {"id": "AAMkMsg1=", "conversationId": "AAQkConv1=", "subject": "Lunch?", "bodyPreview": "Want to get lunch?",
         "importance": "normal", "isRead": true, "isDraft": false, "hasAttachments": false,
          "internetMessageId": "<msg1@outlook.com>",
         "parentFolderId": "AAMkInbox=", "receivedDateTime": "2026-11-23T15:00:00Z",
         "from": {"emailAddress": {"name": "Jamie Rivera", "address": "jamie@outlook.com"}},
         "toRecipients": [{"emailAddress": {"name": "Alex Kim", "address": "alex@example.com"}}],
          "flag": {"flagStatus": "notFlagged"}},
        {"id": "", "subject": "No ID, so it can't be shown"}
     ],
     "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/mailFolders/AAMkInbox=/messages?%24top=25&%24skip=75"}
    """#

    @Test func inboxTabsFilterSortPageAndGroupByConversation() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        transport.on("GET", "\(Self.api)/mailFolders/AAMkInbox=/messages") { _ in .json(Self.messagePage) }
        let page = try await service(transport).listConversations(ListRequest(folderID: "AAMkInbox=", tabID: "focused", pageSize: 25,
                                                                               pageIndex: 2))

        let request = try #require(transport.sent("GET", "\(Self.api)/mailFolders/AAMkInbox=/messages").first)
        #expect(request.query("$filter") == "receivedDateTime ge 1900-01-01T00:00:00Z and inferenceClassification eq 'focused'")
        #expect(request.query("$orderby") == "receivedDateTime desc")
        #expect(request.query("$top") == "25" && request.query("$skip") == "50" && request.query("$count") == "true")
        #expect(request.query("$select") == "id,conversationId,subject,bodyPreview,from,toRecipients,ccRecipients,receivedDateTime,isRead,"
                + "flag,importance,hasAttachments,isDraft,internetMessageId,parentFolderId")
        #expect(request.value(forHTTPHeaderField: "ConsistencyLevel") == "eventual")

        #expect(page.totalCount == 120)
        #expect(page.nextPageToken == "https://graph.microsoft.com/v1.0/me/mailFolders/AAMkInbox=/messages?%24top=25&%24skip=75")
        #expect(page.conversations.map(\.id) == ["AAQkConv1=", "AAQkConv2="])
        let lunch = page.conversations[0]
        #expect(lunch.messages.map(\.id) == ["AAMkMsg1=", "AAMkMsg3="])
        let reply = lunch.messages[1]
        #expect(reply.isUnread && reply.isStarred && reply.isImportant && reply.hasAttachments && !reply.isDraft)
        #expect(reply.snippet == "Sounds good, see you then")
        #expect(reply.from == MailAddress(name: "Alex Kim", email: "alex@example.com"))
        #expect(reply.cc == [MailAddress(email: "sam@example.com")])
        #expect(reply.folderID == "AAMkInbox=" && reply.messageIDHeader == "<msg3@outlook.com>")
        #expect(reply.date == WebFixtures.date("2026-11-23T17:00:00Z"))
        #expect(lunch.isUnread && lunch.isStarred && !page.conversations[1].isUnread)
    }

    @Test func aRefusedFocusedFilterFallsBackToTheWholeInbox() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        transport.on("GET", "\(Self.api)/mailFolders/AAMkInbox=/messages") { request in
            request.query("$filter") == nil ? .json(Self.messagePage)
                : .json(#"""
                {"error": {"code": "ErrorInvalidProperty",
                 "message": "Could not find a property named 'inferenceClassification'."}}
                """#,
                        status: 400)
        }
        let mail = service(transport)
        let page = try await mail.listConversations(ListRequest(folderID: "AAMkInbox=", tabID: "other"))
        #expect(page.conversations.count == 2)
        _ = try await mail.listConversations(ListRequest(folderID: "AAMkInbox=", tabID: "focused"))
        let filters = transport.sent("GET", "\(Self.api)/mailFolders/AAMkInbox=/messages").map { $0.query("$filter") }
        #expect(filters == ["receivedDateTime ge 1900-01-01T00:00:00Z and inferenceClassification eq 'other'", nil, nil])
    }

    @Test func searchesPageByNextLink() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/mailFolders/AAMkInbox=/messages") { _ in .json(Self.messagePage) }
        let mail = service(transport)
        let page = try await mail.listConversations(ListRequest(folderID: "AAMkInbox=", tabID: "focused", query: #"lunch "tacos""#,
                                                                pageIndex: 3))
        let search = try #require(transport.requests.first)
        #expect(search.query("$search") == #""lunch \"tacos\"""#)
        #expect(search.query("$orderby") == nil && search.query("$skip") == nil && search.query("$filter") == nil)
        #expect(search.query("$count") == nil)

        let next = try #require(page.nextPageToken)
        _ = try await mail.listConversations(ListRequest(folderID: "AAMkInbox=", query: "lunch", pageToken: next))
        #expect(transport.requests.last?.url?.absoluteString == next)
    }

    @Test func theStarredFolderListsFlaggedMail() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/messages") { _ in .json(Self.messagePage) }
        _ = try await service(transport).listConversations(ListRequest(folderID: MicrosoftMailService.flaggedFolderID))
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "\(Self.api)/messages")
        #expect(request.query("$filter") == "receivedDateTime ge 1900-01-01T00:00:00Z and flag/flagStatus eq 'flagged'")
    }

    // MARK: Reading

    @Test func conversationsLoadEachMessagesMIME() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        transport.on("GET", "\(Self.api)/messages") { _ in
            .json(#"""
            {"value": [
                {"id": "AAMkMsg3=", "conversationId": "AAQkConv1=", "subject": "RE: Lunch?", "isRead": true,
                 "parentFolderId": "AAMkInbox=",
                 "receivedDateTime": "2026-11-23T17:00:00Z", "from": {"emailAddress": {"name": "Alex Kim",
                  "address": "alex@example.com"}}},
                {"id": "AAMkMsgDel=", "conversationId": "AAQkConv1=", "subject": "RE: Lunch?", "isRead": true,
                 "parentFolderId": "AAMkDeleted=",
                 "receivedDateTime": "2026-11-23T18:00:00Z"},
                {"id": "AAMkMsg1=", "conversationId": "AAQkConv1=", "subject": "Lunch?", "isRead": true,
                 "parentFolderId": "AAMkSent=",
                 "receivedDateTime": "2026-11-23T15:00:00Z", "internetMessageId": "<msg1@outlook.com>"}
            ]}
            """#)
        }
        transport.on("GET", "\(Self.api)/messages/AAMkMsg1=/$value") { _ in
            .text("From: Jamie Rivera <jamie@outlook.com>\r\nSubject: Lunch?\r\nMessage-ID: <msg1@outlook.com>\r\n\r\n"
                  + "Want to get lunch?\r\n", contentType: "message/rfc822")
        }
        transport.on("GET", "\(Self.api)/messages/AAMkMsg3=/$value") { _ in
            .text("From: Alex Kim <alex@example.com>\r\nSubject: RE: Lunch?\r\nMessage-ID: <msg3@outlook.com>\r\n\r\nSounds good.\r\n",
                  contentType: "message/rfc822")
        }
        let hint = Conversation(id: "AAQkConv1=", messages: [MessageSummary(id: "AAMkMsg1=", threadID: "AAQkConv1="),
                                                            MessageSummary(id: "AAMkMsg3=", threadID: "AAQkConv1=")])
        let messages = try await service(transport).loadConversation(id: "AAQkConv1=", hint: hint)

        let lookup = try #require(transport.requests.first { $0.url?.path == "\(Self.api)/messages" })
        #expect(lookup.query("$filter") == "conversationId eq 'AAQkConv1='")
        #expect(messages.map(\.id) == ["AAMkMsg1=", "AAMkMsg3="])  // Oldest first; the deleted reply stays out.
        #expect(transport.sent("GET", "\(Self.api)/messages/AAMkMsgDel=").isEmpty)
        #expect(messages[0].textBody?.contains("Want to get lunch?") == true)
        #expect(messages[1].summary.messageIDHeader == "<msg3@outlook.com>")
        #expect(messages[1].rawSource.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("From: Alex Kim") == true)
    }

    // MARK: Actions

    private func stubBatch(_ transport: StubTransport) {
        transport.on("POST", "/v1.0/$batch") { request in
            let answers = request.bodyJSONValue["requests"].array.map { #"""
            {"id": "\#($0["id"].string ?? "")", "status": 200, "body": {}}
            """# }
            return .json(#"{"responses": [\#(answers.joined(separator: ","))]}"#)
        }
    }

    private func batched(_ transport: StubTransport) -> [JSONValue] {
        transport.sent("POST", "/v1.0/$batch").flatMap { $0.bodyJSONValue["requests"].array }
    }

    @Test func flagsReadAndImportanceAreBatchedPatches() async throws {
        let transport = StubTransport()
        stubBatch(transport)
        let mail = service(transport)
        let messages = [MessageSummary(id: "AAMkMsg1="), MessageSummary(id: "AAMkMsg3=")]
        try await mail.perform(.markRead, on: messages)
        let first = batched(transport)
        #expect(first == [
            ["id": "1", "method": "PATCH", "url": "/me/messages/AAMkMsg1=", "body": ["isRead": true],
             "headers": ["Content-Type": "application/json", "Prefer": "IdType=\"ImmutableId\""]],
            ["id": "2", "method": "PATCH", "url": "/me/messages/AAMkMsg3=", "body": ["isRead": true],
             "headers": ["Content-Type": "application/json", "Prefer": "IdType=\"ImmutableId\""]],
        ])
        try await mail.perform(.unstar, on: messages)
        try await mail.perform(.markImportant, on: messages)
        try await mail.perform(.move(toFolderID: MicrosoftMailService.flaggedFolderID), on: [messages[0]])
        let bodies = batched(transport).dropFirst(2).map { $0["body"] }
        #expect(bodies == [["flag": ["flagStatus": "notFlagged"]], ["flag": ["flagStatus": "notFlagged"]],
                           ["importance": "high"], ["importance": "high"], ["flag": ["flagStatus": "flagged"]]])

        let many = (1...25).map { MessageSummary(id: "AAMkMany\($0)=") }
        let before = transport.sent("POST", "/v1.0/$batch").count
        try await mail.perform(.star, on: many)
        let batches = transport.sent("POST", "/v1.0/$batch").dropFirst(before).map { $0.bodyJSONValue["requests"].array.count }
        #expect(batches == [20, 5])
    }

    @Test func movesGoToTheRightFoldersAndDeletesAreForever() async throws {
        let transport = StubTransport()
        stubBatch(transport)
        let mail = service(transport)
        let message = [MessageSummary(id: "AAMkMsg1=")]
        try await mail.perform(.archive, on: message)
        try await mail.perform(.trash, on: message)
        try await mail.perform(.markSpam, on: message)
        try await mail.perform(.notSpam, on: message)
        try await mail.perform(.moveToInbox, on: message)
        try await mail.perform(.move(toFolderID: "AAMkProjects="), on: message)
        try await mail.perform(.deleteForever, on: message)
        let requests = batched(transport)
        #expect(requests.dropLast().allSatisfy { $0["method"] == "POST" && $0["url"] == "/me/messages/AAMkMsg1=/move" })
        #expect(requests.dropLast().map { $0["body"]["destinationId"].string ?? "" }
                == ["archive", "deleteditems", "junkemail", "inbox", "inbox", "AAMkProjects="])
        #expect(requests.last?["method"] == "DELETE" && requests.last?["url"] == "/me/messages/AAMkMsg1=")
        #expect(requests.last?["body"].isNull == true)

        await #expect(throws: PMailError.notSupported("Microsoft accounts file mail in folders and don’t have labels.")) {
            try await mail.perform(.addLabel("Work"), on: message)
        }
    }

    // MARK: Sending and drafts

    private let jamie = MailAddress(name: "Jamie Rivera", email: "jamie@outlook.com")

    @Test func sendingPostsBase64MIME() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/sendMail") { _ in .status(202) }
        let message = OutgoingMessage(from: jamie, to: [MailAddress(name: "Alex Kim", email: "alex@example.com")],
                                      bcc: [MailAddress(email: "boss@example.com")], subject: "RE: Lunch?", textBody: "Yes please")
        try await service(transport).send(message)
        let request = try #require(transport.sent("POST", "\(Self.api)/sendMail").first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        let mime = String(decoding: Data(base64Encoded: request.bodyText) ?? Data(), as: UTF8.self)
        #expect(mime.contains("Subject: RE: Lunch?"))
        #expect(mime.contains("To: Alex Kim <alex@example.com>"))
        #expect(mime.contains("Bcc: boss@example.com"))
        #expect(mime.contains("Yes please"))
    }

    @Test func draftsAreSavedAsMIMEAndReplacedByDeletingTheOldOne() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/messages") { _ in
            .json(#"""
            {"id": "AAMkDraft2=", "conversationId": "AAQkConv9=", "subject": "Plans", "bodyPreview": "Definitely",
             "isDraft": true, "isRead": true,
             "internetMessageId": "<draft@outlook.com>", "parentFolderId": "AAMkDrafts=",
              "receivedDateTime": "2026-11-23T18:00:00Z",
             "toRecipients": [{"emailAddress": {"name": "Alex Kim", "address": "alex@example.com"}}],
              "flag": {"flagStatus": "notFlagged"}}
            """#, status: 201)
        }
        transport.on("DELETE", "\(Self.api)/messages/") { _ in .status(204) }
        let mail = service(transport)
        let message = OutgoingMessage(from: jamie, to: [MailAddress(name: "Alex Kim", email: "alex@example.com")], subject: "Plans",
                                      textBody: "Definitely")
        let old = MessageSummary(id: "AAMkDraft1=", threadID: "AAQkConv9=", isDraft: true)
        let saved = try #require(try await mail.saveDraft(message, replacing: old))

        let post = try #require(transport.sent("POST", "\(Self.api)/messages").first)
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(String(decoding: Data(base64Encoded: post.bodyText) ?? Data(), as: UTF8.self).contains("Subject: Plans"))
        #expect(transport.sent("DELETE", "\(Self.api)/messages/AAMkDraft1=").count == 1)
        #expect(saved.id == "AAMkDraft2=" && saved.threadID == "AAQkConv9=" && saved.isDraft && saved.folderID == "AAMkDrafts=")

        try await mail.deleteDraft(saved)
        #expect(transport.sent("DELETE", "\(Self.api)/messages/AAMkDraft2=").count == 1)
    }

    @Test func aTurnedDownTokenIsRefreshedForGraph() async throws {
        let transport = StubTransport()
        let tokens = WebTestTokens()
        transport.on("POST", "\(Self.api)/sendMail") { request in
            request.authorization == "Bearer token-1"
                ? .json(#"""
                {"error": {"code": "InvalidAuthenticationToken", "message": "Access token has expired or is not yet valid."}}
                """#, status: 401)
                : .status(202)
        }
        try await service(transport, tokens: tokens).send(OutgoingMessage(from: jamie, to: [jamie], subject: "Note to self"))
        #expect(tokens.invalidations == 1)
        #expect(transport.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-2"])
    }
}
