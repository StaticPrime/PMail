import AppKit
import PMailKit
import SwiftUI
import UniformTypeIdentifiers

/// The colors offered for a calendar, in rows from deep to light.
enum CalendarColors {
    static let palette = [
        "#AD1457", "#F4511E", "#E4C441", "#0B8043", "#3F51B5", "#8E24AA",
        "#D81B60", "#EF6C00", "#C0CA33", "#009688", "#7986CB", "#795548",
        "#D50000", "#F09300", "#7CB342", "#039BE5", "#B39DDB", "#616161",
        "#E67C73", "#F6BF26", "#33B679", "#4285F4", "#9E69AF", "#A79B8E",
    ]
}

/// Which calendar Settings ▸ Calendar should show, when asked from a calendar's ⋯ menu.
struct CalendarSettingsTarget: Equatable {
    var accountID: UUID
    var calendarID: String
}

/// A calendar's ⋯ menu: show just it, its settings, and its color.
struct CalendarRowMenu: View {
    let app: AppModel
    let model: CalendarViewModel
    let calendar: CalendarInfo
    let close: () -> Void
    @State private var custom: Color

    init(app: AppModel, model: CalendarViewModel, calendar: CalendarInfo, close: @escaping () -> Void) {
        self.app = app
        self.model = model
        self.calendar = calendar
        self.close = close
        _custom = State(initialValue: Theme.color(hexString: model.colorHex(of: calendar)) ?? Theme.accent)
    }

