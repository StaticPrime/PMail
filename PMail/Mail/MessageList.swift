import AppKit
import PMailKit
import SwiftUI

/// The list of conversations: the toolbar, the inbox tabs and a row per conversation, fifty to a page.
struct MessageList: View {
    let app: AppModel
    let mail: MailViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(app: app, mail: mail)
            if mail.selectedTabID != nil, mail.activeSearch == nil, mail.currentFolder?.role == .inbox, !mail.inboxTabs.isEmpty {
                InboxTabs(mail: mail)
            }
            Divider().overlay(Theme.divider)
            if let error = mail.listError, mail.conversations.isEmpty {
                ErrorState(text: error) { mail.refresh() }
            } else if mail.conversations.isEmpty, !mail.isLoadingList, mail.foldersLoaded {
                EmptyListState(mail: mail)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mail.conversations) { conversation in
                            MessageRow(app: app, mail: mail, conversation: conversation)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if mail.isLoadingList { ProgressView().controlSize(.small).padding(.top, 14) }
                }
            }
        }
    }
}

/// Select-all, refresh and more on the left; actions for ticked rows; the page and its arrows on the right.
private struct ListToolbar: View {
    let app: AppModel
    let mail: MailViewModel

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                CheckBox(isOn: !mail.checkedIDs.isEmpty && mail.checkedIDs.count == mail.conversations.count,
                         help: mail.checkedIDs.isEmpty ? "Select all" : "Select none") {
                    mail.check(mail.checkedIDs.isEmpty ? .all : .none)
                }
                Menu {
                    Button("All") { mail.check(.all) }
                    Button("None") { mail.check(.none) }
                    Button("Read") { mail.check(.read) }
                    Button("Unread") { mail.check(.unread) }
                    if mail.capabilities.canStar {
                        Button("Starred") { mail.check(.starred) }
                        Button("Unstarred") { mail.check(.unstarred) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .help("Select")
            }
            .padding(.leading, 8)
            if mail.checkedIDs.isEmpty {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { mail.refresh() }
                Menu {
                    Button("Mark all as read") { mail.perform(.markRead, on: mail.conversations) }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 36, height: 36)
                .help("More")
            } else {
                ConversationActions(app: app, mail: mail, targets: mail.checkedConversations)
            }
            Spacer()
            if !mail.rangeText.isEmpty {
                Text(mail.rangeText).font(.pm(12)).foregroundStyle(Theme.textSecondary).padding(.trailing, 4)
            }
            IconButton(symbol: "chevron.left", help: "Newer", isDisabled: !mail.canGoBack) { mail.previousPage() }
            IconButton(symbol: "chevron.right", help: "Older", isDisabled: !mail.canGoForward) { mail.nextPage() }
                .padding(.trailing, 8)
        }
        .frame(height: 48)
    }
}

/// Archive, spam, delete, read and move for the ticked rows or the open conversation.
struct ConversationActions: View {
    let app: AppModel
    let mail: MailViewModel
    let targets: [Conversation]

    var body: some View {
        let role = mail.currentFolder?.role
        HStack(spacing: 2) {
            if MailViewModel.isLocal(mail.selectedFolderID) {
                LocalFolderActions(mail: mail, targets: targets)
            } else {
                standardActions(role: role)
            }
        }
    }

