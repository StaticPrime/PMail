import Foundation
import Testing
@testable import PMailKit

@Suite struct GoogleMailServiceTests {
    static let api = "/gmail/v1/users/me"

    private func service(_ transport: StubTransport, tokens: WebTestTokens = WebTestTokens()) -> GoogleMailService {
        GoogleMailService(email: "jamie@gmail.com", client: .test(transport, tokens: tokens))
    }

    // MARK: Folders

    static let labels = #"""
    {"labels": [
        {"id": "CHAT", "name": "CHAT", "messageListVisibility": "hide", "labelListVisibility": "labelHide", "type": "system"},
        {"id": "SENT", "name": "SENT", "type": "system"},
        {"id": "INBOX", "name": "INBOX", "messageListVisibility": "hide", "labelListVisibility": "labelShow", "type": "system"},
        {"id": "IMPORTANT", "name": "IMPORTANT", "type": "system"},
        {"id": "TRASH", "name": "TRASH", "type": "system"},
        {"id": "DRAFT", "name": "DRAFT", "type": "system"},
        {"id": "SPAM", "name": "SPAM", "type": "system"},
        {"id": "CATEGORY_FORUMS", "name": "CATEGORY_FORUMS", "type": "system"},
        {"id": "CATEGORY_UPDATES", "name": "CATEGORY_UPDATES", "type": "system"},
        {"id": "CATEGORY_PERSONAL", "name": "CATEGORY_PERSONAL", "type": "system"},
        {"id": "CATEGORY_PROMOTIONS", "name": "CATEGORY_PROMOTIONS", "type": "system"},
        {"id": "CATEGORY_SOCIAL", "name": "CATEGORY_SOCIAL", "type": "system"},
        {"id": "STARRED", "name": "STARRED", "type": "system"},
        {"id": "UNREAD", "name": "UNREAD", "type": "system"},
        {"id": "Label_1", "name": "Work", "messageListVisibility": "show", "labelListVisibility": "labelShow", "type": "user",
         "color": {"textColor": "#ffffff", "backgroundColor": "#16a766"}},
        {"id": "Label_2", "name": "Work/Projects", "type": "user"},
        {"id": "Label_3", "name": "Work/Projects/Puggle", "type": "user"},
        {"id": "Label_4", "name": "Receipts/2026", "type": "user"}
    ]}
    """#

    @Test func labelsBecomeFoldersWithRolesNestingAndCounts() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/labels") { _ in .json(Self.labels) }
        transport.on("GET", "\(Self.api)/labels/") { _ in .json(#"""
        {"error": {"code": 500, "message": "Backend Error"}}
        """#, status: 500) }
        transport.on("GET", "\(Self.api)/labels/INBOX") { _ in
            .json(#"""
            {"id": "INBOX", "name": "INBOX", "messagesTotal": 1200, "messagesUnread": 14, "threadsTotal": 900,
             "threadsUnread": 12}
            """#)
        }
        transport.on("GET", "\(Self.api)/labels/DRAFT") { _ in
            .json(#"""
            {"id": "DRAFT", "name": "DRAFT", "messagesTotal": 3, "messagesUnread": 0, "threadsTotal": 3, "threadsUnread": 0}
            """#)
        }
        transport.on("GET", "\(Self.api)/labels/SPAM") { _ in
            .json(#"""
            {"id": "SPAM", "name": "SPAM", "messagesTotal": 41, "messagesUnread": 5, "threadsTotal": 40, "threadsUnread": 5}
            """#)
        }
        transport.on("GET", "\(Self.api)/labels/Label_1") { _ in
            .json(#"""
            {"id": "Label_1", "name": "Work", "messagesTotal": 31, "messagesUnread": 2, "threadsTotal": 30, "threadsUnread": 2}
            """#)
        }
        let folders = try await service(transport).loadFolders()

        #expect(folders.map(\.id) == ["INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "SPAM", "TRASH",
                                      "Label_4", "Label_1", "Label_2", "Label_3"])
        #expect(folders.prefix(7).map(\.role) == [.inbox, .starred, .important, .sent, .drafts, .spam, .trash])
        #expect(folders.prefix(7).allSatisfy { $0.kind == .folder })
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        #expect(byID["INBOX"]?.name == "Inbox")
        #expect(byID["INBOX"]?.unreadCount == 12 && byID["INBOX"]?.totalCount == 900)
        #expect(byID["DRAFT"]?.unreadCount == 3)
        #expect(byID["SPAM"]?.unreadCount == 5)
        #expect(byID["Label_1"] == MailFolder(id: "Label_1", name: "Work", kind: .label, unreadCount: 2, totalCount: 30,
                                              colorHex: "#16A766"))
        #expect(byID["Label_2"]?.name == "Projects" && byID["Label_2"]?.parentID == "Label_1")
        #expect(byID["Label_3"]?.name == "Puggle" && byID["Label_3"]?.parentID == "Label_2")
        #expect(byID["Label_4"]?.name == "Receipts/2026" && byID["Label_4"]?.parentID == nil)
        // Counts were asked for only where they're shown; a failed count (Label_2 has no stub) just reads as zero.
        let counted = Set(transport.sent("GET", "\(Self.api)/labels/").compactMap { $0.url?.lastPathComponent })
        #expect(counted == ["INBOX", "DRAFT", "SPAM", "Label_1", "Label_2", "Label_3", "Label_4"])
        #expect(byID["Label_2"]?.unreadCount == 0)
    }

    @Test func capabilitiesAndInboxTabs() {
        let mail = service(StubTransport())
        #expect(mail.capabilities == MailCapabilities(usesLabels: true, canStar: true, canMarkImportant: true, hasInboxTabs: true,
                                                      searchesOnServer: true, canArchive: true, supportsDrafts: true, canMove: true))
        #expect(mail.inboxTabs.map(\.id) == ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES",
                                             "CATEGORY_FORUMS"])
        #expect(mail.inboxTabs.map(\.name) == ["Primary", "Promotions", "Social", "Updates", "Forums"])
        #expect(mail.inboxTabs.map(\.symbol) == ["tray", "tag", "person.2", "info.circle", "bubble.left.and.bubble.right"])
    }

    // MARK: Listing

    static let threadOne = #"""
    {"id": "t1", "historyId": "9001", "messages": [
        {"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "CATEGORY_SOCIAL", "IMPORTANT"], "snippet": "Want to get lunch?",
         "sizeEstimate": 2048, "historyId": "8999", "internalDate": "1795446000000",
         "payload": {"partId": "", "mimeType": "multipart/alternative", "filename": "", "headers": [
            {"name": "From", "value": "Alex Kim <alex@example.com>"},
            {"name": "To", "value": "Jamie Rivera <jamie@gmail.com>"},
            {"name": "Subject", "value": "Lunch?"},
            {"name": "Date", "value": "Mon, 23 Nov 2026 10:00:00 -0500"},
            {"name": "Message-ID", "value": "<m1@example.com>"}]}},
        {"id": "m2", "threadId": "t1", "labelIds": ["INBOX", "UNREAD", "STARRED", "CATEGORY_SOCIAL"],
         "snippet": "Sounds good &amp; see you &#39;then&#39;", "sizeEstimate": 40960, "internalDate": "1795449600000",
         "payload": {"mimeType": "multipart/mixed", "headers": [
            {"name": "From", "value": "\"Rivera, Jamie\" <jamie@gmail.com>"},
            {"name": "To", "value": "alex@example.com"},
            {"name": "Cc", "value": "Sam Lee <sam@example.com>, pat@example.com"},
            {"name": "Subject", "value": "Re: Lunch?"},
            {"name": "Message-Id", "value": "<m2@gmail.com>"},
            {"name": "In-Reply-To", "value": "<m1@example.com>"},
            {"name": "References", "value": "<m0@example.com> <m1@example.com>"}]}},
        {"id": "m3", "threadId": "t1", "labelIds": ["TRASH"], "snippet": "deleted", "internalDate": "1795453200000",
         "payload": {"mimeType": "text/plain", "headers": [{"name": "Subject", "value": "Re: Lunch?"}]}}
    ]}
    """#

    static let threadTwo = #"""
    {"id": "t2", "messages": [
        {"id": "m4", "threadId": "t2", "labelIds": ["INBOX", "CATEGORY_SOCIAL"], "snippet": "Pug meetup on Saturday",
         "internalDate": "1795339800000",
         "payload": {"mimeType": "text/html", "headers": [
            {"name": "From", "value": "=?UTF-8?Q?Pug_Club_=F0=9F=90=B6?= <club@example.org>"},
            {"name": "Subject", "value": "=?UTF-8?B?V2FmZmxlcyDwn5C2?="}]}}
    ]}
    """#

    private func stubThreads(_ transport: StubTransport) {
        transport.on("GET", "\(Self.api)/threads") { _ in
            .json(#"""
            {"threads": [{"id": "t1", "snippet": "", "historyId": "9001"}, {"id": "t2", "snippet": "", "historyId": "77"}],
             "nextPageToken": "tok2", "resultSizeEstimate": 57}
            """#)
        }
        transport.on("GET", "\(Self.api)/threads/t1") { _ in .json(Self.threadOne) }
        transport.on("GET", "\(Self.api)/threads/t2") { _ in .json(Self.threadTwo) }
    }

    @Test func listingAskForTheFolderTabAndSearchAndMapsThreads() async throws {
        let transport = StubTransport()
        stubThreads(transport)
        let request = ListRequest(folderID: "INBOX", tabID: "CATEGORY_SOCIAL", query: "from:alex has:attachment", pageSize: 2,
                                  pageToken: "tok1")
        let page = try await service(transport).listConversations(request)

        let list = try #require(transport.requests.first)
        #expect(list.url?.path == "\(Self.api)/threads")
        #expect(list.queryValues(named: "labelIds") == ["INBOX", "CATEGORY_SOCIAL"])
        #expect(list.query("q") == "from:alex has:attachment")
        #expect(list.query("maxResults") == "2")
        #expect(list.query("pageToken") == "tok1")
        #expect(list.query("includeSpamTrash") == nil)
        let metadata = try #require(transport.sent("GET", "\(Self.api)/threads/t1").first)
        #expect(metadata.query("format") == "metadata")
        #expect(metadata.queryValues(named: "metadataHeaders") == ["From", "To", "Cc", "Subject", "Date", "Message-ID", "References",
                                                                    "In-Reply-To"])

        #expect(page.totalCount == 57)
        #expect(page.nextPageToken == "tok2")
        #expect(page.conversations.map(\.id) == ["t1", "t2"])
        let first = page.conversations[0]
        #expect(first.messages.map(\.id) == ["m1", "m2"])  // The trashed reply stays out of the inbox.
        let m1 = first.messages[0], m2 = first.messages[1]
        #expect(m1.from == MailAddress(name: "Alex Kim", email: "alex@example.com"))
        #expect(m1.subject == "Lunch?" && m1.isImportant && !m1.isUnread && !m1.hasAttachments)
        #expect(m1.date == WebFixtures.date("2026-11-23T15:00:00Z"))
        #expect(m1.messageIDHeader == "<m1@example.com>" && m1.size == 2048)
        #expect(m2.isUnread && m2.isStarred && m2.hasAttachments)
        #expect(m2.snippet == "Sounds good & see you 'then'")
        #expect(m2.from?.name == "Rivera, Jamie")
        #expect(m2.cc == [MailAddress(name: "Sam Lee", email: "sam@example.com"), MailAddress(email: "pat@example.com")])
        #expect(m2.messageIDHeader == "<m2@gmail.com>" && m2.inReplyTo == "<m1@example.com>")
        #expect(m2.references == ["<m0@example.com>", "<m1@example.com>"])
        #expect(m2.labelIDs == ["INBOX", "UNREAD", "STARRED", "CATEGORY_SOCIAL"])
        #expect(first.isUnread && first.hasAttachments)
        let m4 = page.conversations[1].messages[0]
        #expect(m4.subject == "Waffles 🐶")
        #expect(m4.from == MailAddress(name: "Pug Club 🐶", email: "club@example.org"))
    }

    @Test func trashListsOnlyTrashedMessagesAndAllMailHasNoLabel() async throws {
        let transport = StubTransport()
        stubThreads(transport)
        let mail = service(transport)
        let trash = try await mail.listConversations(ListRequest(folderID: "TRASH"))
        #expect(trash.conversations.map(\.id) == ["t1"])
        #expect(trash.conversations[0].messages.map(\.id) == ["m3"])
        let trashList = try #require(transport.sent("GET", "\(Self.api)/threads").first)
        #expect(trashList.queryValues(named: "labelIds") == ["TRASH"])
        #expect(trashList.query("includeSpamTrash") == "true")

        _ = try await mail.listConversations(ListRequest(folderID: nil, tabID: "CATEGORY_SOCIAL"))
        let allMail = try #require(transport.requests.last { $0.url?.path == "\(Self.api)/threads" })
        #expect(allMail.queryValues(named: "labelIds").isEmpty)
    }

    // MARK: New mail

    static let inboxLabel = #"""
    {"id": "INBOX", "name": "INBOX", "messageListVisibility": "hide", "labelListVisibility": "labelShow", "type": "system",
     "messagesTotal": 1200, "messagesUnread": 14, "threadsTotal": 900, "threadsUnread": 12}
    """#

    /// The profile, with the mailbox's history ID now, and the inbox's counts.
    private func stubProfile(_ transport: StubTransport, historyID: String = "4001") {
        transport.on("GET", "\(Self.api)/profile") { _ in
            .json(#"{"emailAddress": "jamie@gmail.com", "messagesTotal": 1200, "threadsTotal": 900, "historyId": "\#(historyID)"}"#)
        }
        transport.on("GET", "\(Self.api)/labels/INBOX") { _ in .json(Self.inboxLabel) }
    }

    /// A message as `format=metadata` gives it.
    private static func metadata(_ id: String, thread: String? = nil, labels: [String], internalDate: String = "1795449600000",
                                 from: String = "Alex Kim <alex@example.com>", subject: String = "Pug meetup",
                                 messageID: String? = nil) -> String {
        let labelList = labels.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"""
        {"id": "\#(id)", "threadId": "\#(thread ?? "t-" + id)", "labelIds": [\#(labelList)], "snippet": "See you at the park",
         "sizeEstimate": 3100, "historyId": "4007", "internalDate": "\#(internalDate)",
         "payload": {"partId": "", "mimeType": "multipart/alternative", "filename": "", "headers": [
            {"name": "From", "value": "\#(from)"},
            {"name": "To", "value": "Jamie Rivera <jamie@gmail.com>"},
            {"name": "Subject", "value": "\#(subject)"},
            {"name": "Date", "value": "Mon, 23 Nov 2026 11:00:00 -0500"},
            {"name": "Message-ID", "value": "\#(messageID ?? "<\(id)@example.com>")"}]}}
        """#
    }

    @Test func theFirstCheckOnlyNotesWhereTheHistoryIsUpTo() async throws {
        let transport = StubTransport()
        stubProfile(transport)
        let new = try await service(transport).checkForNewMail(since: nil)
        #expect(new.messages.isEmpty)
        #expect(new.state == MailSyncState("4001"))
        #expect(new.inboxUnread == 14)
        #expect(transport.requests.compactMap { $0.url?.path }.sorted() == ["\(Self.api)/labels/INBOX", "\(Self.api)/profile"])
    }

    static let history = #"""
    {"history": [
        {"id": "4002", "messages": [{"id": "m11", "threadId": "t11"}],
         "messagesAdded": [{"message": {"id": "m11", "threadId": "t11", "labelIds": ["UNREAD", "CATEGORY_UPDATES", "INBOX"]}}]},
        {"id": "4005", "messages": [{"id": "m12", "threadId": "t12"}],
         "messagesAdded": [{"message": {"id": "m12", "threadId": "t12", "labelIds": ["SENT", "INBOX", "IMPORTANT"]}}]},
        {"id": "4007", "messages": [{"id": "m10", "threadId": "t10"}],
         "messagesAdded": [{"message": {"id": "m10", "threadId": "t10",
                                        "labelIds": ["UNREAD", "IMPORTANT", "CATEGORY_PERSONAL", "INBOX"]}}]},
        {"id": "4008", "messages": [{"id": "m13", "threadId": "t10"}],
         "messagesAdded": [{"message": {"id": "m13", "threadId": "t10", "labelIds": ["UNREAD", "CATEGORY_PERSONAL", "INBOX"]}}]}
     ],
     "historyId": "4010"}
    """#

    @Test func laterChecksListAddedMessagesStillInTheInboxNewestFirst() async throws {
        let transport = StubTransport()
        stubProfile(transport)
        transport.on("GET", "\(Self.api)/history") { _ in .json(Self.history) }
        transport.on("GET", "\(Self.api)/messages/m10") { _ in
            .json(Self.metadata("m10", thread: "t10", labels: ["UNREAD", "IMPORTANT", "CATEGORY_PERSONAL", "INBOX"]))
        }
        transport.on("GET", "\(Self.api)/messages/m11") { _ in  // Archived since it came.
            .json(Self.metadata("m11", thread: "t11", labels: ["CATEGORY_UPDATES"], from: "Pug Club <club@example.org>"))
        }
        transport.on("GET", "\(Self.api)/messages/m13") { _ in
            .json(Self.metadata("m13", thread: "t10", labels: ["UNREAD", "CATEGORY_PERSONAL", "INBOX"],
                                internalDate: "1795450200000", from: "Sam Lee <sam@example.com>", subject: "Re: Pug meetup"))
        }
        let new = try await service(transport).checkForNewMail(since: MailSyncState("4001"))

        let history = try #require(transport.sent("GET", "\(Self.api)/history").first)
        #expect(history.query("startHistoryId") == "4001")
        #expect(history.queryValues(named: "historyTypes") == ["messageAdded"])
        #expect(history.query("labelId") == "INBOX" && history.query("maxResults") == "500" && history.query("pageToken") == nil)
        #expect(transport.sent("GET", "\(Self.api)/profile").isEmpty)
        // Mail sent from the account isn't even fetched; the archived message is, and turns out to be out of the inbox.
        let fetched = transport.sent("GET", "\(Self.api)/messages/")
        #expect(Set(fetched.compactMap { $0.url?.lastPathComponent }) == ["m10", "m11", "m13"])
        #expect(fetched.allSatisfy {
            $0.query("format") == "metadata" && $0.queryValues(named: "metadataHeaders") == GoogleMailService.listHeaders
        })

        #expect(new.messages.map(\.id) == ["m13", "m10"])
        #expect(new.state == MailSyncState("4010"))
        #expect(new.inboxUnread == 14)
        let reply = new.messages[0]
        #expect(reply.threadID == "t10" && reply.isUnread && !reply.isImportant)
        #expect(reply.from == MailAddress(name: "Sam Lee", email: "sam@example.com") && reply.subject == "Re: Pug meetup")
        #expect(reply.date == WebFixtures.date("2026-11-23T16:10:00Z") && reply.messageIDHeader == "<m13@example.com>")
    }

    @Test func historyIsReadPageByPageAndOnlyTheFiftyNewestAreFetched() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/history") { request in
            // Page one adds m1…m30, page two m31…m60, with m50's record there twice.
            let second = request.query("pageToken") == "page-2"
            let numbers = second ? Array(31...50) + Array(50...60) : Array(1...30)
            let records = numbers.map { number in
                #"{"id": "\#(5000 + number)", "messagesAdded": [{"message": {"id": "m\#(number)", "labelIds": ["INBOX"]}}]}"#
            }
            let next = second ? "" : #""nextPageToken": "page-2", "#
            return .json(#"{"history": [\#(records.joined(separator: ", "))], \#(next)"historyId": "\#(second ? 5070 : 5065)"}"#)
        }
        transport.on("GET", "\(Self.api)/messages/") { request in
            .json(Self.metadata(request.url?.lastPathComponent ?? "", labels: ["UNREAD", "INBOX"]))
        }
        let new = try await service(transport).checkForNewMail(since: MailSyncState("5000"))

        let pages = transport.sent("GET", "\(Self.api)/history")
        #expect(pages.map { $0.query("pageToken") } == [nil, "page-2"])
        #expect(pages.allSatisfy { $0.query("startHistoryId") == "5000" })
        #expect(new.messages.map(\.id) == (11...60).reversed().map { "m\($0)" })
        #expect(transport.sent("GET", "\(Self.api)/messages/").count == 50)
        #expect(new.state == MailSyncState("5070"))
    }

    @Test func checksStartAgainFromNowWhenTheHistoryIsGoneOrTooLong() async throws {
        let transport = StubTransport()
        stubProfile(transport, historyID: "9100")
        transport.on("GET", "\(Self.api)/history") { _ in
            .json(#"""
            {"error": {"code": 404, "message": "Requested entity was not found.",
             "errors": [{"message": "Requested entity was not found.", "domain": "global", "reason": "notFound"}],
             "status": "NOT_FOUND"}}
            """#, status: 404)
        }
        let mail = service(transport)
        let expired = try await mail.checkForNewMail(since: MailSyncState("12"))
        #expect(expired.messages.isEmpty && expired.state == MailSyncState("9100") && expired.inboxUnread == 14)
        #expect(transport.sent("GET", "\(Self.api)/history").first?.query("startHistoryId") == "12")

        // History that runs on past the pages one check reads is skipped too, rather than half announced.
        transport.on("GET", "\(Self.api)/history") { request in
            let page = Int(request.query("pageToken") ?? "0") ?? 0
            return .json(#"""
            {"history": [{"id": "\#(8001 + page)", "messagesAdded": [{"message": {"id": "m\#(page)", "labelIds": ["INBOX"]}}]}],
             "nextPageToken": "\#(page + 1)", "historyId": "9050"}
            """#)
        }
        let flooded = try await mail.checkForNewMail(since: MailSyncState("8000"))
        #expect(flooded.messages.isEmpty && flooded.state == MailSyncState("9100"))
        #expect(transport.sent("GET", "\(Self.api)/history").count == 1 + GoogleMailService.historyPageLimit)
        #expect(transport.sent("GET", "\(Self.api)/messages/").isEmpty)
        #expect(transport.sent("GET", "\(Self.api)/profile").count == 2)
    }

    @Test func oddHistoryAnswersAndStatesNeverCrash() async throws {
        let transport = StubTransport()
        stubProfile(transport)
        transport.on("GET", "\(Self.api)/history") { _ in
            .json(#"""
            {"history": [{"id": [1], "messagesAdded": "m1"}, 7,
                         {"messagesAdded": [{"message": "m2"}, {"message": {"id": 3, "labelIds": "INBOX"}}, 5]}],
             "historyId": 4020}
            """#)
        }
        let mail = service(transport)
        let odd = try await mail.checkForNewMail(since: MailSyncState("4001"))
        #expect(odd.messages.isEmpty && odd.state == MailSyncState("4020"))
        // A state this service didn't make starts again from now.
        let foreign = try await mail.checkForNewMail(since: MailSyncState("2026-11-23T17:00:00Z"))
        #expect(foreign.messages.isEmpty && foreign.state == MailSyncState("4001"))
        #expect(transport.sent("GET", "\(Self.api)/history").count == 1)

        // Nothing readable keeps the state where it was, and a count that can't be had is left out.
        transport.on("GET", "\(Self.api)/history") { _ in .json(#"{"history": "lots", "historyId": "soon"}"#) }
        transport.on("GET", "\(Self.api)/labels/INBOX") { _ in .status(500) }
        let kept = try await mail.checkForNewMail(since: MailSyncState("4020"))
        #expect(kept.messages.isEmpty && kept.state == MailSyncState("4020") && kept.inboxUnread == nil)

        transport.on("GET", "\(Self.api)/profile") { _ in .json(#"{"emailAddress": "jamie@gmail.com"}"#) }
        await #expect(throws: PMailError.protocolError("the mailbox had no history ID")) {
            try await mail.checkForNewMail(since: nil)
        }

        transport.on("GET", "\(Self.api)/messages") { _ in .json(#"{"messages": "m1"}"#) }
        #expect(try await mail.findMessages(withMessageIDs: ["<a@example.com>"]).isEmpty)
        #expect(try await mail.findMessages(withMessageIDs: []).isEmpty)
    }

    // MARK: Finding messages

    @Test func messagesAreFoundByMessageIDOutsideTrashAndSpam() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/messages") { request in
            switch request.query("q") {
            case "rfc822msgid:CAKx+3=pug@mail.gmail.com":
                .json(#"{"messages": [{"id": "m20", "threadId": "t20"}], "resultSizeEstimate": 1}"#)
            case "rfc822msgid:plans@example.com":
                .json(#"{"messages": [{"id": "m21", "threadId": "t21"}], "resultSizeEstimate": 1}"#)
            default:
                .json(#"{"resultSizeEstimate": 0}"#)
            }
        }
        transport.on("GET", "\(Self.api)/messages/m20") { _ in
            .json(Self.metadata("m20", labels: ["Label_1", "IMPORTANT"], messageID: "<CAKx+3=pug@mail.gmail.com>"))
        }
        transport.on("GET", "\(Self.api)/messages/m21") { _ in
            .json(Self.metadata("m21", labels: ["TRASH"], messageID: "<plans@example.com>"))
        }
        let found = try await service(transport).findMessages(withMessageIDs: [
            "<CAKx+3=pug@mail.gmail.com>", "<plans@example.com>", "<nobody@example.com>", "<CAKx+3=pug@mail.gmail.com>", "<>",
        ])

        #expect(found.map(\.id) == ["m20"])  // Filed under a label now, so found; the trashed one isn't.
        #expect(found.first?.labelIDs == ["Label_1", "IMPORTANT"] && found.first?.messageIDHeader == "<CAKx+3=pug@mail.gmail.com>")
        let searches = transport.requests.filter { $0.url?.path == "\(Self.api)/messages" }
        #expect(searches.count == 3)  // Each Message-ID once, without its brackets.
        #expect(Set(searches.compactMap { $0.query("q") })
                == ["rfc822msgid:CAKx+3=pug@mail.gmail.com", "rfc822msgid:plans@example.com", "rfc822msgid:nobody@example.com"])
        let escaped = "/messages?q=rfc822msgid:CAKx%2B3%3Dpug@mail.gmail.com"  // A "+" or "=" stays itself.
        #expect(searches.contains { $0.url?.absoluteString.hasSuffix(escaped) == true })
        #expect(transport.sent("GET", "\(Self.api)/messages/m20").first?.query("format") == "metadata")
    }

    // MARK: Reading

    static let rawText = "From: Alex Kim <alex@example.com>\r\nTo: jamie@gmail.com\r\nSubject: Lunch? ~~~\r\n"
        + "Message-ID: <m1@example.com>\r\n\r\nShall we get lunch??? >>> ~~~\r\n"

    @Test func conversationsLoadWholeMessagesFromBase64URL() async throws {
        let raw = WebFixtures.base64url(Self.rawText)
        #expect(raw.contains("-") && raw.contains("_"))  // Really base64url, not plain base64.
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/threads/t1") { _ in
            .json(#"""
            {"id": "t1", "messages": [
                {"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Shall we", "sizeEstimate": 120,
                 "internalDate": "1795446000000"},
                {"id": "m3", "threadId": "t1", "labelIds": ["TRASH"]}]}
            """#)
        }
        transport.on("GET", "\(Self.api)/messages/m1") { _ in
            .json(#"{"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Shall we get lunch", "#
                  + #""sizeEstimate": 120, "internalDate": "1795446000000", "raw": "\#(raw)"}"#)
        }
        let alex = MailAddress(name: "Alex Kim", email: "alex@example.com")
        let hint = Conversation(id: "t1", messages: [MessageSummary(id: "m1", threadID: "t1", from: alex)])
        let messages = try await service(transport).loadConversation(id: "t1", hint: hint)

        #expect(transport.sent("GET", "\(Self.api)/threads/t1").first?.query("format") == "minimal")
        #expect(transport.sent("GET", "\(Self.api)/messages/m1").first?.query("format") == "raw")
        #expect(transport.sent("GET", "\(Self.api)/messages/m3").isEmpty)  // Trashed, and not in the list.
        let message = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(message.summary.id == "m1" && message.summary.threadID == "t1")
        #expect(message.summary.subject == "Lunch? ~~~")
        #expect(message.summary.messageIDHeader == "<m1@example.com>")
        #expect(message.summary.isUnread && message.summary.labelIDs == ["INBOX", "UNREAD"])
        #expect(message.summary.from?.email == "alex@example.com")
        #expect(message.summary.date == WebFixtures.date("2026-11-23T15:00:00Z"))
        #expect(message.textBody?.contains("Shall we get lunch??? >>> ~~~") == true)
        #expect(message.rawSource == Data(Self.rawText.utf8))
    }

    // MARK: Actions

    private func summary(_ id: String, labels: [String] = ["INBOX"]) -> MessageSummary {
        MessageSummary(id: id, threadID: "t1", labelIDs: labels)
    }

    @Test func labelActionsSendBatchModify() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/messages/batchModify") { _ in .status(204) }
        let mail = service(transport)
        let messages = [summary("m1"), summary("m2")]
        try await mail.perform(.markRead, on: messages)
        try await mail.perform(.markUnread, on: messages)
        try await mail.perform(.star, on: messages)
        try await mail.perform(.markImportant, on: messages)
        try await mail.perform(.archive, on: messages)
        try await mail.perform(.markSpam, on: messages)
        try await mail.perform(.notSpam, on: messages)
        try await mail.perform(.move(toFolderID: "Label_1"), on: messages)
        try await mail.perform(.addLabel("Label_2"), on: messages)
        try await mail.perform(.removeLabel("Label_2"), on: messages)
        try await mail.perform(.moveToInbox, on: [summary("m9", labels: ["TRASH"])])

        let bodies = transport.sent("POST", "\(Self.api)/messages/batchModify").map(\.bodyJSONValue)
        let ids: JSONValue = ["m1", "m2"]
        #expect(bodies == [
            ["ids": ids, "removeLabelIds": ["UNREAD"]],
            ["ids": ids, "addLabelIds": ["UNREAD"]],
            ["ids": ids, "addLabelIds": ["STARRED"]],
            ["ids": ids, "addLabelIds": ["IMPORTANT"]],
            ["ids": ids, "removeLabelIds": ["INBOX"]],
            ["ids": ids, "addLabelIds": ["SPAM"], "removeLabelIds": ["INBOX"]],
            ["ids": ids, "addLabelIds": ["INBOX"], "removeLabelIds": ["SPAM"]],
            ["ids": ids, "addLabelIds": ["Label_1"], "removeLabelIds": ["INBOX"]],
            ["ids": ids, "addLabelIds": ["Label_2"]],
            ["ids": ids, "removeLabelIds": ["Label_2"]],
            ["ids": ["m9"], "addLabelIds": ["INBOX"], "removeLabelIds": ["TRASH"]],
        ])
    }

    @Test func trashAndDeleteForever() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/messages/") { _ in .json(#"{"id": "m1", "labelIds": ["TRASH"]}"#) }
        transport.on("POST", "\(Self.api)/messages/batchDelete") { _ in .status(204) }
        let mail = service(transport)
        try await mail.perform(.trash, on: [summary("m1"), summary("m2"), summary("m1")])
        let trashed = Set(transport.requests.compactMap { $0.url?.path })
        #expect(trashed == ["\(Self.api)/messages/m1/trash", "\(Self.api)/messages/m2/trash"])

        try await mail.perform(.deleteForever, on: [summary("m1"), summary("m2")])
        #expect(transport.sent("POST", "\(Self.api)/messages/batchDelete").first?.bodyJSONValue == ["ids": ["m1", "m2"]])
    }

    // MARK: Sending and drafts

    private let jamie = MailAddress(name: "Jamie Rivera", email: "jamie@gmail.com")

    @Test func sendingUploadsBase64URLWithTheThread() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/messages/send") { _ in .json(#"""
        {"id": "m20", "threadId": "t1", "labelIds": ["SENT"]}
        """#) }
        let message = OutgoingMessage(from: jamie, to: [MailAddress(name: "Alex Kim", email: "alex@example.com")],
                                      bcc: [MailAddress(email: "boss@example.com")], subject: "Re: Lunch? ~~~",
                                      textBody: "Yes please??? >>>", inReplyTo: "<m1@example.com>", threadID: "t1")
        try await service(transport).send(message)

        let body = try #require(transport.sent("POST", "\(Self.api)/messages/send").first?.bodyJSONValue)
        #expect(body["threadId"].string == "t1")
        let raw = try #require(body["raw"].string)
        #expect(!raw.contains("+") && !raw.contains("/") && !raw.contains("="))
        let text = String(decoding: try #require(TransferEncoding.decodeBase64(raw)), as: UTF8.self)
        #expect(text.contains("Subject: Re: Lunch? ~~~"))
        #expect(text.contains("Bcc: boss@example.com"))
        #expect(text.contains("Yes please??? >>>"))
    }

    @Test func draftsAreCreatedReplacedAndDeleted() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/drafts") { _ in
            .json(#"{"id": "r-1", "message": {"id": "m10", "threadId": "t10", "labelIds": ["DRAFT"]}}"#)
        }
        transport.on("PUT", "\(Self.api)/drafts/r-1") { _ in
            .json(#"{"id": "r-1", "message": {"id": "m11", "threadId": "t10", "labelIds": ["DRAFT"]}}"#)
        }
        transport.on("DELETE", "\(Self.api)/drafts/r-1") { _ in .status(204) }
        let mail = service(transport)
        let first = OutgoingMessage(from: jamie, to: [MailAddress(email: "alex@example.com")], subject: "Plans", textBody: "Maybe")
        let saved = try #require(try await mail.saveDraft(first, replacing: nil))
        #expect(saved.id == "m10" && saved.threadID == "t10" && saved.isDraft && saved.labelIDs == ["DRAFT"])
        #expect(saved.messageIDHeader == first.messageID)
        let created = try #require(transport.sent("POST", "\(Self.api)/drafts").first?.bodyJSONValue)
        #expect(created["message"]["raw"].string != nil && created["message"]["threadId"].isNull)

        var second = first
        second.textBody = "Definitely"
        let replaced = try #require(try await mail.saveDraft(second, replacing: saved))
        #expect(replaced.id == "m11")
        let put = try #require(transport.sent("PUT", "\(Self.api)/drafts/r-1").first?.bodyJSONValue)
        #expect(put["id"].string == "r-1" && put["message"]["threadId"].string == "t10")
        let text = String(decoding: TransferEncoding.decodeBase64(put["message"]["raw"].string ?? "") ?? Data(), as: UTF8.self)
        #expect(text.contains("Definitely"))
        #expect(transport.sent("GET", "\(Self.api)/drafts").isEmpty)  // Remembered, not looked up.

        try await mail.deleteDraft(replaced)
        #expect(transport.sent("DELETE", "\(Self.api)/drafts/r-1").count == 1)
    }

    @Test func draftsSavedElsewhereAreFoundByListing() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/drafts") { request in
            request.query("pageToken") == nil
                ? .json(#"{"drafts": [{"id": "r-7", "message": {"id": "m70", "threadId": "t70"}}], "nextPageToken": "d2"}"#)
                : .json(#"{"drafts": [{"id": "r-9", "message": {"id": "m90", "threadId": "t90"}}]}"#)
        }
        transport.on("DELETE", "\(Self.api)/drafts/r-9") { _ in .status(204) }
        try await service(transport).deleteDraft(MessageSummary(id: "m90", threadID: "t90", labelIDs: ["DRAFT"], isDraft: true))
        #expect(transport.sent("GET", "\(Self.api)/drafts").count == 2)
        #expect(transport.sent("DELETE", "\(Self.api)/drafts/r-9").count == 1)
    }

    @Test func aTurnedDownTokenIsRefreshedForGoogleMail() async throws {
        let transport = StubTransport()
        let tokens = WebTestTokens()
        transport.on("GET", "\(Self.api)/labels") { request in
            request.authorization == "Bearer token-1" ? .status(401) : .json(#"{"labels": [{"id": "INBOX", "type": "system"}]}"#)
        }
        let folders = try await service(transport, tokens: tokens).loadFolders()
        #expect(folders.map(\.role) == [.inbox])
        #expect(tokens.invalidations == 1)
    }
}