    var body: some View {
        let current = model.colorHex(of: calendar).uppercased()
        VStack(alignment: .leading, spacing: 4) {
            menuButton("Display This Only") {
                model.showOnly(calendar)
                close()
            }
            if !calendar.isTaskList {
                menuButton("Settings…") {
                    close()
                    app.calendarSettingsTarget = CalendarSettingsTarget(accountID: model.account.id, calendarID: calendar.id)
                    SettingsWindowController.show(app, pane: .calendar)
                }
            }
            Divider().padding(.vertical, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), spacing: 8) {
                ForEach(CalendarColors.palette, id: \.self) { hex in
                    Button {
                        model.setColor(calendar, to: hex)
                        close()
                    } label: {
                        ZStack {
                            Circle().fill(Theme.color(hexString: hex) ?? .gray).frame(width: 24, height: 24)
                            if hex.uppercased() == current {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(hex)")
                    .accessibilityAddTraits(hex.uppercased() == current ? .isSelected : [])
                }
            }
            // Any other color.
            HStack(spacing: 8) {
                ColorPicker("Other color", selection: $custom, supportsOpacity: false).labelsHidden()
                Text("Other color").font(.pm(12.5)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 6)
            .onChange(of: custom) { _, color in
                if let hex = Self.hex(color), hex.uppercased() != model.colorHex(of: calendar).uppercased() { model.setColor(calendar, to: hex) }
            }
        }
        .padding(12)
        .frame(width: 236)
        .background(Theme.surface)
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.pm(13.5)).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}

/// Settings ▸ Calendar: an account's video meeting for new events and its answers to conflicting invitations; and a
/// calendar's name, description, time zone, owner and color, the notifications new events get, its provider's email
/// notices, and exporting it. What its provider keeps goes to it; the rest is kept on this Mac.
struct CalendarSettingsPane: View {
    let app: AppModel
    @State private var accountID: UUID?
    @State private var calendarID: String?
    @State private var settings: CalendarSettings?
    @State private var saved: CalendarSettings?
    @State private var problem: String?
    @State private var saving: Task<Void, Never>?

    private var account: UUID? {
        if let accountID, app.accounts.accounts.contains(where: { $0.id == accountID }) { return accountID }
        return app.accounts.currentID ?? app.accounts.accounts.first?.id
    }
    private var model: CalendarViewModel? { account.flatMap { app.accounts.session(for: $0) }?.calendar }
    private var choices: [CalendarInfo] { model?.calendars.filter { !$0.isTaskList } ?? [] }
    private var calendar: CalendarInfo? {
        let id = calendarID ?? choices.first(where: \.isPrimary)?.id ?? choices.first?.id
        return choices.first { $0.id == id }
    }

    var body: some View {
        Form {
            if app.accounts.accounts.isEmpty {
                Text("Add an account to see its calendars’ settings here.").foregroundStyle(.secondary)
            } else {
                Section {
                    Picker("Account", selection: Binding(get: { account }, set: { accountID = $0; calendarID = nil })) {
                        ForEach(app.accounts.accounts) { account in Text(account.email).tag(Optional(account.id)) }
                    }
                }
                if let model {
                    // Which meeting is the account's own shows once its calendars are in.
                    if !model.calendars.isEmpty { videoMeetingSection(model) }
                    conflictSection(model)
                }
                Section {
                    Picker("Calendar", selection: Binding(get: { calendar?.id }, set: { calendarID = $0 })) {
                        ForEach(choices) { calendar in Text(calendar.name).tag(Optional(calendar.id)) }
                    }
                }
                if let model, let calendar, settings != nil {
                    sections(model, calendar)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if let model, choices.isEmpty, let error = model.error {
                    Text("This account’s calendars couldn’t be loaded: \(error)").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .settingsPane()
        .task(id: "\(account?.uuidString ?? "")|\(calendar?.id ?? "")") { await load() }
        .onAppear { follow(app.calendarSettingsTarget) }
        .onChange(of: app.calendarSettingsTarget) { _, target in follow(target) }
        .onChange(of: settings) { _, changed in scheduleSave(changed) }
    }

    /// The video meeting new events on the account's calendars are offered (its own: Meet, Teams or FaceTime; Zoom; or
    /// none), and for Zoom, whether that's the Personal Room, at once.
    private func videoMeetingSection(_ model: CalendarViewModel) -> some View {
        let own = model.ownConference
        let choice = model.videoMeeting
        let option = choice.option(own: own)
        return Section {
            Picker("New events", selection: Binding(get: { option }, set: { chosen in model.setVideoMeeting { $0.chosen = chosen } })) {
                ForEach(VideoMeetingChoice.options(own: own), id: \.self) { option in Text(option.title).tag(option) }
            }
            if option == .zoom {
                Toggle("Always use my Personal Room", isOn: Binding(get: { choice.alwaysUsesPersonalRoom },
                                                                    set: { on in model.setVideoMeeting { $0.alwaysUsesPersonalRoom = on } }))
                if choice.alwaysUsesPersonalRoom {
                    LabeledContent("Personal Room link") {
                        HStack(spacing: 8) {
                            // A whole invitation pasted is kept as its link.
                            TextField("Personal Room link", text: Binding(get: { model.videoMeeting.personalRoom }, set: { text in
                                model.setVideoMeeting { $0.personalRoom = VideoMeetingChoice.personalRoom(from: text) }
                            }), prompt: Text("https://zoom.us/j/…"))
                            .labelsHidden()
                            Button("Paste") {
                                guard let text = NSPasteboard.general.string(forType: .string) else { return }
                                model.setVideoMeeting { $0.personalRoom = VideoMeetingChoice.personalRoom(from: text) }
                            }
                        }
                    }
                    if !choice.personalRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, choice.personalRoomMeeting == nil {
                        Text("That isn’t a Zoom meeting link.").font(.pm(11.5)).foregroundStyle(Theme.danger)
                    }
                }
            }
        } header: {
            Text("Video meetings")
        } footer: {
            // A personal Microsoft account's calendars can't make Teams meetings, so it isn't offered: say why.
            let noTeams = model.account.kind == .microsoft && own == nil ? " Teams meetings need a Microsoft work or school account." : ""
            Text(Self.videoMeetingFooter(option, personalRoom: choice.alwaysUsesPersonalRoom) + noTeams)
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
    }

    private static func videoMeetingFooter(_ option: VideoMeetingChoice.Option, personalRoom: Bool) -> String {
        let keep = " Events that already have a meeting keep it."
        switch option {
        case .meet, .teams:
            return "New events on this account’s calendars are offered \(option.title)." + keep
        case .zoom where personalRoom:
            return "New events on this account’s calendars are offered your Personal Room, in one click. In Zoom, open "
                + "Meetings ▸ Personal Room, click Copy Invitation and paste it here."
        case .zoom:
            return "New events on this account’s calendars are offered a Zoom meeting: Zoom opens for you to schedule it, "
                + "and you paste the invitation Zoom copies." + keep
        case .faceTime:
            return "New events on this account’s calendars are offered a FaceTime link, made in FaceTime and pasted in." + keep
        case .noMeeting:
            return "New events on this account’s calendars aren’t offered a video meeting." + keep
        }
    }

    /// The account's automatic answer to invitations that overlap an event it's going to, and its message.
    private func conflictSection(_ model: CalendarViewModel) -> some View {
        Section {
            Picker("Automatic reply", selection: Binding(get: { model.preferences.conflictReply?.response },
                                                         set: { model.setConflictReply(response: $0) })) {
                Text("None").tag(AttendeeResponse?.none)
                Text("No").tag(Optional(AttendeeResponse.declined))
                Text("Maybe").tag(Optional(AttendeeResponse.tentative))
            }
            if model.preferences.conflictReply != nil {
                TextField("Message", text: Binding(get: { model.preferences.conflictReply?.message ?? "" },
                                                   set: { model.setConflictReply(message: $0) }), axis: .vertical)
                    .lineLimit(1...4)
            }
        } header: {
            Text("Invitations that conflict")
        } footer: {
            Text("For new invitations that overlap an event you’re going to on this account’s own calendars: PMail answers them for you "
                 + "while it’s open, and sends the organizer your message. Invitations already waiting, all-day ones and ones you’ve "
                 + "answered are left to you.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sections(_ model: CalendarViewModel, _ calendar: CalendarInfo) -> some View {
        let support = model.settingsSupport(for: calendar)
        Section("Calendar") {
            TextField("Name", text: field(\.name)).disabled(!support.name)
            if support.description {
                TextField("Description", text: field(\.description), axis: .vertical).lineLimit(2...5)
            }
            if support.timeZone {
                Picker("Time zone", selection: Binding(get: { settings?.timeZone }, set: { settings?.timeZone = $0 })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { zone in Text(Self.zoneName(zone)).tag(Optional(zone)) }
                }
            }
            if let owner = settings?.owner { LabeledContent("Owner", value: owner) }
            LabeledContent("Color") {
                HStack(spacing: 6) {
                    ForEach(CalendarColors.palette.prefix(12), id: \.self) { hex in
                        Button { settings?.colorHex = hex } label: {
                            Circle().fill(Theme.color(hexString: hex) ?? .gray).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(settings?.colorHex.uppercased() == hex ? 0.7 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Color", selection: Binding(get: { Theme.color(hexString: settings?.colorHex ?? "") ?? .gray },
                                                            set: { if let hex = CalendarRowMenu.hex($0) { settings?.colorHex = hex } }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
        Section {
            ForEach(Array((settings?.eventReminders ?? []).enumerated()), id: \.offset) { index, minutes in
                HStack {
                    let reminder = Reminder(minutes: minutes)
                    TextField("Amount", value: Binding(get: { reminder.amount }, set: { setReminder(index, Reminder(amount: max(0, $0), unit: reminder.unit)) }),
                              format: .number).frame(width: 60).labelsHidden()
                    Picker("Unit", selection: Binding(get: { reminder.unit }, set: { setReminder(index, Reminder(amount: reminder.amount, unit: $0)) })) {
                        ForEach(Reminder.Unit.allCases, id: \.self) { unit in Text(unit.name(reminder.amount)).tag(unit) }
                    }
                    .labelsHidden().frame(width: 110)
                    Text("before").foregroundStyle(.secondary)
                    Spacer()
                    Button { settings?.eventReminders.remove(at: index) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .help("Remove this notification")
                }
            }
            Button("Add Notification") { settings?.eventReminders.append(10) }
        } header: {
            Text("Event notifications")
        } footer: {
            Text(support.eventReminders ? "New events on this calendar start with these, here and on the calendar’s other apps."
                 : "New events on this calendar start with these. Kept on this Mac.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
        Section {
            ForEach(Array((settings?.allDayReminders ?? []).enumerated()), id: \.offset) { index, reminder in
                HStack {
                    Stepper(reminder.daysBefore == 1 ? "1 day before" : "\(reminder.daysBefore) days before",
                            value: Binding(get: { reminder.daysBefore }, set: { setAllDay(index, AllDayReminder(daysBefore: $0, minuteOfDay: $0 == 0 ? 0 : reminder.minuteOfDay)) }),
                            in: 0...28)
                    DatePicker("at", selection: Binding(get: { Self.time(reminder.minuteOfDay) },
                                                        set: { setAllDay(index, AllDayReminder(daysBefore: reminder.daysBefore, minuteOfDay: Self.minuteOfDay($0))) }),
                               displayedComponents: .hourAndMinute)
                        .disabled(reminder.daysBefore == 0)
                        .frame(width: 130)
                    Spacer()
                    Button { settings?.allDayReminders.remove(at: index) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .help("Remove this notification")
                }
            }
            Button("Add Notification") { settings?.allDayReminders.append(AllDayReminder(daysBefore: 1, minuteOfDay: 9 * 60)) }
        } header: {
            Text("All-day event notifications")
        } footer: {
            Text("New all-day events on this calendar start with these. On the day itself, a notification comes as the day starts. Kept on this Mac.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
        if support.emailNotices, settings?.emailNotices != nil {
            Section {
                ForEach(EmailNotice.allCases, id: \.self) { notice in
                    Picker(selection: Binding(get: { settings?.emailNotices?.contains(notice) == true },
                                              set: { on in if on { settings?.emailNotices?.insert(notice) } else { settings?.emailNotices?.remove(notice) } })) {
                        Text("Email").tag(true)
                        Text("None").tag(false)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(notice.title)
                            Text(notice.detail).font(.pm(11)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Email notifications")
            } footer: {
                Text("Emails the calendar’s provider sends you when this calendar changes.").font(.pm(11.5)).foregroundStyle(.secondary)
            }
        }
        Section {
            Button("Export Calendar…") { export(model, calendar) }
        } footer: {
            Text("Saves its events, from a year ago to two years ahead, as an iCalendar file other calendar apps can import.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
    }

    private func field(_ path: WritableKeyPath<CalendarSettings, String>) -> Binding<String> {
        Binding(get: { settings?[keyPath: path] ?? "" }, set: { settings?[keyPath: path] = $0 })
    }

    private func setReminder(_ index: Int, _ reminder: Reminder) {
        guard let settings, settings.eventReminders.indices.contains(index) else { return }
        self.settings?.eventReminders[index] = reminder.minutes
    }

    private func setAllDay(_ index: Int, _ reminder: AllDayReminder) {
        guard let settings, settings.allDayReminders.indices.contains(index) else { return }
        self.settings?.allDayReminders[index] = reminder
    }

    private func follow(_ target: CalendarSettingsTarget?) {
        guard let target else { return }
        accountID = target.accountID
        calendarID = target.calendarID
    }

    private func load() async {
        settings = nil
        saved = nil
        problem = nil
        // An account the window hasn't shown yet hasn't loaded its calendars; once they're in, this runs again.
        if let account { app.accounts.session(for: account)?.startCalendar() }
        guard let model, let calendar else { return }
        do {
            let loaded = try await model.settings(for: calendar)
            saved = loaded
            settings = loaded
        } catch {
            problem = "This calendar’s settings couldn’t be loaded: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Saves a moment after the last change, so typing a name doesn't save every letter.
    private func scheduleSave(_ changed: CalendarSettings?) {
        guard let changed, changed != saved, let model, let calendar else { return }
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                try await model.saveSettings(changed, for: calendar)
                saved = changed
            } catch {
                app.report(error, doing: "Saving “\(calendar.name)”’s settings")
            }
        }
    }

    private func export(_ model: CalendarViewModel, _ calendar: CalendarInfo) {
        let panel = NSSavePanel()
        panel.title = "Export Calendar"
        panel.nameFieldStringValue = "\(calendar.name).ics"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try await model.exportDocument(for: calendar)
                try Data(text.utf8).write(to: url, options: .atomic)
                app.show("Exported “\(calendar.name)”.")
            } catch {
                app.report(error, doing: "Exporting “\(calendar.name)”")
            }
        }
    }

    static func zoneName(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = zone.secondsFromGMT()
        let offset = String(format: "GMT%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3_600, abs(seconds) % 3_600 / 60)
        return "(\(offset)) " + identifier.replacingOccurrences(of: "_", with: " ")
    }

    static func time(_ minuteOfDay: Int) -> Date {
        Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: Date()) ?? Date()
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