    @ViewBuilder
    private func standardActions(role: FolderRole?) -> some View {
        HStack(spacing: 2) {
            if mail.capabilities.canArchive, role != .archive {
                IconButton(symbol: "archivebox", help: "Archive (E)") { mail.perform(.archive, on: targets) }
            }
            if role == .spam {
                IconButton(symbol: "exclamationmark.octagon", help: "Not spam") { mail.perform(.notSpam, on: targets) }
            } else {
                if mail.canReportSpam {
                    IconButton(symbol: "exclamationmark.octagon", help: "Report spam (!)") { mail.perform(.markSpam, on: targets) }
                }
            }
            if role == .trash || role == .spam {
                IconButton(symbol: "trash.slash", help: "Delete forever") { confirmDeleteForever() }
            } else {
                IconButton(symbol: "trash", help: "Delete (#)") { mail.perform(.trash, on: targets) }
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            let anyUnread = targets.contains(where: \.isUnread)
            IconButton(symbol: anyUnread ? "envelope.open" : "envelope.badge", help: anyUnread ? "Mark as read" : "Mark as unread") {
                mail.perform(anyUnread ? .markRead : .markUnread, on: targets)
                if !anyUnread, mail.openConversation != nil { mail.closeConversation() }
            }
            if mail.canSnooze {
                LaterPicker(help: "Snooze", heading: "Snooze until…", choices: { LaterTimes.snooze(now: AppClock.now()) }) { date in
                    mail.snooze(targets, until: date)
                } label: {
                    Image(systemName: "clock").foregroundStyle(Theme.icon).frame(width: 36, height: 36)
                }
                .frame(width: 36, height: 36)
            }
            if role == .trash || role == .archive || (role != .inbox && mail.capabilities.usesLabels && mail.selectedFolderID == nil) {
                IconButton(symbol: "tray.and.arrow.down", help: "Move to Inbox") { mail.perform(.moveToInbox, on: targets) }
            }
            if mail.capabilities.canMove {
                Menu {
                    ForEach(mail.moveTargets) { folder in
                        Button(mail.displayName(for: folder)) { mail.perform(.move(toFolderID: folder.id), on: targets) }
                    }
                } label: {
                    Image(systemName: "folder").foregroundStyle(Theme.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 36, height: 36)
                .help("Move to")
            }
            if mail.capabilities.usesLabels {
                Menu {
                    ForEach(mail.userFolders, id: \.folder.id) { item in
                        let has = targets.allSatisfy { $0.labelIDs.contains(item.folder.id) }
                        Button {
                            mail.perform(has ? .removeLabel(item.folder.id) : .addLabel(item.folder.id), on: targets)
                        } label: {
                            Label(item.folder.name, systemImage: has ? "checkmark.square" : "square")
                        }
                    }
                } label: {
                    Image(systemName: "tag").foregroundStyle(Theme.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 36, height: 36)
                .help("Labels")
            }
        }
    }

    private func confirmDeleteForever() {
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Delete this conversation forever?" : "Delete \(targets.count) conversations forever?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete Forever")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { mail.perform(.deleteForever, on: targets) }
    }
}

/// Primary, Promotions, Social… (or Focused and Other) across the top of the inbox.
private struct InboxTabs: View {
    let mail: MailViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(mail.inboxTabs) { tab in
                InboxTabButton(tab: tab, isSelected: mail.selectedTabID == tab.id) { mail.select(tabID: tab.id) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 52)
    }
}

private struct InboxTabButton: View {
    let tab: InboxTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: tab.symbol).font(.system(size: 16))
                Text(tab.name).font(.pm(13.5, isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: 240, maxHeight: .infinity)
            .background(hovering ? Theme.hover : .clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                        .fill(Theme.accent)
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One conversation: tick, star, who, subject and the start of the text, and when. Hovering shows quick actions.
struct MessageRow: View {
    let app: AppModel
    let mail: MailViewModel
    let conversation: Conversation
    @State private var hovering = false

    var body: some View {
        let checked = mail.checkedIDs.contains(conversation.id)
        let unread = conversation.isUnread
        let weight: Font.Weight = unread ? .bold : .regular
        HStack(spacing: 0) {
            CheckBox(isOn: checked, help: checked ? "Deselect" : "Select") { mail.toggleChecked(conversation.id) }
                .padding(.leading, 8)
            if mail.capabilities.canStar {
                Button {
                    mail.perform(conversation.isStarred ? .unstar : .star, on: [conversation])
                } label: {
                    Image(systemName: conversation.isStarred ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundStyle(conversation.isStarred ? Theme.star : Theme.textTertiary)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(conversation.isStarred ? "Starred" : "Not starred")
                .accessibilityLabel(conversation.isStarred ? "Remove star" : "Add star")
            }
            if mail.capabilities.canMarkImportant {
                Image(systemName: conversation.isImportant ? "chevron.right.2" : "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(conversation.isImportant ? Theme.important : Theme.textTertiary.opacity(0.35))
                    .frame(width: 22)
                    .help(conversation.isImportant ? "Important" : "Not important")
            }
            HStack(spacing: 4) {
                Text(senders)
                    .font(.pm(13.5, weight))
                    .lineLimit(1)
                if conversation.messageCount > 1 {
                    Text("\(conversation.messageCount)").font(.pm(11.5)).foregroundStyle(Theme.textTertiary)
                }
                if conversation.hasDraft {
                    Text("Draft").font(.pm(13.5)).foregroundStyle(Theme.danger)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 190, alignment: .leading)
            .padding(.leading, 8)
            HStack(spacing: 0) {
                if !labelChips.isEmpty {
                    ForEach(labelChips, id: \.id) { folder in
                        Chip(text: folder.name, color: Theme.color(hexString: folder.colorHex)).padding(.trailing, 4)
                    }
                }
                Text(conversation.subject.isEmpty ? "(no subject)" : conversation.subject)
                    .font(.pm(13.5, weight))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !conversation.snippet.isEmpty {
                    Text(" – " + conversation.snippet)
                        .font(.pm(13.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if conversation.hasAttachments {
                    Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(Theme.textTertiary).padding(.trailing, 8)
                }
            }
            .padding(.leading, 12)
            ZStack(alignment: .trailing) {
                if hovering {
                    HoverActions(mail: mail, conversation: conversation)
                } else {
                    Text(mail.rowDate(for: conversation))
                        .font(.pm(12.5, unread ? .bold : .regular))
                        .foregroundStyle(unread ? Theme.textPrimary : Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 150, alignment: .trailing)
            .padding(.trailing, 16)
        }
        .frame(height: 40)
        .background(checked ? Theme.rowChecked : (unread ? Theme.surface : Theme.rowRead))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider.opacity(0.6)).frame(height: 0.5) }
        .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: hovering ? 2 : 0, y: hovering ? 1 : 0)
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { mail.open(conversation) }
        .onHover { hovering = $0 }
        .draggable(conversation.id)
        .contextMenu { RowMenu(app: app, mail: mail, conversation: conversation) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unread ? "Unread, " : "")\(senders), \(conversation.subject), \(conversation.snippet), \(mail.formatting.listDate(conversation.date))")
        .accessibilityAddTraits(.isButton)
    }

    private var senders: String {
        let names = conversation.participants(me: mail.account.email, showRecipients: mail.listShowsRecipients)
        if mail.listShowsRecipients { return names.isEmpty ? "(no recipients)" : "To: " + names.joined(separator: ", ") }
        if names.count > 3 { return "\(names[0]) .. \(names[names.count - 2]), \(names[names.count - 1])" }
        return names.isEmpty ? "(unknown sender)" : names.joined(separator: ", ")
    }

    /// The user labels on the conversation, shown before the subject (not the one being listed).
    private var labelChips: [MailFolder] {
        guard mail.capabilities.usesLabels else { return [] }
        return conversation.labelIDs.compactMap { id in mail.folder(id) }.filter { $0.role == nil && $0.id != mail.selectedFolderID }
            .sorted { $0.name < $1.name }.prefix(3).map { $0 }
    }
}

/// Archive, delete, read/unread and star, shown on a row under the pointer in place of its date.
private struct HoverActions: View {
    let mail: MailViewModel
    let conversation: Conversation

    @ViewBuilder
    var body: some View {
        if MailViewModel.isLocal(mail.selectedFolderID) {
            if mail.selectedFolderID == Snooze.folderID {
                IconButton(symbol: "tray.and.arrow.down", help: "Unsnooze", size: 32, iconSize: 14) { mail.unsnooze(conversation) }
            } else {
                Text(mail.rowDate(for: conversation)).font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            hoverButtons
        }
    }

    private var hoverButtons: some View {
        HStack(spacing: 0) {
            if mail.capabilities.canArchive, mail.currentFolder?.role != .archive {
                IconButton(symbol: "archivebox", help: "Archive", size: 32, iconSize: 14) { mail.perform(.archive, on: [conversation]) }
            }
            IconButton(symbol: "trash", help: "Delete", size: 32, iconSize: 14) { mail.perform(.trash, on: [conversation]) }
            IconButton(symbol: conversation.isUnread ? "envelope.open" : "envelope.badge",
                       help: conversation.isUnread ? "Mark as read" : "Mark as unread", size: 32, iconSize: 14) {
                mail.perform(conversation.isUnread ? .markRead : .markUnread, on: [conversation])
            }
            if mail.canSnooze {
                LaterPicker(help: "Snooze", heading: "Snooze until…", choices: { LaterTimes.snooze(now: AppClock.now()) }) { date in
                    mail.snooze([conversation], until: date)
                } label: {
                    Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(Theme.icon).frame(width: 32, height: 32)
                }
                .frame(width: 32, height: 32)
            }
        }
    }
}

/// Buttons for Snoozed, Scheduled and Outbox rows, which PMail keeps on the Mac.
struct LocalFolderActions: View {
    let mail: MailViewModel
    let targets: [Conversation]

    var body: some View {
        HStack(spacing: 2) {
            if mail.selectedFolderID == Snooze.folderID {
                IconButton(symbol: "tray.and.arrow.down", help: "Unsnooze: back to the inbox now") {
                    for conversation in targets { mail.unsnooze(conversation) }
                }
            }
        }
    }
}

/// The right-click menu on a row.
private struct RowMenu: View {
    let app: AppModel
    let mail: MailViewModel
    let conversation: Conversation

    var body: some View {
        let targets = mail.checkedIDs.contains(conversation.id) ? mail.checkedConversations : [conversation]
        Button("Open") { mail.open(conversation) }
        Divider()
        if mail.selectedFolderID == Snooze.folderID {
            Button("Unsnooze") { for item in targets { mail.unsnooze(item) } }
        } else if !MailViewModel.isLocal(mail.selectedFolderID) {
            standardItems(targets)
        }
    }

    @ViewBuilder
    private func standardItems(_ targets: [Conversation]) -> some View {
        if mail.canSnooze {
            Menu("Snooze until") {
                ForEach(LaterTimes.snooze(now: AppClock.now()), id: \.title) { choice in
                    Button("\(choice.title)   \(AppClock.formatting.laterDate(choice.date))") { mail.snooze(targets, until: choice.date) }
                }
            }
        }
        if mail.capabilities.canArchive { Button("Archive") { mail.perform(.archive, on: targets) } }
        Button("Delete") { mail.perform(.trash, on: targets) }
        Button(targets.contains(where: \.isUnread) ? "Mark as read" : "Mark as unread") {
            mail.perform(targets.contains(where: \.isUnread) ? .markRead : .markUnread, on: targets)
        }
        if mail.capabilities.canStar {
            Button(targets.allSatisfy(\.isStarred) ? "Remove star" : "Add star") {
                mail.perform(targets.allSatisfy(\.isStarred) ? .unstar : .star, on: targets)
            }
        }
        if mail.capabilities.canMove {
            Menu("Move to") {
                ForEach(mail.moveTargets) { folder in
                    Button(mail.displayName(for: folder)) { mail.perform(.move(toFolderID: folder.id), on: targets) }
                }
            }
        }
        Divider()
        if mail.canReportSpam { Button("Report spam") { mail.perform(.markSpam, on: targets) } }
    }
}

/// What an empty list says.
private struct EmptyListState: View {
    let mail: MailViewModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: mail.activeSearch != nil ? "magnifyingglass" : "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(message).font(.pm(14)).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var message: String {
        if mail.activeSearch != nil { return "No messages matched your search." }
        switch mail.currentFolder?.role {
        case .inbox?: return mail.selectedTabID != nil && mail.inboxTabs.first?.id != mail.selectedTabID ? "Nothing in this tab." : "Your inbox is empty. Nice work!"
        case .starred?: return "No starred messages. Stars let you give messages a special status to make them easier to find."
        case .sent?: return "No sent messages."
        case .drafts?: return "You don’t have any saved drafts."
        case .snoozed?: return "Nothing snoozed. Snooze a conversation to have it come back to the inbox when you’re ready for it."
        case .scheduled?: return "No scheduled messages."
        case .outbox?: return "Your Outbox is empty."
        case .spam?: return "Hooray, no spam here!"
        case .trash?: return "No conversations in Trash."
        default: return "No conversations here."
        }
    }
}

/// A failed list, with a way to try again.
struct ErrorState: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(text).font(.pm(13.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                .textSelection(.enabled)
            OutlinePillButton(title: "Try Again", symbol: "arrow.clockwise", action: retry)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

extension MailViewModel {
    var formatting: MailFormatting { AppClock.formatting }
}
