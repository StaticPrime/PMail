import AppKit
import PMailKit
import SwiftUI

/// An account's signature, with the same formatting as messages: fonts, colors, links, and pictures (from a file,
/// kept in it, or from the web, by address). It reports the signature as HTML and as plain text as it changes.
struct SignatureEditor: View {
    let account: Account
    /// Whether the signature lives on the account's server too (a Google account), where pictures have to come from
    /// the web.
    let syncsWithServer: Bool
    let onChange: (_ html: String?, _ plain: String) -> Void
    @State private var controller = RichTextController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signature").font(.pm(12)).foregroundStyle(Theme.textSecondary)
            FormattingBar(editor: controller, compact: true)
            SignatureTextView(initial: initialText, controller: controller) { text in
                let empty = text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Self.hasPictures(text)
                let html = syncsWithServer ? RichTextHTML.html(from: text) : RichTextHTML.selfContainedHTML(from: text)
                onChange(empty ? nil : html, RichTextHTML.plainText(from: text))
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider))
            HStack(spacing: 12) {
                Button("Link…") { controller.insertLink() }
                if !syncsWithServer { Button("Picture…") { choosePicture() } }
                Button("Picture from the Web…") { askForPictureAddress() }
                Spacer()
            }
            .controlSize(.small)
            Text(note).font(.pm(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where this account's signature lives.
    private var note: String {
        if syncsWithServer {
            return "This is the account's signature on Google: changes made here are saved there, and changes made there show up here. Pictures in it come from the web."
        }
        if account.kind == .microsoft {
            return "Microsoft doesn't let other apps read or change Outlook signatures, so this is PMail's own, kept on this Mac."
        }
        return "Kept on this Mac, pictures and all."
    }

    private var initialText: NSAttributedString {
        if let html = account.signatureHTML, !html.isEmpty { return RichTextHTML.attributedString(fromHTML: html) }
        return NSAttributedString(string: account.signature, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor])
    }

    private static func hasPictures(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        if panel.runModal() == .OK, let url = panel.url { controller.insertPicture(url) }
    }

    /// A picture shown from its web address (what a Google signature's logo needs).
    private func askForPictureAddress() {
        let alert = NSAlert()
        alert.messageText = "Picture from the web"
        alert.informativeText = "Paste the web address of the picture. It's shown from there in every message."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let address = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        controller.insertWebPicture(url)
    }
}

/// The text view a signature is written in.
private struct SignatureTextView: NSViewRepresentable {
    let initial: NSAttributedString
    let controller: RichTextController
    let onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposeTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
        textView.isAutomaticLinkDetectionEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.keepsListMarkersInText()
        textView.textStorage?.setAttributedString(initial)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Signature")
        controller.textView = textView
        RemotePictures.load(in: textView)
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

/// Pictures in text that are shown from the web (a signature's logo): fetched privately, through the proxy in
/// Settings ▸ Privacy when there is one, and drawn once they arrive.
enum RemotePictures {
    static func load(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        var wanted: [(NSTextAttachment, URL)] = []
        storage.enumerateAttribute(RichTextHTML.imageSourceKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let source = value as? String, let url = URL(string: source),
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  attachment.image == nil else { return }
            wanted.append((attachment, url))
        }
        for (attachment, url) in wanted {
            Task { [weak textView] in
                guard let data = try? await RemoteContentLoader.shared.data(from: url), let image = NSImage(data: data), let textView else { return }
                attachment.image = image
                // Wherever it is now (the text may have changed meanwhile).
                guard let storage = textView.textStorage else { return }
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard (value as? NSTextAttachment) === attachment else { return }
                    textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                    textView.needsDisplay = true
                    stop.pointee = true
                }
            }
        }
    }
}
