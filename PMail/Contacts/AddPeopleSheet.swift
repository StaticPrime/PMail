import PMailKit
import SwiftUI

/// "Add to Contacts?" for several people written to at once: each with a box to tick and a name to fix up, added
/// together.
struct AddPeopleSheet: View {
    struct Row: Identifiable {
        let id = UUID()
        let email: String
        var givenName: String
        var familyName: String
        var adds = true
    }

    let model: ContactsViewModel
    @State private var rows: [Row]
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: ContactsViewModel, people: [MailAddress]) {
        self.model = model
        _rows = State(initialValue: people.map { person in
            let name = PersonName.split(person.name ?? "")
            return Row(email: person.email, givenName: name.given, familyName: name.family)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Contacts").font(.pm(20)).foregroundStyle(Theme.textPrimary)
            Text("People you wrote to who aren’t in your contacts yet.").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            Toggle("Add \(row.email)", isOn: $row.adds).toggleStyle(.checkbox).labelsHidden()
                            TextField("First name", text: $row.givenName).textFieldStyle(.roundedBorder).frame(width: 130)
                            TextField("Last name", text: $row.familyName).textFieldStyle(.roundedBorder).frame(width: 130)
                            Text(row.email).font(.pm(12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .opacity(row.adds ? 1 : 0.55)
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack(spacing: 12) {
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                FilledPillButton(title: isSaving ? "Adding…" : "Add to Contacts", isDisabled: isSaving || !rows.contains(where: \.adds)) { add() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.pm(13))
        .padding(24)
        .frame(width: 580)
        .background(Theme.surface)
    }

    private func add() {
        isSaving = true
        let chosen = rows.filter(\.adds)
        Task {
            var added = 0
            for row in chosen {
                let contact = Contact(id: "new-" + UUID().uuidString, givenName: row.givenName.trimmingCharacters(in: .whitespaces),
                                      familyName: row.familyName.trimmingCharacters(in: .whitespaces),
                                      emails: [LabeledValue(label: "other", value: row.email)])
                if await model.save(contact, isNew: true, quietly: true) != nil { added += 1 }
            }
            model.app?.show(added == 1 ? "Added 1 person to your contacts." : "Added \(added) people to your contacts.")
            dismiss()
        }
    }
}
