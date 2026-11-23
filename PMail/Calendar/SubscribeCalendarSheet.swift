import PMailKit
import SwiftUI

/// Subscribing to a calendar: another person's (by their address, where the account's calendars allow it), or one
/// from a web address (an .ics link), shown under "Other calendars".
struct SubscribeCalendarSheet: View {
    enum Kind {
        case person
        case address
    }

    let app: AppModel
    let model: CalendarViewModel
    let kind: Kind
    @State private var address = ""
    @State private var name = ""
    @State private var isWorking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .person ? "Subscribe to Calendar" : "Subscribe from a Web Address").font(.pm(20)).foregroundStyle(Theme.textPrimary)
            Text(kind == .person
                 ? "Add someone’s calendar by their email address. You’ll see it if they’ve shared it with you, or made it public."
                 : "Add a calendar from its webcal:// or https:// address. PMail checks it for changes every hour; its events can’t be changed here.")
                .font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(kind == .person ? "Email address" : "Calendar address", text: $address,
                      prompt: Text(kind == .person ? "name@example.com" : "webcal://example.com/calendar.ics"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { subscribe() }
            if kind == .address {
                TextField("Name", text: $name, prompt: Text("Optional: the calendar’s own name is used otherwise"))
                    .textFieldStyle(.roundedBorder)
            }
            if let error {
                Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                FilledPillButton(title: isWorking ? "Subscribing…" : "Subscribe", isDisabled: isWorking || !isComplete) { subscribe() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.pm(13))
        .padding(24)
        .frame(width: 480)
        .background(Theme.surface)
    }

    private var isComplete: Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .person ? text.contains("@") && !text.contains(" ") : CalendarFeeds.fetchableURL(text) != nil
    }

    private func subscribe() {
        guard isComplete, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            do {
                let calendar = kind == .person
                    ? try await model.subscribe(toCalendarOf: address)
                    : try await model.subscribe(toFeed: address, name: name)
                app.show("Subscribed to “\(calendar.name)”.")
                dismiss()
            } catch {
                isWorking = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
