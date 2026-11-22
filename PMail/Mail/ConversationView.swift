import AppKit
import PMailKit
import SwiftUI
import UniformTypeIdentifiers

/// An open conversation: the toolbar, the subject, each message (older ones folded to a line), and Reply, Reply all
/// and Forward at the bottom.
struct ConversationView: View {
    let app: AppModel
    let session: AccountSession
    let mail: MailViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.left", help: "Back to \(mail.listTitle)") { mail.closeConversation() }
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                if let queued = mail.openQueuedItem {
                    OutlinePillButton(title: "Send Now", symbol: "paperplane") { mail.sendQueuedNow(queued) }
                    OutlinePillButton(title: queued.isScheduled ? "Cancel Send" : "Edit", symbol: "pencil") { mail.editQueued(queued) }
                        .help(queued.isScheduled ? "Stop the scheduled send and open the message to edit" : "Take it out of the Outbox to edit")
                    IconButton(symbol: "trash", help: "Delete") { mail.deleteQueued(queued) }
                    if let sendAt = queued.sendAt {
                        Text("Sends \(AppClock.formatting.laterDate(sendAt))").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 8)
                    } else if let error = queued.lastError {
                        Text("Not sent yet: \(error)").font(.pm(12.5)).foregroundStyle(Theme.danger).lineLimit(1).padding(.leading, 8)
                    }
                } else if let wake = mail.openSnoozeTime, let conversation = mail.openConversation {
                    OutlinePillButton(title: "Unsnooze", symbol: "tray.and.arrow.down") { mail.unsnooze(conversation) }
                    Text("Snoozed until \(AppClock.formatting.laterDate(wake))").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 8)
                } else if let conversation = mail.openConversation {
                    ConversationActions(app: app, mail: mail, targets: [conversation])
                }
                Spacer()
                if !mail.positionText.isEmpty {
                    Text(mail.positionText).font(.pm(12)).foregroundStyle(Theme.textSecondary).padding(.trailing, 4)
                }
                IconButton(symbol: "chevron.left", help: "Newer", isDisabled: mail.neighbor(-1) == nil) {
                    if let newer = mail.neighbor(-1) { mail.open(newer) }
                }
                IconButton(symbol: "chevron.right", help: "Older", isDisabled: mail.neighbor(1) == nil) {
                    if let older = mail.neighbor(1) { mail.open(older) }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 48)
            Divider().overlay(Theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    subjectRow
                    if let error = mail.conversationError {
                        ErrorState(text: error) { if let conversation = mail.openConversation { mail.open(conversation) } }
                            .frame(height: 240)
                    } else if mail.isLoadingConversation && mail.openMessages.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(mail.openMessages) { message in
                            if mail.expandedMessageIDs.contains(message.id) {
                                ExpandedMessage(app: app, session: session, mail: mail, message: message)
                            } else {
                                CollapsedMessage(mail: mail, message: message)
                            }
                            Divider().overlay(Theme.divider).padding(.leading, 72)
                        }
                        if let last = mail.openMessages.last(where: { !$0.summary.isDraft }), mail.openQueuedItem == nil {
                            HStack(spacing: 12) {
                                OutlinePillButton(title: "Reply", symbol: "arrowshape.turn.up.left") { app.reply(to: last, kind: .reply, in: session) }
                                if last.summary.to.count + last.summary.cc.count > 1 {
                                    OutlinePillButton(title: "Reply all", symbol: "arrowshape.turn.up.left.2") {
                                        app.reply(to: last, kind: .replyAll, in: session)
                                    }
                                }
                                OutlinePillButton(title: "Forward", symbol: "arrowshape.turn.up.right") { app.reply(to: last, kind: .forward, in: session) }
                            }
                            .padding(.leading, 72)
                            .padding(.vertical, 24)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
        }
    }

    private var subjectRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(mail.openConversation?.subject.isEmpty == false ? mail.openConversation!.subject : "(no subject)")
                .font(.pm(22))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            ForEach(chips, id: \.id) { folder in
                Chip(text: mail.displayName(for: folder), color: Theme.color(hexString: folder.colorHex),
                     onRemove: mail.capabilities.usesLabels && folder.role != .inbox ? {
                         if let conversation = mail.openConversation { mail.perform(.removeLabel(folder.id), on: [conversation]) }
                     } : nil)
            }
            Spacer()
        }
        .padding(.leading, 72)
        .padding(.trailing, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    /// The folders and labels the conversation is in.
    private var chips: [MailFolder] {
        guard let conversation = mail.openConversation else { return [] }
        if mail.capabilities.usesLabels {
            return conversation.labelIDs.compactMap { mail.folder($0) }
                .filter { $0.role == nil || $0.role == .inbox }.sorted { ($0.role == .inbox ? 0 : 1, $0.name) < ($1.role == .inbox ? 0 : 1, $1.name) }
        }
        return Set(conversation.messages.compactMap(\.folderID)).compactMap { mail.folder($0) }
    }
}

