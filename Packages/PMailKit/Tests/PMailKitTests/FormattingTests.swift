import Foundation
import Testing
@testable import PMailKit

@Suite struct FormattingTests {
    static let utc = TimeZone(identifier: "UTC")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 1
        return calendar
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    let formatting = MailFormatting(calendar: FormattingTests.calendar, locale: Locale(identifier: "en_US"),
                                    now: { FormattingTests.date("2026-11-21T15:00:00Z") })

    @Test func listDatesShortenWithAge() {
        #expect(formatting.listDate(Self.date("2026-11-21T10:42:00Z")).plainSpaces == "10:42 AM")
        #expect(formatting.listDate(Self.date("2026-11-03T10:42:00Z")) == "Nov 3")
        #expect(formatting.listDate(Self.date("2024-03-04T10:42:00Z")) == "3/4/24")
    }

    @Test func laterDatesSayWhen() {
        #expect(formatting.laterDate(Self.date("2026-11-21T18:00:00Z")).plainSpaces == "Today, 6:00 PM")
        #expect(formatting.laterDate(Self.date("2026-11-22T08:00:00Z")).plainSpaces == "Tomorrow, 8:00 AM")
        #expect(formatting.laterDate(Self.date("2026-11-24T08:00:00Z")).plainSpaces == "Tue, 8:00 AM")
        #expect(formatting.laterDate(Self.date("2026-12-03T08:00:00Z")).plainSpaces == "Dec 3, 8:00 AM")
        #expect(formatting.laterDate(Self.date("2027-01-04T08:00:00Z")).plainSpaces == "Jan 4, 2027, 8:00 AM")
    }

    @Test func messageDatesSayHowLongAgo() {
        #expect(formatting.messageDate(Self.date("2026-11-21T13:00:00Z")).hasSuffix("(2 hours ago)"))
        #expect(!formatting.messageDate(Self.date("2025-01-01T13:00:00Z")).contains("ago"))
    }

    @Test func eventTimes() {
        let start = Self.date("2026-11-21T10:00:00Z")
        #expect(formatting.eventTime(start: start, end: Self.date("2026-11-21T11:00:00Z"), isAllDay: false).plainSpaces == "10:00 AM – 11:00 AM")
        #expect(formatting.eventTime(start: Self.date("2026-11-21T00:00:00Z"), end: Self.date("2026-11-22T00:00:00Z"), isAllDay: true)
                == "Saturday, November 21")
        #expect(formatting.eventTime(start: Self.date("2026-11-21T00:00:00Z"), end: Self.date("2026-11-24T00:00:00Z"), isAllDay: true)
                == "Nov 21 – Nov 23")
        #expect(formatting.shortTime(start) == "10am")
        #expect(formatting.shortTime(Self.date("2026-11-21T13:30:00Z")) == "1:30pm")
    }

    @Test func monthGridsCoverWholeWeeks() {
        let grid = CalendarGrid(calendar: Self.calendar)
        let weeks = grid.monthWeeks(of: Self.date("2026-11-15T12:00:00Z"))
        // November 2026 starts on a Sunday and ends on a Monday: five weeks.
        #expect(weeks.count == 5)
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(weeks.first?.first == Self.date("2026-11-01T00:00:00Z"))
        #expect(grid.startOfWeek(Self.date("2026-11-21T15:00:00Z")) == Self.date("2026-11-15T00:00:00Z"))
        var mondayFirst = Self.calendar
        mondayFirst.firstWeekday = 2
        #expect(CalendarGrid(calendar: mondayFirst).startOfWeek(Self.date("2026-11-21T15:00:00Z")) == Self.date("2026-11-16T00:00:00Z"))
    }

    @Test func overlappingEventsShareTheColumn() {
        func t(_ hour: Double) -> Date { Self.date("2026-11-21T00:00:00Z").addingTimeInterval(hour * 3600) }
        let placements = EventLayout.layout([
            ("a", t(9), t(10)), ("b", t(9.5), t(11)), ("c", t(10), t(10.5)), ("d", t(12), t(13)),
        ])
        #expect(placements["a"] == .init(column: 0, columns: 2, span: 1))
        #expect(placements["b"] == .init(column: 1, columns: 2, span: 1))
        #expect(placements["c"] == .init(column: 0, columns: 2, span: 1))
        #expect(placements["d"] == .init(column: 0, columns: 1, span: 1))
        // Nothing overlaps the late event on the right, so an early event alone in its column can stretch.
        let stretched = EventLayout.layout([("x", t(9), t(10)), ("y", t(9), t(12)), ("z", t(11), t(12))])
        #expect(stretched["y"]?.column == 0 && stretched["x"]?.column == 1)
        #expect(stretched["z"] == .init(column: 1, columns: 2, span: 1))
    }
}

