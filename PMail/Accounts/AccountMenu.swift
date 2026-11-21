import AppKit
import PMailKit
import SwiftUI

/// The account switcher, from the picture at the top right: the account showing, the others to switch to, adding one
/// and the account's settings.
struct AccountMenu: View {
    let app: AppModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let current = app.current?.account {
                HStack {
                    Spacer()
                    Text(current.email).font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                }
                .overlay(alignment: .trailing) { IconButton(symbol: "xmark", help: "Close", size: 28, iconSize: 11, action: dismiss) }
                .padding(.bottom, 14)
                AccountAvatar(account: current, size: 80)
                Text("Hi, \(current.name.split(separator: " ").first.map(String.init) ?? current.email)!")
                    .font(.pm(22))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 10)
                HStack(spacing: 6) {
                    ProviderLogo(kind: current.kind, size: 14)
                    Text(current.kind == .other ? (current.incoming?.mailProtocol.displayName ?? "Mail") + " account" : "\(current.kind.displayName) account")
                        .font(.pm(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
                OutlinePillButton(title: "Account settings") {
                    dismiss()
                    app.sheet = .accountSettings(current.id)
                }
                .padding(.top, 14)
            }
            let others = app.accounts.accounts.filter { $0.id != app.accounts.currentID }
            VStack(spacing: 0) {
                ForEach(others) { account in
                    AccountRow(account: account, unread: app.sync?.unread(for: account.id) ?? 0) {
                        dismiss()
                        app.switchAccount(to: account.id)
                    }
                }
                MenuRow(symbol: "person.badge.plus", title: "Add another account") {
                    dismiss()
                    app.sheet = .addAccount(nil)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.top, 18)
            Text("PMail talks only to your mail providers. No ads, no tracking.")
                .font(.pm(11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 14)
        }
        .padding(18)
        .frame(width: 380)
        .background(Theme.canvas)
    }
}

private struct AccountRow: View {
    let account: Account
    var unread = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AccountAvatar(account: account, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name.isEmpty ? account.email : account.name).font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                    Text(account.email).font(.pm(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if unread > 0 {
                    Text(unread > 999 ? "999+" : "\(unread)").font(.pm(12, .semibold)).foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("\(unread) unread")
                }
                ProviderLogo(kind: account.kind, size: 16)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Switch to \(account.email)")
    }
}

private struct MenuRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.icon).frame(width: 32)
                Text(title).font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An account's settings: the name on sent mail, the signature, its servers, signing in again and removing it.
struct AccountSettingsView: View {
    let app: AppModel
    @State var account: Account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AccountAvatar(account: account, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email).font(.pm(16, .medium))
                    HStack(spacing: 5) {
                        ProviderLogo(kind: account.kind, size: 13)
                        Text(account.kind == .other ? "Mail account" : "\(account.kind.displayName) account").font(.pm(12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Form {
                Section("Sending") {
                    TextField("Name on sent mail", text: $account.name)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signature").font(.pm(12)).foregroundStyle(Theme.textSecondary)
                        TextEditor(text: $account.signature).font(.pm(13)).frame(height: 90)
                    }
                }
                if let incoming = account.incoming {
                    Section("Servers") {
                        LabeledContent("Incoming (\(incoming.mailProtocol.displayName))", value: "\(incoming.host):\(incoming.port), \(incoming.security.displayName)")
                        if let outgoing = account.outgoing {
                            LabeledContent("Outgoing (SMTP)", value: "\(outgoing.host):\(outgoing.port), \(outgoing.security.displayName)")
                        }
                        if let calendar = account.calendarServer { LabeledContent("Calendar", value: calendar.host ?? calendar.absoluteString) }
                        if let contacts = account.contactsServer { LabeledContent("Contacts", value: contacts.host ?? contacts.absoluteString) }
                    }
                }
                Section {
                    Button("Sign In Again…") {
                        dismiss()
                        app.sheet = .addAccount(account.kind)
                    }
                    Button("Remove This Account…", role: .destructive) { confirmRemove() }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                FilledPillButton(title: "Save") {
                    app.accounts.update(account)
                    app.show("Account settings saved.")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: account.incoming == nil ? 480 : 600)
        .background(Theme.surface)
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email) from PMail?"
        alert.informativeText = "Its mail, calendars and contacts stay on the server; PMail just stops showing them and forgets its password or sign-in."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dismiss()
        app.removeAccount(account.id)
    }
}
