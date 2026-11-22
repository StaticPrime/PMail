import Foundation

/// Something a message asks for from the internet.
public struct RemoteReference: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// A picture or a font: shown as it arrives.
        case content
        /// A style sheet, whose own addresses are pointed at PMail's loader in turn.
        case style
    }

    public var url: URL
    public var kind: Kind

    public init(_ url: URL, kind: Kind = .content) {
        self.url = url
        self.kind = kind
    }
}

/// The pictures, style sheets and fonts a message asks for from the internet, found and pointed at PMail's own loader
/// instead, so a message's page never reaches the internet itself.
///
/// The page asks for `pmail-remote://content/…` (or `pmail-remote://style/…` for a style sheet), with the internet
/// address following in base64url, and PMail answers with its own copy or loads one privately.
public enum RemoteContent {
    /// The scheme a message's page asks PMail for remote content by.
    public static let scheme = "pmail-remote"

    /// The address a page asks for in place of a reference's own.
    public static func address(for reference: RemoteReference) -> String {
        "\(scheme)://\(reference.kind.rawValue)/" + WebBase64.urlEncoded(Data(reference.url.absoluteString.utf8))
    }

    /// The reference behind a `pmail-remote:` address.
    public static func reference(from url: URL) -> RemoteReference? {
        guard url.scheme?.lowercased() == scheme, let kind = url.host.flatMap({ RemoteReference.Kind(rawValue: $0.lowercased()) }),
              let data = decodeBase64URL(String(url.path.drop { $0 == "/" })), let text = String(data: data, encoding: .utf8),
              let original = webURL(text) else { return nil }
        return RemoteReference(original, kind: kind)
    }

    /// A message's HTML with what it asks for from the internet pointed at PMail's loader: pictures (an `img`'s or
    /// image button's `src`, `srcset`s, `background`s), the style sheets it links, and what its styles ask for
    /// (`url(…)`, `@import`). Scripts, frames, video and anything in a comment stay as they are, never to load.
    /// Nothing else changes.
    public static func rewrite(html: String) -> (html: String, references: [RemoteReference]) {
        process(html, rewriting: true)
    }

    /// What a message's HTML asks for from the internet (what `rewrite(html:)` points at the loader), each once, in order.
    public static func references(in html: String) -> [RemoteReference] {
        process(html, rewriting: false).references
    }

    /// A style sheet with what it asks for pointed at PMail's loader: `url(…)` (pictures and fonts) and `@import` (more
    /// style sheets), relative addresses taken from `base`, the style sheet's own address.
    public static func rewrite(css: String, base: URL?) -> (css: String, references: [RemoteReference]) {
        let text = css as NSString
        var output = ""
        var references: [RemoteReference] = []
        var last = 0
        for match in cssReference.matches(in: css, range: NSRange(location: 0, length: text.length)) {
            let isQuotedImport = match.range(at: 1).location != NSNotFound || match.range(at: 2).location != NSNotFound
            let isImport = isQuotedImport || match.range(at: 3).location != NSNotFound
            let raw = [1, 2, 4, 5, 6].map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(text.substring(with:)) ?? ""
            guard let url = webURL(raw, base: base) else { continue }
            let reference = RemoteReference(url, kind: isImport ? .style : .content)
            if !references.contains(reference) { references.append(reference) }
            output += text.substring(with: NSRange(location: last, length: match.range.location - last))
            output += isQuotedImport ? "@import \"\(address(for: reference))\"" : (isImport ? "@import " : "") + "url(\"\(address(for: reference))\")"
            last = NSMaxRange(match.range)
        }
        output += text.substring(from: last)
        return (output, references)
    }

