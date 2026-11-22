import AppKit
import PMailKit
import SwiftUI

/// Settings ▸ Junk Mail ▸ Advanced: the rule for "Do what’s set up under Advanced". A description, whether all or any
/// of its conditions must be met, the conditions and the actions, each row with − and + to take it away or add one after it.
struct RuleEditor: View {
    @State var rule: MailRule
    let accounts: [Account]
    let onSave: (MailRule) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The conditions in groups, as their menu shows them.
    static let fieldGroups: [[RuleCondition.Field]] = [
        [.from, .to, .cc, .subject], [.anyRecipient], [.addressedToFullName, .notAddressedToFullName], [.dateSent, .dateReceived], [.account],
        [.senderInContacts, .senderNotInContacts, .senderInPreviousRecipients, .senderNotInPreviousRecipients, .senderIsStarred, .senderHasLabel,
         .senderLacksLabel],
        [.content, .isJunk, .isSigned, .isEncrypted, .priorityHigh, .priorityNormal, .priorityLow], [.attachmentName], [.attachmentType, .everyMessage],
        [.header],
    ]

    static let actionGroups: [[RuleAction.Kind]] = [
        [.moveToJunk, .markJunk, .moveToTrash, .archive, .moveToFolder], [.addLabel, .markRead, .star], [.notify, .playSound, .bounceDockIcon],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Description:")
                TextField("Description", text: $rule.description).labelsHidden()
            }
            HStack(spacing: 6) {
                Text("If")
                Picker("All or any", selection: $rule.matchesAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following conditions are met:")
            }
            rows {
                ForEach($rule.conditions) { $condition in
                    ConditionRow(condition: $condition, accounts: accounts, canRemove: rule.conditions.count > 1,
                                 add: { add(after: condition.id) }, remove: { rule.conditions.removeAll { $0.id == condition.id } })
                }
            }
            Text("Do the following:")
            rows {
                ForEach($rule.actions) { $action in
                    ActionRow(action: $action, canRemove: rule.actions.count > 1,
                              add: { addAction(after: action.id) }, remove: { rule.actions.removeAll { $0.id == action.id } })
                }
            }
            HStack {
                Text("Conditions about a message’s text, headers or attachments load the whole message first.")
                    .font(.pm(11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
    }

    private func rows(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 6) { content() }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private func add(after id: UUID) {
        let index = (rule.conditions.firstIndex { $0.id == id } ?? rule.conditions.count - 1) + 1
        rule.conditions.insert(RuleCondition(.from), at: index)
    }

    private func addAction(after id: UUID) {
        let index = (rule.actions.firstIndex { $0.id == id } ?? rule.actions.count - 1) + 1
        rule.actions.insert(RuleAction(.markRead), at: index)
    }
}

private struct ConditionRow: View {
    @Binding var condition: RuleCondition
    let accounts: [Account]
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Condition", selection: Binding(get: { condition.field }, set: change)) {
                ForEach(Array(RuleEditor.fieldGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { field in Text(field.name).tag(field) }
                }
            }
            .labelsHidden()
            .fixedSize()
            parameters
            Spacer(minLength: 4)
            RowButtons(canRemove: canRemove, add: add, remove: remove)
        }
    }

    @ViewBuilder private var parameters: some View {
        let field = condition.field
        if field.takesText {
            if field == .header {
                TextField("Header name", text: $condition.header).frame(width: 120)
            }
            Picker("Comparison", selection: $condition.comparison) {
                ForEach(RuleCondition.Comparison.forText, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Text", text: $condition.value)
        } else if field.takesDays {
            Picker("Comparison", selection: $condition.comparison) {
                ForEach(RuleCondition.Comparison.forDays, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Days", text: $condition.value).frame(width: 50)
            Text("days old")
        } else if field == .account {
            Picker("Account", selection: $condition.value) {
                ForEach(accounts) { Text($0.email).tag($0.email.lowercased()) }
            }
            .labelsHidden()
            .fixedSize()
        } else if field.takesLabel {
            TextField("Contact label", text: $condition.value)
        } else if field == .attachmentType {
            Text("is")
            Picker("Kind", selection: $condition.value) {
                ForEach(AttachmentKind.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// A new condition starts with what it compares filled in sensibly.
    private func change(_ field: RuleCondition.Field) {
        condition.field = field
        if field.takesText, !RuleCondition.Comparison.forText.contains(condition.comparison) { condition.comparison = .contains }
        if field.takesDays {
            condition.comparison = .moreThanDaysOld
            if Int(condition.value) == nil { condition.value = "7" }
        }
        if field == .account { condition.value = accounts.first?.email.lowercased() ?? "" }
        if field == .attachmentType { condition.value = AttachmentKind.image.rawValue }
    }
}

private struct ActionRow: View {
    @Binding var action: RuleAction
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Action", selection: Binding(get: { action.kind }, set: change)) {
                ForEach(Array(RuleEditor.actionGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { kind in Text(kind.name).tag(kind) }
                }
            }
            .labelsHidden()
            .fixedSize()
            if action.kind.takesName {
                TextField(action.kind == .moveToFolder ? "Folder name" : "Label name", text: $action.value)
            } else if action.kind.takesSound {
                Picker("Sound", selection: Binding(get: { action.value }, set: { sound in
                    action.value = sound
                    NSSound(named: NSSound.Name(sound))?.play()
                })) {
                    ForEach(RuleAction.sounds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 4)
            RowButtons(canRemove: canRemove, add: add, remove: remove)
        }
    }

    private func change(_ kind: RuleAction.Kind) {
        action.kind = kind
        if kind.takesSound, !RuleAction.sounds.contains(action.value) { action.value = "Glass" }
        if !kind.takesName, !kind.takesSound { action.value = "" }
    }
}

/// − and + beside a row.
private struct RowButtons: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: remove) { Image(systemName: "minus").frame(width: 14, height: 14) }
                .disabled(!canRemove)
                .help("Remove")
            Button(action: add) { Image(systemName: "plus").frame(width: 14, height: 14) }
                .help("Add another after this one")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
