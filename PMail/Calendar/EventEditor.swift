import AppKit
import PMailKit
import SwiftUI

/// Making or changing an event (or a task, out of office or focus time): its kind, title, when and how it repeats,
/// video meeting, where, notifications, calendar, color, visibility, description, guests and what they may do, as suit
/// the kind; and for an event, finding a time when everyone's free.
struct EventEditor: View {
    enum DetailsTab: String { case details, findATime }
    enum GuestsTab: String { case guests, suggested }

    let app: AppModel
    let model: CalendarViewModel
    let contacts: ContactsViewModel
    @State var draft: EventDraft
    @State private var isSaving = false
    @State private var error: String?
    @State private var asksScope = false
    @State private var showsFaceTime = false
    @State private var colorMenu = PopUpMenu()
    @State private var detailsTab = DetailsTab.details
    @State private var guestsTab = GuestsTab.guests
    @State private var asksCustomRepeat = false
    /// A guest's address typed and not yet added (saving adds it).
    @State private var guestText = ""
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, model: CalendarViewModel, contacts: ContactsViewModel, draft: EventDraft) {
        self.app = app
        self.model = model
        self.contacts = contacts
        _draft = State(initialValue: draft)
        _showsFaceTime = State(initialValue: !draft.faceTimeLink.isEmpty)
        #if DEBUG
        // `-PMEditorTab findATime`, `-PMGuestsTab suggested` and `-PMRepeatSheet YES` open those.
        let defaults = UserDefaults.standard
        if let tab = defaults.string(forKey: "PMEditorTab").flatMap(DetailsTab.init(rawValue:)) { _detailsTab = State(initialValue: tab) }
        if let tab = defaults.string(forKey: "PMGuestsTab").flatMap(GuestsTab.init(rawValue:)) { _guestsTab = State(initialValue: tab) }
        _asksCustomRepeat = State(initialValue: defaults.bool(forKey: "PMRepeatSheet"))
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconButton(symbol: "xmark", help: "Close without saving") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                TextField("Add title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.pm(22))
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 2) }
                    .accessibilityLabel("Title")
                FilledPillButton(title: isSaving ? "Saving…" : "Save", isDisabled: isSaving) { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
            typeRow
                .padding(.horizontal, 68)
                .padding(.bottom, 12)
            whenRow
                .padding(.horizontal, 68)
                .padding(.bottom, 14)
            if let error {
                Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 68).padding(.bottom, 8)
            }
            Divider().overlay(Theme.divider)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if draft.type == .event {
                        EditorTabs(tabs: [(DetailsTab.details, "Event details"), (.findATime, "Find a time")], selection: $detailsTab)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                    if draft.type == .event, detailsTab == .findATime {
                        FindATimeView(model: model, draft: $draft)
                    } else {
                        ScrollView { details.padding(20) }
                    }
                }
                Divider().overlay(Theme.divider)
                Group {
                    if draft.type == .event {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorTabs(tabs: [(GuestsTab.guests, "Guests"), (.suggested, "Suggested times")], selection: $guestsTab)
                            if guestsTab == .suggested {
                                SuggestedTimesView(model: model, draft: $draft)
                            } else {
                                guestsColumn
                            }
                        }
                        .padding(.top, 8)
                    } else {
                        aboutColumn.padding(.top, 20)
                    }
                }
                .frame(width: 300)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 940, height: 680)
        .background(Theme.surface)
        .confirmationDialog("Save recurring event", isPresented: $asksScope) {
            Button("This event") { commit(scope: .thisEvent) }
            Button("All events") { commit(scope: .allEvents) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $asksCustomRepeat) {
            CustomRepeatSheet(start: draft.start, isAllDay: draft.isAllDay, calendar: model.calendar,
                              rule: draft.repeatRule ?? RepeatRule(frequency: .weekly, weekdays: [model.calendar.component(.weekday, from: draft.start)])) { rule in
                draft.repeatRule = rule
                draft.keepsOwnRule = false
            }
        }
    }

    // MARK: Kind

    /// Event, task, out of office or focus time, where the item can be more than one.
    @ViewBuilder
    private var typeRow: some View {
        let types = model.types(for: draft)
        if types.count > 1 {
            HStack(spacing: 8) {
                ForEach(types, id: \.self) { type in
                    EventTypeChoice(type: type, isSelected: draft.type == type) {
                        model.retype(&draft, as: type)
                        error = nil
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: When

    @ViewBuilder
    private var whenRow: some View {
        if draft.isTask {
            // A task is due on a day.
            HStack(spacing: 10) {
                Text("Due").foregroundStyle(Theme.textSecondary)
                DatePicker("Due", selection: taskDayBinding, displayedComponents: [.date])
                    .labelsHidden()
                Spacer()
            }
            .font(.pm(13))
        } else {
            HStack(spacing: 10) {
                DatePicker("Starts", selection: startBinding, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                Text("to").foregroundStyle(Theme.textSecondary)
                DatePicker("Ends", selection: endBinding, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                // Focus time is a stretch of hours.
                if draft.type != .focusTime {
                    Toggle("All day", isOn: allDayBinding).toggleStyle(.checkbox).padding(.leading, 12)
                }
                repeatPicker
                Spacer()
                Text(TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier)
                    .font(.pm(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.pm(13))
        }
    }

    /// A task's day: the whole day.
    private var taskDayBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { value in
            draft.start = model.calendar.startOfDay(for: value)
            draft.end = model.calendar.date(byAdding: .day, value: 1, to: draft.start) ?? draft.start.addingTimeInterval(86_400)
        })
    }

    /// For all-day events the end shown is the last day (iCalendar keeps the day after).
    private var endBinding: Binding<Date> {
        Binding(get: {
            draft.isAllDay ? (model.calendar.date(byAdding: .day, value: -1, to: draft.end) ?? draft.end) : draft.end
        }, set: { value in
            draft.end = draft.isAllDay ? (model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: value)) ?? value) : value
        })
    }

    /// Moving the start keeps the length.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { value in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = draft.isAllDay ? model.calendar.startOfDay(for: value) : value
            draft.end = draft.start.addingTimeInterval(max(length, draft.isAllDay ? 86_400 : 60))
        })
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { draft.isAllDay }, set: { allDay in
            draft.isAllDay = allDay
            if allDay {
                draft.start = model.calendar.startOfDay(for: draft.start)
                draft.end = model.calendar.date(byAdding: .day, value: 1, to: draft.start) ?? draft.start
                draft.reminders = []
            } else {
                draft.start = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
                draft.end = draft.start.addingTimeInterval(3600)
                draft.reminders = [Reminder(minutes: 10)]
            }
        })
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            // An event's details have a tab instead.
            if draft.type != .event {
                Text(draft.isTask ? "Task details" : "Event details").font(.pm(14, .medium)).foregroundStyle(Theme.accent)
            }
            if draft.isTask {
                taskRows
            } else {
                eventRows
            }
            field(icon: "text.alignleft") {
                if draft.isTask {
                    // A task's notes are plain text, which is all task lists keep.
                    TextEditor(text: $draft.notes)
                        .font(.pm(13))
                        .frame(minHeight: 130)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
                        .overlay(alignment: .topLeading) {
                            if draft.notes.isEmpty {
                                Text("Add description").font(.pm(13)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 9).padding(.vertical, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                } else {
                    EventNotesEditor(initialHTML: draft.notesHTML, initialText: draft.notes) { plain, html in
                        draft.notes = plain
                        draft.notesHTML = html
                    }
                }
            }
        }
    }

    /// A task's list, and whether it's done.
    @ViewBuilder
    private var taskRows: some View {
        field(icon: "checklist") {
            Picker("List", selection: $draft.calendarID) {
                ForEach(model.taskLists) { list in
                    Text(list.name).tag(list.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!draft.isNew)
        }
        if !draft.isNew {
            field(icon: "checkmark.circle") {
                Toggle("Done", isOn: $draft.isCompleted).toggleStyle(.checkbox).padding(.top, 5)
            }
        }
    }

    /// An event's video meeting and place (out of office and focus time have neither), reminder, calendar, color and
    /// whether it shows as busy, and for out of office and focus time, whether meetings then are declined.
    @ViewBuilder
    private var eventRows: some View {
        if draft.type == .event {
            conferenceRow
            // Over the rows below it, for the places it suggests.
            field(icon: "mappin.and.ellipse") {
                LocationField(location: $draft.location)
            }
            .zIndex(1)
        }
        remindersRow
        field(icon: "calendar") {
            HStack(spacing: 12) {
                Picker("Calendar", selection: $draft.calendarID) {
                    ForEach(model.eventCalendars) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(draft.original != nil)
                Button { showColorMenu() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(hexString: draft.colorHex) ?? calendarColor).frame(width: 16, height: 16)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(MenuAnchor(menu: colorMenu))
                .fixedSize()
                .help("Event color")
                // Out of office and focus time are always busy.
                if draft.type == .event {
                    Picker("Show as", selection: $draft.availability) {
                        Text("Busy").tag(EventAvailability.busy)
                        Text("Free").tag(EventAvailability.free)
                    }
                    .labelsHidden()
                    .fixedSize()
                    if !model.features.visibilities.isEmpty {
                        Picker("Visibility", selection: $draft.visibility) {
                            ForEach(model.features.visibilities, id: \.self) { visibility in
                                Text(visibility.name).tag(visibility)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Private: people who can see your calendar but not change it see only that you’re busy. Public: they see the details.")
                    }
                }
            }
        }
        if model.canDecline(draft) { declineRow }
    }

    private var calendarColor: Color { model.color(for: model.calendarInfo(draft.calendarID) ?? CalendarInfo(id: "", name: "")) }

    /// The event's own color, or its calendar's.
    private func showColorMenu() {
        colorMenu.show([PopUpMenu.Item(title: "Calendar color", swatch: calendarColor, isChecked: draft.colorHex == nil) { draft.colorHex = nil },
                        .separator]
            + Theme.eventColors.map { color in
                PopUpMenu.Item(title: color.name, swatch: Theme.color(hexString: color.hex), isChecked: draft.colorHex == color.hex) {
                    draft.colorHex = color.hex
                }
            })
    }

    /// Declining meetings during out of office or focus time, with a message for the people whose meetings are declined.
    private var declineRow: some View {
        field(icon: "person.crop.circle.badge.xmark") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Decline meetings during this time", isOn: $draft.declinesInvitations)
                    .toggleStyle(.checkbox)
                    .padding(.top, 5)
                if draft.declinesInvitations {
                    TextField("Message for declined meetings (optional)", text: $draft.declineMessage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 420)
                }
                Text("Where the calendar can: the main calendar of a work or school account.")
                    .font(.pm(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// The video meeting: the calendar's own (Meet or Teams) with one click, or a FaceTime link pasted in.
    @ViewBuilder
    private var conferenceRow: some View {
        let native = model.conferenceKind(for: draft.calendarID)
        field(icon: "video") {
            VStack(alignment: .leading, spacing: 8) {
                if let conference = draft.conference, conference.kind != .faceTime || draft.faceTimeLink.isEmpty {
                    HStack(spacing: 10) {
                        FilledPillButton(title: "Join with \(conference.kind.displayName)") { NSWorkspace.shared.open(conference.joinURL) }
                        Text(conference.joinURL.host ?? "").font(.pm(12)).foregroundStyle(Theme.textSecondary)
                        IconButton(symbol: "xmark", help: "Remove the video meeting", size: 28, iconSize: 11) {
                            draft.conference = nil
                            draft.faceTimeLink = ""
                        }
                    }
                } else if let native {
                    if draft.addsNativeConference {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            Text("\(native.displayName) video conferencing will be added when you save.").font(.pm(13))
                            IconButton(symbol: "xmark", help: "Don’t add it", size: 28, iconSize: 11) { draft.addsNativeConference = false }
                        }
                    } else {
                        OutlinePillButton(title: "Add \(native.displayName) video conferencing") { draft.addsNativeConference = true }
                    }
                } else if showsFaceTime {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Paste a FaceTime link", text: $draft.faceTimeLink).textFieldStyle(.roundedBorder).frame(width: 340)
                            Button("Paste") { pasteFaceTimeLink() }
                            Button("Open FaceTime") { openFaceTime() }
                        }
                        Text("In FaceTime, click Create Link, choose Copy Link, then paste it here. Guests click the link to join, on a Mac, iPhone or iPad, or in a web browser.")
                            .font(.pm(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                        if !draft.faceTimeLink.isEmpty, !ConferenceDetector.isFaceTimeLink(draft.faceTimeLink) {
                            Text("That doesn’t look like a FaceTime link; it will be saved as a video call link.")
                                .font(.pm(11.5)).foregroundStyle(Theme.danger)
                        }
                    }
                } else {
                    OutlinePillButton(title: "Add FaceTime link") {
                        showsFaceTime = true
                        pasteFaceTimeLink(onlyIfFaceTime: true)
                    }
                }
            }
        }
    }

    private func pasteFaceTimeLink(onlyIfFaceTime: Bool = false) {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if !onlyIfFaceTime || ConferenceDetector.isFaceTimeLink(text) { draft.faceTimeLink = text }
    }

    private func openFaceTime() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: About the kind

    /// What a task, out of office or focus time is, and where it's kept.
    private var aboutColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(draft.type.name, systemImage: draft.type.symbol)
                .font(.pm(14, .medium))
                .foregroundStyle(Theme.accent)
            Text(about)
                .font(.pm(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var about: String {
        switch draft.type {
        case .task:
            let place = TaskLists.listID(from: draft.calendarID) == LocalTaskService.listID
                ? "This account’s tasks are kept on this Mac."
                : "It’s saved in \(model.calendarInfo(draft.calendarID)?.name ?? "the task list"), with the account’s other tasks."
            return "A task is due on a day rather than at a time, and shows at the top of that day. Click its circle when it’s done. " + place
        case .outOfOffice:
            return "Shows you’re away. Where the calendar can’t keep out of office, it’s saved as an event and shown as out of office on this Mac."
        case .focusTime:
            return "Time set aside to work without interruptions. Where the calendar can’t keep focus time, it’s saved as an event and shown as focus time on this Mac."
        case .event:
            return ""
        }
    }

    // MARK: Notifications

    /// The event's notifications, each so many minutes, hours, days or weeks before, as many as the calendar keeps.
    private var remindersRow: some View {
        field(icon: "bell") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(draft.reminders.enumerated()), id: \.offset) { index, reminder in
                    HStack(spacing: 8) {
                        TextField("Amount", value: reminderAmount(index), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .accessibilityLabel("Notification \(index + 1)")
                        Picker("Unit", selection: reminderUnit(index)) {
                            ForEach(Reminder.Unit.allCases, id: \.self) { unit in
                                Text(unit.name(reminder.amount)).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("before").foregroundStyle(Theme.textSecondary)
                        IconButton(symbol: "xmark", help: "Remove this notification", size: 26, iconSize: 10) {
                            if draft.reminders.indices.contains(index) { draft.reminders.remove(at: index) }
                        }
                    }
                    .font(.pm(13))
                }
                if draft.reminders.count < model.features.maximumReminders {
                    Button(draft.reminders.isEmpty ? "Add a notification" : "Add notification") {
                        draft.reminders.append(Reminder(minutes: draft.isAllDay ? 1_440 : (draft.reminders.isEmpty ? 10 : 60)))
                    }
                    .buttonStyle(.link)
                    .font(.pm(13))
                    .padding(.top, draft.reminders.isEmpty ? 5 : 0)
                }
            }
        }
    }

    private func reminderAmount(_ index: Int) -> Binding<Int> {
        Binding(get: { draft.reminders.indices.contains(index) ? draft.reminders[index].amount : 0 },
                set: { value in if draft.reminders.indices.contains(index) { draft.reminders[index].amount = max(0, min(value, 999)) } })
    }

    private func reminderUnit(_ index: Int) -> Binding<Reminder.Unit> {
        Binding(get: { draft.reminders.indices.contains(index) ? draft.reminders[index].unit : .minutes },
                set: { value in if draft.reminders.indices.contains(index) { draft.reminders[index].unit = value } })
    }

    // MARK: Repeating

    private enum RepeatChoice: Hashable {
        case never, own, current, preset(Int), custom
    }

    /// Does not repeat, the usual choices for the day, or a custom rule.
    @ViewBuilder
    private var repeatPicker: some View {
        if !draft.isTask {
            let presets = RepeatRule.presets(for: draft.start, calendar: model.calendar)
            Picker("Repeat", selection: repeatChoice(presets)) {
                Text("Does not repeat").tag(RepeatChoice.never)
                if draft.keepsOwnRule { Text("Repeats by its own rule").tag(RepeatChoice.own) }
                if let rule = draft.repeatRule, !presets.contains(rule.normalized(start: draft.start, calendar: model.calendar)) {
                    Text(rule.summary(start: draft.start, calendar: model.calendar)).tag(RepeatChoice.current)
                }
                ForEach(presets.indices, id: \.self) { index in
                    Text(presetTitle(presets[index])).tag(RepeatChoice.preset(index))
                }
                Divider()
                Text("Custom…").tag(RepeatChoice.custom)
            }
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
            .accessibilityLabel("Repeat")
        }
    }

    private func presetTitle(_ rule: RepeatRule) -> String {
        let text = rule.summary(start: draft.start, calendar: model.calendar)
        return text == "Every weekday" ? "Every weekday (Monday to Friday)" : text
    }

    private func repeatChoice(_ presets: [RepeatRule]) -> Binding<RepeatChoice> {
        Binding(get: {
            if draft.keepsOwnRule { return .own }
            guard let rule = draft.repeatRule?.normalized(start: draft.start, calendar: model.calendar) else { return .never }
            return presets.firstIndex(of: rule).map { .preset($0) } ?? .current
        }, set: { choice in
            switch choice {
            case .never:
                draft.repeatRule = nil
                draft.keepsOwnRule = false
            case let .preset(index):
                draft.repeatRule = presets[index]
                draft.keepsOwnRule = false
            case .custom:
                asksCustomRepeat = true
            case .own, .current:
                break
            }
        })
    }

    // MARK: Guests

    private var guestsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuestField(guests: $draft.guests, text: $guestText, contacts: contacts)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !draft.guests.isEmpty {
                        HStack(spacing: 10) {
                            AccountAvatar(account: model.account, size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.account.name.isEmpty ? model.account.email : model.account.name).font(.pm(12.5))
                                Text("Organizer").font(.pm(11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    ForEach(Array(draft.guests.enumerated()), id: \.offset) { index, guest in
                        HStack(spacing: 10) {
                            Avatar(name: guest.name ?? "", email: guest.email, size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(guest.displayName).font(.pm(12.5)).lineLimit(1)
                                if guest.name != nil { Text(guest.email).font(.pm(11)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                            }
                            Spacer()
                            IconButton(symbol: "xmark", help: "Remove \(guest.displayName)", size: 24, iconSize: 10) { draft.guests.remove(at: index) }
                        }
                    }
                }
            }
            if !draft.guests.isEmpty {
                Text("Guests get an invitation by email when you save.").font(.pm(11.5)).foregroundStyle(Theme.textTertiary)
            }
            if !model.features.guestPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest permissions").font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                    ForEach(model.features.guestPermissions, id: \.self) { permission in
                        Toggle(permission.name, isOn: permissionBinding(permission)).toggleStyle(.checkbox).font(.pm(13))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func permissionBinding(_ permission: GuestPermission) -> Binding<Bool> {
        switch permission {
        case .modify: $draft.guestsCanModify
        case .inviteOthers: $draft.guestsCanInviteOthers
        case .seeGuestList: $draft.guestsCanSeeOtherGuests
        }
    }

    private func field(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.icon).frame(width: 22).padding(.top, 6)
            content()
        }
    }

    // MARK: Saving

    private func save() {
        // A guest typed but not added with Return is added now, rather than lost.
        let typed = guestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.type == .event, !typed.isEmpty {
            let added = TypedAddresses.adding(typed, to: draft.guests)
            guard added.dropFirst(draft.guests.count).allSatisfy({ TypedAddresses.isComplete($0.email) }), added.count > draft.guests.count else {
                error = "“\(typed)” isn’t a complete email address."
                return
            }
            draft.guests = added
            guestText = ""
        }
        guard draft.isTask || draft.end > draft.start else {
            error = "The event has to end after it starts."
            return
        }
        if draft.original?.isRecurring == true {
            // A new rule is for the whole series.
            if draft.changesRepeat { commit(scope: .allEvents) } else { asksScope = true }
        } else {
            commit(scope: .thisEvent)
        }
    }

    private func commit(scope: RecurrenceScope) {
        draft.scope = scope
        isSaving = true
        error = nil
        let saving = draft
        Task {
            do {
                let outcome = try await model.save(saving)
                if outcome == .waiting {
                    app.show("Saved on this Mac. It’ll go to your \(saving.isTask ? "tasks" : "calendar") when you’re back online.")
                } else {
                    app.show(saving.isNew ? (saving.isTask ? "Task saved." : "Event saved.") : "Changes saved.")
                }
                dismiss()
            } catch {
                isSaving = false
                self.error = "It wasn’t saved: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}

/// Adding guests by name or address, with suggestions from contacts.
private struct GuestField: View {
    @Binding var guests: [MailAddress]
    @Binding var text: String
    let contacts: ContactsViewModel
    @FocusState private var focused: Bool

    var body: some View {
        let suggestions = contacts.suggestions(for: text, excluding: guests)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add guests", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(TypedAddresses.pick(suggestions.first, typed: text)) }
                .onChange(of: text) { _, new in
                    if RecipientParser.hasSeparator(new) { add(nil) }
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { add(nil) } }
            if focused, !text.isEmpty, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.email) { address in
                        HStack(spacing: 8) {
                            Avatar(name: address.name ?? "", email: address.email, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(address.name ?? address.email).font(.pm(12.5))
                                if address.name != nil { Text(address.email).font(.pm(11)).foregroundStyle(Theme.textSecondary) }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                        .onTapGesture { add(address) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            }
        }
    }

    /// Adds the suggestion picked, or every whole address typed (what isn't an address stays to be fixed).
    private func add(_ suggestion: MailAddress?) {
        if let suggestion {
            if !guests.contains(where: { $0.isSameMailbox(as: suggestion) }) { guests.append(suggestion) }
            text = ""
            return
        }
        let typed = RecipientParser.parse(text)
        guard !typed.isEmpty, typed.allSatisfy({ TypedAddresses.isComplete($0.email) }) else { return }
        guests = TypedAddresses.adding(text, to: guests)
        text = ""
    }
}
