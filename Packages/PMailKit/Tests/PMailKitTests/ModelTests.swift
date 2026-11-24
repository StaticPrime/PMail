import Foundation
import Testing
@testable import PMailKit

@Suite struct ModelTests {
    @Test func initialsComeFromFirstAndLastNames() {
        #expect(Account.initials(name: "Jamie Rivera", email: "j@example.com") == "JR")
        #expect(Account.initials(name: "Jamie Lee Rivera", email: "j@example.com") == "JR")
        #expect(Account.initials(name: "Waffles", email: "w@example.com") == "W")
        #expect(Account.initials(name: "", email: "pug@example.com") == "P")
        #expect(Account.initials(name: "  ", email: "") == "?")
    }

    @Test func addressesFormatAndShorten() {
        #expect(MailAddress(name: "Jamie Rivera", email: "jamie@example.com").formatted == "Jamie Rivera <jamie@example.com>")
        #expect(MailAddress(name: "Rivera, Jamie", email: "jamie@example.com").formatted == "\"Rivera, Jamie\" <jamie@example.com>")
        #expect(MailAddress(name: "Rivera, Jamie", email: "jamie@example.com").shortName == "Jamie")
        #expect(MailAddress(email: "waffles@example.com").shortName == "waffles")
        #expect(MailAddress(name: "  ", email: "a@b.c").name == nil)
    }

