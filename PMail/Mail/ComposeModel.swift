import AppKit
import Observation
import PMailKit
import UniformTypeIdentifiers

/// A message being written: its fields, its text, its files, and sending it (with a few seconds to take it back).
@Observable
final class ComposeModel: Identifiable {
    let id = UUID()
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let session: AccountSession
    var to: [MailAddress] = []
    var cc: [MailAddress] = [] { didSet { if !cc.isEmpty { showsCc = true } } }
    var bcc: [MailAddress] = [] { didSet { if !bcc.isEmpty { showsBcc = true } } }
    var showsCc = false
    var showsBcc = false
    var subject = ""
    /// The text the person writes, with its formatting.
    var body = NSAttributedString()
    /// Bumped when the body is replaced from code, so the editor shows the new text.
    var bodyRevision = 0
    var attachments: [OutgoingAttachment] = []
    var isMinimized = false
    var isExpanded = false
    var isSending = false
    var showsFormatting = false
    var showsQuote = false
    var error: String?
    /// The original, quoted under a reply or forward.
    var quotedHTML: String?
    var quotedText: String?
    var inReplyTo: String?
    var references: [String] = []
    var threadID: String?
    var kind: ReplyBuilder.Kind?
    /// The draft saved on the server, replaced each time it's saved again.
    @ObservationIgnored private var savedDraft: MessageSummary?
    @ObservationIgnored private var lastSavedFingerprint = ""
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    /// Seconds a sent message waits, so Undo can still stop it.
    @ObservationIgnored var undoSendDelay: TimeInterval = max(1, UserDefaults.standard.double(forKey: "UndoSendSeconds"))

    init(app: AppModel, session: AccountSession) {
        self.app = app
        self.session = session
        let signature = session.account.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        if !signature.isEmpty { setPlainBody("\n\n-- \n" + signature) }
    }

    var account: Account { session.account }

    /// The saved draft this window is editing, so opening that draft again brings this window forward.
    var editingDraftID: String? { savedDraft?.id }

