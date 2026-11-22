import AppKit
import PMailKit
import SwiftUI
import UniformTypeIdentifiers

/// The compose windows, docked side by side along the bottom right of the main window.
struct ComposeDock: View {
    let app: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(app.composers) { composer in
                ComposeWindow(app: app, model: composer)
            }
        }
        .padding(.trailing, 24)
    }
}

/// One message being written, as a floating window with a header, the fields, the editor and the send bar.
struct ComposeWindow: View {
    let app: AppModel
    @Bindable var model: ComposeModel
    @State private var editor = RichTextController()
    @State private var dropTargeted = false
    @FocusState private var subjectFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.isMinimized {
                VStack(spacing: 0) {
                    if app.accounts.accounts.count > 1 {
                        HStack {
                            Text("From").font(.pm(13)).foregroundStyle(Theme.textSecondary)
                            Text(model.account.address.formatted).font(.pm(13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        Divider().overlay(Theme.divider).padding(.horizontal, 16)
                    }
                    RecipientField(label: "To", addresses: $model.to, contacts: model.session.contacts) {
                        HStack(spacing: 8) {
                            if !model.showsCc { Button("Cc") { model.showsCc = true }.buttonStyle(.plain) }
                            if !model.showsBcc { Button("Bcc") { model.showsBcc = true }.buttonStyle(.plain) }
                        }
                        .font(.pm(13))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if model.showsCc { RecipientField(label: "Cc", addresses: $model.cc, contacts: model.session.contacts) { EmptyView() } }
                    if model.showsBcc { RecipientField(label: "Bcc", addresses: $model.bcc, contacts: model.session.contacts) { EmptyView() } }
                    TextField("Subject", text: $model.subject)
                        .textFieldStyle(.plain)
                        .font(.pm(13.5))
                        .focused($subjectFocused)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background { Color.clear.contentShape(Rectangle()).onTapGesture { subjectFocused = true } }
                        .textCursor()
                    Divider().overlay(Theme.divider).padding(.horizontal, 16)
                    RichTextEditor(model: model, controller: editor)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    if model.quotedHTML != nil {
                        HStack {
                            Button {
                                model.showsQuote.toggle()
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 30, height: 14)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                            }
                            .buttonStyle(.plain)
                            .help(model.showsQuote ? "Hide the quoted message" : "Show the quoted message")
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        if model.showsQuote, let quote = model.quotedText {
                            ScrollView {
                                Text(quote).font(.pm(12)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 140)
                            .padding(.horizontal, 16)
                        }
                    }
                    if !model.attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, file in
                                    HStack(spacing: 6) {
                                        Image(systemName: "paperclip").font(.system(size: 11))
                                        Text(file.filename).font(.pm(12, .medium)).lineLimit(1)
                                        Text("(\(MailFormatting().fileSize(file.data.count)))").font(.pm(11)).foregroundStyle(Theme.textSecondary)
                                        Button { model.removeAttachment(at: index) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Remove \(file.filename)")
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip.opacity(0.7)))
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .frame(height: 36)
                    }
                    if let error = model.error {
                        Text(error).font(.pm(12)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    if model.showsFormatting { FormattingBar(editor: editor).padding(.horizontal, 12) }
                    sendBar
                }
                .frame(height: model.isExpanded ? 680 : 500)
            }
        }
        .frame(width: model.isMinimized ? 280 : (model.isExpanded ? 860 : 560))
        .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12)
            .fill(Theme.surfaceRaised))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12)
            .strokeBorder(dropTargeted ? Theme.accent : .clear, lineWidth: 2))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .dropDestination(for: URL.self) { urls, _ in
            model.attach(urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(model.title).font(.pm(13.5, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            IconButton(symbol: "minus", help: model.isMinimized ? "Restore" : "Minimize", size: 26, iconSize: 11) { model.isMinimized.toggle() }
            IconButton(symbol: model.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: model.isExpanded ? "Make smaller" : "Make bigger", size: 26, iconSize: 11) {
                model.isExpanded.toggle()
                model.isMinimized = false
            }
            IconButton(symbol: "xmark", help: "Save & close", size: 26, iconSize: 11) { model.closeKeepingDraft() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Theme.composeHeader)
        .contentShape(Rectangle())
        .onTapGesture { if model.isMinimized { model.isMinimized = false } }
    }

    private var sendBar: some View {
        HStack(spacing: 2) {
            SplitSendButton(isSending: model.isSending) { model.send() } schedule: { date in model.schedule(at: date) }
                .padding(.trailing, 8)
            IconButton(symbol: "textformat", help: model.showsFormatting ? "Hide formatting options" : "Formatting options", size: 34, iconSize: 15,
                       tint: model.showsFormatting && !model.isPlainText ? Theme.accent : Theme.icon, isDisabled: model.isPlainText) {
                model.showsFormatting.toggle()
            }
            IconButton(symbol: "paperclip", help: "Attach files", size: 34, iconSize: 15) { chooseFiles() }
            IconButton(symbol: "link", help: "Insert link (⌘K)", size: 34, iconSize: 15) { editor.insertLink() }
            IconButton(symbol: "face.smiling", help: "Insert emoji", size: 34, iconSize: 15) { editor.showEmoji() }
            IconButton(symbol: "photo", help: model.isPlainText ? "Attach a picture" : "Insert a picture", size: 34, iconSize: 15) { choosePictures() }
            IconButton(symbol: "signature", help: "Insert signature", size: 34, iconSize: 15) { insertSignature() }
            MoreComposeOptions(app: app, model: model, editor: editor)
            Spacer()
            IconButton(symbol: "trash", help: "Discard draft", size: 34, iconSize: 15) { model.discard() }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }

    private func chooseFiles(images: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if images { panel.allowedContentTypes = [.image] }
        panel.prompt = "Attach"
        if panel.runModal() == .OK { model.attach(panel.urls) }
    }

    /// Pictures go in the text where the cursor is (attached instead in plain text mode).
    private func choosePictures() {
        guard !model.isPlainText else { return chooseFiles(images: true) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        if panel.runModal() == .OK { for url in panel.urls { editor.insertPicture(url) } }
    }

    private func insertSignature() {
        guard let signature = model.richSignature else {
            return app.show("This account has no signature yet. Add one in its settings, from the account menu at the top right.")
        }
        let piece = NSMutableAttributedString(string: "\n-- \n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor])
        piece.append(signature)
        if model.isPlainText {
            editor.insertText("\n-- \n" + model.account.signature)
        } else {
            editor.insertAttributed(piece)
        }
    }
}

/// The formatting bar: font, size, bold, italic, underline, text and highlight colors, alignment, lists, indenting,
/// quoting, strikethrough and clearing formatting.
struct FormattingBar: View {
    let editor: RichTextController
    /// Leaves lists, indenting, quotes and strikethrough out, for a narrow place (a signature).
    var compact = false
    @State private var showsColors = false

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(RichTextHTML.fonts, id: \.name) { choice in
                    Button(choice.name) { editor.setFont(choice) }
                }
            } label: {
                // One run of text, so the menu keeps the arrow after the name.
                Text("\(editor.currentFontName)  \(Image(systemName: "chevron.down"))")
                    .font(.pm(13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Font")
            separator
            Menu {
                ForEach(RichTextController.sizes, id: \.name) { size in
                    Button(size.name) { editor.setSize(size.points) }
                }
            } label: {
                Text("\(Image(systemName: "textformat.size")) \(Image(systemName: "chevron.down"))").foregroundStyle(Theme.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Size")
            separator
            IconButton(symbol: "bold", help: "Bold (⌘B)", size: 30, iconSize: 13) { editor.toggleTrait(.boldFontMask) }
            IconButton(symbol: "italic", help: "Italic (⌘I)", size: 30, iconSize: 13) { editor.toggleTrait(.italicFontMask) }
            IconButton(symbol: "underline", help: "Underline (⌘U)", size: 30, iconSize: 13) { editor.toggleAttribute(.underlineStyle) }
            Button { showsColors.toggle() } label: {
                HStack(spacing: 3) {
                    VStack(spacing: 1) {
                        Text("A").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Rectangle().fill(Color(nsColor: editor.currentColor)).frame(width: 14, height: 3)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.icon)
                }
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text and highlight color")
            .popover(isPresented: $showsColors, arrowEdge: .bottom) { ColorPalette(editor: editor) { showsColors = false } }
            separator
            Menu {
                Button { editor.setAlignment(.left) } label: { Label("Align left", systemImage: "text.alignleft") }
                Button { editor.setAlignment(.center) } label: { Label("Center", systemImage: "text.aligncenter") }
                Button { editor.setAlignment(.right) } label: { Label("Align right", systemImage: "text.alignright") }
            } label: {
                Text("\(Image(systemName: "text.alignleft")) \(Image(systemName: "chevron.down"))").foregroundStyle(Theme.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Align")
            if !compact {
                IconButton(symbol: "list.number", help: "Numbered list", size: 30, iconSize: 13) { editor.toggleList(ordered: true) }
                IconButton(symbol: "list.bullet", help: "Bulleted list", size: 30, iconSize: 13) { editor.toggleList(ordered: false) }
                IconButton(symbol: "decrease.indent", help: "Indent less", size: 30, iconSize: 13) { editor.indent(by: -1) }
                IconButton(symbol: "increase.indent", help: "Indent more", size: 30, iconSize: 13) { editor.indent(by: 1) }
                IconButton(symbol: "text.quote", help: "Quote", size: 30, iconSize: 13) { editor.toggleQuote() }
                separator
                IconButton(symbol: "strikethrough", help: "Strikethrough", size: 30, iconSize: 13) { editor.toggleAttribute(.strikethroughStyle) }
            }
            Menu {
                Button { editor.clearFormatting() } label: { Label("Remove formatting", systemImage: "textformat.alt") }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("More formatting")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Capsule().fill(Theme.composeHeader))
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 5)
    }
}

/// Highlight and text colors, in two grids.
private struct ColorPalette: View {
    let editor: RichTextController
    let done: () -> Void

    /// Eight columns: a row of grays, the bright colors, then lighter and darker shades of them.
    static let rows: [[NSColor]] = {
        let grays = [0.0, 0.26, 0.4, 0.6, 0.73, 0.85, 0.94, 1.0].map { NSColor(white: $0, alpha: 1) }
        let hues: [CGFloat] = [0, 30, 52, 120, 180, 215, 270, 310].map { $0 / 360 }
        let shades: [(saturation: CGFloat, brightness: CGFloat)] = [(1, 1), (0.22, 1), (0.42, 1), (0.65, 0.95), (1, 0.72), (1, 0.48)]
        return [grays] + shades.map { shade in hues.map { NSColor(hue: $0, saturation: shade.saturation, brightness: shade.brightness, alpha: 1) } }
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            column("Background color", reset: "No highlight") { editor.setHighlight($0) }
            column("Text color", reset: "Default color") { editor.setColor($0 ?? .textColor) }
        }
        .padding(16)
        .background(Theme.surfaceRaised)
    }

    private func column(_ title: String, reset: String, choose: @escaping (NSColor?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.pm(12.5, .medium)).foregroundStyle(Theme.textPrimary)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(Self.rows[row].indices, id: \.self) { column in
                            let color = Self.rows[row][column]
                            Button {
                                choose(color)
                                done()
                            } label: {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.divider, lineWidth: 0.5))
                                    .frame(width: 17, height: 17)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if row == 1 { GridRow { Color.clear.frame(height: 4).gridCellColumns(8) } }
                }
            }
            Button(reset) {
                choose(nil)
                done()
            }
            .buttonStyle(.plain)
            .font(.pm(12))
            .foregroundStyle(Theme.accent)
        }
    }
}

/// The ⋮ menu: opening new messages full size, plain text, printing, spell checking and labels for the message.
private struct MoreComposeOptions: View {
    let app: AppModel
    let model: ComposeModel
    let editor: RichTextController
    @AppStorage("ComposeFullScreen") private var defaultsToFullScreen = false
    @AppStorage("ComposeSpellCheck") private var checksSpelling = true

    var body: some View {
        Menu {
            Toggle(isOn: $defaultsToFullScreen) { Label("Default to full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Toggle(isOn: Binding(get: { model.isPlainText }, set: { setPlainText($0) })) {
                Label("Plain text mode", systemImage: "textformat.abc")
            }
            Divider()
            Button { editor.printMessage(model) } label: { Label("Print…", systemImage: "printer") }
            Toggle(isOn: Binding(get: { checksSpelling }, set: { on in
                checksSpelling = on
                editor.setSpellChecking(on)
            })) { Label("Spell check", systemImage: "textformat.abc.dottedunderline") }
            if model.session.mail.hasLabels {
                Divider()
                Menu {
                    ForEach(model.session.mail.labels, id: \.folder.id) { item in
                        Toggle(item.folder.name, isOn: Binding(get: { model.labelIDs.contains(item.folder.id) }, set: { on in
                            if on { model.labelIDs.insert(item.folder.id) } else { model.labelIDs.remove(item.folder.id) }
                        }))
                    }
                    if model.session.mail.labels.isEmpty { Text("No labels yet") }
                } label: {
                    Label("Label", systemImage: "tag")
                }
            }
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .help("More options")
    }

    /// Plain text drops the formatting, after asking when there's some to lose.
    private func setPlainText(_ on: Bool) {
        if on, model.hasFormatting {
            let alert = NSAlert()
            alert.messageText = "Switch to plain text?"
            alert.informativeText = "The formatting, and any pictures in the text, will be taken out of this message."
            alert.addButton(withTitle: "Switch to Plain Text")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.setPlainText(on)
    }
}

/// To, Cc or Bcc: the addresses as chips, a field for typing, and suggestions from the account's contacts.
struct RecipientField<Accessory: View>: View {
    let label: String
    @Binding var addresses: [MailAddress]
    let contacts: ContactsViewModel
    @ViewBuilder var accessory: () -> Accessory
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let suggestions = contacts.suggestions(for: text, excluding: addresses)
        VStack(spacing: 0) {
            // The label and Cc and Bcc stay level with the first line of addresses as more lines fill.
            HStack(alignment: .top, spacing: 6) {
                Text(label).font(.pm(13)).foregroundStyle(Theme.textSecondary).frame(width: 28, height: FlowLayout.chipHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                FlowLayout(spacing: 4, minRowHeight: FlowLayout.chipHeight) {
                    ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                        RecipientChip(address: address) { addresses.remove(at: index) }.arrowCursor()
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.pm(13.5))
                        .frame(minWidth: 120)
                        .focused($focused)
                        .onSubmit { commit(suggestions.indices.contains(highlighted) && !text.isEmpty ? suggestions[highlighted] : nil) }
                        .onChange(of: text) { _, new in
                            highlighted = 0
                            if new.contains(",") || new.contains(";") || new.contains("\n") { commit(nil) }
                        }
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit(nil) } }
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, suggestions.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                        .onKeyPress(.tab) {
                            if !text.isEmpty { commit(suggestions.first); return .handled }
                            return .ignored
                        }
                        .onKeyPress(.delete) {
                            if text.isEmpty, !addresses.isEmpty { addresses.removeLast(); return .handled }
                            return .ignored
                        }
                        .accessibilityLabel(label)
                }
                accessory().frame(height: FlowLayout.chipHeight).arrowCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(minHeight: 38)
            // Anywhere in the row is a place to type: the text cursor shows over it, and a click puts the caret in the field.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { focused = true } }
            .textCursor()
            Divider().overlay(Theme.divider).padding(.horizontal, 16)
        }
        .overlay(alignment: .topLeading) {
            if focused, !suggestions.isEmpty, !text.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, address in
                        HStack(spacing: 10) {
                            Avatar(name: address.name ?? "", email: address.email, size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(address.name ?? address.email).font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                                if address.name != nil { Text(address.email).font(.pm(11.5)).foregroundStyle(Theme.textSecondary) }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(index == highlighted ? Theme.hover : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { commit(address) }
                    }
                }
                .frame(width: 360)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .offset(x: 50, y: 38)
                .zIndex(10)
            }
        }
        .zIndex(focused ? 10 : 0)
    }

    /// Turns what's typed into chips: the picked suggestion, or every address in the text.
    private func commit(_ suggestion: MailAddress?) {
        if let suggestion {
            addresses.append(suggestion)
            text = ""
            return
        }
        let parsed = RecipientParser.parse(text)
        guard !parsed.isEmpty else { return }
        addresses.append(contentsOf: parsed.filter { new in !addresses.contains { $0.isSameMailbox(as: new) } })
        text = ""
    }
}

private struct RecipientChip: View {
    let address: MailAddress
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Avatar(name: address.name ?? "", email: address.email, size: 20)
            Text(address.name ?? address.email).font(.pm(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(address.displayName)")
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(Capsule().strokeBorder(Theme.divider))
        .help(address.formatted)
    }
}

/// Addresses typed or pasted into a recipient field: "a@b.c, Jamie <jamie@example.com>; c@d.e".
enum RecipientParser {
    static func parse(_ text: String) -> [MailAddress] {
        text.split(whereSeparator: { ",;\n".contains($0) }).compactMap { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                let email = item[item.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = item[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                return email.contains("@") ? MailAddress(name: name, email: email) : nil
            }
            return MailAddress(email: item)
        }
    }
}

/// Lays chips out in rows, wrapping to the next row as they fill one. Each row is at least `minRowHeight` tall, with
/// what's in it centred, so a text field alone in a row sits where it would beside chips.
struct FlowLayout: Layout {
    /// An address chip's height, the height of a row of them.
    static let chipHeight: CGFloat = 24

    var spacing: CGFloat = 4
    var minRowHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 400, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? 400, height: max(height, 24))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                let isLast = index == subviews.count - 1
                let width = isLast ? max(size.width, bounds.maxX - x) : size.width
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row(height: minRowHeight)]
        var x: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row(height: minRowHeight))
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].sizes.append(size)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}

// MARK: The editor

/// Formatting commands from the bar, carried out on the editor's text view.
@Observable
final class RichTextController {
    @ObservationIgnored weak var textView: NSTextView?

    private var baseFont: NSFont { NSFont.systemFont(ofSize: 13) }

    /// The sizes offered, as the bar names them.
    static let sizes: [(name: String, points: CGFloat)] = [("Small", 10), ("Normal", 13), ("Large", 18), ("Huge", 32)]

    /// The font and color at the cursor (or the start of the selection), shown on the bar.
    var currentFontName = "Sans Serif"
    var currentColor = NSColor.textColor

    /// Follows the cursor, for the bar.
    func selectionChanged() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let attributes = range.length > 0 && range.location < (textView.textStorage?.length ?? 0)
            ? textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:] : textView.typingAttributes
        let font = attributes[.font] as? NSFont
        currentFontName = RichTextHTML.fontChoice(forFamily: font?.familyName)?.name ?? "Sans Serif"
        currentColor = attributes[.foregroundColor] as? NSColor ?? .textColor
    }

    private func applying(_ change: (NSMutableAttributedString, NSRange) -> Void, typing: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            typing(&attributes)
            textView.typingAttributes = attributes
        } else if textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            change(storage, range)
            storage.endEditing()
            textView.didChangeText()
        }
        textView.window?.makeFirstResponder(textView)
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        let sample = range.length > 0 ? (textView.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            : (textView.typingAttributes[.font] as? NSFont)
        let has = sample.map { manager.traits(of: $0).contains(trait) } ?? false
        func convert(_ font: NSFont) -> NSFont { has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait) }
        applying({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                storage.addAttribute(.font, value: convert(value as? NSFont ?? self.baseFont), range: subrange)
            }
        }, typing: { attributes in attributes[.font] = convert(attributes[.font] as? NSFont ?? baseFont) })
    }

    func toggleAttribute(_ key: NSAttributedString.Key) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let current = range.length > 0 ? textView.textStorage?.attribute(key, at: range.location, effectiveRange: nil) as? Int
            : textView.typingAttributes[key] as? Int
        let value = (current ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
        applying({ storage, range in storage.addAttribute(key, value: value, range: range) },
                 typing: { attributes in attributes[key] = value })
    }

    func setColor(_ color: NSColor) {
        applying({ storage, range in storage.addAttribute(.foregroundColor, value: color, range: range) },
                 typing: { attributes in attributes[.foregroundColor] = color })
        currentColor = color
    }

    /// Highlights the text with a color behind it, or takes the highlight off (nil).
    func setHighlight(_ color: NSColor?) {
        applying({ storage, range in
            if let color { storage.addAttribute(.backgroundColor, value: color, range: range) } else { storage.removeAttribute(.backgroundColor, range: range) }
        }, typing: { attributes in attributes[.backgroundColor] = color })
    }

    /// Changes the font, keeping each run's size, bold and italic.
    func setFont(_ choice: RichTextHTML.FontChoice) {
        let manager = NSFontManager.shared
        func convert(_ font: NSFont) -> NSFont {
            let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            var converted: NSFont
            if let family = choice.family {
                converted = manager.font(withFamily: family, traits: traits, weight: 5, size: font.pointSize)
                    ?? NSFont(name: family, size: font.pointSize) ?? font
            } else {
                converted = NSFont.systemFont(ofSize: font.pointSize)
                if traits.contains(.boldFontMask) { converted = manager.convert(converted, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { converted = manager.convert(converted, toHaveTrait: .italicFontMask) }
            }
            return converted
        }
        applying({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                storage.addAttribute(.font, value: convert(value as? NSFont ?? self.baseFont), range: subrange)
            }
        }, typing: { attributes in attributes[.font] = convert(attributes[.font] as? NSFont ?? baseFont) })
        currentFontName = choice.name
    }

    /// Changes the chosen paragraphs' style (the one with the cursor when nothing is chosen), and the typing style.
    private func changingParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let range = string.paragraphRange(for: textView.selectedRange())
        if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let current = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                change(style)
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                location = NSMaxRange(paragraph)
                if paragraph.length == 0 { break }
            }
            storage.endEditing()
            textView.didChangeText()
        }
        let typing = ((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        change(typing)
        textView.typingAttributes[.paragraphStyle] = typing
        textView.window?.makeFirstResponder(textView)
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        changingParagraphs { $0.alignment = alignment }
    }

    /// Moves the chosen paragraphs in (or back out) a step.
    func indent(by steps: Int) {
        changingParagraphs { style in
            guard style.textLists.isEmpty else { return }
            let indent = max(0, style.headIndent + CGFloat(steps) * RichTextHTML.indentStep)
            style.headIndent = indent
            style.firstLineHeadIndent = indent
        }
    }

    /// Quotes the chosen paragraphs (a bar down their left side), or takes the quote off.
    func toggleQuote() {
        guard let textView, let storage = textView.textStorage else { return }
        let location = min(textView.selectedRange().location, max(0, storage.length - 1))
        let style = storage.length > 0 ? storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            : textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let quoted = style?.textBlocks.contains { $0 is RichTextHTML.QuoteBlock } ?? false
        let block = RichTextHTML.QuoteBlock()
        changingParagraphs { style in
            style.textBlocks = quoted ? style.textBlocks.filter { !($0 is RichTextHTML.QuoteBlock) } : [block]
        }
    }

    /// Puts a picture in the text at the cursor, shown no wider than the message.
    func insertPicture(_ url: URL) {
        guard let textView, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        let attachment = NSTextAttachment(data: data, ofType: type.identifier)
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = url.lastPathComponent
        attachment.fileWrapper = wrapper
        attachment.image = image
        let width = min(image.size.width, 480)
        let scale = image.size.width > 0 ? width / image.size.width : 1
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: image.size.height * scale)
        let picture = NSMutableAttributedString(attachment: attachment)
        picture.addAttributes(textView.typingAttributes, range: NSRange(location: 0, length: picture.length))
        textView.window?.makeFirstResponder(textView)
        textView.insertText(picture, replacementRange: textView.selectedRange())
    }

    /// Puts a picture shown from its web address in the text at the cursor; it's fetched to be seen, and goes out by
    /// its address.
    func insertWebPicture(_ url: URL) {
        guard let textView else { return }
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: 0, width: 120, height: 40)
        let picture = NSMutableAttributedString(attachment: attachment)
        picture.addAttributes(textView.typingAttributes, range: NSRange(location: 0, length: picture.length))
        picture.addAttribute(RichTextHTML.imageSourceKey, value: url.absoluteString, range: NSRange(location: 0, length: picture.length))
        textView.window?.makeFirstResponder(textView)
        textView.insertText(picture, replacementRange: textView.selectedRange())
        // Shown at its own size once it arrives, no wider than the message.
        Task { [weak textView] in
            guard let data = try? await RemoteContentLoader.shared.data(from: url), let image = NSImage(data: data), let textView else { return }
            let width = min(image.size.width, 480)
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: image.size.width > 0 ? image.size.height * width / image.size.width : 40)
            attachment.image = image
            textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0), actualCharacterRange: nil)
            textView.didChangeText()
        }
    }

    /// Puts formatted text at the cursor (a signature), fetching any pictures it shows from the web.
    func insertAttributed(_ text: NSAttributedString) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        RemotePictures.load(in: textView)
    }

    /// Types text at the cursor (a signature), with the current style.
    func insertText(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(NSAttributedString(string: text, attributes: textView.typingAttributes), replacementRange: textView.selectedRange())
    }

    func setSpellChecking(_ on: Bool) {
        textView?.isContinuousSpellCheckingEnabled = on
    }

    /// Prints the message as it stands: its subject and recipients, then the text.
    func printMessage(_ model: ComposeModel) {
        let page = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        page.horizontalPagination = .fit
        page.isVerticallyCentered = false
        let width = page.paperSize.width - page.leftMargin - page.rightMargin
        let printable = NSMutableAttributedString()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray]
        printable.append(NSAttributedString(string: (model.subject.isEmpty ? "(no subject)" : model.subject) + "\n",
                                            attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black]))
        printable.append(NSAttributedString(string: "From: \(model.account.address.formatted)\n", attributes: label))
        if !model.to.isEmpty { printable.append(NSAttributedString(string: "To: \(model.to.map(\.formatted).joined(separator: ", "))\n", attributes: label)) }
        if !model.cc.isEmpty { printable.append(NSAttributedString(string: "Cc: \(model.cc.map(\.formatted).joined(separator: ", "))\n", attributes: label)) }
        printable.append(NSAttributedString(string: "\n"))
        printable.append(model.body)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(printable)
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: page)
        operation.jobTitle = model.subject.isEmpty ? "New Message" : model.subject
        if let window = textView?.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func setSize(_ size: CGFloat) {
        applying({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? self.baseFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: subrange)
            }
        }, typing: { attributes in attributes[.font] = NSFontManager.shared.convert(attributes[.font] as? NSFont ?? baseFont, toSize: size) })
    }

    func clearFormatting() {
        let plain: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.textColor]
        applying({ storage, range in storage.setAttributes(plain, range: range) }, typing: { attributes in attributes = plain })
    }

    /// Makes the chosen paragraphs a bulleted or numbered list, or takes them out of one.
    func toggleList(ordered: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let range = string.paragraphRange(for: textView.selectedRange())
        let existing = (range.location < storage.length ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil)?.textLists ?? []
        let removing = !existing.isEmpty
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in paragraphs.append(paragraph) }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: range.location, length: 0)] }
        let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for (number, paragraph) in paragraphs.enumerated().reversed() {
            let style = NSMutableParagraphStyle()
            let text = string.substring(with: paragraph)
            if removing {
                if let marker = text.range(of: "^\\t[^\\t]*\\t", options: .regularExpression) {
                    let length = text.utf16.distance(from: text.startIndex, to: marker.upperBound)
                    storage.replaceCharacters(in: NSRange(location: paragraph.location, length: length), with: "")
                }
                let reset = NSRange(location: paragraph.location, length: max(0, (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0)).length))
                storage.addAttribute(.paragraphStyle, value: style, range: reset)
            } else {
                style.textLists = [list]
                style.headIndent = 28
                style.firstLineHeadIndent = 0
                style.tabStops = [NSTextTab(textAlignment: .left, location: 10), NSTextTab(textAlignment: .left, location: 28)]
                let marker = ordered ? "\t\(number + 1).\t" : "\t•\t"
                storage.insert(NSAttributedString(string: marker, attributes: textView.typingAttributes), at: paragraph.location)
                let styled = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
                storage.addAttribute(.paragraphStyle, value: style, range: styled)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }

    /// Asks for a web address and links the chosen text to it (or inserts the address as a link).
    func insertLink() {
        guard let textView else { return }
        let alert = NSAlert()
        alert.messageText = "Link to"
        alert.informativeText = "Type or paste a web address or an email address."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var address = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if address.contains("@"), !address.contains("://"), !address.hasPrefix("mailto:") { address = "mailto:" + address }
        if !address.contains(":") { address = "https://" + address }
        guard let url = URL(string: address) else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes[.link] = url
            textView.insertText(NSAttributedString(string: field.stringValue, attributes: attributes), replacementRange: range)
        } else if textView.shouldChangeText(in: range, replacementString: nil) {
            textView.textStorage?.addAttribute(.link, value: url, range: range)
            textView.didChangeText()
        }
    }

    func showEmoji() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(textView)
    }
}