    @Test func conversationsGroupByThreadNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [
            MessageSummary(id: "1", threadID: "a", from: MailAddress(name: "Alex Kim", email: "alex@example.com"), subject: "Lunch", date: base),
            MessageSummary(id: "2", threadID: "b", from: MailAddress(name: "Sam", email: "sam@example.com"), subject: "Hi", date: base.addingTimeInterval(60)),
            MessageSummary(id: "3", threadID: "a", from: MailAddress(name: "Me", email: "me@example.com"), subject: "Re: Lunch",
                           date: base.addingTimeInterval(120), isUnread: true),
        ]
        let conversations = Conversation.group(messages)
        #expect(conversations.map(\.id) == ["a", "b"])
        #expect(conversations[0].messages.map(\.id) == ["1", "3"])
        #expect(conversations[0].subject == "Lunch")
        #expect(conversations[0].isUnread)
        #expect(conversations[0].participants(me: "me@example.com") == ["Alex", "me"])
        #expect(conversations[1].participants(me: "me@example.com") == ["Sam"])
    }

    @Test func serverPresetsGuessTheUsualNames() {
        let yahoo = ServerPresets.guess(forEmail: "pug@yahoo.com")
        #expect(yahoo.incoming.host == "imap.mail.yahoo.com" && yahoo.incoming.port == 993)
        #expect(yahoo.outgoing.host == "smtp.mail.yahoo.com" && yahoo.outgoing.port == 465)
        let unknown = ServerPresets.guess(forEmail: "me@puggle.example")
        #expect(unknown.incoming.host == "imap.puggle.example" && unknown.outgoing.host == "smtp.puggle.example")
        #expect(unknown.outgoing.port == 587 && unknown.outgoing.security == .startTLS)
        let pop = ServerPresets.guess(forEmail: "me@puggle.example", incoming: .pop3)
        #expect(pop.incoming.mailProtocol == .pop3 && pop.incoming.port == 995)
        let iCloud = ServerPresets.iCloud(email: "pug@icloud.com", appleAccount: "pug@example.com")
        #expect(iCloud.incoming.host == "imap.mail.me.com" && iCloud.outgoing.port == 587 && iCloud.login == "pug@example.com")
        #expect(ServerPresets.isICloudAddress("Pug@Me.com"))
        #expect(ServerPresets.browserSignInKind(for: "a@gmail.com") == .google)
        #expect(ServerPresets.browserSignInKind(for: "a@outlook.com") == .microsoft)
        #expect(ServerPresets.browserSignInKind(for: "a@example.com") == nil)
    }

    @Test func saslResponses() {
        #expect(SASL.plain(username: "u", password: "p") == Data("\u{0}u\u{0}p".utf8).base64EncodedString())
        #expect(SASL.xoauth2(username: "u@example.com", accessToken: "tok") == Data("user=u@example.com\u{1}auth=Bearer tok\u{1}\u{1}".utf8).base64EncodedString())
    }

    @Test func meetingLinksAreFound() {
        let meet = ConferenceDetector.detect(in: [nil, "Join: https://meet.google.com/abc-defg-hij?authuser=0"])
        #expect(meet?.kind == .meet && meet?.meetingCode == "abc-defg-hij")
        let teams = ConferenceDetector.detect(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0"])
        #expect(teams?.kind == .teams)
        let faceTime = ConferenceDetector.detect(in: ["Call https://facetime.apple.com/join#v=1&p=abc&k=def"])
        #expect(faceTime?.kind == .faceTime)
        #expect(ConferenceDetector.detect(in: ["facetime://pug@icloud.com"])?.kind == .faceTime)
        #expect(ConferenceDetector.detect(in: ["See https://example.com/agenda"]) == nil)
        #expect(ConferenceDetector.isFaceTimeLink(" https://facetime.apple.com/join#v=1&p=abc "))
    }

    @Test func aZoomMeetingIsTakenFromItsCopiedInvitation() {
        let invitation = """
            Pug Dog is inviting you to a scheduled Zoom meeting.

            Topic: Park day
            Time: Nov 25, 2026 10:00 AM Central Time (US and Canada)

            Join Zoom Meeting
            https://us05web.zoom.us/j/81234567890?pwd=AbCdEf12345

            Meeting ID: 812 3456 7890
            Passcode: 4mDq2x

            ---

            One tap mobile
            +13126266799,,81234567890#,,,,*123456# US (Chicago)

            Find your local number: https://us05web.zoom.us/u/kbxyzAbc
            """
        let meeting = ConferenceDetector.zoomMeeting(in: invitation)
        #expect(meeting?.kind == .zoom && meeting?.meetingCode == "81234567890")
        #expect(meeting?.joinURL.absoluteString == "https://us05web.zoom.us/j/81234567890?pwd=AbCdEf12345")
        #expect(ConferenceDetector.zoomMeeting(in: " https://zoom.us/my/pugdog ")?.joinURL.path == "/my/pugdog", "a Personal Room's own link")
        #expect(ConferenceDetector.zoomMeeting(in: "Find your local number: https://us05web.zoom.us/u/kbxyzAbc") == nil, "not a meeting")
        #expect(ConferenceDetector.zoomMeeting(in: "https://meet.google.com/abc-defg-hij") == nil, "another kind of meeting")
        #expect(ConferenceDetector.zoomMeeting(in: "") == nil)
    }

    @Test func eachAccountChoosesTheVideoMeetingItsNewEventsAreOffered() throws {
        // Zoom on every account; Meet only on Google, Teams only on Microsoft, FaceTime only on iCloud.
        #expect(VideoMeetingChoice.options(own: .meet) == [.meet, .zoom, .noMeeting])
        #expect(VideoMeetingChoice.options(own: .teams) == [.teams, .zoom, .noMeeting])
        #expect(VideoMeetingChoice.options(own: .faceTime) == [.faceTime, .zoom, .noMeeting])
        #expect(VideoMeetingChoice.options(own: nil) == [.zoom, .noMeeting], "other accounts, and Microsoft ones without Teams")
        // Until something's chosen: the account's own meeting, or none where it has none.
        let usual = VideoMeetingChoice()
        #expect(usual.option(own: .meet) == .meet && usual.option(own: .faceTime) == .faceTime && usual.option(own: nil) == .noMeeting)
        // Teams on a Microsoft account, Zoom on iCloud, Meet on Google: each account's own choice.
        #expect(usual.offer(calendarsOwn: .teams, accountsOwn: .teams) == .teams)
        let zoom = VideoMeetingChoice(.zoom)
        #expect(zoom.offer(calendarsOwn: nil, accountsOwn: .faceTime) == .zoom && zoom.offer(calendarsOwn: .meet, accountsOwn: .meet) == .zoom)
        #expect(zoom.offer(calendarsOwn: nil, accountsOwn: nil) == .zoom)
        #expect(usual.offer(calendarsOwn: nil, accountsOwn: .faceTime) == .faceTime, "FaceTime on every iCloud calendar")
        #expect(VideoMeetingChoice(.noMeeting).offer(calendarsOwn: .meet, accountsOwn: .meet) == .noMeeting)
        #expect(usual.offer(calendarsOwn: nil, accountsOwn: .meet) == .noMeeting, "no FaceTime on a calendar that can't make Meet")
        #expect(VideoMeetingChoice(.faceTime).option(own: .meet) == .meet, "a choice the account can't have gives way")
        #expect(VideoMeetingChoice(.teams).option(own: nil) == .noMeeting)
        // Zoom's Personal Room, at once where that's chosen.
        #expect(zoom.personalRoomMeeting == nil, "Add Zoom Meeting schedules one unless the Personal Room is chosen")
        var room = VideoMeetingChoice(.zoom, alwaysUsesPersonalRoom: true, personalRoom: "https://zoom.us/j/5551234567?pwd=xyz")
        #expect(room.personalRoomMeeting?.joinURL.absoluteString == "https://zoom.us/j/5551234567?pwd=xyz")
        #expect(VideoMeetingChoice.personalRoom(from: "Join Zoom Meeting\nhttps://zoom.us/j/5551234567?pwd=xyz\n\nMeeting ID: 555 123 4567")
                == "https://zoom.us/j/5551234567?pwd=xyz", "a whole invitation pasted keeps its link")
        #expect(VideoMeetingChoice.personalRoom(from: "https://zoom.us/j/55") == "https://zoom.us/j/55")
        #expect(VideoMeetingChoice(.zoom, alwaysUsesPersonalRoom: true, personalRoom: "not a link").personalRoomMeeting == nil)
        // Kept with the account's calendar preferences; a later choice of FaceTime keeps the room for when Zoom's back.
        room.chosen = .faceTime
        #expect(room.personalRoomMeeting == nil, "only while Zoom is chosen")
        let saved = try JSONDecoder().decode(VideoMeetingChoice.self, from: JSONEncoder().encode(room))
        #expect(saved == room && saved.personalRoom == "https://zoom.us/j/5551234567?pwd=xyz")
        #expect(try JSONDecoder().decode(VideoMeetingChoice.self, from: JSONEncoder().encode(usual)).chosen == nil)
    }

    @Test func htmlBecomesPlainTextAndSnippets() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;there,</p><p>Waffles &amp; friends &#x1F436;</p></body></html>"
        let text = HTMLText.plainText(fromHTML: html)
        #expect(text.contains("Hello there,"))
        #expect(text.contains("Waffles & friends 🐶"))
        #expect(!text.contains("color"))
        #expect(HTMLText.snippet(from: "  Line one\n\n  line   two ") == "Line one line two")
    }
}

