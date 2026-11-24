import Foundation
import Testing
@testable import PMailKit

@Suite struct IMAPParserTests {
    private func parse(_ text: String) throws -> IMAPResponse {
        try IMAPParser.parse(Data(text.utf8))
    }

    @Test func atomsStringsNilAndNestedLists() throws {
        let values = try IMAPParser.parseValues(#"FLAGS (\Seen \Flagged) "say \"hi\" \\ bye" NIL nil "NIL" (a (b (c NIL)) ())"#)
        #expect(values.count == 7)
        #expect(values[0] == .atom("FLAGS"))
        #expect(values[1] == .list([.atom("\\Seen"), .atom("\\Flagged")]))
        #expect(values[2].text == #"say "hi" \ bye"#)
        #expect(values[3] == .null)
        #expect(values[4] == .null)
        #expect(values[5] == .string(Data("NIL".utf8)))
        #expect(values[6] == .list([.atom("a"), .list([.atom("b"), .list([.atom("c"), .null])]), .list([])]))
        #expect(try IMAPParser.parseValues("4294967295 12").map(\.uint32) == [4_294_967_295, 12])
    }

    @Test func literalsInTheMiddleOfAResponse() throws {
        let header = "Subject: Hi there\r\n\r\n"
        let response = try parse("* 12 FETCH (UID 7 BODY[HEADER.FIELDS (SUBJECT)] \(IMAPScript.literal(header)) FLAGS (\\Seen) "
            + "BODY[1]<0> \(IMAPScript.literal("")) BODY[2] ~\(IMAPScript.literal("bin")))")
        guard case let .untagged(.fetch(fetch)) = response else {
            Issue.record("expected a FETCH response, got \(response)")
            return
        }
        #expect(fetch.sequenceNumber == 12)
        #expect(fetch.uid == 7)
        #expect(fetch.flags == ["\\Seen"])
        #expect(fetch.section("header.fields  ( subject )") == Data(header.utf8))
        #expect(fetch.section("1") == Data())
        #expect(fetch.section("2") == Data("bin".utf8))
        #expect(fetch.headerFields == Data(header.utf8))
    }

    @Test func wholeResponsesAreReadAcrossLiterals() async throws {
        let body = "hello\r\nworld"
        let stream = ScriptedByteStream(greeting: IMAPScript.lines(
            "* 1 FETCH (UID 5 BODY[] \(IMAPScript.literal(body)) BODY[1] \(IMAPScript.literal("abc")))",
            "* OK [ALERT] Words that end like a literal {5}",
            "A1 OK fine"), script: [])
        let connection = LineConnection(stream: stream)
        let first = try IMAPParser.parse(try await IMAPParser.readResponseData(from: connection))
        guard case let .untagged(.fetch(fetch)) = first else {
            Issue.record("expected a FETCH response, got \(first)")
            return
        }
        #expect(fetch.uid == 5)
        #expect(fetch.section("") == Data(body.utf8))
        #expect(fetch.section("1") == Data("abc".utf8))
        let second = try IMAPParser.parse(try await IMAPParser.readResponseData(from: connection))
        let alert = IMAPStatusResponse(status: .ok, code: .alert, text: "Words that end like a literal {5}")
        #expect(second == .untagged(.condition(alert)))
        let third = try IMAPParser.parse(try await IMAPParser.readResponseData(from: connection))
        #expect(third == .tagged(tag: "A1", IMAPStatusResponse(status: .ok, text: "fine")))
    }

    @Test func responseCodes() throws {
        func code(_ line: String) throws -> IMAPResponseCode? {
            switch try parse(line) {
            case let .untagged(.condition(status)), let .tagged(_, status): return status.code
            default: return nil
            }
        }
        #expect(try code("* OK [UIDVALIDITY 3857529045] UIDs valid") == .uidValidity(3_857_529_045))
        #expect(try code("* OK [UIDNEXT 4392] Predicted next UID") == .uidNext(4392))
        #expect(try code("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] Ready")
            == .capability(["IMAP4rev1", "AUTH=PLAIN", "SASL-IR"]))
        #expect(try code(#"* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited"#) == .permanentFlags(["\\Deleted", "\\Seen", "\\*"]))
        #expect(try code("A3 OK [APPENDUID 38505 3955] APPEND completed") == .appendUID(uidValidity: 38505, uid: 3955))
        #expect(try code("A4 OK [COPYUID 38505 304,319:320 3956:3958] Done")
            == .copyUID(uidValidity: 38505, source: [304, 319, 320], destination: [3956, 3957, 3958]))
        #expect(try code("A5 NO [TRYCREATE] No such mailbox") == .tryCreate)
        #expect(try code("* NO [ALERT] Shutting down in 10 minutes") == .alert)
        #expect(try code("A6 OK [READ-WRITE] SELECT completed") == .readWrite)
        #expect(try code("A7 OK [READ-ONLY] EXAMINE completed") == .readOnly)
        #expect(try code("* OK [UNSEEN 12] First unseen") == .unseen(12))
        #expect(try code("* OK [HIGHESTMODSEQ 715194045007] Highest") == .highestModSeq(715194045007))
        #expect(try code("* OK [UIDVALIDITY nope] Odd") == .other(name: "UIDVALIDITY", text: "nope"))
        #expect(try code("A8 OK Plain words") == nil)
    }

    @Test func taggedUntaggedAndContinuationResponses() throws {
        #expect(try parse("+ Ready for literal data") == .continuation("Ready for literal data"))
        #expect(try parse("+") == .continuation(""))
        #expect(try parse("A1 OK LOGIN completed") == .tagged(tag: "A1", IMAPStatusResponse(status: .ok, text: "LOGIN completed")))
        #expect(try parse("A2 no [AUTHENTICATIONFAILED] Wrong password")
            == .tagged(tag: "A2", IMAPStatusResponse(status: .no, code: .other(name: "AUTHENTICATIONFAILED", text: ""),
                                                     text: "Wrong password")))
        #expect(try parse("* 23 EXISTS") == .untagged(.exists(23)))
        #expect(try parse("* 5 RECENT") == .untagged(.recent(5)))
        #expect(try parse("* 3 EXPUNGE") == .untagged(.expunge(3)))
        #expect(try parse("* SEARCH 2 84 882") == .untagged(.search([2, 84, 882])))
        #expect(try parse("* SEARCH") == .untagged(.search([])))
        #expect(try parse("* SEARCH 4 9 (MODSEQ 917162500)") == .untagged(.search([4, 9])))
        #expect(try parse("* CAPABILITY IMAP4rev1 STARTTLS AUTH=GSSAPI")
            == .untagged(.capability(["IMAP4rev1", "STARTTLS", "AUTH=GSSAPI"])))
        #expect(try parse(#"* FLAGS (\Answered \Seen $Forwarded)"#) == .untagged(.flags(["\\Answered", "\\Seen", "$Forwarded"])))
        #expect(try parse("* BYE Autologout; idle for too long")
            == .untagged(.condition(IMAPStatusResponse(status: .bye, text: "Autologout; idle for too long"))))
        #expect(try parse("* PREAUTH Welcome back")
            == .untagged(.condition(IMAPStatusResponse(status: .preauth, text: "Welcome back"))))
        #expect(try parse("* ENABLED CONDSTORE") == .untagged(.other(name: "ENABLED", values: [.atom("CONDSTORE")])))
    }

    @Test func listResponsesWithSpecialUseAndModifiedUTF7() throws {
        func mailbox(_ line: String) throws -> IMAPMailbox? {
            if case let .untagged(.list(mailbox)) = try parse(line) { return mailbox }
            return nil
        }
        let sent = try #require(try mailbox(#"* LIST (\HasNoChildren \Sent) "/" "Sent Messages""#))
        #expect(sent.name == "Sent Messages" && sent.delimiter == "/" && sent.specialUseRole == .sent && sent.isSelectable)
        let cafe = try #require(try mailbox(#"* LIST (\HasNoChildren) "/" "Projects/Caf&AOk-""#))
        #expect(cafe.name == "Projects/Café" && cafe.rawName == "Projects/Caf&AOk-")
        #expect(cafe.parentName == "Projects" && cafe.displayName == "Café")
        let old = try #require(try mailbox(#"* LIST (\Noselect \HasChildren) "/" Old"#))
        #expect(!old.isSelectable && old.name == "Old")
        let drafts = try #require(try mailbox(#"* LIST (\Drafts) "." INBOX.Drafts"#))
        #expect(drafts.parentName == "INBOX" && drafts.displayName == "Drafts" && drafts.specialUseRole == .drafts)
        let inbox = try #require(try mailbox(#"* LIST (\HasChildren) "." Inbox"#))
        #expect(inbox.isInbox && inbox.name == "INBOX" && inbox.specialUseRole == .inbox)
        let flat = try #require(try mailbox(#"* LIST () NIL "Receipts""#))
        #expect(flat.delimiter == nil && flat.parentName == nil)
        let literal = try #require(try mailbox("* LIST (\\Junk \\HasNoChildren) \"/\" \(IMAPScript.literal("Spam"))"))
        #expect(literal.name == "Spam" && literal.specialUseRole == .spam)
        let all = try #require(try mailbox(#"* LIST (\All \HasNoChildren) "/" "All Mail""#))
        #expect(all.specialUseRole == .allMail)
        let ghost = try #require(try mailbox(#"* LIST (\NonExistent) "/" "Gone""#))
        #expect(!ghost.isSelectable)
    }

    @Test func statusResponses() throws {
        let response = try parse(#"* STATUS "Projects/Caf&AOk-" (MESSAGES 231 UNSEEN 4 UIDNEXT 44292 UIDVALIDITY 1)"#)
        #expect(response == .untagged(.status(mailbox: "Projects/Café",
                                              attributes: ["MESSAGES": 231, "UNSEEN": 4, "UIDNEXT": 44292, "UIDVALIDITY": 1])))
        #expect(try parse("* STATUS inbox (UNSEEN 0)") == .untagged(.status(mailbox: "INBOX", attributes: ["UNSEEN": 0])))
    }

    @Test func malformedResponsesNeverCrash() throws {
        let samples = [
            #"* 1 FETCH (UID 5 FLAGS (\Seen"#,
            "* 1 FETCH (BODY[] {500}\r\nshort)",
            "* 1 FETCH (BODY[] {99999999999999999999}\r\n)",
            #"* LIST (\Noselect) "/"#,
            "* LIST",
            "* STATUS",
            "* 1 FETCH (" + String(repeating: "(", count: 20_000),
            "* OK [UNCLOSED code without end",
            #"* 1 FETCH (ENVELOPE (NIL) BODYSTRUCTURE ("TEXT") UID x INTERNALDATE "nonsense" BODY[ "#,
            "* 1 FETCH (BODYSTRUCTURE ((((((((NIL)))))))) ENVELOPE ((((NIL)))))",
            "* 1 FETCH (ENVELOPE (\"\" \"\" ((NIL NIL NIL NIL) (1 2)) NIL NIL NIL NIL NIL NIL NIL))",
            "* COPYUID",
            "*",
            "",
            "A1",
            "A1 MAYBE",
            "+ ",
            "\u{0}\u{1}\u{2}",
        ]
        for sample in samples {
            _ = try? parse(sample)
        }
        #expect(try parse(#"* 1 FETCH (UID 5 FLAGS (\Seen"#) == .untagged(.other(name: "1", values: [])))
        #expect(throws: PMailError.self) { try parse("A1 MAYBE so") }
        #expect(try parse("* OK [UNCLOSED code without end") == .untagged(.condition(IMAPStatusResponse(
            status: .ok, code: .other(name: "UNCLOSED", text: "code without end"), text: ""))))
    }

    @Test func literalLengthsAreOnlyLookedForWhereLiteralsCanBe() {
        #expect(IMAPParser.literalLength(atEndOf: Data("* 1 FETCH (BODY[] {42}".utf8)) == 42)
        #expect(IMAPParser.literalLength(atEndOf: Data("A1 APPEND x {7+}".utf8)) == 7)
        #expect(IMAPParser.literalLength(atEndOf: Data("* 1 FETCH (BODY[] {4x}".utf8)) == nil)
        #expect(IMAPParser.literalLength(atEndOf: Data("no literal here".utf8)) == nil)
        #expect(IMAPParser.mayCarryLiterals(Data("* 1 FETCH (BODY[] {42}".utf8)))
        #expect(IMAPParser.mayCarryLiterals(Data("* LIST () \"/\" {4}".utf8)))
        #expect(!IMAPParser.mayCarryLiterals(Data("* OK [ALERT] see {5}".utf8)))
        #expect(!IMAPParser.mayCarryLiterals(Data("A9 NO quota {5}".utf8)))
        #expect(!IMAPParser.mayCarryLiterals(Data("+ go ahead {5}".utf8)))
    }

    @Test func internalDates() throws {
        let expected = try #require(ISO8601DateFormatter().date(from: "1996-07-17T09:44:25Z"))
        #expect(IMAPDate.parse("17-Jul-1996 02:44:25 -0700") == expected)
        #expect(IMAPDate.parse(" 7-Jul-1996 02:44:25 -0700") == expected.addingTimeInterval(-10 * 86400))
        #expect(IMAPDate.parse("17-jul-1996 09:44:25 +0000") == expected)
        #expect(IMAPDate.parse("17-Jux-1996 02:44:25 -0700") == nil)
        #expect(IMAPDate.parse("garbage") == nil)
        let pacific = try #require(TimeZone(secondsFromGMT: -7 * 3600))
        #expect(IMAPDate.format(expected, timeZone: pacific) == "17-Jul-1996 02:44:25 -0700")
    }

    @Test func modifiedUTF7MailboxNames() {
        #expect(IMAPMailboxName.decode("&AOk-") == "é")
        #expect(IMAPMailboxName.encode("é") == "&AOk-")
        #expect(IMAPMailboxName.decode("Caf&AOk-") == "Café")
        #expect(IMAPMailboxName.encode("Café") == "Caf&AOk-")
        #expect(IMAPMailboxName.decode("Tom &- Jerry") == "Tom & Jerry")
        #expect(IMAPMailboxName.encode("Tom & Jerry") == "Tom &- Jerry")
        #expect(IMAPMailboxName.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-") == "~peter/mail/台北/日本語")
        #expect(IMAPMailboxName.encode("~peter/mail/台北/日本語") == "~peter/mail/&U,BTFw-/&ZeVnLIqe-")
        let emoji = "Pugs 🐶 & friends"
        let encoded = IMAPMailboxName.encode(emoji)
        #expect(encoded.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(IMAPMailboxName.decode(encoded) == emoji)
        // Malformed runs are kept as they came.
        #expect(IMAPMailboxName.decode("Odd &Jjo!") == "Odd &Jjo!")
        #expect(IMAPMailboxName.decode("Odd &!!!-") == "Odd &!!!-")
        #expect(IMAPMailboxName.decode("Odd &A-") == "Odd &A-")
    }

    @Test func sequenceSets() {
        #expect(IMAPSequenceSet.string([7, 1, 2, 3, 9, 10, 2]) == "1:3,7,9:10")
        #expect(IMAPSequenceSet.string([4_294_967_295, 4_294_967_294]) == "4294967294:4294967295")
        #expect(IMAPSequenceSet.parse("304,319:320") == [304, 319, 320])
        #expect(IMAPSequenceSet.parse("5:3") == [3, 4, 5])
        #expect(IMAPSequenceSet.parse("1:4294967295", limit: 3) == [1, 2, 3])
        #expect(IMAPSequenceSet.parse("x,7") == [7])
    }

    @Test func searchKeysRenderWithLiteralsForNonASCII() {
        var builder = IMAPCommandBuilder()
        for (index, key) in IMAPSearchKey.matching(query: "pug \"park day\"").enumerated() {
            if index > 0 { builder.text(" ") }
            key.write(into: &builder)
        }
        #expect(builder.parts == [.text(#"OR OR FROM "pug" SUBJECT "pug" TEXT "pug" "#
            + #"OR OR FROM "park day" SUBJECT "park day" TEXT "park day""#)])
        #expect(!builder.hasNonASCII)

        var unicode = IMAPCommandBuilder()
        IMAPSearchKey.or(.header("In-Reply-To", "<a@b>"), .subject("café")).write(into: &unicode)
        #expect(unicode.parts == [.text(#"OR HEADER In-Reply-To "<a@b>" SUBJECT "#), .literal(Data("café".utf8))])
        #expect(unicode.hasNonASCII)
        #expect(IMAPSearchKey.any([.seen, .flagged, .draft]) == .or(.seen, .or(.flagged, .draft)))
        #expect(IMAPSearchKey.words(in: "  a  \"b c\"d ") == ["a", "b c", "d"])
    }
}

