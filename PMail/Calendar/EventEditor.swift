import AppKit
import PMailKit
import SwiftUI

/// Making or changing an event: title, when, video meeting, where, reminder, calendar and color, description and
/// guests.
struct EventEditor: View {
    let app: AppModel
    let model: CalendarViewModel
    let contacts: ContactsViewModel
    @State var draft: EventDraft
    @State private var isSaving = false
    @State private var error: String?
    @State private var asksScope = false
    @State private var showsFaceTime = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, model: CalendarViewModel, contacts: ContactsViewModel, draft: EventDraft) {
        self.app = app
        self.model = model
        self.contacts = contacts
        _draft = State(initialValue: draft)
        _showsFaceTime = State(initialValue: !draft.faceTimeLink.isEmpty)
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
            whenRow
                .padding(.horizontal, 68)
                .padding(.bottom, 14)
            if let error {
                Text(error).font(.pm(12.5)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 68).padding(.bottom, 8)
            }
            Divider().overlay(Theme.divider)
            HStack(alignment: .top, spacing: 0) {
                ScrollView { details.padding(20) }
                Divider().overlay(Theme.divider)
                guestsColumn
                    .frame(width: 300)
                    .padding(20)
            }
        }
        .frame(width: 920, height: 640)
        .background(Theme.surface)
        .confirmationDialog("Save recurring event", isPresented: $asksScope) {
            Button("This event") { commit(scope: .thisEvent) }
            Button("All events") { commit(scope: .allEvents) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: When

    private var whenRow: some View {
        HStack(spacing: 10) {
            DatePicker("Starts", selection: startBinding, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                .labelsHidden()
            Text("to").foregroundStyle(Theme.textSecondary)
            DatePicker("Ends", selection: endBinding, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                .labelsHidden()
            Toggle("All day", isOn: allDayBinding).toggleStyle(.checkbox).padding(.leading, 12)
            Spacer()
            Text(TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier)
                .font(.pm(12))
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.pm(13))
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
                draft.reminderMinutes = nil
            } else {
                draft.start = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
                draft.end = draft.start.addingTimeInterval(3600)
                draft.reminderMinutes = 10
            }
        })
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Event details").font(.pm(14, .medium)).foregroundStyle(Theme.accent)
            conferenceRow
            field(icon: "mappin.and.ellipse") {
                TextField("Add location", text: $draft.location).textFieldStyle(.roundedBorder)
            }
            field(icon: "bell") {
                Picker("Notification", selection: $draft.reminderMinutes) {
                    Text("No notification").tag(Int?.none)
                    ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { minutes in
                        Text(EventDetailsView.reminderText(minutes)).tag(Int?.some(minutes))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            field(icon: "calendar") {
                HStack(spacing: 12) {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(model.writableCalendars) { calendar in
                            Text(calendar.name).tag(calendar.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(draft.original != nil)
                    Menu {
                        Button("Calendar color") { draft.colorHex = nil }
                        Divider()
                        ForEach(Theme.eventColors, id: \.hex) { color in
                            Button(color.name) { draft.colorHex = color.hex }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.color(hexString: draft.colorHex) ?? model.color(for: model.calendarInfo(draft.calendarID)
                                ?? CalendarInfo(id: "", name: ""))).frame(width: 16, height: 16)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Event color")
                    Picker("Show as", selection: $draft.availability) {
                        Text("Busy").tag(EventAvailability.busy)
                        Text("Free").tag(EventAvailability.free)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            field(icon: "text.alignleft") {
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

    // MARK: Guests

    private var guestsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guests").font(.pm(14, .medium)).foregroundStyle(Theme.accent)
            GuestField(guests: $draft.guests, contacts: contacts)
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
            Spacer(minLength: 0)
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
        guard draft.end > draft.start else {
            error = "The event has to end after it starts."
            return
        }
        if draft.original?.isRecurring == true { asksScope = true } else { commit(scope: .thisEvent) }
    }

    private func commit(scope: RecurrenceScope) {
        draft.scope = scope
        isSaving = true
        error = nil
        let saving = draft
        Task {
            do {
                try await model.save(saving)
                app.show(saving.isNew ? "Event saved." : "Changes saved.")
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
    let contacts: ContactsViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let suggestions = contacts.suggestions(for: text, excluding: guests)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add guests", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(suggestions.first) }
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

    private func add(_ suggestion: MailAddress?) {
        let new = suggestion.map { [$0] } ?? RecipientParser.parse(text).filter { $0.email.contains("@") }
        guests.append(contentsOf: new.filter { address in !guests.contains { $0.isSameMailbox(as: address) } })
        text = ""
    }
}