@Suite struct PrimitiveTests {
    @Test func encodedWordsDecode() {
        #expect(EncodedWords.decode("=?utf-8?B?SGVsbG8gV2FmZmxlcw==?=") == "Hello Waffles")
        #expect(EncodedWords.decode("=?ISO-8859-1?Q?Caf=E9_au_lait?=") == "Café au lait")
        #expect(EncodedWords.decode("=?utf-8?Q?a?= =?utf-8?Q?b?=") == "ab")
        #expect(EncodedWords.decode("Re: =?utf-8?Q?Pug_=F0=9F=90=B6?= party") == "Re: Pug 🐶 party")
        #expect(EncodedWords.decode("plain =? not encoded") == "plain =? not encoded")
    }

    @Test func transferEncodingsDecode() {
        #expect(TransferEncoding.decodeBase64("SGVs\r\nbG8=") == Data("Hello".utf8))
        #expect(TransferEncoding.decodeBase64("SGVsbG8") == Data("Hello".utf8))
        #expect(String(decoding: TransferEncoding.decodeQuotedPrintable(Data("caf=C3=A9 =\r\nau lait=3D".utf8)), as: UTF8.self) == "café au lait=")
        #expect(String(decoding: TransferEncoding.decodeQuotedPrintable(Data("bad =ZZ escape".utf8)), as: UTF8.self) == "bad =ZZ escape")
    }

    @Test func charsetsDecodeWithFallbacks() {
        #expect(Charsets.decode(Data([0x63, 0x61, 0x66, 0xE9]), charset: "iso-8859-1") == "café")
        #expect(Charsets.decode(Data("café".utf8), charset: "us-ascii") == "café")
        #expect(Charsets.decode(Data([0x93, 0x68, 0x69, 0x94]), charset: "nonsense") == "“hi”")
    }

    @Test func mailDatesParse() throws {
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-21T18:45:00Z"))
        #expect(MailDate.parse("Sat, 21 Nov 2026 13:45:00 -0500") == expected)
        #expect(MailDate.parse("21 Nov 2026 13:45:00 EST") == expected)
        #expect(MailDate.parse("Sat, 21 Nov 26 18:45 GMT (UTC)") == expected)
        #expect(MailDate.parse("2026-11-21T18:45:00Z") == expected)
        #expect(MailDate.parse("not a date") == nil)
        #expect(MailDate.format(expected, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!) == "Sat, 21 Nov 2026 13:45:00 -0500")
    }
}