/// A message folded to one line: who, the start of the text and when.
private struct CollapsedMessage: View {
    let mail: MailViewModel
    let message: MailMessage
    @State private var hovering = false

    var body: some View {
        let sender = message.summary.from ?? MailAddress(email: "")
        HStack(spacing: 16) {
            Avatar(name: sender.name ?? "", email: sender.email, size: 40)
            Text(message.summary.isDraft ? "Draft" : sender.isSameMailbox(as: mail.account.email) ? "me" : sender.displayName)
                .font(.pm(14, message.summary.isUnread ? .bold : .semibold))
                .foregroundStyle(message.summary.isDraft ? Theme.danger : Theme.textPrimary)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
            Text(message.summary.snippet.isEmpty ? HTMLText.snippet(from: message.textBody ?? "") : message.summary.snippet)
                .font(.pm(13.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer()
            Text(mail.formatting.listDate(message.summary.date)).font(.pm(12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .frame(height: 64)
        .background(hovering ? Theme.hover.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // A draft opens to carry on writing it.
            if message.summary.isDraft { mail.editDraft(message.summary) } else { mail.toggleExpanded(message.id) }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(message.summary.isDraft ? "Opens the draft to edit it" : "Shows the whole message")
    }
}

/// A whole message: who sent it to whom and when, its body, and its files.
private struct ExpandedMessage: View {
    let app: AppModel
    let session: AccountSession
    let mail: MailViewModel
    let message: MailMessage
    @State private var bodyHeight: CGFloat = 60
    @State private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = message.summary
        let sender = summary.from ?? MailAddress(email: "")
        HStack(alignment: .top, spacing: 16) {
            Avatar(name: sender.name ?? "", email: sender.email, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sender.displayName).font(.pm(14, .bold)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    if sender.name != nil {
                        Text("<\(sender.email)>").font(.pm(12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(mail.formatting.messageDate(summary.date)).font(.pm(12)).foregroundStyle(Theme.textSecondary)
                    // A draft isn't mail yet: it's edited or thrown away, not starred or replied to.
                    if summary.isDraft, mail.openQueuedItem == nil {
                        Text("Draft").font(.pm(12.5, .semibold)).foregroundStyle(Theme.danger)
                        Button("Edit") { mail.editDraft(summary) }.help("Carry on writing this draft")
                        Button("Discard") { mail.discardDraft(summary) }.help("Throw this draft away")
                    }
                    // A message waiting to be sent has nothing to star or reply to yet.
                    if mail.openQueuedItem == nil, !summary.isDraft {
                        if mail.capabilities.canStar {
                            IconButton(symbol: summary.isStarred ? "star.fill" : "star", help: summary.isStarred ? "Starred" : "Not starred",
                                       size: 30, iconSize: 14, tint: summary.isStarred ? Theme.star : Theme.icon) {
                                mail.perform(summary.isStarred ? .unstar : .star, onMessage: summary)
                            }
                        }
                        IconButton(symbol: "arrowshape.turn.up.left", help: "Reply", size: 30, iconSize: 14) {
                            app.reply(to: message, kind: .reply, in: session)
                        }
                        Menu {
                            Button("Reply") { app.reply(to: message, kind: .reply, in: session) }
                            Button("Reply all") { app.reply(to: message, kind: .replyAll, in: session) }
                            Button("Forward") { app.reply(to: message, kind: .forward, in: session) }
                            Divider()
                            Button("Delete this message") { mail.perform(.trash, onMessage: summary) }
                            Button("Mark unread from here") { mail.perform(.markUnread, onMessage: summary); mail.closeConversation() }
                            Divider()
                            if message.rawSource != nil { Button("Download message") { saveOriginal() } }
                            if let unsubscribe = message.listUnsubscribe.flatMap(unsubscribeURL) {
                                Button("Unsubscribe") { NSWorkspace.shared.open(unsubscribe) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.icon)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 30, height: 30)
                        .help("More")
                    }
                }
                Button { showsDetails.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(recipientsLine).font(.pm(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) { MessageDetails(mail: mail, message: message) }
                if MessageHTML.hasRemoteContent(message), !mail.showsImages(for: message) {
                    HStack(spacing: 8) {
                        Text("Pictures in this message are hidden.").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                        Button("Show pictures") { mail.imagesShownFor.insert(message.id) }.buttonStyle(.link).font(.pm(12.5))
                        if let email = summary.from?.email.lowercased() {
                            Text("·").foregroundStyle(Theme.textTertiary)
                            Button("Always show pictures from \(summary.from?.email ?? "")") { mail.trustedImageSenders.insert(email) }
                                .buttonStyle(.link).font(.pm(12.5))
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chip.opacity(0.5)))
                    .padding(.top, 8)
                }
                let onCard = colorScheme == .dark && !(message.htmlBody?.isEmpty ?? true)
                MessageBodyView(message: message, loadsRemoteImages: mail.showsImages(for: message), height: $bodyHeight) { url in
                    app.handleMailto(url)
                }
                .frame(height: bodyHeight)
                .padding(onCard ? 14 : 0)
                .background(RoundedRectangle(cornerRadius: 10).fill(onCard ? Color.white : .clear))
                .padding(.top, 14)
                if !message.attachments.isEmpty {
                    AttachmentStrip(app: app, mail: mail, message: message)
                        .padding(.top, 16)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.vertical, 16)
    }

    private var recipientsLine: String {
        let me = mail.account.email
        let names = (message.summary.to + message.summary.cc).map { $0.isSameMailbox(as: me) ? "me" : $0.shortName }
        return names.isEmpty ? "to undisclosed recipients" : "to " + names.joined(separator: ", ")
    }

    private func unsubscribeURL(_ header: String) -> URL? {
        let links = header.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) }
        return (links.first { $0.hasPrefix("https://") } ?? links.first { $0.hasPrefix("mailto:") }).flatMap(URL.init(string:))
    }

    private func saveOriginal() {
        guard let data = message.rawSource else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (message.summary.subject.isEmpty ? "Message" : message.summary.subject)
            .replacingOccurrences(of: "/", with: "-") + ".eml"
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

/// From, to, cc, date and subject of a message, from "to me ▾".
private struct MessageDetails: View {
    let mail: MailViewModel
    let message: MailMessage

    var body: some View {
        let summary = message.summary
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("from:", summary.from.map { [$0] } ?? [])
            if !message.replyTo.isEmpty { row("reply-to:", message.replyTo) }
            row("to:", summary.to)
            if !summary.cc.isEmpty { row("cc:", summary.cc) }
            if !message.bcc.isEmpty { row("bcc:", message.bcc) }
            GridRow {
                Text("date:").foregroundStyle(Theme.textSecondary)
                Text(summary.date.formatted(date: .abbreviated, time: .shortened)).textSelection(.enabled)
            }
            GridRow {
                Text("subject:").foregroundStyle(Theme.textSecondary)
                Text(summary.subject).textSelection(.enabled)
            }
        }
        .font(.pm(12))
        .foregroundStyle(Theme.textPrimary)
        .padding(16)
        .frame(maxWidth: 480)
        .background(Theme.surfaceRaised)
    }

    private func row(_ label: String, _ addresses: [MailAddress]) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textSecondary)
            Text(addresses.map(\.formatted).joined(separator: ",\n")).textSelection(.enabled)
        }
    }
}

/// A message's files as cards: click one to save it to Downloads; right-click for more.
private struct AttachmentStrip: View {
    let app: AppModel
    let mail: MailViewModel
    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.divider)
            Text(message.attachments.count == 1 ? "One attachment" : "\(message.attachments.count) attachments")
                .font(.pm(13, .medium))
                .foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 200), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(message.attachments) { attachment in
                    AttachmentCard(attachment: attachment) { open in
                        Task { await save(attachment, open: open) }
                    } saveAs: {
                        Task { await saveAs(attachment) }
                    }
                }
            }
        }
    }

    private func data(for attachment: Attachment) async -> Data? {
        if let data = attachment.data { return data }
        do {
            return try await mail.service.loadAttachment(attachment, in: message.summary)
        } catch {
            app.report(error, doing: "Downloading “\(attachment.filename)”")
            return nil
        }
    }

    /// Saves to Downloads under a name not already taken, and opens it or offers to show it.
    private func save(_ attachment: Attachment, open: Bool) async {
        guard let data = await data(for: attachment),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let name = attachment.filename.isEmpty ? "Attachment" : attachment.filename.replacingOccurrences(of: "/", with: "-")
        var url = downloads.appendingPathComponent(name)
        var copy = 1
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            copy += 1
            url = downloads.appendingPathComponent("\(base) \(copy)" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        do {
            try data.write(to: url)
            if open {
                NSWorkspace.shared.open(url)
            } else {
                app.show("Saved “\(url.lastPathComponent)” to Downloads.", actionTitle: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } catch {
            app.report(error, doing: "Saving “\(name)”")
        }
    }

    private func saveAs(_ attachment: Attachment) async {
        guard let data = await data(for: attachment) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { app.report(error, doing: "Saving “\(attachment.filename)”") }
        }
    }
}

private struct AttachmentCard: View {
    let attachment: Attachment
    let save: (_ open: Bool) -> Void
    let saveAs: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Theme.chip.opacity(0.6))
                if attachment.mimeType.hasPrefix("image/"), let data = attachment.data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: attachment.mimeType) ?? .data))
                        .resizable().frame(width: 48, height: 48)
                }
            }
            .frame(height: 96)
            .clipped()
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename).font(.pm(12, .medium)).lineLimit(1)
                    Text(MailFormatting().fileSize(attachment.size)).font(.pm(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if hovering {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 12)).foregroundStyle(Theme.icon)
                }
            }
            .padding(8)
        }
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { save(true) }
        .onTapGesture { save(false) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { save(true) }
            Button("Save to Downloads") { save(false) }
            Button("Save As…") { saveAs() }
        }
        .help("Click to save to Downloads, double-click to open")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
