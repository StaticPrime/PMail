import AppKit
import Foundation

/// Turns what the person wrote (rich text from the editor) into the HTML that goes out, with styles written inline
/// so every mail app shows it the same way.
public enum RichTextHTML {
    /// The HTML for a body: bold, italic, underline and strikethrough, colors, font sizes, links, and bulleted or
    /// numbered lists. Paragraphs become `<div>`s; empty paragraphs keep their space with `<br>`.
    public static func html(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var html = ""
        var openList: (ordered: Bool, marker: NSTextList)?
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
            if let current = openList, current.marker !== list {
                html += current.ordered ? "</ol>" : "</ul>"
                openList = nil
            }
            if let list, openList == nil {
                let ordered = list.isOrdered
                html += ordered ? "<ol style=\"margin:0 0 0 1.5em;padding:0\">" : "<ul style=\"margin:0 0 0 1.5em;padding:0\">"
                openList = (ordered, list)
            }
            var inner = runs(in: text, range: contentRange, dropping: list)
            if inner.isEmpty { inner = "<br>" }
            let alignment = style.map(alignmentCSS) ?? ""
            if list != nil {
                html += "<li\(alignment.isEmpty ? "" : " style=\"\(alignment)\"")>\(inner)</li>"
            } else {
                html += "<div\(alignment.isEmpty ? "" : " style=\"\(alignment)\"")>\(inner)</div>"
            }
            location = NSMaxRange(paragraphRange)
            if paragraphRange.length == 0 { break }
        }
        if let current = openList { html += current.ordered ? "</ol>" : "</ul>" }
        return html
    }

    /// The paragraph's text as HTML runs, with the list marker the editor put in front left out.
    private static func runs(in text: NSAttributedString, range: NSRange, dropping list: NSTextList?) -> String {
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
                if traits.contains(.monoSpace) { styles.append("font-family:monospace") }
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
        text.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\t•\t", with: "• ")
            .replacingOccurrences(of: "\\t(\\d+\\.)\\t", with: "$1 ", options: .regularExpression)
    }

    /// Wraps a body in a document with PMail's default font, for sending.
    public static func document(body: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px\">"
            + body + "</div></body></html>"
    }
}
