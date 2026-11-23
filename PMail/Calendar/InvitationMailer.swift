import Foundation
import PMailKit

/// Emails invitations, cancellations and answers for an account whose calendar has no server to send them (iTIP by
/// email), from the account's own address. Offline, or when the server can't be reached, they wait in the Outbox.
@MainActor
final class InvitationMailer {
    private weak var session: AccountSession?

    init(session: AccountSession) {
        self.session = session
    }

    /// Sends the iCalendar text about an event (`InvitationText`, or a calendar's `invitationText`) to some people.
    func send(_ method: Invitation.Method, text: String, about event: CalendarEvent, to people: [MailAddress],
              answer: AttendeeResponse? = nil, note: String? = nil) {
        guard let session, !people.isEmpty, method != .other else { return }
        let message = Self.message(method, text: text, about: event, from: session.account.address, to: people, answer: answer,
                                   note: note, formatting: session.calendar.formatting)
        Task { await deliver(message, in: session) }
    }

    /// The message that carries an invitation, cancellation or answer: a few plain words for any mail program, and the
    /// event itself for those that show it.
    static func message(_ method: Invitation.Method, text: String, about event: CalendarEvent, from sender: MailAddress, to people: [MailAddress],
                        answer: AttendeeResponse?, note: String? = nil, formatting: MailFormatting) -> OutgoingMessage {
        let when = formatting.eventTime(start: event.start, end: event.end, isAllDay: event.isAllDay, includeDate: true)
        let title = event.shownTitle
        let name = sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? sender.email
        let subject: String
        var lines: [String]
        switch method {
        case .request:
            subject = "Invitation: \(title) @ \(when)"
            lines = ["\(name) invited you to \(title).", "", when]
            if let location = event.location, !location.isEmpty { lines.append(location) }
            if let link = event.conference?.joinURL.absoluteString { lines.append("Join: \(link)") }
            if let notes = event.notes, !notes.isEmpty { lines += ["", notes] }
        case .cancel:
            subject = "Canceled: \(title) @ \(when)"
            lines = ["\(name) canceled \(title).", "", when]
        case .reply:
            let word: String
            switch answer {
            case .accepted?: word = "Accepted"
            case .declined?: word = "Declined"
            case .tentative?: word = "Maybe"
            default: word = "Answer"
            }
            subject = "\(word): \(title) @ \(when)"
            let said: String
            switch answer {
            case .accepted?: said = "is going to"
            case .declined?: said = "isn’t going to"
            case .tentative?: said = "might go to"
            default: said = "answered the invitation to"
            }
            lines = ["\(name) \(said) \(title).", "", when]
            if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { lines += ["", note] }
        case .other:
            subject = title
            lines = [title]
        }
        return OutgoingMessage(from: sender, to: people, subject: subject, textBody: lines.joined(separator: "\n"),
                               calendar: OutgoingCalendar(method: method.rawValue, text: text))
    }

    private func deliver(_ message: OutgoingMessage, in session: AccountSession) async {
        if session.mail.app?.sync?.isOnline != false {
            do {
                try await session.services.mail.send(message)
                return
            } catch where MailViewModel.isConnectionProblem(error) {
                // Kept in the Outbox below.
            } catch {
                session.mail.app?.report(error, doing: "Emailing “\(message.subject)”")
                return
            }
        }
        do {
            try await session.storage.queue.save(QueuedMessage(message: message, queuedAt: AppClock.now(), draft: nil))
            session.mail.queueChanged()
        } catch {
            session.mail.app?.report(error, doing: "Keeping “\(message.subject)” to send later")
        }
    }
}
