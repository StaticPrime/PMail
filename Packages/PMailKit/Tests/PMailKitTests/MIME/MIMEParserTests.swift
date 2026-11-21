import Foundation
import Testing
@testable import PMailKit

@Suite struct MIMEParserTests {
    private let novemberDate = Date(timeIntervalSince1970: 1_795_286_700)  // 2026-11-21 18:45:00 UTC

    // MARK: Simple messages

    @Test func plainTextMessageFillsEveryField() {
        let message = MIMEParser.parse(mimeWire("""
            From: Jamie Rivera <jamie@example.com>
            Sender: Mail Robot <robot@example.com>
            To: Sam Lee <sam@example.com>, alex@example.com
            Cc: "Kim, Alex" <alex.kim@example.com>
            Bcc: hidden@example.com
            Reply-To: Jamie at Home <jamie@home.example>
            Subject: Lunch on
             Friday?
            Date: Sat, 21 Nov 2026 13:45:00 -0500
            Message-ID: <abc123@example.com>
            In-Reply-To: <parent@example.com> (Sam's message)
            References: <root@example.com>
            \t<parent@example.com>
            List-Unsubscribe: <mailto:leave@example.com>, <https://example.com/leave>
            MIME-Version: 1.0
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: 8bit

            Hi Sam,

            Lunch on Friday? 🍜
            """))
        #expect(message.subject == "Lunch on Friday?")
        #expect(message.from == MailAddress(name: "Jamie Rivera", email: "jamie@example.com"))
        #expect(message.sender == MailAddress(name: "Mail Robot", email: "robot@example.com"))
        #expect(message.to == [MailAddress(name: "Sam Lee", email: "sam@example.com"), MailAddress(email: "alex@example.com")])
        #expect(message.cc == [MailAddress(name: "Kim, Alex", email: "alex.kim@example.com")])
        #expect(message.bcc == [MailAddress(email: "hidden@example.com")])
        #expect(message.replyTo == [MailAddress(name: "Jamie at Home", email: "jamie@home.example")])
        #expect(message.date == novemberDate)
        #expect(message.messageID == "<abc123@example.com>")
        #expect(message.inReplyTo == "<parent@example.com>")
        #expect(message.references == ["<root@example.com>", "<parent@example.com>"])
        #expect(message.listUnsubscribe == "<mailto:leave@example.com>, <https://example.com/leave>")
        #expect(message.textBody == "Hi Sam,\n\nLunch on Friday? 🍜")
        #expect(message.htmlBody == nil)
        #expect(message.attachments.isEmpty && message.inlineParts.isEmpty)
        #expect(message.header("subject") == "Lunch on Friday?")
        #expect(message.header("References") == "<root@example.com>\t<parent@example.com>")
        #expect(message.snippet == "Hi Sam, Lunch on Friday? 🍜")
    }

    @Test func lineFeedOnlyMessagesAndMboxLinesRead() {
        let message = MIMEParser.parse(Data("""
            From jamie@example.com Sat Nov 21 13:45:00 2026
            From: Jamie <jamie@example.com>
            Subject: Just LF

            One
            Two
            """.utf8))
        #expect(message.from?.email == "jamie@example.com")
        #expect(message.subject == "Just LF")
        #expect(message.textBody == "One\nTwo")
    }

    @Test func dateFallsBackToReceivedAndIDsGetBrackets() {
        let message = MIMEParser.parse(mimeWire("""
            Received: from mx.example.com by mail.example.net with ESMTPS id 123;
             Sat, 21 Nov 2026 18:45:00 +0000
            Message-ID: abc@example.com
            References: root@example.com parent@example.com
            Subject: No date

            Body
            """))
        #expect(message.date == novemberDate)
        #expect(message.messageID == "<abc@example.com>")
        #expect(message.references == ["<root@example.com>", "<parent@example.com>"])
    }