@Suite struct ReplyTests {
    let me = "jamie@example.com"

    func message(from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], replyTo: [MailAddress] = []) -> MailMessage {
        MailMessage(summary: MessageSummary(id: "1", threadID: "t", from: from, to: to, cc: cc, subject: "Re: RE: Fwd: Lunch?",
                                            messageIDHeader: "<m1@example.com>", references: ["<m0@example.com>"]),
                    replyTo: replyTo, textBody: "Tacos at noon?\nBring Waffles.")
    }

    @Test func subjectsGetOnePrefix() {
        #expect(ReplyBuilder.subject("Re: RE: Fwd: Lunch?", kind: .reply) == "Re: Lunch?")
        #expect(ReplyBuilder.subject("Lunch?", kind: .forward) == "Fwd: Lunch?")
        #expect(ReplyBuilder.subject("AW: Termin", kind: .reply) == "Re: Termin")
    }

    @Test func replyAllLeavesMeOutAndKeepsEveryoneElse() {
        let alex = MailAddress(name: "Alex", email: "alex@example.com")
        let sam = MailAddress(name: "Sam", email: "sam@example.com")
        let rae = MailAddress(name: "Rae", email: "rae@example.com")
        let original = message(from: alex, to: [MailAddress(email: me), sam], cc: [rae, alex])
        let reply = ReplyBuilder.recipients(for: original, kind: .reply, me: me)
        #expect(reply.to == [alex] && reply.cc.isEmpty)
        let all = ReplyBuilder.recipients(for: original, kind: .replyAll, me: me)
        #expect(all.to == [alex, sam])
        #expect(all.cc == [rae])
    }

    @Test func replyingToMyOwnMessageGoesToItsRecipients() {
        let sam = MailAddress(name: "Sam", email: "sam@example.com")
        let original = message(from: MailAddress(name: "Jamie", email: me), to: [sam])
        #expect(ReplyBuilder.recipients(for: original, kind: .reply, me: me).to == [sam])
    }

    @Test func replyToHeaderWins() {
        let list = MailAddress(email: "list@example.com")
        let original = message(from: MailAddress(email: "alex@example.com"), to: [MailAddress(email: me)], replyTo: [list])
        #expect(ReplyBuilder.recipients(for: original, kind: .reply, me: me).to == [list])
    }

    @Test func draftsQuoteAndThread() {
        let original = message(from: MailAddress(name: "Alex", email: "alex@example.com"), to: [MailAddress(email: me)])
        let reply = ReplyBuilder.draft(for: original, kind: .reply, me: me)
        #expect(reply.inReplyTo == "<m1@example.com>")
        #expect(reply.references == ["<m0@example.com>", "<m1@example.com>"])
        #expect(reply.threadID == "t")
        #expect(reply.quotedText.contains("> Tacos at noon?") && reply.quotedText.contains("Alex <alex@example.com> wrote:"))
        #expect(reply.quotedHTML.contains("<blockquote"))
        let forward = ReplyBuilder.draft(for: original, kind: .forward, me: me)
        #expect(forward.to.isEmpty && forward.inReplyTo == nil && forward.subject == "Fwd: Lunch?")
        #expect(forward.quotedText.hasPrefix("---------- Forwarded message ---------"))
    }
}

private extension String {
    /// The text with the narrow and no-break spaces date formats use made ordinary spaces.
    var plainSpaces: String { replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
}
