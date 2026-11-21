import Foundation
import Testing
@testable import PMailKit

@Suite struct MIMEPrimitivesExtraTests {
    @Test func base64ToleratesPaddingInTheMiddle() {
        #expect(TransferEncoding.decodeBase64("SGk=SGk=") == Data("HiHi".utf8))
        #expect(TransferEncoding.decodeBase64("") == Data())
        #expect(TransferEncoding.decodeBase64("A") == Data())
        #expect(TransferEncoding.decodeBase64("_-8") == Data([0xFF, 0xEF]))  // base64url
    }

    @Test func quotedPrintableDropsOnlyTransportWhitespace() {
        func decode(_ text: String) -> String {
            String(decoding: TransferEncoding.decodeQuotedPrintable(Data(text.utf8)), as: UTF8.self)
        }
        #expect(decode("trailing   \r\nnext") == "trailing\r\nnext")
        #expect(decode("kept=20\r\nnext") == "kept \r\nnext")
        #expect(decode("tab\t=\r\njoined") == "tab\tjoined")
        #expect(decode("inner  spaces stay") == "inner  spaces stay")
        #expect(decode("ends in spaces  ") == "ends in spaces  ")
        #expect(decode("lower =c3=a9") == "lower é")
    }

    @Test func quotedPrintableRoundTripsWithShortLines() {
        let text = String(repeating: "Waffles the pug likes long walks, naps and café crème. ", count: 6)
            + "   \r\nNext line ends in a tab\t\r\n= sign\r\n.dot"
        let encoded = TransferEncoding.encodeQuotedPrintable(Array(text.utf8))
        let lines = String(decoding: encoded, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 76 })
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") && !$0.hasSuffix("\t") })
        #expect(String(decoding: TransferEncoding.decodeQuotedPrintable(Data(encoded)), as: UTF8.self) == text)
    }

    @Test func encodedWordsEncodeShortAndRoundTrip() {
        let longJapanese = String(repeating: "日本語のメールの件名はとても長くなることがあります。", count: 2)
        let samples = ["Grüße aus Köln", longJapanese,
                       "Pug 🐶 party: 1+1=2? _maybe_", String(repeating: "é", count: 200), "👩‍👩‍👧‍👦 family"]
        for sample in samples {
            let words = EncodedWords.encode(sample)
            #expect(words.allSatisfy { $0.count <= 75 && !$0.contains(" ") })
            #expect(EncodedWords.decode(words.joined(separator: "\r\n ")) == sample)
            #expect(EncodedWords.decode(words.joined(separator: " ")) == sample)
        }
        #expect(EncodedWords.encode("Café au lait with friends").first?.hasPrefix("=?utf-8?Q?") == true)
        #expect(EncodedWords.encode("日本語").first?.hasPrefix("=?utf-8?B?") == true)
        #expect(EncodedWords.encode("").isEmpty)
    }

    @Test func encodedWordsKeepSpacesAroundPlainText() {
        #expect(EncodedWords.decode("=?utf-8?Q?Caf=C3=A9?= au lait") == "Café au lait")
        #expect(EncodedWords.decode("Hello =?utf-8?Q?W=C3=B6rld?=!") == "Hello Wörld!")
        #expect(EncodedWords.decode("=?utf-8?Q?a?= =?iso-8859-1?Q?=E9?=") == "aé")
        #expect(EncodedWords.decode("=?utf-8?B?8J+Q?= =?utf-8?B?tg==?=") == "🐶")
        #expect(EncodedWords.decode("=?utf-8*en?Q?language?=") == "language")
    }

    @Test func charsetHeuristics() {
        // Mostly UTF-8 with one stray byte keeps the UTF-8 letters.
        #expect(Charsets.decode(Data("Grüße ".utf8) + Data([0xFF]) + Data("Köln".utf8), charset: "utf-8") == "Grüße \u{FFFD}Köln")
        // Bytes that Windows-1252 leaves undefined still decode (as Latin-1).
        #expect(Charsets.decode(Data([0x61, 0x81, 0x62]), charset: nil).unicodeScalars.map(\.value) == [0x61, 0x81, 0x62])
        #expect(Charsets.decode(Data("plain".utf8), charset: "ks_c_5601-1987") == "plain")
        #expect(Charsets.encoding(named: "SJIS") != nil)
        #expect(Charsets.encoding(named: "made-up") == nil)
    }

    @Test func mailDatesWithColonOffsets() throws {
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-21T08:15:00Z"))
        #expect(MailDate.parse("Sat, 21 Nov 2026 13:45:00 +05:30") == expected)
        #expect(MailDate.parse("Sat, 21 Nov 2026 13:45 +0530 (IST)") == expected)
    }
}
