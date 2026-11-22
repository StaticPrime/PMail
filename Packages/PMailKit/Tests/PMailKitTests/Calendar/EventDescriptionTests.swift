import AppKit
import Foundation
import Testing
@testable import PMailKit

/// Formatted event descriptions: the simple HTML written from the editor, providers' HTML cut down to it, and each
/// calendar keeping it.
struct EventDescriptionTests {
    private let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]

    private func text(_ pieces: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, attributes) in pieces { result.append(NSAttributedString(string: string, attributes: plain.merging(attributes) { $1 })) }
        return result
    }

    private var bold: [NSAttributedString.Key: Any] { [.font: NSFont.boldSystemFont(ofSize: 13)] }
    private var italic: [NSAttributedString.Key: Any] {
        [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)]
    }

    private func list(ordered: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
        return [.paragraphStyle: style]
    }

    @Test func plainTextStaysPlain() {
        #expect(EventDescription.html(from: NSAttributedString(string: "Bring the slides.\nAnd snacks.", attributes: plain)) == nil)
        let typedLink = text([("See ", [:]), ("https://example.com/plan", [.link: URL(string: "https://example.com/plan")!])])
        #expect(EventDescription.html(from: typedLink) == nil, "a link that's just its own address, as typing one makes, isn't formatting")
    }

    @Test func formattingIsWrittenAsSimpleHTML() {
        let formatted = text([("Plan: ", [:]), ("bold", bold), (", ", [:]), ("italic", italic), (", ", [:]),
                              ("under", [.underlineStyle: NSUnderlineStyle.single.rawValue]), (" & ", [:]),
                              ("the agenda", [.link: URL(string: "https://example.com/agenda?a=1&b=2")!]), ("\nNext line", [:])])
        #expect(EventDescription.html(from: formatted)
                == "Plan: <b>bold</b>, <i>italic</i>, <u>under</u> &amp; <a href=\"https://example.com/agenda?a=1&amp;b=2\">the agenda</a><br>Next line")
        let lists = text([("Before\n", [:]), ("\t•\tApples\n\t•\tPears\n", list(ordered: false)), ("\t1.\tFirst\n", list(ordered: true)), ("After", [:])])
        #expect(EventDescription.html(from: lists) == "Before<ul><li>Apples</li><li>Pears</li></ul><ol><li>First</li></ol>After")
        let spaced = text([("Title", bold), ("\n\nBody", [:])])
        #expect(EventDescription.html(from: spaced) == "<b>Title</b><br><br>Body", "an empty line stays")
    }

    @Test func providersHTMLIsCutDownToFormatting() {
        let outlook = #"""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><style>p{margin:0}</style></head>
        <body><div class="elementToProof" style="font-family:Aptos;font-size:12pt">Hello <b>team</b>,
        <img src="https://tracker.example/pixel.gif"><script>alert(1)</script><span style="color:red">see</span>
        <a href="https://example.com/doc" target="_blank" onclick="x()">the doc</a> <a href="javascript:alert(2)">bad</a></div></body></html>
        """#
        let simplified = EventDescription.simplified(outlook)
        #expect(simplified?.hasPrefix("<div>Hello <b>team</b>,") == true, "\(simplified ?? "nil")")
        #expect(simplified?.contains("<a href=\"https://example.com/doc\">the doc</a>") == true)
        #expect(simplified?.contains("<a>bad</a>") == true, "a script link loses its address")
        for gone in ["img", "script", "style", "meta", "span", "tracker", "alert", "onclick", "class="] {
            #expect(simplified?.contains(gone) == false, "no \(gone)")
        }
        #expect(EventDescription.simplified("<p>Just text, <span>no formatting</span></p>") == nil, "plain text in HTML is plain")
        #expect(EventDescription.simplified("<ul><li>One</li></ul>") == "<ul><li>One</li></ul>")
    }

    @Test func googleKeepsTheDescriptionAsHTML() async throws {
        let events = "/calendar/v3/calendars/jamie@acme.example/events"
        let transport = StubTransport()
        transport.on("GET", events) { _ in
            .json(#"{"items": [{"id": "rich", "summary": "Planning", "description": "<b>Agenda</b><br><ul><li>Budget</li></ul>", "start": {"dateTime": "2026-11-24T14:00:00Z"}, "end": {"dateTime": "2026-11-24T15:00:00Z"}}, {"id": "plain", "summary": "Lunch", "description": "Bring cake", "start": {"dateTime": "2026-11-25T14:00:00Z"}, "end": {"dateTime": "2026-11-25T15:00:00Z"}}]}"#)
        }
        transport.on("POST", events) { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "made"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let calendar = GoogleCalendarService(client: .test(transport))
        let loaded = try await calendar.loadEvents(in: ["jamie@acme.example"], from: WebFixtures.date("2026-11-22T00:00:00Z"),
                                                   to: WebFixtures.date("2026-11-30T00:00:00Z"))
        let rich = try #require(loaded.first { $0.id == "rich" })
        #expect(rich.notesHTML == "<b>Agenda</b><br><ul><li>Budget</li></ul>")
        #expect(rich.notes?.contains("Agenda") == true && rich.notes?.contains("Budget") == true && rich.notes?.contains("<") == false)
        #expect(loaded.first { $0.id == "plain" }?.notesHTML == nil)
        let start = WebFixtures.date("2026-11-26T15:00:00Z")
        _ = try await calendar.create(CalendarEvent(calendarID: "jamie@acme.example", title: "Review", start: start, end: start.addingTimeInterval(3_600),
                                                    notes: "Agenda", notesHTML: "<b>Agenda</b>"), addingConference: false)
        #expect(transport.sent("POST", events).last?.bodyJSONValue["description"] == "<b>Agenda</b>")
        _ = try await calendar.create(CalendarEvent(calendarID: "jamie@acme.example", title: "Review", start: start, end: start.addingTimeInterval(3_600),
                                                    notes: "Agenda"), addingConference: false)
        #expect(transport.sent("POST", events).last?.bodyJSONValue["description"] == "Agenda")
    }

    @Test func microsoftKeepsTheBodyAsHTML() async throws {
        let transport = StubTransport()
        transport.on("POST", "/v1.0/me/calendars/AAMkCal1=/events") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "AAMkNew="
            echo["start"] = ["dateTime": "2026-11-26T15:00:00.0000000", "timeZone": "UTC"]
            echo["end"] = ["dateTime": "2026-11-26T16:00:00.0000000", "timeZone": "UTC"]
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self))
        }
        let calendar = MicrosoftCalendarService(client: .test(transport))
        let start = WebFixtures.date("2026-11-26T15:00:00Z")
        let made = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "Review", start: start, end: start.addingTimeInterval(3_600),
                                                           notes: "Agenda", notesHTML: "<b>Agenda</b>"), addingConference: false)
        #expect(transport.requests.last?.bodyJSONValue["body"] == ["contentType": "html", "content": "<b>Agenda</b>"])
        #expect(made.notesHTML == "<b>Agenda</b>" && made.notes == "Agenda", "read back from the body")
        _ = try await calendar.create(CalendarEvent(calendarID: "AAMkCal1=", title: "Review", start: start, end: start.addingTimeInterval(3_600),
                                                    notes: "Agenda"), addingConference: false)
        #expect(transport.requests.last?.bodyJSONValue["body"] == ["contentType": "text", "content": "Agenda"])
    }

    @Test func iCalendarKeepsAFormattedCopy() throws {
        let writer = ICalendarWriter(ownerEmail: "me@example.com", localTimeZone: ICS.timeZone("UTC"), now: ICS.moment("2026-11-21 12:00"))
        let event = CalendarEvent(calendarID: "cal", title: "Review", start: ICS.moment("2026-11-24 15:00"), end: ICS.moment("2026-11-24 16:00"),
                                  notes: "Agenda\n• Budget", notesHTML: "<b>Agenda</b><ul><li>Budget</li></ul>")
        var file = writer.newCalendar(for: event, uid: "rich-1")
        #expect(file.serialized.contains("X-ALT-DESC;FMTTYPE=text/html:"))
        var loaded = try #require(ICS.events(file.serialized, from: "2026-11-22 00:00", to: "2026-11-30 00:00").first)
        #expect(loaded.notesHTML == "<b>Agenda</b><ul><li>Budget</li></ul>" && loaded.notes == "Agenda\n• Budget", "other programs read DESCRIPTION")
        loaded.notesHTML = nil
        loaded.notes = "Just text"
        _ = try writer.update(&file, with: loaded, scope: .thisEvent)
        #expect(!file.serialized.contains("X-ALT-DESC"), "no formatted copy left to show instead")
    }

    @Test func aPastedLinkGoesInTheFormattedDescriptionToo() {
        let start = WebFixtures.date("2026-11-26T15:00:00Z")
        var event = CalendarEvent(calendarID: "cal", title: "Call", start: start, end: start.addingTimeInterval(1_800), location: "Office",
                                  notes: "Agenda", notesHTML: "<b>Agenda</b>")
        event.conference = Conference(kind: .faceTime, joinURL: URL(string: "https://facetime.apple.com/join#v=1&p=abc")!)
        let edited = WebEvents.withPastedLink(event, original: nil, addingConference: false)
        #expect(edited.notes == "Agenda\n\nhttps://facetime.apple.com/join#v=1&p=abc")
        #expect(edited.notesHTML == "<b>Agenda</b><br><br><a href=\"https://facetime.apple.com/join#v=1&amp;p=abc\">https://facetime.apple.com/join#v=1&amp;p=abc</a>")
    }
}