@Suite struct IMAPStructureTests {
    private func value(_ text: String) throws -> IMAPValue {
        try #require(try IMAPParser.parseValues(text).first)
    }

    @Test func envelopesDecodeWordsAndGroups() throws {
        let text = #"("Sat, 21 Nov 2026 13:45:00 -0500" "=?utf-8?Q?Caf=C3=A9_plans?=" "#
            + #"(("=?ISO-8859-1?Q?Andr=E9?= Pug" NIL "andre" "example.com")) NIL NIL "#
            + #"((NIL NIL "team" NIL)("Alex Kim" NIL "alex" "example.com")("Sam" NIL "sam" "example.org")(NIL NIL NIL NIL)"#
            + #"("Pug" NIL "pug" "example.com")) ((NIL NIL "undisclosed-recipients" NIL)(NIL NIL NIL NIL)) NIL "#
            + #""<parent@example.com> (Alex's message)" "<msg-1@example.com>")"#
        let envelope = try #require(IMAPEnvelope(try value(text)))
        #expect(envelope.subject == "Café plans")
        #expect(envelope.from == [MailAddress(name: "André Pug", email: "andre@example.com")])
        #expect(envelope.to.map(\.email) == ["alex@example.com", "sam@example.org", "pug@example.com"])
        #expect(envelope.to.first?.name == "Alex Kim")
        #expect(envelope.cc.isEmpty && envelope.sender.isEmpty && envelope.bcc.isEmpty)
        #expect(envelope.inReplyTo == "<parent@example.com>")
        #expect(envelope.messageID == "<msg-1@example.com>")
        #expect(envelope.date == ISO8601DateFormatter().date(from: "2026-11-21T18:45:00Z"))
    }

