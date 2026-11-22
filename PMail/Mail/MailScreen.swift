import AppKit
import PMailKit
import SwiftUI

/// Mail: the sidebar with Compose and the folders, and the list or the open conversation on its panel.
struct MailScreen: View {
    let app: AppModel
    let session: AccountSession
    let mail: MailViewModel

    var body: some View {
        HStack(spacing: 0) {
            MailSidebar(app: app, mail: mail)
            Panel {
                VStack(spacing: 0) {
                    if mail.needsSignIn {
                        Banner(text: "\(session.account.email) needs to be signed in again.", symbol: "person.crop.circle.badge.exclamationmark",
                               actionTitle: "Sign In…") { app.sheet = .addAccount(session.account.kind) }
                    } else if mail.isOffline {
                        OfflineBanner()
                    }
                    if mail.openConversation != nil {
                        ConversationView(app: app, session: session, mail: mail)
                    } else {
                        MessageList(app: app, mail: mail)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { mail.labelEditor }, set: { mail.labelEditor = $0 })) { editing in
            LabelEditorView(mail: mail, editing: editing)
        }
        .confirmationDialog("Report spam", isPresented: Binding(get: { mail.spamReport != nil }, set: { if !$0 { mail.spamReport = nil } }),
                            presenting: mail.spamReport) { report in
            Button("Report Spam") { mail.finishSpamReport(report, block: .nobody) }
            Button(report.addresses.count == 1 ? "Report and Block \(report.addresses[0])"
                                               : "Report and Block These \(report.addresses.count) Senders") {
                mail.finishSpamReport(report, block: .senders)
            }
            if !report.domains.isEmpty {
                Button(report.domains.count == 1 ? "Report and Block Everything from \(report.domains[0])"
                                                 : "Report and Block Everything from These \(report.domains.count) Domains") {
                    mail.finishSpamReport(report, block: .domains)
                }
            }
            Button("Cancel", role: .cancel) { mail.spamReport = nil }
        } message: { _ in
            Text("Mail from blocked senders goes to \(mail.spamFolderName) as it arrives. You can unblock them in Settings.")
        }
    }
}

/// Compose, then the folders and labels.
struct MailSidebar: View {
    let app: AppModel
    let mail: MailViewModel
    @State private var labelToDelete: MailFolder?

    var body: some View {
        let expanded = app.isSidebarExpanded
        VStack(alignment: .leading, spacing: 0) {
            BigActionButton(title: "Compose", symbol: "pencil", collapsed: !expanded) { app.compose() }
                .padding(.leading, expanded ? 8 : 8)
                .padding(.bottom, 16)
                .help("Compose a new message (C)")
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mail.primaryFolders) { folder in folderRow(folder) }
                        if !mail.moreFolders.isEmpty || mail.showsAllMail {
                            SidebarRow(title: mail.showsMoreFolders ? "Less" : "More",
                                       symbol: mail.showsMoreFolders ? "chevron.up" : "chevron.down", isSelected: false) {
                                withAnimation(.easeInOut(duration: 0.15)) { mail.showsMoreFolders.toggle() }
                            }
                            if mail.showsMoreFolders {
                                if mail.showsAllMail {
                                    SidebarRow(title: "All Mail", symbol: "tray.2", isSelected: mail.selectedFolderID == nil && mail.activeSearch == nil) {
                                        mail.select(folderID: nil)
                                    }
                                }
                                ForEach(mail.moreFolders) { folder in folderRow(folder) }
                            }
                        }
                        if !mail.userFolders.isEmpty {
                            sectionHeader("Folders")
                            ForEach(mail.userFolders, id: \.folder.id) { item in
                                folderRow(item.folder, depth: item.depth)
                            }
                        }
                        if mail.hasLabels {
                            sectionHeader("Labels") {
                                if mail.capabilities.canEditLabels {
                                    IconButton(symbol: "plus", help: "New label", size: 28, iconSize: 12) { mail.newLabel() }
                                }
                            }
                            ForEach(mail.labels, id: \.folder.id) { item in
                                folderRow(item.folder, depth: item.depth)
                                    .contextMenu {
                                        if mail.capabilities.canEditLabels {
                                            Button("Edit Label…") { mail.editLabel(item.folder) }
                                            Button("Delete Label…") { labelToDelete = item.folder }
                                        }
                                    }
                            }
                        }
                        if !mail.foldersLoaded {
                            ProgressView().controlSize(.small).padding(.leading, 30).padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
            } else {
                VStack(spacing: 4) {
                    ForEach(mail.primaryFolders) { folder in
                        IconButton(symbol: mail.symbol(for: folder), help: mail.displayName(for: folder), size: 40, iconSize: 16,
                                   tint: mail.selectedFolderID == folder.id ? Theme.onSelection : Theme.icon) {
                            mail.select(folderID: folder.id)
                        }
                        .background(Circle().fill(mail.selectedFolderID == folder.id ? Theme.selection : .clear))
                    }
                }
                .padding(.leading, 16)
            }
            Spacer(minLength: 0)
        }
        .frame(width: expanded ? 256 : 80, alignment: .leading)
        .confirmationDialog("Delete the label “\(labelToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { labelToDelete != nil }, set: { if !$0 { labelToDelete = nil } }),
                            presenting: labelToDelete) { label in
            Button("Delete Label", role: .destructive) { mail.deleteLabel(label) }
            Button("Cancel", role: .cancel) { labelToDelete = nil }
        } message: { _ in
            Text("Conversations with it keep everything else; only the label goes.")
        }
    }

    private func sectionHeader(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(title)
                .font(.pm(15, .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func folderRow(_ folder: MailFolder, depth: Int = 0) -> some View {
        let count = [.drafts, .scheduled, .outbox].contains(folder.role) ? (folder.totalCount ?? 0) : folder.unreadCount
        let selected = mail.selectedFolderID == folder.id && mail.activeSearch == nil
        // Counts only where they mean something: unread in the inbox, spam and labels, and how many drafts there are.
        let showsCount = count > 0 && [nil, .inbox, .drafts, .spam, .outbox, .scheduled].contains(folder.role)
        return SidebarRow(title: mail.displayName(for: folder), symbol: mail.symbol(for: folder), isSelected: selected,
                          isBold: showsCount && folder.role != .drafts, symbolColor: Theme.color(hexString: folder.colorHex),
                          trailing: {
                              if showsCount { Text(count.formatted()) }
                          }) {
            mail.select(folderID: folder.id)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .opacity(folder.isSelectable ? 1 : 0.6)
        .disabled(!folder.isSelectable)
        .dropDestination(for: String.self) { ids, _ in
            let conversations = mail.conversations.filter { ids.contains($0.id) }
            guard !conversations.isEmpty, folder.id != mail.selectedFolderID else { return false }
            let isLabel = folder.kind == .label && folder.role == nil || mail.capabilities.usesLabels && folder.role == nil
            mail.perform(isLabel ? .addLabel(folder.id) : .move(toFolderID: folder.id), on: conversations)
            return true
        }
    }
}
