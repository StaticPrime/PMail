import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns what the person wrote (rich text from the editor) into the HTML that goes out, with styles written inline
/// so every mail app shows it the same way.
public enum RichTextHTML {
    /// A font the editor offers: what it's called, the Mac font it uses (nil for the default), and the CSS that asks
    /// for it in the message, with fallbacks for other systems.
    public struct FontChoice: Sendable, Hashable {
        public let name: String
        public let family: String?
        public let css: String
    }

    public static let fonts: [FontChoice] = [
        FontChoice(name: "Sans Serif", family: nil, css: "Arial, Helvetica, sans-serif"),
        FontChoice(name: "Serif", family: "Times New Roman", css: "'Times New Roman', Times, serif"),
        FontChoice(name: "Fixed Width", family: "Courier New", css: "'Courier New', Courier, monospace"),
        FontChoice(name: "Wide", family: "Arial Black", css: "'Arial Black', Arial, sans-serif"),
        FontChoice(name: "Narrow", family: "Arial Narrow", css: "'Arial Narrow', Arial, sans-serif"),
        FontChoice(name: "Comic Sans MS", family: "Comic Sans MS", css: "'Comic Sans MS', cursive, sans-serif"),
        FontChoice(name: "Georgia", family: "Georgia", css: "Georgia, serif"),
        FontChoice(name: "Tahoma", family: "Tahoma", css: "Tahoma, Geneva, sans-serif"),
        FontChoice(name: "Trebuchet MS", family: "Trebuchet MS", css: "'Trebuchet MS', Helvetica, sans-serif"),
        FontChoice(name: "Verdana", family: "Verdana", css: "Verdana, Geneva, sans-serif"),
    ]

    /// The font choice a Mac font family is, if it's one of them.
    public static func fontChoice(forFamily family: String?) -> FontChoice? {
        guard let family else { return nil }
        return fonts.first { $0.family == family }
    }

    /// Marks quoted paragraphs in the editor, which draws them with a bar down their left side; they go out as
    /// `<blockquote>`.
    public final class QuoteBlock: NSTextBlock {
        public override init() {
            super.init()
            setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            setBorderColor(.tertiaryLabelColor, for: .minX)
            setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
        }

        public required init?(coder: NSCoder) {
            super.init(coder: coder)
        }
    }

    /// How far each step of indenting moves a paragraph, in points.
    public static let indentStep: CGFloat = 40

    /// The HTML for a body: fonts, sizes, bold, italic, underline and strikethrough, text and highlight colors,
    /// links, alignment, indenting, quotes, bulleted or numbered lists, and pictures (as `cid:` references, the
    /// pictures themselves added to `images`). Paragraphs become `<div>`s; empty paragraphs keep their space with
    /// `<br>`.
    public static func html(from text: NSAttributedString, images: inout [OutgoingAttachment]) -> String {
        let string = text.string as NSString
        var html = ""
        var openList: (ordered: Bool, marker: NSTextList)?
        var inQuote = false
        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            var contentRange = paragraphRange
            // Leave the paragraph's own line break out.
            while contentRange.length > 0, let scalar = UnicodeScalar(string.character(at: contentRange.upperBound - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentRange.length -= 1
            }
            let style = paragraphRange.length > 0 && paragraphRange.location < text.length
                ? text.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let list = style?.textLists.last
            let quoted = style?.textBlocks.contains { $0 is QuoteBlock } ?? false
            if let current = openList, current.marker !== list || quoted != inQuote {
                html += current.ordered ? "</ol>" : "</ul>"
                openList = nil
            }
            if quoted != inQuote {
                html += quoted ? "<blockquote style=\"margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex\">" : "</blockquote>"
                inQuote = quoted
            }
            if let list, openList == nil {
                let ordered = list.isOrdered
                html += ordered ? "<ol style=\"margin:0 0 0 1.5em;padding:0\">" : "<ul style=\"margin:0 0 0 1.5em;padding:0\">"
                openList = (ordered, list)
            }
            var inner = runs(in: text, range: contentRange, dropping: list, images: &images)
            if inner.isEmpty { inner = "<br>" }
            var paragraphStyles: [String] = []
            if let style, !alignmentCSS(style).isEmpty { paragraphStyles.append(alignmentCSS(style)) }
            // Indenting (outside lists and quotes, which have their own) moves the paragraph in from the left.
            if list == nil, !quoted, let indent = style?.headIndent, indent >= 1 {
                paragraphStyles.append("margin-left:\(Int(indent.rounded()))px")
            }
            let styleAttribute = paragraphStyles.isEmpty ? "" : " style=\"\(paragraphStyles.joined(separator: ";"))\""
            html += list != nil ? "<li\(styleAttribute)>\(inner)</li>" : "<div\(styleAttribute)>\(inner)</div>"
            location = NSMaxRange(paragraphRange)
            if paragraphRange.length == 0 { break }
        }
        if let current = openList { html += current.ordered ? "</ol>" : "</ul>" }
        if inQuote { html += "</blockquote>" }
        return html
    }