    @Test func envelopeSubjectsAsLiteralsAndMissingFields() throws {
        let subject = "Weekend \"plans\" \u{1F436}"
        let envelope = try #require(IMAPEnvelope(try value("(NIL \(IMAPScript.literal(subject)) ((NIL NIL \"root\" \"\")))")))
        #expect(envelope.subject == subject)
        #expect(envelope.from.map(\.email) == ["root"])
        #expect(envelope.date == nil && envelope.messageID == nil)
        #expect(IMAPEnvelope(.atom("ENVELOPE")) == nil)
    }

    @Test func singlePartBodyStructure() throws {
        let part = try #require(IMAPBodyPart.parse(try value(#"("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 3028 92)"#)))
        #expect(part.section == "1")
        #expect(part.mimeType == "text/plain" && part.charset == "US-ASCII" && part.encoding == "7bit")
        #expect(part.size == 3028 && part.lines == 92)
        #expect(part.snippetPart == part)
        #expect(!part.hasAttachments)
    }

    @Test func alternativeBodyStructure() throws {
        let text = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 120 4 NIL NIL NIL NIL)"#
            + #"("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 450 10 NIL NIL NIL NIL) "#
            + #""ALTERNATIVE" ("BOUNDARY" "b1") NIL NIL NIL)"#
        let body = try #require(IMAPBodyPart.parse(try value(text)))
        #expect(body.section == "" && body.mimeType == "multipart/alternative" && body.parameters["boundary"] == "b1")
        #expect(body.parts.map(\.section) == ["1", "2"])
        #expect(body.parts.map(\.mimeType) == ["text/plain", "text/html"])
        #expect(body.snippetPart?.section == "1")
        #expect(!body.hasAttachments)
    }

    @Test func mixedBodyStructureWithAnAttachment() throws {
        let text = #"(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL NIL)"#
            + #"("APPLICATION" "PDF" ("NAME" "report.pdf") NIL NIL "BASE64" 4000 NIL ("ATTACHMENT" ("FILENAME" "Report.pdf")) "#
            + #"NIL NIL) "MIXED" ("BOUNDARY" "b2") NIL NIL NIL)"#
        let body = try #require(IMAPBodyPart.parse(try value(text)))
        let file = try #require(body.part(atSection: "2"))
        #expect(file.isAttachment && file.filename == "Report.pdf" && file.disposition == "attachment" && file.encoding == "base64")
        #expect(body.hasAttachments)
        #expect(body.snippetPart?.mimeType == "text/html")
    }

    @Test func nestedRelatedBodyStructure() throws {
        let text = #"((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1)"#
            + #"(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 100 3)"#
            + #"("IMAGE" "PNG" ("NAME" "logo.png") "<logo@pmail>" NIL "BASE64" 2000 NIL "#
            + #"("INLINE" ("FILENAME" "logo.png")) NIL NIL) "#
            + #""RELATED" ("BOUNDARY" "r" "TYPE" "text/html") NIL NIL) "ALTERNATIVE" ("BOUNDARY" "a") NIL NIL)"#
            + #"("APPLICATION" "OCTET-STREAM" ("NAME" "=?utf-8?B?4oKsIHJhdGVzLnhsc3g=?=") NIL NIL "BASE64" 5000 NIL "#
            + #"("ATTACHMENT" ("FILENAME*0*" "utf-8''%E2%82%AC%20" "FILENAME*1" "rates.xlsx")) NIL NIL) "#
            + #""MIXED" ("BOUNDARY" "m") NIL NIL)"#
        let body = try #require(IMAPBodyPart.parse(try value(text)))
        #expect(body.leafParts.map(\.section) == ["1.1", "1.2.1", "1.2.2", "2"])
        #expect(body.part(atSection: "1")?.mimeType == "multipart/alternative")
        #expect(body.part(atSection: "1.2")?.mimeType == "multipart/related")
        let logo = try #require(body.part(atSection: "1.2.2"))
        #expect(!logo.isAttachment && logo.contentID == "<logo@pmail>")
        let sheet = try #require(body.part(atSection: "2"))
        #expect(sheet.isAttachment && sheet.filename == "€ rates.xlsx" && sheet.parameters["name"] == "€ rates.xlsx")
        #expect(body.snippetPart?.section == "1.1")
        #expect(body.hasAttachments)
    }

    @Test func bodyStructureExtensionData() throws {
        let text = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8" "FORMAT" "flowed") "<note@x>" "A =?utf-8?Q?n=C3=B6te?=" "#
            + #""QUOTED-PRINTABLE" 200 5 "Q2hlY2s=" ("INLINE" NIL) ("EN" "FR") "http://example.com/note.txt" (1 2 "future"))"#
        let part = try #require(IMAPBodyPart.parse(try value(text)))
        #expect(part.parameters == ["charset": "UTF-8", "format": "flowed"])
        #expect(part.contentID == "<note@x>" && part.contentDescription == "A nöte")
        #expect(part.md5 == "Q2hlY2s=" && part.disposition == "inline" && part.dispositionParameters.isEmpty)
        #expect(part.languages == ["EN", "FR"] && part.location == "http://example.com/note.txt")
        #expect(!part.isAttachment)

        let multipart = #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1) "MIXED" ("BOUNDARY" "z") ("INLINE" ("X" "y")) "DE" NIL)"#
        let body = try #require(IMAPBodyPart.parse(try value(multipart)))
        #expect(body.disposition == "inline" && body.dispositionParameters == ["x": "y"] && body.languages == ["DE"])
    }

    /// An invitation as it usually comes: text/calendar beside the text and HTML, and an invite.ics file.
    @Test func invitationsAreFoundInTheBodyStructure() throws {
        let text = #"((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2)"#
            + #"("TEXT" "CALENDAR" ("CHARSET" "UTF-8" "METHOD" "REQUEST") NIL NIL "7BIT" 900 30) "ALTERNATIVE" ("BOUNDARY" "a") NIL NIL)"#
            + #"("APPLICATION" "ICS" ("NAME" "invite.ics") NIL NIL "BASE64" 1200 NIL ("ATTACHMENT" ("FILENAME" "invite.ics")) NIL NIL) "#
            + #""MIXED" ("BOUNDARY" "m") NIL NIL)"#
        #expect(try #require(IMAPBodyPart.parse(try value(text))).hasCalendar)
        let plain = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1)"#
        #expect(try #require(IMAPBodyPart.parse(try value(plain))).hasCalendar == false)
    }

    @Test func attachedMessageBodyStructure() throws {
        let text = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1)("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 800 "#
            + #"("Mon, 2 Nov 2026 10:00:00 +0000" "Fwd stuff" (("Sam" NIL "sam" "example.org")) NIL NIL NIL NIL NIL NIL "#
            + #""<inner@example.org>") (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 50 2)"#
            + #"("IMAGE" "JPEG" ("NAME" "a.jpg") NIL NIL "BASE64" 300 NIL ("ATTACHMENT" ("FILENAME" "a.jpg")) NIL NIL) "#
            + #""MIXED" ("BOUNDARY" "x") NIL NIL) 30 NIL ("ATTACHMENT" NIL) NIL NIL) "MIXED" ("BOUNDARY" "y") NIL NIL)"#
        let body = try #require(IMAPBodyPart.parse(try value(text)))
        let message = try #require(body.part(atSection: "2"))
        #expect(message.isAttachedMessage && message.isAttachment && message.lines == 30)
        #expect(message.envelope?.subject == "Fwd stuff" && message.envelope?.from.first?.email == "sam@example.org")
        #expect(message.parts.first?.parts.map(\.section) == ["2.1", "2.2"])
        #expect(body.part(atSection: "2.2")?.filename == "a.jpg")
        #expect(body.leafParts.map(\.section) == ["1", "2"])
        #expect(body.snippetPart?.section == "1")

        let single = #"("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 80 (NIL "Inner" NIL NIL NIL NIL NIL NIL NIL NIL) "#
            + #"("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1) 3)"#
        let wrapped = try #require(IMAPBodyPart.parse(try value(single)))
        #expect(wrapped.section == "1" && wrapped.parts.first?.section == "1.1")
    }

    @Test func snippetsFromTheFirstBytesOfAPart() throws {
        let text = "Waffles says hi to everyone at the park, see you there!"
        let base64 = Data(text.utf8).base64EncodedString()
        let cut = Data(base64.prefix(31).utf8)  // Partway through a group of four.
        let plain = IMAPBodyPart(section: "1", type: "text", subtype: "plain", parameters: ["charset": "utf-8"], encoding: "base64")
        let snippet = plain.snippet(from: cut)
        #expect(!snippet.isEmpty && text.hasPrefix(snippet))

        let quoted = IMAPBodyPart(section: "1", type: "text", subtype: "plain", parameters: ["charset": "UTF-8"],
                                  encoding: "quoted-printable")
        #expect(quoted.snippet(from: Data("Caf=C3=A9 au lait,=\r\n see you =C3=A".utf8)) == "Café au lait, see you")
        #expect(quoted.snippet(from: Data("Pug =F0=9F=90".utf8)) == "Pug")

        let latin = IMAPBodyPart(section: "2", type: "text", subtype: "plain", parameters: ["charset": "iso-8859-1"],
                                 encoding: "8bit")
        #expect(latin.snippet(from: Data([0x43, 0x61, 0x66, 0xE9])) == "Café")

        let html = IMAPBodyPart(section: "2", type: "text", subtype: "html", parameters: ["charset": "utf-8"], encoding: "7bit")
        #expect(html.snippet(from: Data("<html><head><style>body { color: red; }".utf8)) == "")
        #expect(html.snippet(from: Data("<p>Hello <b>there</b>&nbsp;pug</p><div class=\"foot".utf8)) == "Hello there pug")
        #expect(html.snippet(from: Data("<p>Hi</p><!-- a comment that never".utf8)) == "Hi")
    }
}
