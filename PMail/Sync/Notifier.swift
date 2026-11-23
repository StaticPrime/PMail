import AppKit
import PMailKit
@preconcurrency import UserNotifications

/// Shows notifications: new mail, and conversations back from snooze. Clicking one opens its conversation.
protocol MailNotifier: AnyObject {
    /// Called with the account and the message whose notification was clicked.
    var onOpen: ((UUID, MessageSummary) -> Void)? { get set }
    func notify(newMail messages: [MessageSummary], in account: Account)
    func notify(backFromSnooze conversation: Conversation, in account: Account)
    func removeNotifications(for account: UUID)
}

/// The system's notifications, asked for the first time PMail has something to show.
final class SystemNotifier: NSObject, MailNotifier, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID, MessageSummary) -> Void)?
    private var asked = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(newMail messages: [MessageSummary], in account: Account) {
        // A handful at most, each its own; a flood is one summary.
        if messages.count > 4 {
            post(title: account.email, subtitle: "", body: "\(messages.count) new messages", account: account, message: messages[0])
            return
        }
        for message in messages.prefix(4) {
            post(title: message.from?.displayName ?? "New message", subtitle: message.subject.isEmpty ? "(no subject)" : message.subject,
                 body: message.snippet, account: account, message: message)
        }
    }

    func notify(backFromSnooze conversation: Conversation, in account: Account) {
        guard let latest = conversation.latest else { return }
        post(title: "Back from snooze", subtitle: conversation.subject.isEmpty ? "(no subject)" : conversation.subject,
             body: latest.from.map { "From \($0.displayName)" } ?? "", account: account, message: latest)
    }

    func removeNotifications(for account: UUID) {
        let center = UNUserNotificationCenter.current()
        let prefix = account.uuidString
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private func post(title: String, subtitle: String, body: String, account: Account, message: MessageSummary) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = account.id.uuidString
        content.userInfo = ["account": account.id.uuidString, "message": (try? JSONEncoder().encode(message)) ?? Data()]
        let request = UNNotificationRequest(identifier: "\(account.id.uuidString)-\(message.id)", content: content, trigger: nil)
        let ask = !asked
        asked = true
        Task {
            // macOS asks the person the first time; after that this answers at once.
            if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            try? await center.add(request)
        }
    }

    // Banners show even while PMail is open (the window may be showing something else).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let accountText = info["account"] as? String
        let data = info["message"] as? Data
        completionHandler()
        Task { @MainActor [weak self] in
            if let accountText, let account = UUID(uuidString: accountText), let data,
               let message = try? JSONDecoder().decode(MessageSummary.self, from: data) {
                self?.onOpen?(account, message)
            }
        }
    }
}

#if DEBUG
/// Notifications for sample runs: kept in a list, never shown.
final class RecordingNotifier: MailNotifier {
    var onOpen: ((UUID, MessageSummary) -> Void)?
    private(set) var newMail: [(account: UUID, messages: [MessageSummary])] = []
    private(set) var snoozeReturns: [(account: UUID, conversation: Conversation)] = []

    func notify(newMail messages: [MessageSummary], in account: Account) { newMail.append((account.id, messages)) }
    func notify(backFromSnooze conversation: Conversation, in account: Account) { snoozeReturns.append((account.id, conversation)) }
    func removeNotifications(for account: UUID) {}

    /// Forgets the notifications so far (the self-test starts its new-mail steps clean).
    func forgetNewMail() { newMail = [] }
}
#endif
