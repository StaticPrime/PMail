import AppKit
import PMailKit
import SwiftUI

/// Contacts: the sidebar with Create contact and the groups, and the list or one person's page.
struct ContactsScreen: View {
    let app: AppModel
    let session: AccountSession
    let model: ContactsViewModel

    var body: some View {
        HStack(spacing: 0) {
            ContactsSidebar(app: app, model: model)
            Panel {
                VStack(spacing: 0) {
                    if model.needsSignIn {
                        Banner(text: "\(session.account.email) needs to be signed in again.", symbol: "person.crop.circle.badge.exclamationmark",
                               actionTitle: "Sign In…") { app.sheet = .addAccount(session.account.kind) }
                    }
                    if let contact = model.contact(model.openContactID) {
                        ContactPage(app: app, session: session, model: model, contact: contact)
                    } else {
                        ContactsList(app: app, model: model)
                    }
                }
            }
        }
    }
}

private struct ContactsSidebar: View {
    let app: AppModel
    let model: ContactsViewModel

    var body: some View {
        let expanded = app.isSidebarExpanded
        VStack(alignment: .leading, spacing: 0) {
            BigActionButton(title: "Create contact", symbol: "person.badge.plus", collapsed: !expanded) {
                app.sheet = .contactEditor(Contact(id: "new-\(UUID().uuidString)", labels: labelForNew))
            }
            .padding(.leading, 8)
            .padding(.bottom, 16)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        row("Contacts", "person.crop.circle", .contacts)
                        if !model.otherContacts.isEmpty { row("Other contacts", "person.crop.circle.badge.clock", .other) }
                        if !model.labels.isEmpty {
                            Text("Labels").font(.pm(14, .medium)).foregroundStyle(Theme.textPrimary).padding(.leading, 26).padding(.top, 18).padding(.bottom, 6)
                            ForEach(model.labels, id: \.self) { label in row(label, "tag", .label(label)) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .frame(width: expanded ? 256 : 80, alignment: .leading)
    }

    private var labelForNew: [String] {
        if case let .label(name) = model.section { return [name] }
        return []
    }

    private func row(_ title: String, _ symbol: String, _ section: ContactsViewModel.Section) -> some View {
        SidebarRow(title: title, symbol: symbol, isSelected: model.section == section && model.openContactID == nil,
                   trailing: { Text("\(model.count(in: section))") }) {
            model.section = section
            model.openContactID = nil
        }
    }
}

/// The table of contacts: name, email, phone, job and company, and labels.
private struct ContactsList: View {
    let app: AppModel
    let model: ContactsViewModel

    var body: some View {
        let contacts = model.contacts(in: model.section, matching: app.searchText)
        let starred = model.section == .contacts ? contacts.filter(\.isStarred) : []
        let rest = model.section == .contacts ? contacts.filter { !$0.isStarred } : contacts
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.pm(22)).foregroundStyle(Theme.textPrimary)
                Text("(\(contacts.count))").font(.pm(16)).foregroundStyle(Theme.textSecondary)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { model.reload() }
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
            if let error = model.error, contacts.isEmpty {
                ErrorState(text: error) { model.reload() }
            } else if contacts.isEmpty, model.loaded {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.2").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textTertiary)
                    Text(app.searchText.isEmpty ? "No contacts yet." : "No contacts matched your search.").font(.pm(14)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                header
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !starred.isEmpty {
                            sectionTitle("Starred contacts (\(starred.count))")
                            ForEach(starred) { contact in ContactRow(app: app, model: model, contact: contact) }
                        }
                        if !starred.isEmpty, !rest.isEmpty { sectionTitle("Contacts (\(rest.count))") }
                        ForEach(rest) { contact in ContactRow(app: app, model: model, contact: contact) }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var title: String {
        switch model.section {
        case .contacts: "Contacts"
        case .other: "Other contacts"
        case let .label(name): name
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Name").frame(width: 260, alignment: .leading).padding(.leading, 64)
            Text("Email").frame(maxWidth: .infinity, alignment: .leading)
            Text("Phone number").frame(width: 160, alignment: .leading)
            Text("Job title & company").frame(maxWidth: .infinity, alignment: .leading)
            Text("Labels").frame(width: 160, alignment: .leading)
        }
        .font(.pm(12, .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.trailing, 24)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.pm(11, .medium)).foregroundStyle(Theme.textSecondary).padding(.leading, 24).padding(.top, 16).padding(.bottom, 6)
    }
}

private struct ContactRow: View {
    let app: AppModel
    let model: ContactsViewModel
    let contact: Contact
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                Avatar(name: contact.displayName, email: contact.primaryEmail ?? "", size: 34, imageData: contact.photoData)
                Text(contact.displayName.isEmpty ? "(no name)" : contact.displayName).font(.pm(13.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            .frame(width: 284, alignment: .leading)
            .padding(.leading, 16)
            Text(contact.primaryEmail ?? "").font(.pm(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(contact.phones.first?.value ?? "").font(.pm(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(width: 160, alignment: .leading)
            Text(contact.jobAndCompany).font(.pm(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                if hovering, contact.kind == .contact {
                    HStack(spacing: 0) {
                        IconButton(symbol: contact.isStarred ? "star.fill" : "star", help: contact.isStarred ? "Unstar" : "Star", size: 30, iconSize: 14,
                                   tint: contact.isStarred ? Theme.star : Theme.icon) { model.toggleStar(contact) }
                        IconButton(symbol: "pencil", help: "Edit contact", size: 30, iconSize: 14) { app.sheet = .contactEditor(contact) }
                        IconButton(symbol: "trash", help: "Delete contact", size: 30, iconSize: 14) { confirmDelete() }
                    }
                } else {
                    HStack(spacing: 4) {
                        ForEach(contact.labels.prefix(2), id: \.self) { Chip(text: $0) }
                    }
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .padding(.trailing, 24)
        .frame(height: 52)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.openContactID = contact.id }
        .onHover { hovering = $0 }
        .contextMenu {
            if let email = contact.primaryEmail { Button("Send email") { app.compose(to: [MailAddress(name: contact.displayName, email: email)]) } }
            if contact.kind == .contact {
                Button("Edit") { app.sheet = .contactEditor(contact) }
                Button(contact.isStarred ? "Unstar" : "Star") { model.toggleStar(contact) }
                Divider()
                Button("Delete") { confirmDelete() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(contact.displayName.isEmpty ? "this contact" : contact.displayName)?"
        alert.informativeText = "The contact is deleted from your account everywhere it’s used."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.delete(contact) }
    }
}

/// One person's page: a big picture, their name and job, buttons to email, invite, call or video call them, and
/// their details.
struct ContactPage: View {
    let app: AppModel
    let session: AccountSession
    let model: ContactsViewModel
    let contact: Contact

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                IconButton(symbol: "arrow.left", help: "Back to contacts") { model.openContactID = nil }
                Spacer()
                if contact.kind == .contact {
                    IconButton(symbol: contact.isStarred ? "star.fill" : "star", help: contact.isStarred ? "Unstar" : "Star",
                               tint: contact.isStarred ? Theme.star : Theme.icon) { model.toggleStar(contact) }
                    FilledPillButton(title: "Edit") { app.sheet = .contactEditor(contact) }
                        .padding(.leading, 6)
                    Menu {
                        Button("Delete", role: .destructive) { model.delete(contact) }
                    } label: {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.icon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 28) {
                        Avatar(name: contact.displayName, email: contact.primaryEmail ?? "", size: 156, imageData: contact.photoData)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(contact.displayName.isEmpty ? "(no name)" : contact.displayName)
                                .font(.pm(28))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            if !contact.jobAndCompany.isEmpty {
                                Text(contact.jobAndCompany).font(.pm(14)).foregroundStyle(Theme.textSecondary)
                            }
                            if !contact.labels.isEmpty {
                                HStack(spacing: 6) { ForEach(contact.labels, id: \.self) { Chip(text: $0) } }
                            }
                        }
                    }
                    HStack(spacing: 28) {
                        action("Email", "envelope", enabled: contact.primaryEmail != nil) {
                            if let email = contact.primaryEmail { app.compose(to: [MailAddress(name: contact.displayName, email: email)]) }
                        }
                        action("Event", "calendar.badge.plus", enabled: contact.primaryEmail != nil) {
                            let guest = contact.mailAddresses.first.map { [$0] } ?? []
                            if let draft = session.calendar.newDraft(guests: guest) {
                                app.show(.calendar)
                                app.sheet = .eventEditor(draft)
                            }
                        }
                        action("Call", "phone", enabled: contact.phones.first != nil) {
                            if let phone = contact.phones.first?.value, let url = URL(string: "tel:" + phone.filter { "+0123456789".contains($0) }) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        action("Video", "video", enabled: contact.primaryEmail != nil || contact.phones.first != nil) {
                            let handle = contact.primaryEmail ?? contact.phones.first?.value.filter { "+0123456789".contains($0) } ?? ""
                            if let url = URL(string: "facetime://" + handle) { NSWorkspace.shared.open(url) }
                        }
                    }
                    detailsCard
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 16)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: perform) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.onSelection)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.selection))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            Text(title).font(.pm(12)).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contact details").font(.pm(15, .medium)).foregroundStyle(Theme.textPrimary)
            ForEach(contact.emails, id: \.self) { email in
                detail("envelope", email.value, label: email.label) {
                    app.compose(to: [MailAddress(name: contact.displayName, email: email.value)])
                }
            }
            ForEach(contact.phones, id: \.self) { phone in detail("phone", phone.value, label: phone.label) }
            ForEach(contact.addresses.filter { !$0.isEmpty }, id: \.self) { address in detail("mappin.and.ellipse", address.formatted, label: address.label) }
            ForEach(contact.urls, id: \.self) { url in
                detail("link", url.value, label: url.label) { if let link = URL(string: url.value) { NSWorkspace.shared.open(link) } }
            }
            if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
                detail("gift", birthdayText(month: month, day: day, year: birthday.year), label: "")
            }
            if !contact.notes.isEmpty { detail("note.text", contact.notes, label: "") }
            if contact.emails.isEmpty && contact.phones.isEmpty && contact.addresses.allSatisfy(\.isEmpty) && contact.notes.isEmpty {
                Text("No details yet.").font(.pm(13)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.canvas))
    }

    private func detail(_ symbol: String, _ value: String, label: String, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.icon).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                if let action {
                    Button(value, action: action).buttonStyle(.link).font(.pm(13.5))
                } else {
                    Text(value).font(.pm(13.5)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                }
                if !label.isEmpty { Text(label.capitalized).font(.pm(11.5)).foregroundStyle(Theme.textSecondary) }
            }
        }
    }

    private func birthdayText(month: Int, day: Int, year: Int?) -> String {
        var components = DateComponents(year: year ?? 2000, month: month, day: day)
        components.calendar = Calendar.current
        guard let date = components.date else { return "\(month)/\(day)" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(year == nil ? "MMMMd" : "MMMMdy")
        return formatter.string(from: date)
    }
}
