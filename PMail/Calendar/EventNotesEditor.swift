import AppKit
import PMailKit
import SwiftUI

/// An event's description with formatting: bold, italic, underline, numbered and bulleted lists, and links, from the
/// bar above it (or ⌘B, ⌘I, ⌘U and ⌘K). It reports the description as plain text, and as the simple HTML calendars
/// keep when it has formatting.
struct EventNotesEditor: View {
    let initialHTML: String?
    let initialText: String
    let onChange: (_ plain: String, _ html: String?) -> Void
    @State private var controller = RichTextController()
    @State private var isEmpty: Bool

    init(initialHTML: String?, initialText: String, onChange: @escaping (_ plain: String, _ html: String?) -> Void) {
        self.initialHTML = initialHTML
        self.initialText = initialText
        self.onChange = onChange
        _isEmpty = State(initialValue: initialText.isEmpty && (initialHTML ?? "").isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            DescriptionFormattingBar(editor: controller)
            Divider().overlay(Theme.divider)
            NotesTextView(initialHTML: initialHTML, initialText: initialText, controller: controller) { text in
                isEmpty = text.length == 0
                onChange(RichTextHTML.plainText(from: text), EventDescription.html(from: text))
            }
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text("Add description").font(.pm(13)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minHeight: 170)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
    }
}

/// The formatting a description keeps: bold, italic, underline, numbered and bulleted lists, a link, and taking
/// formatting off.
private struct DescriptionFormattingBar: View {
    let editor: RichTextController

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "bold", help: "Bold (⌘B)", size: 28, iconSize: 12) { editor.toggleTrait(.boldFontMask) }
            IconButton(symbol: "italic", help: "Italic (⌘I)", size: 28, iconSize: 12) { editor.toggleTrait(.italicFontMask) }
            IconButton(symbol: "underline", help: "Underline (⌘U)", size: 28, iconSize: 12) { editor.toggleAttribute(.underlineStyle) }
            separator
            IconButton(symbol: "list.number", help: "Numbered list", size: 28, iconSize: 12) { editor.toggleList(ordered: true) }
            IconButton(symbol: "list.bullet", help: "Bulleted list", size: 28, iconSize: 12) { editor.toggleList(ordered: false) }
            separator
            IconButton(symbol: "link", help: "Link (⌘K)", size: 28, iconSize: 12) { editor.insertLink() }
            IconButton(symbol: "textformat.alt", help: "Remove formatting", size: 28, iconSize: 12) { editor.clearFormatting() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(Theme.composeHeader.opacity(0.6))
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 5)
    }
}

/// The text view a description is written in.
private struct NotesTextView: NSViewRepresentable {
    let initialHTML: String?
    let initialText: String
    let controller: RichTextController
    let onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposeTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        let typing: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.typingAttributes = typing
        textView.isAutomaticLinkDetectionEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.keepsListMarkersInText()
        // Made once, here: reading HTML is slow, and the view keeps the text from then on.
        let initial = initialHTML.map { RichTextHTML.attributedString(fromHTML: $0) } ?? NSAttributedString(string: initialText, attributes: typing)
        textView.textStorage?.setAttributedString(initial)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Description")
        (textView as? ComposeTextView)?.controller = controller
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView { controller.textView = textView }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichTextController
        let onChange: (NSAttributedString) -> Void

        init(controller: RichTextController, onChange: @escaping (NSAttributedString) -> Void) {
            self.controller = controller
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(NSAttributedString(attributedString: textView.attributedString()))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionChanged()
        }
    }
}

/// A formatted description for showing in SwiftUI text: bold, italic, underlining and links, with list markers as
/// they read ("• Budget", "1. First").
enum RichNotes {
    static func attributed(fromHTML html: String) -> AttributedString {
        let text = RichTextHTML.attributedString(fromHTML: html)
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = AttributedString((text.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\u{2028}", with: "\n"))
            var intent: InlinePresentationIntent = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if traits.contains(.italic) { intent.insert(.emphasized) }
            }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { piece.underlineStyle = .single }
            if let link = attributes[.link] { piece.link = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) }
            result += piece
        }
        return result
    }
}
