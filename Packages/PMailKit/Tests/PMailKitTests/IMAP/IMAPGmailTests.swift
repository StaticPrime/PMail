import Foundation
import Testing
@testable import PMailKit

/// A Google account's mail over IMAP, the Gmail way: labels, Gmail's special folders and names, category tabs and
/// search through Gmail's own search, whole conversations by Gmail's conversation IDs, and sent mail Gmail files
/// itself.
@Suite(.timeLimit(.minutes(1))) struct IMAPGmailTests {
    private typealias Script = IMAPScript
    private typealias Step = ScriptedByteStream.Step

    static let capabilities = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS ENABLE MOVE "
        + "CONDSTORE ESEARCH UTF8=ACCEPT LIST-EXTENDED LITERAL- SPECIAL-USE SASL-IR AUTH=XOAUTH2"

    private func service(_ streams: [ScriptedByteStream], sender: IMAPRecordingSender = IMAPRecordingSender()) -> IMAPMailService {
        let account = Account(kind: .google, name: "Pug Tester", email: "pug@gmail.com")
        let incoming = ServerSettings(mailProtocol: .imap, host: "imap.gmail.com", security: .tls, username: "pug@gmail.com",
                                      authentication: .oauth2)
        return IMAPMailService(account: account, incoming: incoming,
                               credential: .oauth(username: "pug@gmail.com", tokens: IMAPFakeTokens(["token-1"])),
                               sender: sender, connector: ScriptedConnector(streams))
    }

    private static func signIn(_ tag: String) -> Step {
        .expect("\(tag) AUTHENTICATE XOAUTH2 \(SASL.xoauth2(username: "pug@gmail.com", accessToken: "token-1"))",
                reply: "\(tag) OK [CAPABILITY \(capabilities)] pug@gmail.com authenticated (Success)\r\n")
    }

    private static let mailboxes = [
        #"* LIST (\HasNoChildren) "/" "INBOX""#,
        #"* LIST (\HasChildren \Noselect) "/" "[Gmail]""#,
        #"* LIST (\All \HasNoChildren) "/" "[Gmail]/All Mail""#,
        #"* LIST (\Drafts \HasNoChildren) "/" "[Gmail]/Drafts""#,
        #"* LIST (\HasNoChildren \Important) "/" "[Gmail]/Important""#,
        #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#,
        #"* LIST (\HasNoChildren \Junk) "/" "[Gmail]/Spam""#,
        #"* LIST (\Flagged \HasNoChildren) "/" "[Gmail]/Starred""#,
        #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#,
        #"* LIST (\HasChildren) "/" "Work""#,
        #"* LIST (\HasNoChildren) "/" "Work/Projects""#,
        #"* LIST (\HasNoChildren) "/" "Sent""#,
    ]

    private static func list(_ tag: String) -> Step {
        .expect("\(tag) LIST \"\" \"*\"", reply: (mailboxes + ["\(tag) OK Success"]).map { $0 + "\r\n" }.joined())
    }

    private static func status(_ tag: String, _ mailbox: String, messages: Int, unseen: Int) -> Step {
        Script.ok(tag, #"STATUS "\#(mailbox)" (MESSAGES UNSEEN)"#,
                  untagged: [#"* STATUS "\#(mailbox)" (MESSAGES \#(messages) UNSEEN \#(unseen))"#])
    }

    private static let summaryFetch = "(\(IMAPClient.summaryItems) X-GM-THRID X-GM-LABELS)"

    /// A list row as Gmail gives it, with its conversation ID and labels (no structure, so no snippet is fetched).
    private static func row(_ sequence: Int, uid: UInt32, flags: String, subject: String, messageID: String, thread: String,
                            labels: String, date: String = "Sat, 21 Nov 2026 13:45:00 -0500") -> String {
        #"* \#(sequence) FETCH (UID \#(uid) FLAGS (\#(flags)) INTERNALDATE "21-Nov-2026 18:45:05 +0000" RFC822.SIZE 1200 "#
            + #"ENVELOPE ("\#(date)" "\#(subject)" (("Alex Kim" NIL "alex" "example.com")) NIL NIL "#
            + #"((NIL NIL "pug" "gmail.com")) NIL NIL NIL "\#(messageID)") X-GM-THRID \#(thread) X-GM-LABELS (\#(labels)))"#
    }

    @Test func aGoogleAccountWorksTheGmailWay() {
        let mail = service([])
        #expect(mail.isGmail)
        #expect(mail.capabilities.usesLabels && mail.capabilities.canMarkImportant && mail.capabilities.hasInboxTabs)
        #expect(mail.inboxTabs.map(\.id) == GoogleMailService.tabs.map(\.id))
        #expect(!mail.capabilities.canEditLabels && !mail.capabilities.syncsSignature, "those need Google's mail API")
    }

    @Test func gmailsFoldersShowWithGmailsNamesAndTheRestAsLabels() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Self.list("A2"),
            Self.status("A3", "INBOX", messages: 120, unseen: 7),
            Self.status("A4", "[Gmail]/Drafts", messages: 2, unseen: 0),
            Self.status("A5", "[Gmail]/Spam", messages: 9, unseen: 3),
            Self.status("A6", "Work", messages: 40, unseen: 1),
            Self.status("A7", "Work/Projects", messages: 12, unseen: 2),
            Self.status("A8", "Sent", messages: 5, unseen: 0),
        ])
        let folders = try await service([stream]).loadFolders()
        let special = folders.filter { $0.kind == .folder }
        #expect(special.map(\.name) == ["Inbox", "Starred", "Important", "Sent", "Drafts", "All Mail", "Spam", "Trash"])
        #expect(special.map(\.role) == [.inbox, .starred, .important, .sent, .drafts, .allMail, .spam, .trash])
        #expect(special.first { $0.role == .sent }?.id == "[Gmail]/Sent Mail")
        #expect(special.first { $0.role == .inbox }?.unreadCount == 7 && special.first { $0.role == .spam }?.unreadCount == 3)
        #expect(special.first { $0.role == .drafts }?.unreadCount == 2, "Drafts counts its drafts")
        let labels = folders.filter { $0.kind == .label }
        #expect(labels.map(\.id) == ["Sent", "Work", "Work/Projects"], "a label named Sent stays a label")
        #expect(labels.last?.name == "Projects" && labels.last?.parentID == "Work" && labels.last?.unreadCount == 2)
        #expect(!folders.contains { $0.id == "[Gmail]" || $0.id == IMAPMailService.starredFolderID })
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func theInboxTabsAndSearchUseGmailsOwnSearch() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", #"UID SEARCH X-GM-RAW "category:primary""#, untagged: ["* SEARCH 21 22 23"]),
            .expect("A4 UID FETCH 21:23 \(Self.summaryFetch)", reply: Script.lines(
                Self.row(1, uid: 21, flags: #"\Seen"#, subject: "Park day", messageID: "<a@example.com>", thread: "1790000000000000001",
                         labels: #"\Inbox \Important "Work/Projects""#),
                Self.row(2, uid: 22, flags: "", subject: "Re: Park day", messageID: "<b@example.com>", thread: "1790000000000000001",
                         labels: #"\Inbox "Caf&AOk-""#, date: "Sat, 21 Nov 2026 15:00:00 -0500"),
                Self.row(3, uid: 23, flags: #"\Flagged"#, subject: "Pug meetup", messageID: "<c@example.com>", thread: "1790000000000000002",
                         labels: #"\Inbox"#, date: "Sat, 21 Nov 2026 16:00:00 -0500"),
                "A4 OK Success")),
            Self.list("A5"),
            Script.select("A6", "[Gmail]/All Mail", readOnly: true),
            Script.ok("A7", #"UID SEARCH X-GM-RAW "from:alex has:attachment""#, untagged: ["* SEARCH"]),
        ])
        let mail = service([stream])
        let primary = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PERSONAL"))
        #expect(primary.conversations.map(\.id) == ["1790000000000000002", "1790000000000000001"], "Gmail's conversations, newest first")
        let park = try #require(primary.conversations.last)
        #expect(park.messages.map(\.id) == [IMAPMessageID.inbox(21), IMAPMessageID.inbox(22)])
        #expect(park.messages[0].labelIDs == ["INBOX", "Work/Projects"] && park.messages[0].isImportant)
        #expect(park.messages[1].labelIDs == ["INBOX", "Café"] && !park.messages[1].isImportant && park.messages[1].isUnread)
        let found = try await mail.listConversations(ListRequest(folderID: nil, query: "from:alex has:attachment"))
        #expect(found.conversations.isEmpty)
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func actionsWorkOnLabelsTheGmailWay() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Self.list("A2"),
            Script.select("A3"),
            Script.ok("A4", #"UID STORE 21 -X-GM-LABELS (\Inbox)"#),
            Script.ok("A5", #"UID STORE 21 +X-GM-LABELS ("Work/Projects")"#),
            Script.ok("A6", #"UID STORE 21 +X-GM-LABELS (\Important)"#),
            Script.ok("A7", #"UID MOVE 21 "Work""#),
            Script.select("A8", "[Gmail]/All Mail"),
            // Move to a label from All Mail: the label goes on and the message leaves the inbox, as Gmail's Move to does.
            Script.ok("A9", #"UID STORE 5 +X-GM-LABELS ("Work")"#),
            Script.ok("A10", #"UID STORE 5 -X-GM-LABELS (\Inbox)"#),
            Script.ok("A11", #"UID STORE 5 +X-GM-LABELS (\Inbox)"#),
            Script.ok("A12", #"UID MOVE 5 "[Gmail]/Trash""#),
        ])
        let mail = service([stream])
        let inbox = MessageSummary(id: IMAPMessageID.inbox(21), threadID: "1")
        let archived = MessageSummary(id: IMAPMessageID(mailbox: "[Gmail]/All Mail", uidValidity: 7, uid: 5).rawValue, threadID: "2")
        try await mail.perform(.archive, on: [inbox])
        try await mail.perform(.addLabel("Work/Projects"), on: [inbox])
        try await mail.perform(.markImportant, on: [inbox])
        try await mail.perform(.move(toFolderID: "Work"), on: [inbox])
        try await mail.perform(.move(toFolderID: "Work"), on: [archived])
        try await mail.perform(.moveToInbox, on: [archived])
        try await mail.perform(.trash, on: [archived])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func aConversationOpensWholeFromAllMail() async throws {
        let message = { (id: String, subject: String, date: String) in
            "Message-ID: <\(id)@example.com>\r\nDate: \(date)\r\nFrom: Alex Kim <alex@example.com>\r\nSubject: \(subject)\r\n\r\nHello\r\n"
        }
        let first = message("a", "Park day", "Sat, 21 Nov 2026 13:45:00 -0500")
        let reply = message("b", "Re: Park day", "Sat, 21 Nov 2026 15:00:00 -0500")
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", readOnly: true),
            .expect("A3 UID FETCH 21 (UID FLAGS BODY.PEEK[])", reply: Script.lines(
                #"* 1 FETCH (UID 21 FLAGS (\Seen) BODY[] "# + Script.literal(first) + ")", "A3 OK Success")),
            Self.list("A4"),
            Script.select("A5", "[Gmail]/All Mail", readOnly: true),
            Script.ok("A6", "UID SEARCH X-GM-THRID 1790000000000000001", untagged: ["* SEARCH 5 6"]),
            .expect("A7 UID FETCH 5:6 (\(IMAPClient.summaryItems) X-GM-THRID X-GM-LABELS BODY.PEEK[])", reply: Script.lines(
                Self.row(1, uid: 5, flags: #"\Seen"#, subject: "Park day", messageID: "<a@example.com>", thread: "1790000000000000001",
                         labels: #"\Inbox"#).dropLast() + " BODY[] " + Script.literal(first) + ")",
                Self.row(2, uid: 6, flags: #"\Seen"#, subject: "Re: Park day", messageID: "<b@example.com>", thread: "1790000000000000001",
                         labels: #"\Sent"#, date: "Sat, 21 Nov 2026 15:00:00 -0500").dropLast() + " BODY[] " + Script.literal(reply) + ")",
                "A7 OK Success")),
        ])
        let hint = Conversation(id: "1790000000000000001", messages: [
            MessageSummary(id: IMAPMessageID.inbox(21), threadID: "1790000000000000001", folderID: "INBOX", subject: "Park day",
                           date: Date(timeIntervalSince1970: 1_795_200_300), messageIDHeader: "<a@example.com>"),
        ])
        let messages = try await service([stream]).loadConversation(id: "1790000000000000001", hint: hint)
        #expect(messages.map(\.summary.subject) == ["Park day", "Re: Park day"], "with the reply sent from the account")
        #expect(messages.first?.id == IMAPMessageID.inbox(21), "the message the list showed keeps its ID")
        #expect(messages.last?.summary.folderID == "[Gmail]/All Mail")
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func sentMailIsFiledByGmailItself() async throws {
        let sender = IMAPRecordingSender()
        let mail = service([], sender: sender)
        try await mail.send(OutgoingMessage(from: MailAddress(name: "Pug", email: "pug@gmail.com"), to: [MailAddress(email: "alex@example.com")],
                                            subject: "Hi", textBody: "Hello"))
        #expect(sender.sent.count == 1, "sent, and no copy put in Sent (there's no IMAP connection to make one)")
    }

    @Test func theTabsCountTheirUnreadMailByGmailsSearch() async throws {
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", #"UID SEARCH UNSEEN X-GM-RAW "category:primary""#, untagged: ["* SEARCH 4 9"]),
            Script.ok("A4", #"UID SEARCH UNSEEN X-GM-RAW "category:promotions""#, untagged: ["* SEARCH 11 12 13"]),
            Script.ok("A5", #"UID SEARCH UNSEEN X-GM-RAW "category:social""#, untagged: ["* SEARCH"]),
            Script.ok("A6", #"UID SEARCH UNSEEN X-GM-RAW "category:updates""#, untagged: ["* SEARCH 20"]),
            Script.ok("A7", #"UID SEARCH UNSEEN X-GM-RAW "category:forums""#, untagged: ["* SEARCH"]),
        ])
        let counts = try await service([stream]).unreadCounts(inTabs: GoogleMailService.tabs)
        #expect(counts == ["CATEGORY_PERSONAL": 2, "CATEGORY_PROMOTIONS": 3, "CATEGORY_SOCIAL": 0, "CATEGORY_UPDATES": 1,
                           "CATEGORY_FORUMS": 0])
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func anotherPageOfTheSameListDoesntSearchAgain() async throws {
        let rows = (1...3).map { index in
            Self.row(index, uid: UInt32(20 + index), flags: #"\Seen"#, subject: "Note \(index)", messageID: "<n\(index)@example.com>",
                     thread: "17900000000000000\(10 + index)", labels: #"\Inbox"#)
        }
        let stream = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", #"UID SEARCH X-GM-RAW "category:primary""#, untagged: ["* SEARCH 21 22 23"]),
            .expect("A4 UID FETCH 22:23 \(Self.summaryFetch)", reply: Script.lines(rows[2], rows[1], "A4 OK Success")),
            // The second page: the mailbox is the same, so the search is too.
            Script.select("A5", readOnly: true),
            .expect("A6 UID FETCH 21 \(Self.summaryFetch)", reply: Script.lines(rows[0], "A6 OK Success")),
            // An action changes what's listed: the list is searched again.
            Self.list("A7"),
            Script.select("A8"),
            Script.ok("A9", #"UID STORE 21 -X-GM-LABELS (\Inbox)"#),
            Script.select("A10", readOnly: true),
            Script.ok("A11", #"UID SEARCH X-GM-RAW "category:primary""#, untagged: ["* SEARCH 22 23"]),
            .expect("A12 UID FETCH 22:23 \(Self.summaryFetch)", reply: Script.lines(rows[2], rows[1], "A12 OK Success")),
        ])
        let mail = service([stream])
        let first = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PERSONAL", pageSize: 2))
        #expect(first.conversations.count == 2 && first.nextPageToken == "1")
        let second = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PERSONAL", pageSize: 2,
                                                                  pageToken: first.nextPageToken, pageIndex: 1))
        #expect(second.conversations.map(\.messages.first?.subject) == ["Note 1"])
        try await mail.perform(.archive, on: [MessageSummary(id: IMAPMessageID.inbox(21), threadID: "x")])
        _ = try await mail.listConversations(ListRequest(folderID: "INBOX", tabID: "CATEGORY_PERSONAL", pageSize: 2))
        #expect(stream.mismatches.isEmpty && stream.isFinished)
    }

    @Test func backgroundWorkHasAConnectionOfItsOwn() async throws {
        let main = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", "Work", readOnly: true),
            Script.ok("A3", "UID SEARCH ALL", untagged: ["* SEARCH"]),
        ])
        let background = ScriptedByteStream(greeting: Script.greeting(Self.capabilities), script: [
            Self.signIn("A1"),
            Script.select("A2", readOnly: true),
            Script.ok("A3", #"UID SEARCH UNSEEN X-GM-RAW "category:primary""#, untagged: ["* SEARCH 4"]),
        ])
        let mail = service([main, background])
        _ = try await mail.listConversations(ListRequest(folderID: "Work"))
        let counts = try await BackgroundWork.run { try await mail.unreadCounts(inTabs: Array(GoogleMailService.tabs.prefix(1))) }
        #expect(counts == ["CATEGORY_PERSONAL": 1])
        #expect(main.mismatches.isEmpty && main.isFinished && background.mismatches.isEmpty && background.isFinished)
    }

    @Test func gmailSearchKeysAndLabelsReadSafely() {
        var builder = IMAPCommandBuilder()
        IMAPSearchKey.gmailThread("12; DELETE").write(into: &builder)
        #expect(builder.parts == [.text("NOT ALL")], "a conversation ID that isn't a number matches nothing")
        #expect(IMAPMailService.gmailLabelIDs(["\\Inbox", "\\Sent", "\\Important", "Work"]) == ["INBOX", "Work"])
        #expect(IMAPMailService.gmailSearchKeys(for: ListRequest(folderID: "INBOX", tabID: "CATEGORY_SOCIAL"), in: "INBOX")
            == [.gmailSearch("category:social")])
        #expect(IMAPMailService.gmailSearchKeys(for: ListRequest(folderID: "Work"), in: "Work").isEmpty)
    }
}