/// The text view messages are written in.
struct RichTextEditor: NSViewRepresentable {
    let model: ComposeModel
    let controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(model: model, controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposeTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = UserDefaults.standard.object(forKey: "ComposeSpellCheck") as? Bool ?? true
        textView.importsGraphics = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Message")
        textView.textStorage?.setAttributedString(model.body)
        context.coordinator.revision = model.bodyRevision
        controller.textView = textView
        RemotePictures.load(in: textView)
        if let composeView = textView as? ComposeTextView {
            composeView.controller = controller
            composeView.onSend = { [weak model] in model?.send() }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.revision != model.bodyRevision {
            context.coordinator.revision = model.bodyRevision
            textView.textStorage?.setAttributedString(model.body)
        }
        controller.textView = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ComposeModel
        let controller: RichTextController
        var revision = 0

        init(model: ComposeModel, controller: RichTextController) {
            self.model = model
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.body = NSAttributedString(attributedString: textView.attributedString())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionChanged()
        }
    }
}

/// ⌘B, ⌘I, ⌘U and ⌘K format the text, and ⌘Return sends.
final class ComposeTextView: NSTextView {
    weak var controller: RichTextController?
    var onSend: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": controller?.toggleTrait(.boldFontMask)
        case "i": controller?.toggleTrait(.italicFontMask)
        case "u": controller?.toggleAttribute(.underlineStyle)
        case "k": controller?.insertLink()
        case "\r": onSend?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
