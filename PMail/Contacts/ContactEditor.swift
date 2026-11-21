import AppKit
import PMailKit
import SwiftUI

/// Making or changing a contact: names, company, email addresses, phone numbers, addresses, birthday, notes and
/// labels.
struct ContactEditor: View {
    let app: AppModel
    let model: ContactsViewModel
    @State var contact: Contact
    @State private var showsMoreNames = false
    @State private var isSaving = false
    @State private var newLabel = ""
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    init(app: AppModel, model: ContactsViewModel, contact: Contact) {
        self.app = app
        self.model = model
        isNew = contact.id.hasPrefix("new-") || model.contact(contact.id) == nil
        var editable = contact
        if editable.emails.isEmpty { editable.emails = [LabeledValue(label: "home", value: "")] }
        if editable.phones.isEmpty { editable.phones = [LabeledValue(label: "mobile", value: "")] }
        _contact = State(initialValue: editable)
        _hasBirthday = State(initialValue: contact.birthday?.month != nil)
        let components = contact.birthday ?? DateComponents(year: 1990, month: 1, day: 1)
        _birthday = State(initialValue: Calendar.current.date(from: DateComponents(year: components.year ?? 2000, month: components.month ?? 1,
                                                                                   day: components.day ?? 1)) ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconButton(symbol: "xmark", help: "Close without saving") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Text(isNew ? "Create contact" : "Edit contact").font(.pm(18)).foregroundStyle(Theme.textPrimary)
                Spacer()
                FilledPillButton(title: isSaving ? "Saving…" : "Save", isDisabled: isSaving || cleaned.isEmpty) { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            Divider().overlay(Theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Avatar(name: contact.displayName, email: contact.emails.first?.value ?? "", size: 110, imageData: contact.photoData)
                        Spacer()
                    }
                    section("person") {
                        if showsMoreNames { TextField("Prefix", text: $contact.prefix) }
                        TextField("First name", text: $contact.givenName)
                        if showsMoreNames { TextField("Middle name", text: $contact.middleName) }
                        TextField("Last name", text: $contact.familyName)
                        if showsMoreNames {
                            TextField("Suffix", text: $contact.suffix)
                            TextField("Nickname", text: $contact.nickname)
                        }
                        Button(showsMoreNames ? "Show less" : "Show more") { showsMoreNames.toggle() }.buttonStyle(.link).font(.pm(12.5))
                    }
                    section("building.2") {
                        TextField("Company", text: $contact.company)
                        TextField("Job title", text: $contact.jobTitle)
                        TextField("Department", text: $contact.department)
                    }
                    section("envelope") {
                        labeledList($contact.emails, placeholder: "Email", labels: ["home", "work", "other"], defaultLabel: "home")
                    }
                    section("phone") {
                        labeledList($contact.phones, placeholder: "Phone", labels: ["mobile", "home", "work", "main", "other"], defaultLabel: "mobile")
                    }
                    section("mappin.and.ellipse") {
                        ForEach(contact.addresses.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Street address", text: $contact.addresses[index].street)
                                HStack {
                                    TextField("City", text: $contact.addresses[index].city)
                                    TextField("State", text: $contact.addresses[index].region).frame(width: 90)
                                    TextField("ZIP", text: $contact.addresses[index].postalCode).frame(width: 90)
                                }
                                HStack {
                                    TextField("Country", text: $contact.addresses[index].country)
                                    Picker("Label", selection: $contact.addresses[index].label) {
                                        ForEach(["home", "work", "other"], id: \.self) { Text($0.capitalized).tag($0) }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)
                                    IconButton(symbol: "minus.circle", help: "Remove address", size: 26, iconSize: 13) { contact.addresses.remove(at: index) }
                                }
                            }
                        }
                        Button("Add address") { contact.addresses.append(PostalAddress(label: "home")) }.buttonStyle(.link).font(.pm(12.5))
                    }
                    section("gift") {
                        Toggle("Birthday", isOn: $hasBirthday).toggleStyle(.checkbox)
                        if hasBirthday { DatePicker("Birthday", selection: $birthday, displayedComponents: .date).labelsHidden() }
                    }
                    section("note.text") {
                        TextField("Notes", text: $contact.notes, axis: .vertical).lineLimit(3...8)
                    }
                    section("tag") {
                        HStack(spacing: 6) {
                            ForEach(contact.labels, id: \.self) { label in
                                Chip(text: label) { contact.labels.removeAll { $0 == label } }
                            }
                        }
                        HStack {
                            TextField("Add a label", text: $newLabel).onSubmit(addLabel)
                            Menu("Labels") {
                                ForEach(model.labels.filter { !contact.labels.contains($0) }, id: \.self) { label in
                                    Button(label) { contact.labels.append(label) }
                                }
                            }
                            .fixedSize()
                            .disabled(model.labels.allSatisfy { contact.labels.contains($0) })
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(24)
            }
        }
        .frame(width: 620, height: 700)
        .background(Theme.surface)
    }

    private func section(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.icon).frame(width: 22).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    private func labeledList(_ values: Binding<[LabeledValue]>, placeholder: String, labels: [String], defaultLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: values[index].value)
                    Picker("Label", selection: values[index].label) {
                        ForEach(Array(Set(labels + [values.wrappedValue[index].label]).filter { !$0.isEmpty }).sorted(), id: \.self) { label in
                            Text(label.capitalized).tag(label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    if values.wrappedValue.count > 1 {
                        IconButton(symbol: "minus.circle", help: "Remove", size: 26, iconSize: 13) { values.wrappedValue.remove(at: index) }
                    }
                }
            }
            Button("Add \(placeholder.lowercased())") { values.wrappedValue.append(LabeledValue(label: defaultLabel, value: "")) }
                .buttonStyle(.link).font(.pm(12.5))
        }
    }

    private func addLabel() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, !contact.labels.contains(label) { contact.labels.append(label) }
        newLabel = ""
    }

    /// The contact without empty rows, with the birthday filled in.
    private var cleaned: Contact {
        var result = contact
        result.emails = result.emails.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        result.phones = result.phones.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        result.addresses = result.addresses.filter { !$0.isEmpty }
        if hasBirthday {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: birthday)
            result.birthday = DateComponents(year: parts.year, month: parts.month, day: parts.day)
        } else {
            result.birthday = nil
        }
        return result
    }

    private func save() {
        isSaving = true
        let contact = cleaned
        Task {
            if let saved = await model.save(contact, isNew: isNew) {
                if isNew { model.openContactID = saved.id }
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
