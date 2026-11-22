import PMailKit
import SwiftUI

/// Makes or changes a label: its name and its color.
struct LabelEditorView: View {
    let mail: MailViewModel
    let editing: MailViewModel.LabelEditing
    @State private var name: String
    @State private var colorHex: String?
    @Environment(\.dismiss) private var dismiss

    /// The colors offered, a dozen that read on light and dark backgrounds.
    static let palette = ["#D93025", "#E8710A", "#F9AB00", "#188038", "#12A4AF", "#1A73E8",
                          "#4B53BC", "#A142F4", "#E52592", "#8D6E63", "#5F6368", "#202124"]

    init(mail: MailViewModel, editing: MailViewModel.LabelEditing) {
        self.mail = mail
        self.editing = editing
        _name = State(initialValue: editing.label?.name ?? "")
        _colorHex = State(initialValue: editing.label?.colorHex)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing.label == nil ? "New label" : "Edit label").font(.pm(18, .medium))
            TextField("Label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Color").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                swatch(nil)
                ForEach(Self.palette, id: \.self) { swatch($0) }
            }
            if !editing.applyTo.isEmpty {
                Text(editing.applyTo.count == 1 ? "It goes on the conversation you chose." : "It goes on the \(editing.applyTo.count) conversations you chose.")
                    .font(.pm(12)).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing.label == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.surface)
    }

    private func swatch(_ hex: String?) -> some View {
        let selected = hex == colorHex
        return Button { colorHex = hex } label: {
            ZStack {
                Circle().fill(hex.map { Theme.color(hexString: $0) ?? .gray } ?? Theme.surfaceRaised)
                    .overlay(Circle().stroke(Theme.divider, lineWidth: hex == nil ? 1 : 0))
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(hex == nil ? Theme.textPrimary : .white)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "No color" : hex!)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        mail.saveLabel(editing, name: trimmed, colorHex: colorHex)
        dismiss()
    }
}