    /// An address as a page gives it, if it's on the web: http or https, absolute, protocol-relative (`//host/…`) or
    /// relative to `base`. Line breaks and tabs are dropped and spaces trimmed, as browsers do.
    public static func webURL(_ text: String, base: URL? = nil) -> URL? {
        var text = text.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" }.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = (base?.scheme ?? "https") + ":" + text }
        let url: URL?
        if let absolute = URL(string: text), absolute.scheme != nil {
            url = absolute
        } else if let base {
            url = URL(string: text, relativeTo: base)?.absoluteURL
        } else {
            url = nil
        }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: Finding them

    /// A comment; an element whose contents aren't markup (a style sheet's are rewritten as CSS); or a start tag.
    private static let segment = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title|xmp)\b((?:[^>"']|"[^"]*"|'[^']*')*)>([\s\S]*?)</\1\s*>|<([a-zA-Z][a-zA-Z0-9:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>"#,
        options: [.caseInsensitive])

    /// An attribute: its name, then its value in double quotes, single quotes or none.
    private static let attribute = try! NSRegularExpression(pattern: #"([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)

    /// `@import "…"`, or a `url(…)` (perhaps after `@import`), quoted or not.
    private static let cssReference = try! NSRegularExpression(
        pattern: #"@import\s+(?:"([^"]*)"|'([^']*)')|(@import\s+)?url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"'\s]*))\s*\)"#,
        options: [.caseInsensitive])

    private static func process(_ html: String, rewriting: Bool) -> (html: String, references: [RemoteReference]) {
        let text = html as NSString
        var output = ""
        var references: [RemoteReference] = []
        var last = 0
        func note(_ found: [RemoteReference]) {
            for reference in found where !references.contains(reference) { references.append(reference) }
        }
        for match in segment.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            var replacement: String?
            if match.range(at: 1).location != NSNotFound {
                guard text.substring(with: match.range(at: 1)).lowercased() == "style" else { continue }
                let contents = match.range(at: 3)
                let result = rewrite(css: text.substring(with: contents), base: nil)
                guard !result.references.isEmpty else { continue }
                note(result.references)
                replacement = text.substring(with: NSRange(location: match.range.location, length: contents.location - match.range.location))
                    + result.css + text.substring(with: NSRange(location: NSMaxRange(contents), length: NSMaxRange(match.range) - NSMaxRange(contents)))
            } else if match.range(at: 4).location != NSNotFound {
                let name = text.substring(with: match.range(at: 4))
                let result = rewrite(attributes: text.substring(with: match.range(at: 5)), of: name.lowercased())
                guard !result.references.isEmpty else { continue }
                note(result.references)
                replacement = "<" + name + result.attributes + ">"
            }
            guard rewriting, let replacement else { continue }
            output += text.substring(with: NSRange(location: last, length: match.range.location - last)) + replacement
            last = NSMaxRange(match.range)
        }
        guard rewriting else { return (html, references) }
        output += text.substring(from: last)
        return (output, references)
    }

    /// A start tag's attributes with the addresses that load something pointed at the loader.
    private static func rewrite(attributes: String, of tag: String) -> (attributes: String, references: [RemoteReference]) {
        let text = attributes as NSString
        let matches = attribute.matches(in: attributes, range: NSRange(location: 0, length: text.length))
        func value(_ match: NSTextCheckingResult) -> String? {
            (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { HTMLText.decodeEntities(text.substring(with: $0)) }
        }
        let linksStyleSheet = tag == "link" && matches.contains { match in
            text.substring(with: match.range(at: 1)).lowercased() == "rel"
                && (value(match) ?? "").lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet")
        }
        var output = ""
        var references: [RemoteReference] = []
        var last = 0
        for match in matches {
            guard let raw = value(match) else { continue }
            let name = text.substring(with: match.range(at: 1)).lowercased()
            var newValue: String?
            if (name == "src" && (tag == "img" || tag == "input")) || name == "background" {
                if let url = webURL(raw) {
                    let reference = RemoteReference(url)
                    references.append(reference)
                    newValue = address(for: reference)
                }
            } else if name == "srcset", tag == "img" || tag == "source" {
                var changed = false
                let candidates = srcsetCandidates(raw).map { candidate -> String in
                    let descriptor = candidate.descriptor.isEmpty ? "" : " " + candidate.descriptor
                    guard let url = webURL(candidate.url) else { return candidate.url + descriptor }
                    let reference = RemoteReference(url)
                    references.append(reference)
                    changed = true
                    return address(for: reference) + descriptor
                }
                if changed { newValue = candidates.joined(separator: ", ") }
            } else if name == "href", linksStyleSheet {
                if let url = webURL(raw) {
                    let reference = RemoteReference(url, kind: .style)
                    references.append(reference)
                    newValue = address(for: reference)
                }
            } else if name == "style" {
                let result = rewrite(css: raw, base: nil)
                if !result.references.isEmpty {
                    references += result.references
                    newValue = result.css
                }
            }
            guard let newValue else { continue }
            output += text.substring(with: NSRange(location: last, length: match.range.location - last))
            output += text.substring(with: match.range(at: 1)) + "=\"" + newValue.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;") + "\""
            last = NSMaxRange(match.range)
        }
        output += text.substring(from: last)
        return (output, references)
    }

    /// A `srcset`'s candidates: each address with what follows it (`2x`, `640w`), as browsers split them, so a
    /// `data:` address's comma stays in it.
    static func srcsetCandidates(_ value: String) -> [(url: String, descriptor: String)] {
        var candidates: [(url: String, descriptor: String)] = []
        var index = value.startIndex
        while index < value.endIndex {
            while index < value.endIndex, value[index].isWhitespace || value[index] == "," { index = value.index(after: index) }
            guard index < value.endIndex else { break }
            var end = index
            while end < value.endIndex, !value[end].isWhitespace { end = value.index(after: end) }
            var url = String(value[index..<end])
            index = end
            var descriptor = ""
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url.removeLast() }
            } else {
                var depth = 0
                let start = index
                while index < value.endIndex {
                    let character = value[index]
                    if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if character == ",", depth == 0 { break }
                    index = value.index(after: index)
                }
                descriptor = value[start..<index].trimmingCharacters(in: .whitespaces)
            }
            if !url.isEmpty { candidates.append((url, descriptor)) }
        }
        return candidates
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
