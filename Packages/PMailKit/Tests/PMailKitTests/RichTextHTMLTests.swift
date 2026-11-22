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

    @Test func fontsHighlightsAndAlignmentGoOutAsStyles() throws {
        let georgia = try #require(NSFont(name: "Georgia", size: 18))
        let text = NSMutableAttributedString(string: "Big serif", attributes: [.font: georgia])
        text.append(NSAttributedString(string: " marked", attributes: [.font: base, .backgroundColor: NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        text.append(NSAttributedString(string: "\nMiddle", attributes: [.font: base, .paragraphStyle: centered]))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("font-size:18px;font-family:Georgia, serif"), "the font goes out with fallbacks")
        #expect(html.contains("background-color:#ffff00"))
        #expect(html.contains("<div style=\"text-align:center\">Middle</div>"))
        #expect(RichTextHTML.fontChoice(forFamily: "Georgia")?.name == "Georgia" && RichTextHTML.fontChoice(forFamily: "Zapfino") == nil)
        #expect(!html.contains("font-family:Arial"), "the default font isn't written out")
    }

    @Test func indentsAndQuotesKeepTheirShape() {
        let indented = NSMutableParagraphStyle()
        indented.headIndent = RichTextHTML.indentStep * 2
        indented.firstLineHeadIndent = RichTextHTML.indentStep * 2
        let quote = NSMutableParagraphStyle()
        quote.textBlocks = [RichTextHTML.QuoteBlock()]
        let text = NSMutableAttributedString(string: "Moved in\n", attributes: [.font: base, .paragraphStyle: indented])
        text.append(NSAttributedString(string: "Quoted one\nQuoted two\n", attributes: [.font: base, .paragraphStyle: quote]))
        text.append(NSAttributedString(string: "Back out", attributes: [.font: base]))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("<div style=\"margin-left:80px\">Moved in</div>"))
        #expect(html.contains("<blockquote style=\"margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex\"><div>Quoted one</div><div>Quoted two</div></blockquote><div>Back out</div>"),
                "neighbouring quoted paragraphs share one quote")
    }

    @Test func picturesGoOutAsInlineParts() throws {
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        let attachment = NSTextAttachment(data: png, ofType: "public.png")
        let text = NSMutableAttributedString(string: "Look: ", attributes: [.font: base])
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " nice", attributes: [.font: base]))
        var images: [OutgoingAttachment] = []
        let html = RichTextHTML.html(from: text, images: &images)
        let picture = try #require(images.first)
        #expect(images.count == 1 && picture.mimeType == "image/png" && picture.data == png)
        let contentID = try #require(picture.contentID)
        #expect(html.contains("<img src=\"cid:\(contentID)\""))
        #expect(!html.contains("\u{FFFC}") && !RichTextHTML.plainText(from: text).contains("\u{FFFC}"))
        #expect(RichTextHTML.html(from: text).contains("cid:"), "the picture stays in place even when pictures aren't collected")
    }
}