    @Test func htmlOnlyMessage() {
        let message = MIMEParser.parse(mimeWire("""
            Subject: Newsletter
            Content-Type: text/html; charset=iso-8859-1
            Content-Transfer-Encoding: quoted-printable

            <html><body><p>Caf=E9 news &amp; more</p></body></html>
            """))
        #expect(message.htmlBody == "<html><body><p>Café news &amp; more</p></body></html>")
        #expect(message.textBody == nil)
        #expect(message.snippet == "Café news & more")
    }

    @Test func htmlCharsetComesFromMetaTagWhenTheHeaderHasNone() {
        let message = MIMEParser.parse(mimeWire("Content-Type: text/html", body: Array(
            "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=koi8-r\"></head><body>".utf8)
            + [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4] + Array("</body></html>".utf8)))
        #expect(message.htmlBody?.contains("Привет") == true)
    }

    @Test func contentTypeWithoutSemicolonStillGivesItsCharset() {
        let message = MIMEParser.parse(mimeWire("Content-Type: text/plain charset=iso-8859-1", body: [0x43, 0x61, 0x66, 0xE9]))
        #expect(message.textBody == "Café")
    }

    // MARK: Multipart structures

    @Test func alternativeGivesBothBodiesAndSkipsPreambleAndEpilogue() {
        let message = MIMEParser.parse(mimeWire("""
            Subject: Both
            Content-Type: multipart/alternative; boundary="alt"

            This preamble is for old mail programs.
            --alt
            Content-Type: text/plain; charset=us-ascii

            Plain version
            --alt
            Content-Type: text/html; charset=utf-8

            <p>HTML version</p>
            --alt--
            This epilogue is ignored.
            """))
        #expect(message.textBody == "Plain version")
        #expect(message.htmlBody == "<p>HTML version</p>")
        #expect(message.attachments.isEmpty)
    }

