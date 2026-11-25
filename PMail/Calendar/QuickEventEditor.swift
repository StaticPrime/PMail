import PMailKit
import SwiftUI

/// Making or changing an event beside its block in the day, week or month view, with the calendar still in reach around
/// it (a click on another time or day moves the event there): its title, kind and time, guests, video meeting, place,
/// description and calendar. More Options goes on in the full editor, changes and all.
struct QuickEventEditor: View {
    let app: AppModel
    let model: CalendarViewModel
    /// The draft as the window last drew it, for the moment it closes.
    let current: EventDraft
    /// A guest's address typed and not yet added (saving adds it).
    @State private var guestText = ""
    @State private var error: String?
    @State private var asksScope = false
    @FocusState private var titleFocused: Bool

    private var value: EventDraft { model.quickDraft ?? current }

    private var edit: Binding<EventDraft> {
        Binding(get: { model.quickDraft ?? current }, set: { model.quickDraft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Add title", text: edit.title)
                    .textFieldStyle(.plain)
                    .font(.pm(20))
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 2) }
                    .focused($titleFocused)
                    .onSubmit { save() }
                    .accessibilityLabel("Title")
                IconButton(symbol: "xmark", help: "Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            typeRow
            whenRow
            if value.type == .event {
                if let contacts = model.contacts { guestsRow(contacts) }
                VideoMeetingRow(model: model, draft: edit, compact: true)
                // Over the rows below it, for the places it suggests.
                EditorField(icon: "mappin.and.ellipse") { LocationField(location: edit.location) }
                    .zIndex(1)
            }
            descriptionRow
            calendarRow
            if let error {
                Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                OutlinePillButton(title: "More Options") { moreOptions() }
                    .help("Everything about the event, in the full editor")
                FilledPillButton(title: "Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.divider))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .onAppear { DispatchQueue.main.async { titleFocused = true } }
        .confirmationDialog("Save recurring event", isPresented: $asksScope) {
            Button("This event") { model.saveQuickDraft(value, scope: .thisEvent) }
            Button("All events") { model.saveQuickDraft(value, scope: .allEvents) }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(value.isNew ? "New event" : "Change event")
    }

    // MARK: Kind

    /// Event, task, out of office or focus time, where the item can be more than one.
    @ViewBuilder
    private var typeRow: some View {
        let types = model.types(for: value)
        if types.count > 1 {
            HStack(spacing: 6) {
                ForEach(types, id: \.self) { type in
                    EventTypeChoice(type: type, isSelected: value.type == type) {
                        model.retype(&edit.wrappedValue, as: type)
                        error = nil
                    }
                }
            }
        }
    }

    // MARK: When

    @ViewBuilder
    private var whenRow: some View {
        if value.isTask {
            // A task is due on a day.
            EditorField(icon: "clock") {
                HStack(spacing: 8) {
                    Text("Due").foregroundStyle(Theme.textSecondary)
                    DatePicker("Due", selection: taskDayBinding, displayedComponents: [.date]).labelsHidden()
                }
                .font(.pm(13))
                .padding(.top, 2)
            }
        } else {
            EditorField(icon: "clock") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if value.isAllDay {
                            DatePicker("Starts", selection: startBinding, displayedComponents: [.date]).labelsHidden()
                            Text("–").foregroundStyle(Theme.textSecondary)
                            DatePicker("Ends", selection: lastDayBinding, in: value.start..., displayedComponents: [.date]).labelsHidden()
                        } else {
                            DatePicker("Day", selection: dayBinding, displayedComponents: [.date]).labelsHidden()
                            DatePicker("Starts", selection: startBinding, displayedComponents: [.hourAndMinute]).labelsHidden()
                            Text("–").foregroundStyle(Theme.textSecondary)
                            DatePicker("Ends", selection: edit.end, displayedComponents: [.hourAndMinute]).labelsHidden()
                        }
                    }
                    HStack(spacing: 12) {
                        // Focus time is a stretch of hours.
                        if value.type != .focusTime {
                            Toggle("All day", isOn: allDayBinding).toggleStyle(.checkbox)
                        }
                        Text(repeatText).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            .help("More Options changes how it repeats")
                    }
                    .font(.pm(12.5))
                }
                .font(.pm(13))
                .padding(.top, 2)
            }
        }
    }

    private var repeatText: String {
        if value.keepsOwnRule { return "Repeats by its own rule" }
        return value.repeatRule?.summary(start: value.start, calendar: model.calendar) ?? "Does not repeat"
    }

    /// A timed event's day: the same hours on another day.
    private var dayBinding: Binding<Date> {
        Binding(get: { value.start }, set: { day in
            var draft = value
            let length = draft.end.timeIntervalSince(draft.start)
            let time = model.calendar.dateComponents([.hour, .minute], from: draft.start)
            draft.start = model.calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
            draft.end = draft.start.addingTimeInterval(length)
            edit.wrappedValue = draft
        })
    }

    /// Moving the start keeps the length.
    private var startBinding: Binding<Date> {
        Binding(get: { value.start }, set: { start in
            var draft = value
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = draft.isAllDay ? model.calendar.startOfDay(for: start) : start
            draft.end = draft.start.addingTimeInterval(max(length, draft.isAllDay ? 86_400 : 60))
            edit.wrappedValue = draft
        })
    }

    /// For all-day events the end shown is the last day (iCalendar keeps the day after).
    private var lastDayBinding: Binding<Date> {
        Binding(get: { model.calendar.date(byAdding: .day, value: -1, to: value.end) ?? value.end }, set: { day in
            edit.wrappedValue.end = model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: day)) ?? day
        })
    }

    /// A task's day: the whole day.
    private var taskDayBinding: Binding<Date> {
        Binding(get: { value.start }, set: { day in
            var draft = value
            draft.start = model.calendar.startOfDay(for: day)
            draft.end = model.calendar.date(byAdding: .day, value: 1, to: draft.start) ?? draft.start.addingTimeInterval(86_400)
            edit.wrappedValue = draft
        })
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { value.isAllDay }, set: { allDay in
            var draft = value
            draft.isAllDay = allDay
            if allDay {
                draft.start = model.calendar.startOfDay(for: draft.start)
                draft.end = model.calendar.date(byAdding: .day, value: 1, to: draft.start) ?? draft.start
            } else {
                draft.start = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
                draft.end = draft.start.addingTimeInterval(3_600)
            }
            draft.reminders = model.defaultReminders(for: draft.calendarID, allDay: allDay)
            edit.wrappedValue = draft
        })
    }

    // MARK: Guests, description, calendar

    private func guestsRow(_ contacts: ContactsViewModel) -> some View {
        EditorField(icon: "person.2") {
            VStack(alignment: .leading, spacing: 6) {
                GuestField(guests: edit.guests, text: $guestText, contacts: contacts)
                let shown = value.guests.prefix(4)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, guest in
                    HStack(spacing: 8) {
                        Avatar(name: guest.name ?? "", email: guest.email, size: 22)
                        Text(guest.displayName).font(.pm(12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        IconButton(symbol: "xmark", help: "Remove \(guest.displayName)", size: 22, iconSize: 9) {
                            if edit.wrappedValue.guests.indices.contains(index) { edit.wrappedValue.guests.remove(at: index) }
                        }
                    }
                }
                if value.guests.count > shown.count {
                    Text("and \(value.guests.count - shown.count) more").font(.pm(12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        // Over the rows below it, for the people it suggests.
        .zIndex(2)
    }

    /// The description as plain text; one with formatting is changed under More Options, where its formatting is kept.
    private var descriptionRow: some View {
        EditorField(icon: "text.alignleft") {
            if value.notesHTML == nil {
                TextField("Add description", text: edit.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.pm(13))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.notes).font(.pm(13)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text("More Options changes its formatted description.").font(.pm(11.5)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 5)
            }
        }
    }

    /// Its calendar (or task list), and what it's set to show as and remind of.
    private var calendarRow: some View {
        EditorField(icon: value.isTask ? "checklist" : "calendar") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Picker(value.isTask ? "List" : "Calendar", selection: edit.calendarID) {
                        ForEach(value.isTask ? model.taskLists : model.eventCalendars) { calendar in
                            Text(calendar.name).tag(calendar.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // An event stays on its calendar; More Options says the same.
                    .disabled(!value.isNew)
                    Circle().fill(model.color(for: value.preview)).frame(width: 12, height: 12)
                }
                if !value.isTask {
                    Text(settingsText).font(.pm(11.5)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var settingsText: String {
        let reminders = value.reminders
        let notifications = switch reminders.count {
        case 0: "No notifications"
        case 1: EventDetailsView.reminderText(reminders[0].minutes)
        default: "\(reminders.count) notifications"
        }
        return [value.availability == .busy ? "Busy" : "Free", value.visibility == .default ? nil : value.visibility.name, notifications]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Closing

    /// Closes without saving, asking first whether to discard what was entered.
    private func close() {
        model.closeQuickEditor(typed: !guestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// More Options: the full editor, with a whole address typed and not yet added going along.
    private func moreOptions() {
        var going = value
        let typed = guestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if going.type == .event, !typed.isEmpty {
            let added = TypedAddresses.adding(typed, to: going.guests)
            if added.dropFirst(going.guests.count).allSatisfy({ TypedAddresses.isComplete($0.email) }) { going.guests = added }
        }
        model.openFullEditor(going)
    }

    private func save() {
        var saving = value
        let problem = model.checkedForSaving(&saving, typedGuest: &guestText)
        edit.wrappedValue = saving
        if let problem {
            error = problem
            return
        }
        if saving.original?.isRecurring == true {
            // A new rule is for the whole series.
            if saving.changesRepeat { model.saveQuickDraft(saving, scope: .allEvents) } else { asksScope = true }
        } else {
            model.saveQuickDraft(saving, scope: .thisEvent)
        }
    }
}

/// Where the quick editor's event is drawn in the day, week or month view, for putting the editor beside it.
struct QuickDraftPlace: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The quick editor, beside its event's block: to the right where there's room, else to the left, as high as the block,
/// and kept inside the calendar. Without a block in view (the event is on a day not showing), at the top right.
struct QuickEditorLayer: View {
    let app: AppModel
    let model: CalendarViewModel
    let block: CGRect?
    let area: CGSize
    @State private var size = CGSize(width: 440, height: 460)

    var body: some View {
        if let draft = model.quickDraft {
            QuickEventEditor(app: app, model: model, current: draft)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(x: origin.x, y: origin.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var origin: CGPoint {
        let gap: CGFloat = 12, margin: CGFloat = 12
        guard let block else { return CGPoint(x: max(margin, area.width - size.width - margin), y: margin) }
        var x = block.maxX + gap
        if x + size.width > area.width - margin { x = block.minX - gap - size.width }
        if x < margin { x = max(margin, (area.width - size.width) / 2) }
        let y = min(max(block.minY - 24, margin), max(margin, area.height - size.height - margin))
        return CGPoint(x: x, y: y)
    }
}

/// The quick editor's own block, bar or chip: raised over the others, and its place told to the editor beside it.
struct QuickDraftMark: ViewModifier {
    let isDraft: Bool

    func body(content: Content) -> some View {
        if isDraft {
            content
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                .anchorPreference(key: QuickDraftPlace.self, value: .bounds) { $0 }
                .zIndex(1)
        } else {
            content
        }
    }
}
