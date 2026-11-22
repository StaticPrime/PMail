import AppKit
import PMailKit
import SwiftUI

/// An event's details, in a popover from the event: when, its kind, the video meeting to join, guests and their
/// answers, where, the description, the reminder and the calendar, with edit, delete and email buttons at the top (and
/// for a task, one to tick it off).
struct EventDetailsView: View {
    let app: AppModel
    let model: CalendarViewModel
    let event: CalendarEvent
    @State private var confirmsDelete = false

    var body: some View {
        let calendarInfo = model.calendarInfo(event.calendarID)
        let canEdit = calendarInfo?.isReadOnly == false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                if canEdit {
                    if event.isTask {
                        IconButton(symbol: event.isCompleted ? "checkmark.circle.fill" : "checkmark.circle",
                                   help: event.isCompleted ? "Mark as not done" : "Mark as done", size: 32, iconSize: 15) {
                            model.setCompleted(event, !event.isCompleted)
                        }
                    }
                    IconButton(symbol: "pencil", help: event.isTask ? "Edit task" : "Edit event", size: 32, iconSize: 14) {
                        model.selectedEventID = nil
                        app.sheet = .eventEditor(model.draft(for: event))
                    }
                    IconButton(symbol: "trash", help: event.isTask ? "Delete task" : "Delete event", size: 32, iconSize: 14) { confirmsDelete = true }
                }
                if !guests.isEmpty {
                    IconButton(symbol: "envelope", help: "Email guests", size: 32, iconSize: 14) {
                        model.selectedEventID = nil
                        app.compose(to: guests.map(\.address), subject: event.title)
                    }
                }
                IconButton(symbol: "xmark", help: "Close", size: 32, iconSize: 13) { model.selectedEventID = nil }
            }
            .padding(.bottom, 2)
            row(icon: nil, color: model.color(for: event)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.shownTitle)
                        .font(.pm(21))
                        .strikethrough(event.isTask && event.isCompleted)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((event.isTask ? "Due " : "") + model.formatting.eventTime(start: event.start, end: event.end, isAllDay: event.isAllDay, includeDate: true))
                        .font(.pm(13))
                        .foregroundStyle(Theme.textSecondary)
                    if event.isRecurring {
                        Text(recurrenceText).font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if event.type != .event {
                row(icon: event.type.symbol) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.isTask ? (event.isCompleted ? "Task, done" : "Task") : event.type.name)
                            .font(.pm(13))
                            .foregroundStyle(Theme.textPrimary)
                        if event.declinesInvitations {
                            Text("Declining meetings during this time" + (event.declineMessage.map { ": “\($0)”" } ?? ""))
                                .font(.pm(12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if event.isTypeLocal {
                            Text("Shown as \(event.type.name.lowercased()) on this Mac. The calendar keeps it as an event.")
                                .font(.pm(12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let conference = event.conference {
                row(icon: conference.kind == .faceTime ? "video.fill" : "video") {
                    VStack(alignment: .leading, spacing: 6) {
                        FilledPillButton(title: "Join with \(conference.kind.displayName)") { NSWorkspace.shared.open(conference.joinURL) }
                        Text(displayLink(conference.joinURL))
                            .font(.pm(12))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                        ForEach(conference.phoneNumbers, id: \.self) { number in
                            Text("Join by phone: \(number)").font(.pm(12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if !guests.isEmpty {
                row(icon: "person.2") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(guests.count) guest\(guests.count == 1 ? "" : "s")").font(.pm(13.5, .medium))
                        Text(responseSummary).font(.pm(12)).foregroundStyle(Theme.textSecondary)
                        ForEach(guests, id: \.address.email) { guest in
                            HStack(spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    Avatar(name: guest.address.name ?? "", email: guest.address.email, size: 28)
                                    responseBadge(guest.response)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(guest.address.displayName).font(.pm(12.5)).foregroundStyle(Theme.textPrimary)
                                    if guest.isOrganizer { Text("Organizer").font(.pm(11)).foregroundStyle(Theme.textSecondary) }
                                    else if guest.isOptional { Text("Optional").font(.pm(11)).foregroundStyle(Theme.textSecondary) }
                                }
                            }
                        }
                    }
                }
                if model.account.kind == .icloud || model.account.kind == .other {
                    row(icon: "message") {
                        Button("Message guests") { messageGuests() }.buttonStyle(.link).font(.pm(12.5))
                    }
                }
            }
            if let location = event.location, !location.isEmpty {
                row(icon: "mappin.and.ellipse") {
                    Button(location) {
                        var components = URLComponents(string: "maps://")!
                        components.queryItems = [URLQueryItem(name: "q", value: location)]
                        if let url = components.url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain)
                    .font(.pm(13))
                    .foregroundStyle(Theme.textPrimary)
                    .help("Show in Maps")
                }
            }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                row(icon: "text.alignleft") {
                    Text(LinkedText.attributed(notes)).font(.pm(12.5)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: 180)
                }
            }
            if !event.reminderMinutes.isEmpty {
                row(icon: "bell") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(event.reminderMinutes.sorted(), id: \.self) { minutes in
                            Text(EventDetailsView.reminderText(minutes)).font(.pm(13)).foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            if let calendarInfo {
                row(icon: calendarInfo.isTaskList ? "checklist" : "calendar") { Text(calendarInfo.name).font(.pm(13)).foregroundStyle(Theme.textPrimary) }
            }
            if event.visibility != .default {
                row(icon: event.visibility == .private ? "lock" : "globe") {
                    Text(event.visibility.name).font(.pm(13)).foregroundStyle(Theme.textPrimary)
                }
            }
            if let response = event.myResponse, !(event.organizer?.isSameMailbox(as: model.account.email) ?? false) {
                Divider().overlay(Theme.divider).padding(.vertical, 8)
                HStack(spacing: 8) {
                    Text("Going?").font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    rsvpButton("Yes", .accepted, current: response)
                    rsvpButton("No", .declined, current: response)
                    rsvpButton("Maybe", .tentative, current: response)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 440)
        .background(Theme.surfaceRaised)
        #if DEBUG
        // `-PMConfirmDelete YES` asks about deleting the event showing.
        .onAppear { if UserDefaults.standard.bool(forKey: "PMConfirmDelete") { confirmsDelete = true } }
        #endif
        // Deleting asks first (there's no Undo): a repeating event, whether it's this one or all of them.
        .confirmationDialog("Delete “\(event.shownTitle)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            if event.isRecurring {
                Button("Delete This Event", role: .destructive) { model.delete(event, scope: .thisEvent) }
                Button("Delete All Events", role: .destructive) { model.delete(event, scope: .allEvents) }
            } else {
                Button(event.isTask ? "Delete Task" : "Delete Event", role: .destructive) { model.delete(event, scope: .thisEvent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(event.isRecurring ? "It repeats: delete just this one, or every time it happens? This can’t be undone." : "This can’t be undone.")
        }
    }

    private var guests: [Attendee] {
        event.attendees.sorted { ($0.isOrganizer ? 0 : 1) < ($1.isOrganizer ? 0 : 1) }
    }

    private var responseSummary: String {
        let yes = guests.filter { $0.response == .accepted }.count
        let no = guests.filter { $0.response == .declined }.count
        let maybe = guests.filter { $0.response == .tentative }.count
        let waiting = guests.filter { $0.response == .needsAction }.count
        return [yes > 0 ? "\(yes) yes" : nil, no > 0 ? "\(no) no" : nil, maybe > 0 ? "\(maybe) maybe" : nil,
                waiting > 0 ? "\(waiting) awaiting" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// How it repeats, in words ("Weekly on Monday, Wednesday"), or just that it does.
    private var recurrenceText: String {
        RepeatRule(lines: event.recurrence, start: event.start, calendar: model.calendar)?.summary(start: event.start, calendar: model.calendar)
            ?? "Repeats"
    }

    static func reminderText(_ minutes: Int) -> String {
        guard minutes > 0 else { return "At the start" }
        let reminder = Reminder(minutes: minutes)
        return "\(reminder.amount) \(reminder.unit.name(reminder.amount)) before"
    }

    private func displayLink(_ url: URL) -> String {
        let text = url.absoluteString.replacingOccurrences(of: "https://", with: "")
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    private func row(icon: String?, color: Color? = nil, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let color {
                    RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 14, height: 14).padding(.top, 8)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.icon).padding(.top, 2)
                }
            }
            .frame(width: 20)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func responseBadge(_ response: AttendeeResponse) -> some View {
        let (symbol, color): (String?, Color) = switch response {
        case .accepted: ("checkmark.circle.fill", Theme.hex(0x1E8E3E))
        case .declined: ("xmark.circle.fill", Theme.danger)
        case .tentative: ("questionmark.circle.fill", Theme.textTertiary)
        case .needsAction: (nil, .clear)
        }
        return Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).background(Circle().fill(Theme.surface))
            }
        }
    }

    private func rsvpButton(_ title: String, _ response: AttendeeResponse, current: AttendeeResponse) -> some View {
        Button(title) { model.respond(to: event, with: response) }
            .buttonStyle(.plain)
            .font(.pm(12.5, .medium))
            .foregroundStyle(current == response ? Theme.onSelection : Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(current == response ? Theme.selection : .clear))
            .overlay(Capsule().strokeBorder(current == response ? .clear : Theme.textTertiary.opacity(0.5)))
    }

    /// Opens Messages with every guest, for planning the meeting there.
    private func messageGuests() {
        guard let service = NSSharingService(named: .composeMessage) else { return }
        service.recipients = guests.filter { !$0.address.isSameMailbox(as: model.account.email) }.map(\.address.email)
        service.perform(withItems: [event.title])
    }
}

/// Text with its web addresses made into links.
enum LinkedText {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url,
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