    var title: String {
        if !subject.isEmpty { return subject }
        switch kind {
        case .reply?, .replyAll?: return "Reply"
        case .forward?: return "Forward"
        case nil: return "New Message"
        }
    }

    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && attachments.isEmpty
            && body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setPlainBody(_ text: String) {
        body = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor])
        bodyRevision += 1
    }

    /// Fills the fields for a reply, reply-all or forward.
    func startReply(to message: MailMessage, kind: ReplyBuilder.Kind) {
        let draft = ReplyBuilder.draft(for: message, kind: kind, me: account.email)
        self.kind = kind
        to = draft.to
        cc = draft.cc
        subject = draft.subject
        inReplyTo = draft.inReplyTo
        references = draft.references
        threadID = draft.threadID
        quotedHTML = draft.quotedHTML
        quotedText = draft.quotedText
        // A forward shows what it forwards; a reply keeps the quote folded away.
        showsQuote = kind == .forward
        attachments = draft.attachments.compactMap { attachment in
            attachment.data.map { OutgoingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: $0) }
        }
    }

    // MARK: Files

    func attach(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                app?.show("“\(url.lastPathComponent)” couldn’t be attached.")
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
        let total = attachments.reduce(0) { $0 + $1.data.count }
        if total > 25 * 1024 * 1024 {
            app?.show("These files add up to more than 25 MB, which many mail servers won’t take.", duration: 8)
        }
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    // MARK: Building the message

    func outgoing() -> OutgoingMessage {
        var text = RichTextHTML.plainText(from: body)
        var html = RichTextHTML.html(from: body)
        if let quotedText, let quotedHTML {
            text += "\n\n" + quotedText
            html += "<br><div class=\"pmail_quote\">" + quotedHTML + "</div>"
        }
        return OutgoingMessage(from: account.address, to: to, cc: cc, bcc: bcc, subject: subject, textBody: text,
                               htmlBody: RichTextHTML.document(body: html), attachments: attachments, inReplyTo: inReplyTo,
                               references: references, threadID: threadID)
    }

    /// Addresses that don't look like addresses, for the warning before sending.
    var invalidAddresses: [String] {
        (to + cc + bcc).map(\.email).filter { address in
            let parts = address.split(separator: "@")
            return parts.count != 2 || parts[1].contains(" ") || !parts[1].contains(".") || parts[0].isEmpty
        }
    }

    // MARK: Sending

    /// Sends after a few seconds, during which the note along the bottom offers Undo.
    func send() {
        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
            error = "Add at least one recipient."
            return
        }
        if let bad = invalidAddresses.first {
            error = "“\(bad)” isn’t a complete email address."
            return
        }
        error = nil
        isSending = true
        let message = outgoing()
        let app = self.app
        app?.close(self)
        let delay = undoSendDelay
        // The task keeps the message alive (its window is gone) until it's sent or Undo stops it.
        sendTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.deliver(message)
        }
        app?.show("Sending…", actionTitle: "Undo", duration: delay) { [weak self] in self?.undoSend() }
    }

    private func deliver(_ message: OutgoingMessage) async {
        let service = session.services.mail
        // Offline, it goes straight to the Outbox.
        if app?.sync?.isOnline == false {
            await putInOutbox(message)
            return
        }
        do {
            try await service.send(message)
            if let savedDraft {
                try? await service.deleteDraft(savedDraft)
                session.mail.draftsChanged()
            }
            isSending = false
            app?.show("Message sent.")
            session.mail.didSend()
        } catch where MailViewModel.isConnectionProblem(error) {
            await putInOutbox(message)
        } catch {
            isSending = false
            self.error = "It wasn’t sent: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            isMinimized = false
            app?.open(self)
        }
    }

    /// Keeps a message the server couldn't take in the Outbox, to send once it can.
    private func putInOutbox(_ message: OutgoingMessage) async {
        isSending = false
        do {
            try await session.storage.queue.save(QueuedMessage(message: message, queuedAt: AppClock.now(), draft: savedDraft))
            session.mail.queueChanged()
            app?.show("You’re offline. The message is in your Outbox and will be sent when PMail can reach the server.", duration: 8)
        } catch {
            self.error = "It wasn’t sent, and couldn’t be kept to send later: \((error as? LocalizedError)?.errorDescription ?? "")"
            isMinimized = false
            app?.open(self)
        }
    }

    // MARK: Scheduling

    /// Sends the message at `date` instead of now. It waits on this Mac, in Scheduled, until then.
    func schedule(at date: Date) {
        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
            error = "Add at least one recipient."
            return
        }
        if let bad = invalidAddresses.first {
            error = "“\(bad)” isn’t a complete email address."
            return
        }
        error = nil
        let item = QueuedMessage(message: outgoing(), sendAt: date, queuedAt: AppClock.now(), draft: savedDraft)
        app?.close(self)
        let queue = session.storage.queue
        let mail = session.mail
        let app = self.app
        Task { [weak self] in
            do {
                try await queue.save(item)
                mail.queueChanged()
                app?.show("Send scheduled for \(AppClock.formatting.laterDate(date)).", actionTitle: "Undo", duration: 8) { [weak self] in
                    Task {
                        await queue.remove(item.id)
                        mail.queueChanged()
                        if let self {
                            self.isMinimized = false
                            self.app?.open(self)
                        }
                    }
                }
            } catch {
                guard let self else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                app?.open(self)
            }
        }
    }

    /// Fills the window with a message written earlier (one taken out of Scheduled or the Outbox).
    func load(_ message: OutgoingMessage) {
        to = message.to
        cc = message.cc
        bcc = message.bcc
        subject = message.subject
        attachments = message.attachments
        inReplyTo = message.inReplyTo
        references = message.references
        threadID = message.threadID
        if let html = message.htmlBody, let data = html.data(using: .utf8),
           let text = NSAttributedString(html: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                               .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            body = text
            bodyRevision += 1
        } else {
            setPlainBody(message.textBody)
        }
    }

    /// Fills the window with a saved draft to carry on writing: saving replaces that draft, and sending or discarding
    /// deletes it. Closing it unchanged leaves the draft as it was.
    func load(draft message: MailMessage, files: [OutgoingAttachment]) {
        let summary = message.summary
        load(OutgoingMessage(from: account.address, to: summary.to, cc: summary.cc, bcc: message.bcc, subject: summary.subject,
                             textBody: message.textBody ?? "", htmlBody: message.htmlBody, attachments: files,
                             inReplyTo: summary.inReplyTo, references: summary.references, threadID: summary.threadID))
        savedDraft = summary
        lastSavedFingerprint = Self.fingerprint(outgoing())
    }

    /// What changed-or-not compares when closing, to save a draft only when there's something new in it.
    private static func fingerprint(_ message: OutgoingMessage) -> String {
        "\(message.to)\(message.cc)\(message.bcc)\(message.subject)\(message.textBody)\(message.attachments.count)"
    }

    /// Stops a message whose few seconds haven't run out, and opens it again.
    func undoSend() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        isMinimized = false
        app?.open(self)
        app?.show("Sending undone.")
    }

    // MARK: Drafts

    /// Closes the window, keeping what was written as a draft.
    func closeKeepingDraft() {
        app?.close(self)
        guard !isEmpty, session.services.mail.capabilities.supportsDrafts else { return }
        let message = outgoing()
        let fingerprint = Self.fingerprint(message)
        guard fingerprint != lastSavedFingerprint else { return }
        lastSavedFingerprint = fingerprint
        let previous = savedDraft
        let service = session.services.mail
        Task {
            do {
                savedDraft = try await service.saveDraft(message, replacing: previous)
                app?.show("Draft saved.")
                session.mail.draftsChanged()
            } catch {
                app?.report(error, doing: "Saving the draft")
            }
        }
    }

    /// Closes the window and throws away what was written (and any saved draft).
    func discard() {
        sendTask?.cancel()
        app?.close(self)
        if let savedDraft {
            let service = session.services.mail
            let mail = session.mail
            Task {
                try? await service.deleteDraft(savedDraft)
                mail.draftsChanged()
            }
        }
        if !isEmpty { app?.show("Draft discarded.") }
    }
}