    /// The HTML for a body, leaving pictures out.
    public static func html(from text: NSAttributedString) -> String {
        var images: [OutgoingAttachment] = []
        return html(from: text, images: &images)
    }

    /// The paragraph's text as HTML runs, with the list marker the editor put in front left out.
    private static func runs(in text: NSAttributedString, range: NSRange, dropping list: NSTextList?,
                             images: inout [OutgoingAttachment]) -> String {
        var range = range
        if let list {
            let string = text.string as NSString
            let paragraph = string.substring(with: range)
            // The editor writes markers as "\t•\t" or "\t1.\t".
            if let marker = paragraph.range(of: "^\\t[^\\t]*\\t", options: .regularExpression) {
                let length = paragraph.utf16.distance(from: paragraph.startIndex, to: marker.upperBound)
                range = NSRange(location: range.location + length, length: max(0, range.length - length))
            }
            _ = list
        }
        var html = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            // A picture in the text goes out as a part of its own, shown where it sits.
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let picture = picture(from: attachment, number: images.count + 1) {
                    images.append(picture)
                    html += "<img src=\"cid:\(picture.contentID ?? "")\" alt=\"\(escape(picture.filename))\" style=\"max-width:100%\">"
                }
                return
            }
            let raw = (text.string as NSString).substring(with: runRange)
            var piece = escape(raw).replacingOccurrences(of: "\u{2028}", with: "<br>")
            // Runs of spaces would collapse in HTML.
            piece = piece.replacingOccurrences(of: "  ", with: " &nbsp;").replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")
            var styles: [String] = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { piece = "<b>\(piece)</b>" }
                if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
                if abs(font.pointSize - 13) > 0.5 { styles.append("font-size:\(Int(font.pointSize.rounded()))px") }
                if let choice = fontChoice(forFamily: font.familyName), choice.family != nil {
                    styles.append("font-family:\(choice.css)")
                } else if traits.contains(.monoSpace) {
                    styles.append("font-family:monospace")
                }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { piece = "<s>\(piece)</s>" }
            if let color = attributes[.foregroundColor] as? NSColor, let css = cssColor(color), css != "#000000", css != "#1f1f1f" {
                styles.append("color:\(css)")
            }
            if let background = attributes[.backgroundColor] as? NSColor, let css = cssColor(background) {
                styles.append("background-color:\(css)")
            }
            if !styles.isEmpty { piece = "<span style=\"\(styles.joined(separator: ";"))\">\(piece)</span>" }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { piece = "<a href=\"\(escape(url))\">\(piece)</a>" }
            }
            html += piece
        }
        return html
    }

    /// A picture in the text as an attachment with a Content-ID, or nil when it has no data.
    private static func picture(from attachment: NSTextAttachment, number: Int) -> OutgoingAttachment? {
        var data = attachment.contents ?? attachment.fileWrapper?.regularFileContents
        var type = attachment.fileType.flatMap { UTType($0) }
        if data == nil, let image = attachment.image, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            data = png
            type = .png
        }
        guard let data, !data.isEmpty else { return nil }
        let mimeType = type?.preferredMIMEType ?? "image/png"
        let ext = type?.preferredFilenameExtension ?? "png"
        let name = attachment.fileWrapper?.preferredFilename ?? "picture-\(number).\(ext)"
        return OutgoingAttachment(filename: name, mimeType: mimeType, data: data,
                                  contentID: "picture\(number).\(UUID().uuidString.lowercased().prefix(12))@pmail")
    }

    private static func alignmentCSS(_ style: NSParagraphStyle) -> String {
        switch style.alignment {
        case .center: "text-align:center"
        case .right: "text-align:right"
        case .justified: "text-align:justify"
        default: ""
        }
    }

    /// "#rrggbb" for a color, in sRGB; nil for clear colors.
    public static func cssColor(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.01 else { return nil }
        func hex(_ value: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, value)) * 255).rounded())) }
        return "#" + hex(rgb.redComponent) + hex(rgb.greenComponent) + hex(rgb.blueComponent)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The plain-text version of a body, with list markers written as text ("• ", "1. ").
    public static func plainText(from text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t•\t", with: "• ")
            .replacingOccurrences(of: "\\t(\\d+\\.)\\t", with: "$1 ", options: .regularExpression)
    }

    /// Wraps a body in a document with PMail's default font, for sending.
    public static func document(body: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px\">"
            + body + "</div></body></html>"
    }
}
