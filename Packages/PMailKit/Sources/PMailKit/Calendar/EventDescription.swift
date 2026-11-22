import AppKit
import Foundation

/// Event descriptions with formatting: the simple HTML calendars keep (bold, italic, underline, links, and bulleted or
/// numbered lists, with lines broken by `<br>`), written from the editor's text, and cut down to that from what
/// providers send.
public enum EventDescription {
    /// The tags a description keeps; any other tag goes (its text stays).
    static let keptTags: Set<String> = ["b", "strong", "i", "em", "u", "br", "p", "div", "ul", "ol", "li", "a"]
    /// The tags that make a description formatted rather than plain text.
    static let formattingTags: Set<String> = ["b", "strong", "i", "em", "u", "ul", "ol", "a"]

    // MARK: Writing

    /// A description's HTML, from the editor's text; nil when it has no formatting (it's plain text then). A link
    /// that's just its own address, as typing one makes, isn't formatting.
    public static func html(from text: NSAttributedString) -> String? {
        guard isFormatted(text) else { return nil }
        let string = text.string as NSString
        var html = ""
        var openList: NSTextList?
        var afterLine = false
        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            var contentRange = paragraphRange
            while contentRange.length > 0, let scalar = UnicodeScalar(string.character(at: contentRange.upperBound - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentRange.length -= 1
            }
            let style = text.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            let list = style?.textLists.last
            if let open = openList, open !== list {
                html += open.isOrdered ? "</ol>" : "</ul>"
                openList = nil
                afterLine = false
            }
            if let list, openList == nil {
                html += list.isOrdered ? "<ol>" : "<ul>"
                openList = list
            }
            let inner = runs(in: text, range: contentRange, isListItem: list != nil)
            if list != nil {
                html += "<li>\(inner)</li>"
            } else {
                if afterLine { html += "<br>" }
                html += inner
                afterLine = true
            }
            location = NSMaxRange(paragraphRange)
            if paragraphRange.length == 0 { break }
        }
        if let open = openList { html += open.isOrdered ? "</ol>" : "</ul>" }
        return html
    }

    /// Whether the text has bold, italic, underlining, a list, or a link that isn't just its own address.
    static func isFormatted(_ text: NSAttributedString) -> Bool {
        var formatted = false
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, range, stop in
            if let font = attributes[.font] as? NSFont, !font.fontDescriptor.symbolicTraits.isDisjoint(with: [.bold, .italic]) { formatted = true }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { formatted = true }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty { formatted = true }
            if let link = attributes[.link] {
                let address = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                let shown = (text.string as NSString).substring(with: range)
                if !address.isEmpty, shown != address, shown != address.replacingOccurrences(of: "mailto:", with: "") { formatted = true }
            }
            if formatted { stop.pointee = true }
        }
        return formatted
    }

    /// A paragraph's runs as HTML, without the list marker the editor puts in front of a list item ("\t•\t").
    private static func runs(in text: NSAttributedString, range: NSRange, isListItem: Bool) -> String {
        var range = range
        if isListItem {
            let paragraph = (text.string as NSString).substring(with: range)
            if let marker = paragraph.range(of: "^\\t[^\\t]*\\t", options: .regularExpression) {
                let length = paragraph.utf16.distance(from: paragraph.startIndex, to: marker.upperBound)
                range = NSRange(location: range.location + length, length: max(0, range.length - length))
            }
        }
        var html = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            guard attributes[.attachment] == nil else { return }
            var piece = RichTextHTML.escape((text.string as NSString).substring(with: runRange)).replacingOccurrences(of: "\u{2028}", with: "<br>")
            piece = piece.replacingOccurrences(of: "  ", with: " &nbsp;").replacingOccurrences(of: "\t", with: " ")
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { piece = "<b>\(piece)</b>" }
                if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
            if let link = attributes[.link] {
                let address = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !address.isEmpty { piece = "<a href=\"\(RichTextHTML.escape(address))\">\(piece)</a>" }
            }
            html += piece
        }
        return html
    }

    // MARK: Reading

    /// A provider's HTML cut down to what a description keeps: formatting and links, with no pictures, styles,
    /// scripts, or anything else that could load from the internet. Nil when no formatting is left (it's plain text).
    public static func simplified(_ html: String) -> String? {
        var text = html
        if let body = text.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            text = String(text[body.upperBound...])
            if let end = text.range(of: "</body>", options: .caseInsensitive) { text = String(text[..<end.lowerBound]) }
        }
        for pattern in ["<!--.*?-->", "<head\\b.*?</head>", "<style\\b.*?</style>", "<script\\b.*?</script>", "<title\\b.*?</title>"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard let tagPattern = try? NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>", options: []) else { return nil }
        let source = text as NSString
        var result = ""
        var formatted = false
        var last = 0
        for match in tagPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = NSMaxRange(match.range)
            let closing = source.substring(with: match.range(at: 1)) == "/"
            let name = source.substring(with: match.range(at: 2)).lowercased()
            guard keptTags.contains(name) else { continue }
            if name == "a", !closing {
                let attributes = source.substring(with: match.range(at: 3))
                guard let href = Self.href(in: attributes) else {
                    result += "<a>"
                    continue
                }
                result += "<a href=\"\(href)\">"
                formatted = true
                continue
            }
            if formattingTags.contains(name), name != "a" { formatted = true }
            result += closing ? "</\(name)>" : (name == "br" ? "<br>" : "<\(name)>")
        }
        result += source.substring(from: last)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted && !trimmed.isEmpty ? trimmed : nil
    }

    /// A link's address from a tag's attributes, when it's a web, mail or phone link.
    private static func href(in attributes: String) -> String? {
        guard let range = attributes.range(of: #"href\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var value = String(attributes[range])
        value = String(value[value.index(after: value.firstIndex(of: "=") ?? value.startIndex)...]).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let lower = value.lowercased()
        guard ["http://", "https://", "mailto:", "tel:"].contains(where: lower.hasPrefix) else { return nil }
        return value.replacingOccurrences(of: "\"", with: "&quot;")
    }
}
