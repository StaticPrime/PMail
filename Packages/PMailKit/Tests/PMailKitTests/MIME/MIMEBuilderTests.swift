import Foundation
import Testing
@testable import PMailKit

@Suite struct MIMEBuilderTests {
    private let date = Date(timeIntervalSince1970: 1_795_286_700)
    private let jamie = MailAddress(name: "Jamie Rivera", email: "jamie@example.com")
    private let pictureData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 300))

    /// The message's lines, split at CRLF.
    private func lines(of data: Data) -> [String] {
        data.mimeText.components(separatedBy: "\r\n")
    }

    /// The header block, unfolded, as name/value pairs.
    private func headers(of data: Data) -> [MIMEHeader] {
        MIMEHeaderReader.read([UInt8](data)[...]).fields
    }

    private func structure(of data: Data) -> MIMEPart {
        MIMEPart.read([UInt8](data)[...], number: "", depth: 0, defaultType: "text/plain")
    }

    /// Every line ends with CRLF, no line passes 998 octets, and nothing but ASCII appears unless a test allows it.
    private func expectWellFormed(_ data: Data, allowUTF8: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        let bytes = [UInt8](data)
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0A, index == 0 || bytes[index - 1] != 0x0D {
                Issue.record("bare LF at \(index)", sourceLocation: sourceLocation)
                return
            }
            if byte == 0x0D, index + 1 >= bytes.count || bytes[index + 1] != 0x0A {
                Issue.record("bare CR at \(index)", sourceLocation: sourceLocation)
                return
            }
            if !allowUTF8, byte >= 0x80 {
                Issue.record("8-bit byte at \(index)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(data.mimeText.hasSuffix("\r\n"), sourceLocation: sourceLocation)
        let longest = lines(of: data).map(\.utf8.count).max() ?? 0
        #expect(longest <= 998, "a line is \(longest) octets", sourceLocation: sourceLocation)
    }

    @Test func plainTextMessageHasTheHeadersAndNothingElse() {
        let message = OutgoingMessage(from: jamie, to: [MailAddress(name: "Sam", email: "sam@example.com")],
                                      cc: [MailAddress(email: "alex@example.com")], bcc: [MailAddress(email: "secret@example.com")],
                                      replyTo: [MailAddress(email: "jamie@home.example")], subject: "Lunch on Friday?",
                                      textBody: "Hi Sam,\n\nLunch?\n", inReplyTo: "<parent@example.com>",
                                      references: ["<root@example.com>", "<parent@example.com>"], messageID: "<m1@example.com>",
                                      date: date)
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let fields = headers(of: data)
        #expect(fields.map(\.name) == ["Date", "From", "To", "Cc", "Reply-To", "Subject", "Message-ID", "In-Reply-To",
                                       "References", "MIME-Version", "Content-Type", "Content-Transfer-Encoding"])
        let values = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(values["Date"] == MailDate.format(date))
        #expect(values["From"] == "Jamie Rivera <jamie@example.com>")
        #expect(values["To"] == "Sam <sam@example.com>")
        #expect(values["Cc"] == "alex@example.com")
        #expect(values["Reply-To"] == "jamie@home.example")
        #expect(values["Subject"] == "Lunch on Friday?")
        #expect(values["Message-ID"] == "<m1@example.com>")
        #expect(values["In-Reply-To"] == "<parent@example.com>")
        #expect(values["References"] == "<root@example.com> <parent@example.com>")
        #expect(values["MIME-Version"] == "1.0")
        #expect(values["Content-Type"] == "text/plain; charset=utf-8")
        #expect(values["Content-Transfer-Encoding"] == "7bit")
        #expect(data.mimeText.hasSuffix("\r\n\r\nHi Sam,\r\n\r\nLunch?\r\n"))
        // Blind copies stay blind, and nothing names the app or the computer.
        #expect(!data.mimeText.contains("secret@example.com"))
        for word in ["bcc", "x-mailer", "user-agent", "pmail", "x-originating", "sender:"] {
            #expect(!data.mimeText.lowercased().contains(word), "found \(word)")
        }
    }

    @Test func savedCopiesKeepTheBcc() {
        let message = OutgoingMessage(from: jamie, to: [MailAddress(email: "sam@example.com")],
                                      bcc: [MailAddress(name: "Zoë", email: "zoe@example.com")], subject: "Draft", textBody: "x")
        let saved = MIMEParser.parse(MIMEBuilder.buildForSaving(message))
        #expect(saved.bcc == [MailAddress(name: "Zoë", email: "zoe@example.com")])
        #expect(MIMEParser.parse(MIMEBuilder.build(message)).bcc.isEmpty)
    }

    @Test func nonASCIIHeadersBecomeShortEncodedWords() {
        let subject = "Re: Grüße aus Köln — the café crème meeting about 日本語 and other things that make a subject long"
        let message = OutgoingMessage(from: MailAddress(name: "Jürgen Müller", email: "jm@example.de"),
                                      to: [MailAddress(name: "Rivera, Jamie", email: "jamie@example.com"),
                                           MailAddress(name: "José Álvarez", email: "jose@example.es")],
                                      subject: subject, textBody: "Hallo")
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let headerLines = lines(of: data).prefix { !$0.isEmpty }
        #expect(headerLines.allSatisfy { $0.utf8.count <= 78 })
        let words = headerLines.joined(separator: " ").split(separator: " ").filter { $0.hasPrefix("=?") }
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.count <= 75 })
        #expect(headerLines.contains { $0.hasPrefix("Subject: Re: =?utf-8?") })  // plain words stay readable
        let parsed = MIMEParser.parse(data)
        #expect(parsed.subject == subject)
        #expect(parsed.from == MailAddress(name: "Jürgen Müller", email: "jm@example.de"))
        #expect(parsed.to == message.to)
        #expect(headers(of: data).first { $0.name == "To" }?.value.contains("\"Rivera, Jamie\" <jamie@example.com>") == true)
    }

    @Test func htmlMakesAnAlternativeWithPlainTextFirst() throws {
        let message = OutgoingMessage(from: jamie, to: [jamie], subject: "Formatted", textBody: "Bold move",
                                      htmlBody: "<p><b>Bold</b> move</p>")
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let root = structure(of: data)
        #expect(root.mimeType == "multipart/alternative")
        #expect(root.children.map(\.mimeType) == ["text/plain", "text/html"])
        let parsed = MIMEParser.parse(data)
        #expect(parsed.textBody == "Bold move")
        #expect(parsed.htmlBody == "<p><b>Bold</b> move</p>")
        #expect(parsed.attachments.isEmpty)
    }

    @Test func picturesGoInRelatedAndFilesInMixed() throws {
        let message = OutgoingMessage(from: jamie, to: [jamie], subject: "Pictures", textBody: "See the dog",
                                      htmlBody: "<p>See <img src=\"cid:dog@example.com\"></p>",
                                      attachments: [
                                          OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8)),
                                          OutgoingAttachment(filename: "dog.png", mimeType: "image/png", data: pictureData,
                                                             contentID: "<dog@example.com>"),
                                      ])
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let root = structure(of: data)
        #expect(root.mimeType == "multipart/mixed")
        #expect(root.children.map(\.mimeType) == ["multipart/alternative", "application/pdf"])
        let alternative = root.children[0]
        #expect(alternative.children.map(\.mimeType) == ["text/plain", "multipart/related"])
        let related = alternative.children[1]
        #expect(related.contentType.parameters["type"] == "text/html")
        #expect(related.children.map(\.mimeType) == ["text/html", "image/png"])
        let picture = related.children[1]
        #expect(picture.header("Content-ID") == "<dog@example.com>")
        #expect(picture.disposition?.value == "inline")
        #expect(picture.encoding == "base64")
        #expect(root.children[1].disposition?.value == "attachment")
        #expect(root.children[1].disposition?.parameters["filename"] == "report.pdf")
        #expect(root.children[1].contentType.parameters["name"] == "report.pdf")
        // Base64 lines are 76 characters.
        let base64Lines = String(decoding: picture.body, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(base64Lines.dropLast().allSatisfy { $0.count == 76 })
        // Every boundary is different, and each appears only on its own lines.
        let boundaries = [root, alternative, related].compactMap { $0.contentType.parameters["boundary"] }
        #expect(Set(boundaries).count == 3)
        #expect(boundaries.allSatisfy { $0.hasPrefix("=_") })

        let parsed = MIMEParser.parse(data)
        #expect(parsed.inlineParts.map(\.contentID) == ["dog@example.com"])
        #expect(parsed.inlineParts.first?.data == pictureData)
        #expect(parsed.attachments.map(\.filename) == ["report.pdf"])
    }

    @Test func picturesWithoutHTMLAreOrdinaryFiles() {
        let message = OutgoingMessage(from: jamie, to: [jamie], textBody: "No formatting",
                                      attachments: [OutgoingAttachment(filename: "dog.png", mimeType: "image/png", data: pictureData,
                                                                       contentID: "dog")])
        let data = MIMEBuilder.build(message)
        let root = structure(of: data)
        #expect(root.mimeType == "multipart/mixed")
        #expect(root.children[1].disposition?.value == "attachment")
        #expect(MIMEParser.parse(data).attachments.map(\.filename) == ["dog.png"])
    }

    @Test func textEncodingChoices() {
        func encoding(of text: String) -> String? {
            headers(of: MIMEBuilder.build(OutgoingMessage(from: jamie, to: [jamie], textBody: text)))
                .first { $0.name == "Content-Transfer-Encoding" }?.value
        }
        #expect(encoding(of: "Short ASCII lines\nonly") == "7bit")
        #expect(encoding(of: "Grüße") == "quoted-printable")
        #expect(encoding(of: String(repeating: "long ", count: 40)) == "quoted-printable")
        #expect(encoding(of: "control \u{1B} character") == "quoted-printable")
    }

    @Test func noLineIsTooLongWhateverTheContent() {
        let longWord = String(repeating: "x", count: 1200)
        let message = OutgoingMessage(
            from: MailAddress(name: String(repeating: "Very Long Name ", count: 30), email: "jamie@example.com"),
            to: (0..<60).map { MailAddress(name: "Person \($0) Ünïcödé", email: "person\($0)@example.com") },
            subject: "Long subject " + longWord + " " + String(repeating: "wörds ", count: 80),
            textBody: longWord + "\n" + String(repeating: "é", count: 3000),
            htmlBody: "<p>" + longWord + "</p>",
            attachments: [OutgoingAttachment(filename: String(repeating: "Résumé ", count: 40) + ".pdf", mimeType: "application/pdf",
                                             data: Data(repeating: 0xAB, count: 10_000))],
            references: (0..<50).map { "<reference-\($0)-\(UUID().uuidString)@example.com>" })
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let parsed = MIMEParser.parse(data)
        #expect(parsed.subject == MIMEBuilder.singleLine(message.subject))
        #expect(parsed.to.count == 60)
        #expect(parsed.references.count == 50)
        #expect(parsed.attachments.first?.filename == message.attachments[0].filename)
        #expect(parsed.textBody?.hasPrefix(longWord) == true)
    }

    @Test func headerInjectionIsImpossible() {
        let message = OutgoingMessage(from: MailAddress(name: "Jamie\r\nBcc: evil@example.com", email: "jamie@example.com"),
                                      to: [MailAddress(email: "sam@example.com\r\nBcc: evil@example.com")],
                                      subject: "Hello\r\nBcc: evil@example.com\nX-Evil: yes",
                                      textBody: "Body", inReplyTo: "<a@example.com>\r\nX-Evil: yes",
                                      messageID: "<id@example.com>\r\nX-Evil: yes")
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let names = headers(of: data).map { $0.name.lowercased() }
        #expect(!names.contains("bcc") && !names.contains("x-evil"))
        #expect(MIMEParser.parse(data).subject == "Hello Bcc: evil@example.com X-Evil: yes")
    }

    @Test func repliesWithoutReferencesNameTheirParentThere() {
        let parsed = MIMEParser.parse(MIMEBuilder.build(OutgoingMessage(from: jamie, to: [jamie], subject: "Re: Hi", textBody: "x",
                                                                        inReplyTo: "<parent@example.com>")))
        #expect(parsed.inReplyTo == "<parent@example.com>")
        #expect(parsed.references == ["<parent@example.com>"])
        #expect(parsed.summary(id: "1").threadID == "<parent@example.com>")
    }

    @Test func emptyTextWithHTMLGetsTextFromTheHTML() {
        let data = MIMEBuilder.build(OutgoingMessage(from: jamie, to: [jamie], textBody: "", htmlBody: "<p>Hello &amp; welcome</p>"))
        #expect(MIMEParser.parse(data).textBody == "Hello & welcome")
    }

    @Test func roundTripKeepsEverythingWithNonASCIIContent() throws {
        let text = "Hallo Jamie,\n\nGrüße aus Köln! 🐶\n.A line starting with a dot\nFrom the start of a line\n"
            + "Trailing spaces   \n" + String(repeating: "Lange Zeile mit Ümlauten ", count: 10)
        let html = "<html><body><p>Grüße aus Köln! 🐶</p><img src=\"cid:hund@example.de\"></body></html>"
        let pdf = Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let message = OutgoingMessage(
            from: MailAddress(name: "Jürgen Müller", email: "jm@example.de"),
            to: [MailAddress(name: "Rivera, Jamie", email: "jamie@example.com"), MailAddress(email: "sam@example.com")],
            cc: [MailAddress(name: "Zoë Ñúñez", email: "zoe@example.es")],
            replyTo: [MailAddress(name: "日本語の名前", email: "reply@example.jp")],
            subject: "Grüße aus Köln 🐶 — 日本語のテスト",
            textBody: text, htmlBody: html,
            attachments: [
                OutgoingAttachment(filename: "Résumé 2026 — final.pdf", mimeType: "application/pdf", data: pdf),
                OutgoingAttachment(filename: "hund.png", mimeType: "image/png", data: pictureData, contentID: "hund@example.de"),
                OutgoingAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("plain notes\n".utf8)),
            ],
            inReplyTo: "<parent@example.com>", references: ["<root@example.com>", "<parent@example.com>"], date: date)
        let data = MIMEBuilder.build(message)
        expectWellFormed(data)
        let parsed = MIMEParser.parse(data)
        #expect(parsed.subject == message.subject)
        #expect(parsed.from == message.from)
        #expect(parsed.to == message.to)
        #expect(parsed.cc == message.cc)
        #expect(parsed.replyTo == message.replyTo)
        #expect(parsed.date == date)
        #expect(parsed.messageID == message.messageID)
        #expect(parsed.inReplyTo == "<parent@example.com>")
        #expect(parsed.references == ["<root@example.com>", "<parent@example.com>"])
        #expect(parsed.textBody == text)
        #expect(parsed.htmlBody == html)
        #expect(parsed.attachments.map(\.filename) == ["Résumé 2026 — final.pdf", "notes.txt"])
        #expect(parsed.attachments.map(\.mimeType) == ["application/pdf", "text/plain"])
        #expect(parsed.attachments.first?.data == pdf)
        #expect(parsed.attachments.first?.size == pdf.count)
        #expect(parsed.attachments.last?.data == Data("plain notes\n".utf8))
        let picture = try #require(parsed.inlineParts.first)
        #expect(picture.contentID == "hund@example.de")
        #expect(picture.filename == "hund.png")
        #expect(picture.data == pictureData)
        // The raw file name is RFC 2231 encoded, the Content-Type name RFC 2047.
        #expect(data.mimeText.contains("filename*=utf-8''R%C3%A9sum%C3%A9%202026%20%E2%80%94%20final.pdf"))
        #expect(data.mimeText.contains("name=\"=?utf-8?"))
    }

    @Test func textOnlyRoundTripsExactly() {
        let samples = ["": "", "One line": "One line", "Ends with newlines\n\n": "Ends with newlines",
                       "Ünïcödé\r\nwith CRLF": "Ünïcödé\nwith CRLF",
                       "  leading and trailing spaces  ": "  leading and trailing spaces  "]
        for (text, expected) in samples {
            let parsed = MIMEParser.parse(MIMEBuilder.build(OutgoingMessage(from: jamie, to: [jamie], textBody: text)))
            #expect(parsed.textBody == expected, "\(text)")
        }
    }
}
