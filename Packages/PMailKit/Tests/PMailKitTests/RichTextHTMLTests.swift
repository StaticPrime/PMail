import AppKit
import Testing
@testable import PMailKit

@Suite struct RichTextHTMLTests {
    let base = NSFont.systemFont(ofSize: 13)

    @Test func styledRunsBecomeInlineHTML() {
        let text = NSMutableAttributedString(string: "Hello ", attributes: [.font: base])
        text.append(NSAttributedString(string: "bold", attributes: [.font: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)]))
        text.append(NSAttributedString(string: " & ", attributes: [.font: base]))
        text.append(NSAttributedString(string: "link", attributes: [.font: base, .link: URL(string: "https://example.com/?a=1&b=2")!]))
        text.append(NSAttributedString(string: "\nred", attributes: [.font: base, .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("<div>Hello <b>bold</b> &amp; <a href=\"https://example.com/?a=1&amp;b=2\">link</a></div>"))
        #expect(html.contains("<div><span style=\"color:#ff0000\">red</span></div>"))
    }

    @Test func emptyLinesKeepTheirSpace() {
        let text = NSAttributedString(string: "One\n\nTwo", attributes: [.font: base])
        #expect(RichTextHTML.html(from: text) == "<div>One</div><div><br></div><div>Two</div>")
    }

    @Test func listsBecomeListElements() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        let text = NSMutableAttributedString(string: "Intro\n", attributes: [.font: base])
        text.append(NSAttributedString(string: "\t•\tFirst\n\t•\tSecond\n", attributes: [.font: base, .paragraphStyle: style]))
        text.append(NSAttributedString(string: "After", attributes: [.font: base]))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("<ul"))
        #expect(html.contains("<li>First</li><li>Second</li></ul><div>After</div>"))
        #expect(RichTextHTML.plainText(from: text).contains("• First"))
    }
}