    @Test func mixedMessageWithAttachment() throws {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary=XYZ

            --XYZ
            Content-Type: text/plain

            See the attached report.
            --XYZ
            Content-Type: application/pdf; name="report.pdf"
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            JVBERi0xLjQgcHJldGVuZA==
            --XYZ--
            """))
        #expect(message.textBody == "See the attached report.")
        let attachment = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(attachment.id == "2")
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.size == 16)
        #expect(attachment.data == Data("%PDF-1.4 pretend".utf8))
        #expect(!attachment.isInline)
        #expect(message.summary(id: "m1").hasAttachments)
    }

    @Test func relatedPicturesReferencedByCIDAreInline() throws {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/related; boundary="rel"; type="text/html"

            --rel
            Content-Type: text/html; charset=utf-8

            <p>Our logo: <img src="cid:Logo@Example.com"></p>
            --rel
            Content-Type: image/png
            Content-ID: <logo@example.com>
            Content-Transfer-Encoding: base64

            iVBORw0KGgoBAgM=
            --rel
            Content-Type: image/png; name="unused.png"
            Content-ID: <unused@example.com>
            Content-Disposition: inline
            Content-Transfer-Encoding: base64

            iVBORw0KGgoBAgM=
            --rel--
            """))
        #expect(message.htmlBody == "<p>Our logo: <img src=\"cid:Logo@Example.com\"></p>")
        let picture = try #require(message.inlineParts.first)
        #expect(message.inlineParts.count == 1)
        #expect(picture.id == "2")
        #expect(picture.contentID == "logo@example.com")
        #expect(picture.mimeType == "image/png")
        #expect(picture.filename == "Image.png")
        #expect(picture.isInline)
        #expect(picture.data == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]))
        // A picture the HTML never shows is a file.
        #expect(message.attachments.map(\.filename) == ["unused.png"])
        #expect(message.attachments.first?.id == "3")
    }

    @Test func relatedRootCanBeNamedByStart() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/related; boundary="r"; start="<root@x>"

            --r
            Content-Type: image/gif
            Content-ID: <pic@x>
            Content-Transfer-Encoding: base64

            R0lGODlhAQABAAAAACw=
            --r
            Content-Type: text/html
            Content-ID: <root@x>

            <img src="cid:pic@x">
            --r--
            """))
        #expect(message.htmlBody == "<img src=\"cid:pic@x\">")
        #expect(message.inlineParts.map(\.id) == ["1"])
        #expect(message.attachments.isEmpty)
    }

    @Test func nestedMixedAlternativeRelatedWithPrefixBoundaries() throws {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="outer"

            --outer
            Content-Type: multipart/alternative; boundary="outer-alt"

            --outer-alt
            Content-Type: text/plain; charset=utf-8

            Hello in plain text
            --outer-alt
            Content-Type: multipart/related; boundary="outer-alt-rel"

            --outer-alt-rel
            Content-Type: text/html; charset=utf-8

            <p>Hello <img src="cid:pic"></p>
            --outer-alt-rel
            Content-Type: image/gif
            Content-ID: <pic>
            Content-Transfer-Encoding: base64

            R0lGODlhAQABAAAAACw=
            --outer-alt-rel--
            --outer-alt--
            --outer
            Content-Type: application/pdf
            Content-Disposition: attachment; filename=notes.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQgcHJldGVuZA==
            --outer--
            """))
        #expect(message.textBody == "Hello in plain text")
        #expect(message.htmlBody == "<p>Hello <img src=\"cid:pic\"></p>")
        let picture = try #require(message.inlineParts.first)
        #expect(picture.id == "1.2.2")
        #expect(picture.contentID == "pic")
        #expect(picture.size == 14)
        #expect(message.attachments.map(\.id) == ["2"])
        #expect(message.attachments.map(\.filename) == ["notes.pdf"])
    }

    @Test func boundariesWithOddCharactersAndPadding() {
        let boundary = "----=_Part_0_1234.5678:(odd)'+?/ end"
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/alternative;
             boundary="\(boundary)"

            --\(boundary)\("   ")
            Content-Type: text/plain

            Plain
            --\(boundary)
            Content-Type: text/html

            <b>Bold</b>
            --\(boundary)--\("  ")
            """))
        #expect(message.textBody == "Plain")
        #expect(message.htmlBody == "<b>Bold</b>")
    }

    @Test func calendarInvitationsInAlternativesBecomeFilesButWatchTextDoesNot() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/alternative; boundary="inv"

            --inv
            Content-Type: text/plain

            You're invited.
            --inv
            Content-Type: text/watch-html

            <b>You're invited.</b>
            --inv
            Content-Type: text/html

            <p>You're invited.</p>
            --inv
            Content-Type: text/calendar; method=REQUEST; charset=utf-8

            BEGIN:VCALENDAR
            END:VCALENDAR
            --inv--
            """))
        #expect(message.textBody == "You're invited.")
        #expect(message.htmlBody == "<p>You're invited.</p>")
        #expect(message.attachments.map(\.filename) == ["invite.ics"])
        #expect(message.attachments.first?.mimeType == "text/calendar")
        #expect(message.attachments.first?.id == "4")
    }

    @Test func laterInlineTextPartsInMixedAreAppended() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="pieces"

            --pieces
            Content-Type: text/plain; charset=us-ascii

            Here's the picture:
            --pieces
            Content-Type: image/jpeg; name="photo.jpg"
            Content-Disposition: inline; filename="photo.jpg"
            Content-Transfer-Encoding: base64

            /9j/4AAQ
            --pieces
            Content-Type: text/plain; charset=us-ascii

            Isn't it great?
            --pieces
            Content-Type: text/plain; name="notes.txt"

            A file, not more body text.
            --pieces--
            """))
        #expect(message.textBody == "Here's the picture:\nIsn't it great?")
        #expect(message.htmlBody == nil)
        #expect(message.attachments.map(\.filename) == ["photo.jpg", "notes.txt"])
    }

    @Test func mixedHTMLAndTextPiecesFillBothBodies() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="m"

            --m
            Content-Type: text/html

            <p>Hi</p>
            --m
            Content-Type: text/plain

            Footer <b>text</b>
            --m--
            """))
        #expect(message.htmlBody == "<p>Hi</p><div style=\"white-space: pre-wrap\">Footer &lt;b&gt;text&lt;/b&gt;</div>")
        #expect(message.textBody == "Hi\nFooter <b>text</b>")
    }

    @Test func signedMessagesHideTheirSignature() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/signed; protocol="application/pgp-signature"; micalg=pgp-sha256; boundary="sig"

            --sig
            Content-Type: text/plain; charset=utf-8

            Signed words.
            --sig
            Content-Type: application/pgp-signature; name="signature.asc"

            -----BEGIN PGP SIGNATURE-----
            abc
            -----END PGP SIGNATURE-----
            --sig--
            """))
        #expect(message.textBody == "Signed words.")
        #expect(message.attachments.isEmpty)
    }

    @Test func deliveryReportsKeepTheirParts() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/report; report-type=delivery-status; boundary="rpt"

            --rpt
            Content-Type: text/plain

            Your message couldn't be delivered.
            --rpt
            Content-Type: message/delivery-status

            Reporting-MTA: dns; mx.example.com
            Final-Recipient: rfc822; nobody@example.com
            Action: failed
            --rpt
            Content-Type: text/rfc822-headers

            From: me@example.com
            Subject: Hello
            --rpt--
            """))
        #expect(message.textBody == "Your message couldn't be delivered.")
        #expect(message.attachments.map(\.filename) == ["Delivery Status.txt", "Message Headers.txt"])
        #expect(message.attachments.map(\.mimeType) == ["message/delivery-status", "text/rfc822-headers"])
    }

    @Test func digestPartsAreMessages() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/digest; boundary="dig"

            --dig

            From: a@example.com
            Subject: First

            One
            --dig

            From: b@example.com
            Subject: Second

            Two
            --dig--
            """))
        #expect(message.attachments.map(\.filename) == ["First.eml", "Second.eml"])
        #expect(message.attachments.allSatisfy { $0.mimeType == "message/rfc822" })
        #expect(message.attachments.first?.data.map { $0.mimeText.hasPrefix("From: a@example.com") } == true)
    }

    @Test func attachedMessagesAreNamedAfterTheirSubject() throws {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="fwd"

            --fwd
            Content-Type: text/plain

            Forwarding this.
            --fwd
            Content-Type: message/rfc822

            From: Sam <sam@example.com>
            Subject: =?utf-8?Q?Lunch_plans_=F0=9F=8D=95?=
            Content-Type: text/plain

            Pizza?
            --fwd
            Content-Type: message/rfc822; name="Original"

            Subject: Ignored

            x
            --fwd--
            """))
        #expect(message.textBody == "Forwarding this.")
        #expect(message.attachments.map(\.filename) == ["Lunch plans 🍕.eml", "Original.eml"])
        let forwarded = try #require(message.attachments.first)
        #expect(forwarded.mimeType == "message/rfc822")
        #expect(forwarded.id == "2")
        #expect(forwarded.data.map { MIMEParser.parse($0).textBody } == "Pizza?")
    }

    @Test func wholeMessageThatIsAFile() throws {
        let message = MIMEParser.parse(mimeWire("""
            Subject: Scan
            Content-Type: application/pdf; name=scan.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQgcHJldGVuZA==
            """))
        #expect(message.textBody == nil && message.htmlBody == nil)
        let file = try #require(message.attachments.first)
        #expect(file.id == "1")
        #expect(file.filename == "scan.pdf")
    }

    @Test func unnamedFilesGetNamesFromTheirType() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="u"

            --u
            Content-Type: text/plain

            Body
            --u
            Content-Type: text/plain
            Content-Disposition: attachment

            log
            --u
            Content-Type: application/octet-stream

            ??
            --u
            Content-Type: image/jpeg; name="C:\\Users\\jamie\\Pictures\\dog.jpg"

            /9j/
            --u--
            """))
        #expect(message.textBody == "Body")
        #expect(message.attachments.map(\.filename) == ["Attachment.txt", "Attachment", "dog.jpg"])
    }

    // MARK: Transfer encodings

    @Test func quotedPrintableSoftBreaksEscapesAndTrailingSpace() {
        let body = "This line is long enough that it was wrapped with a soft line =\n"
            + "break, and it says 1 + 1 =3D 2.\n"
            + "Caf=C3=A9 au lait   \n"
            + "Spaces kept=20\n"
            + "Last line="
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: Quoted-Printable

            \(body)
            """))
        #expect(message.textBody == """
            This line is long enough that it was wrapped with a soft line break, and it says 1 + 1 = 2.
            Café au lait
            Spaces kept\("" + " ")
            Last line
            """)
    }

    @Test func base64WithJunkAndMissingPadding() {
        let junk = MIMEParser.parse(mimeWire("""
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: base64

            SGVsbG8s IFdh*ZmZs
            ZXMh!!
            """))
        #expect(junk.textBody == "Hello, Waffles!")
        let unpadded = MIMEParser.parse(mimeWire("""
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: BASE64

            R3LDvMOfZSBhdXMgS8O2bG4
            """))
        #expect(unpadded.textBody == "Grüße aus Köln")
    }

    @Test func encodedMultipartsAreDecodedFirst() {
        let inner = "--q\r\nContent-Type: text/plain\r\n\r\nInside\r\n--q--\r\n"
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="q"
            Content-Transfer-Encoding: base64

            \(Data(inner.utf8).base64EncodedString())
            """))
        #expect(message.textBody == "Inside")
    }

    // MARK: Encoded words and character sets

    @Test func encodedWordsInSubjectsAndNames() {
        func subject(_ value: String) -> String {
            MIMEParser.parse(mimeWire("Subject: \(value)\n\nx")).subject
        }
        #expect(subject("=?utf-8?B?R3LDvMOfZSBhdXMgS8O2bG4=?=") == "Grüße aus Köln")
        #expect(subject("=?iso-8859-1?Q?Caf=E9_au_lait?=") == "Café au lait")
        #expect(subject("=?utf-8?Q?Pug?=\n =?utf-8?Q?_party?= tonight") == "Pug party tonight")
        #expect(subject("Re: =?UTF-8?q?Gr=C3=BC=C3=9Fe?=") == "Re: Grüße")
        #expect(subject("=?x-unknown?Q?caf=C3=A9?=") == "café")
        #expect(subject("=?utf-8?Q?caf=C3?= =?utf-8?Q?=A9?=") == "café")
        #expect(subject("=?ISO-2022-JP?B?GyRCRnxLXDhsGyhC?=") == "日本語")
        #expect(subject("=?utf-8?X?nonsense?= stays") == "=?utf-8?X?nonsense?= stays")
        #expect(subject("Raw UTF-8 straight in the header: café") == "Raw UTF-8 straight in the header: café")
        let message = MIMEParser.parse(mimeWire("From: =?utf-8?Q?J=C3=BCrgen_M=C3=BCller?= <jm@example.de>\n\nx"))
        #expect(message.from == MailAddress(name: "Jürgen Müller", email: "jm@example.de"))
    }

    @Test func bodiesInManyCharacterSets() {
        func body(_ charset: String, _ bytes: [UInt8]) -> String? {
            MIMEParser.parse(mimeWire("Content-Type: text/plain; charset=\(charset)", body: bytes)).textBody
        }
        #expect(body("iso-8859-1", [0x43, 0x61, 0x66, 0xE9]) == "Café")
        #expect(body("windows-1252", [0x93, 0x48, 0x69, 0x94]) == "“Hi”")
        #expect(body("\"utf-8\"", Array("Grüße 🐶".utf8)) == "Grüße 🐶")
        let shiftJIS: [UInt8] = [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x82, 0xCC, 0x83, 0x81, 0x81, 0x5B, 0x83, 0x8B]
        #expect(body("Shift_JIS", shiftJIS) == "日本語のメール")
        #expect(body("koi8-r", [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]) == "Привет")
        // Labelled Latin-1 but really UTF-8, and labelled nothing at all.
        #expect(body("iso-8859-1", Array("café".utf8)) == "café")
        #expect(body("x-nonsense", Array("café".utf8)) == "café")
        #expect(MIMEParser.parse(mimeWire("Subject: none", body: [0xEF, 0xBB, 0xBF] + Array("BOM".utf8))).textBody == "BOM")
    }

    // MARK: File names

    @Test func rfc2231AndEncodedFileNames() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="b"

            --b
            Content-Type: text/plain

            Files attached.
            --b
            Content-Type: application/pdf
            Content-Disposition: attachment;
             filename*0*=utf-8''%E2%82%AC%20rates;
             filename*1*=%20%C3%A9t%C3%A9.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQgcHJldGVuZA==
            --b
            Content-Type: text/plain; name*=iso-8859-1'fr'r%E9sum%E9.txt
            Content-Disposition: inline

            hello
            --b
            Content-Type: application/octet-stream; name="=?utf-8?B?R3LDvMOfZSBhdXMgS8O2bG4=?=.zip"

            zip
            --b
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename*0="very long name "; filename*1="in two pieces.bin"

            bin
            --b
            Content-Type: application/octet-stream; name="fallback.bin"
            Content-Disposition: attachment; filename="preferred.bin"; filename*=utf-8''pr%C3%A9f%C3%A9r%C3%A9.bin

            x
            --b--
            """))
        #expect(message.textBody == "Files attached.")
        #expect(message.attachments.map(\.filename) == [
            "€ rates été.pdf", "résumé.txt", "Grüße aus Köln.zip", "very long name in two pieces.bin", "préféré.bin",
        ])
        #expect(message.attachments.first?.data == Data("%PDF-1.4 pretend".utf8))
    }

    // MARK: format=flowed

    @Test func formatFlowedIsUnwrapped() {
        let lines = [
            "This paragraph was wrapped by the sender's mail program so it ",
            "would fit in seventy-eight characters.",
            "",
            "> Quoted text that is ",
            "> also flowed.",
            ">> Deeper quote ",
            "> back out",
            " From a space-stuffed line",
            "-- ",
            "Jamie",
        ]
        let message = MIMEParser.parse(mimeWire("Content-Type: text/plain; charset=utf-8; format=flowed\n\n" + lines.joined(separator: "\n")))
        #expect(message.textBody == """
            This paragraph was wrapped by the sender's mail program so it would fit in seventy-eight characters.

            > Quoted text that is also flowed.
            >> Deeper quote\(" ")
            > back out
            From a space-stuffed line
            --\(" ")
            Jamie
            """)
        let delSp = MIMEParser.parse(mimeWire("Content-Type: text/plain; format=Flowed; DelSp=Yes\n\nKonnichi \nwa"))
        #expect(delSp.textBody == "Konnichiwa")
        let fixed = MIMEParser.parse(mimeWire("Content-Type: text/plain\n\nNot flowed \nat all"))
        #expect(fixed.textBody == "Not flowed \nat all")
    }

    // MARK: Damaged mail

    @Test func missingBlankLineStillGivesABody() {
        let message = MIMEParser.parse(mimeWire("""
            From: a@example.com
            Subject: No blank line
            This text should still be the body.
            """))
        #expect(message.subject == "No blank line")
        #expect(message.textBody == "This text should still be the body.")
    }

    @Test func missingFinalBoundaryKeepsTheLastPart() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="cut"

            --cut
            Content-Type: text/plain

            First part
            --cut
            Content-Type: text/plain; name="tail.txt"

            The connection dropped here
            """))
        #expect(message.textBody == "First part")
        #expect(message.attachments.map(\.filename) == ["tail.txt"])
        #expect(message.attachments.first?.data == Data("The connection dropped here".utf8))
    }

    @Test func multipartWithoutUsableBoundaryShowsItsText() {
        let wrongBoundary = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="nothere"

            Just some text, no parts at all.
            """))
        #expect(wrongBoundary.textBody == "Just some text, no parts at all.")
        let guessed = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/alternative

            --guess
            Content-Type: text/plain

            Found it
            --guess--
            """))
        #expect(guessed.textBody == "Found it")
    }

    @Test func binaryGarbageNeverCrashes() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let junk = mimeGarbage(count: 4096 * Int(seed), seed: seed)
            _ = MIMEParser.parse(junk)
            _ = MIMEParser.parse(mimeWire("Content-Type: multipart/mixed; boundary=x\n\n--x\n") + junk)
            _ = MIMEParser.parse(mimeWire("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n") + junk)
            _ = MIMEParser.parse(mimeWire("Content-Transfer-Encoding: quoted-printable\nSubject: =?utf-8?Q?") + junk)
        }
        let empty = MIMEParser.parse(Data())
        #expect(empty.subject.isEmpty && empty.headers.isEmpty)
        #expect(MIMEParser.parse(Data("=?".utf8)).headers.isEmpty)
    }

    @Test func absurdNestingStopsAtTheDepthLimit() {
        var text = "Subject: Deep\n"
        for level in 0..<2000 {
            text += "Content-Type: multipart/mixed; boundary=\"b\(level)\"\n\n--b\(level)\n"
        }
        text += "Content-Type: text/plain\n\nBottom\n"
        let started = Date()
        let message = MIMEParser.parse(mimeWire(text))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(message.subject == "Deep")
        #expect(message.textBody?.contains("Bottom") == true)
    }

    @Test func extremeHeaderValuesDoNotCrash() {
        let longSubject = String(repeating: "=?utf-8?Q?a?= ", count: 5000)
        #expect(MIMEParser.parse(mimeWire("Subject: \(longSubject)\n\nx")).subject == String(repeating: "a", count: 5000))
        let manyAddresses = (0..<2000).map { "p\($0)@example.com" }.joined(separator: ", ")
        #expect(MIMEParser.parse(mimeWire("To: \(manyAddresses)\n\nx")).to.count == 2000)
        let unbalanced = MIMEParser.parse(mimeWire("To: \"unclosed <a@example.com>, (comment b@example.com\nContent-Type: ;;;==;\"\n\nx"))
        #expect(unbalanced.textBody == "x")
    }

    @Test func pathologicalInputStaysFast() {
        let started = Date()
        let strayWords = String(repeating: "=?a?Q?b", count: 20_000)
        #expect(MIMEParser.parse(mimeWire("Subject: \(strayWords)\n\nx")).subject == strayWords)
        let flowed = String(repeating: "word ", count: 200_000)
        let message = MIMEParser.parse(mimeWire("Content-Type: text/plain; format=flowed\n\n"
            + flowed.split(separator: " ").map { $0 + " " }.joined(separator: "\n")))
        #expect(message.textBody?.count == flowed.count)
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test func partsWithoutHeadersKeepIndentedText() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="b"

            --b
                Indented first line
            second line
            --b--
            """))
        #expect(message.textBody == "    Indented first line\nsecond line")
    }

    @Test func cidReferencesEndAtLineBreaksAndWorkInCSS() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/related; boundary="r"

            --r
            Content-Type: text/html

            <div style="background: url(cid:bg)"><img src=cid:logo
            alt="Logo"></div>
            --r
            Content-Type: image/png
            Content-ID: <logo>

            x
            --r
            Content-Type: image/png
            Content-ID: <bg>

            y
            --r--
            """))
        #expect(Set(message.inlineParts.compactMap(\.contentID)) == ["logo", "bg"])
        #expect(message.attachments.isEmpty)
    }

    @Test func htmlMarkedAsAnAttachmentIsAFile() {
        let message = MIMEParser.parse(mimeWire("""
            Content-Type: multipart/mixed; boundary="m"

            --m
            Content-Type: text/plain

            Here is the page.
            --m
            Content-Type: text/html
            Content-Disposition: attachment

            <p>Saved page</p>
            --m--
            """))
        #expect(message.textBody == "Here is the page.")
        #expect(message.htmlBody == nil)
        #expect(message.attachments.map(\.filename) == ["Attachment.html"])
    }

    @Test func tabFoldedAndLooselyEncodedSubjects() {
        #expect(MIMEParser.parse(mimeWire("Subject: Quarterly\n\treport\n\nx")).subject == "Quarterly report")
        #expect(MIMEParser.parse(mimeWire("Subject: Re:=?utf-8?Q?Gr=C3=BC=C3=9Fe?=!\n\nx")).subject == "Re:Grüße!")
        #expect(MIMEParser.parse(mimeWire("subject: lower-case field name\n\nx")).subject == "lower-case field name")
    }
}
