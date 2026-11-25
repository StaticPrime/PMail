import AppKit
import PMailKit
import SwiftUI

/// A row of an event editor: its symbol, then what it holds.
struct EditorField<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.icon).frame(width: 22).padding(.top, 6)
            content
        }
    }
}

/// An event's video meeting, or the one chosen for the account in Settings ▸ Calendar ▸ Video meetings: the calendar's
/// own (Meet or Teams) with one click, a Zoom meeting (scheduled in Zoom and its invitation pasted, or the Personal Room),
/// or a FaceTime link pasted in. Nothing shows where the account's choice is None and the event has no meeting.
/// `compact` stacks its fields for the quick editor's narrower card.
struct VideoMeetingRow: View {
    let model: CalendarViewModel
    @Binding var draft: EventDraft
    var compact = false
    @State private var showsFaceTime: Bool
    /// Add Zoom Meeting opened Zoom to schedule one; its copied invitation is pasted here.
    @State private var showsZoomPaste = false
    @State private var zoomPaste = ""

    init(model: CalendarViewModel, draft: Binding<EventDraft>, compact: Bool = false) {
        self.model = model
        _draft = draft
        self.compact = compact
        _showsFaceTime = State(initialValue: !draft.wrappedValue.faceTimeLink.isEmpty)
    }

    var body: some View {
        let offer = model.videoMeetingOffer(for: draft.calendarID)
        if draft.conference != nil || draft.addsNativeConference || showsFaceTime || showsZoomPaste || offer != .noMeeting {
            EditorField(icon: "video") { meeting(offer) }
        }
    }

    @ViewBuilder
    private func meeting(_ offer: VideoMeetingChoice.Option) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let conference = draft.conference, conference.kind != .faceTime || draft.faceTimeLink.isEmpty {
                HStack(spacing: 10) {
                    FilledPillButton(title: "Join with \(conference.kind.displayName)") { NSWorkspace.shared.open(conference.joinURL) }
                    Text(conference.joinURL.host ?? "").font(.pm(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    IconButton(symbol: "xmark", help: "Remove the video meeting", size: 28, iconSize: 11) {
                        draft.conference = nil
                        draft.faceTimeLink = ""
                    }
                }
            } else if showsZoomPaste {
                zoomPasteRow
            } else if showsFaceTime {
                // Ahead of Meet and Teams: an event's FaceTime link shows, whatever the account now offers.
                VStack(alignment: .leading, spacing: 6) {
                    fields {
                        TextField("Paste a FaceTime link", text: $draft.faceTimeLink).textFieldStyle(.roundedBorder)
                            .frame(maxWidth: compact ? .infinity : 340)
                    } buttons: {
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
            } else if let native = offer.madeByCalendar {
                if draft.addsNativeConference {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        Text("\(native.displayName) video conferencing will be added when you save.").font(.pm(13))
                            .fixedSize(horizontal: false, vertical: true)
                        IconButton(symbol: "xmark", help: "Don’t add it", size: 28, iconSize: 11) { draft.addsNativeConference = false }
                    }
                } else {
                    OutlinePillButton(title: "Add \(native.displayName) video conferencing") { draft.addsNativeConference = true }
                }
            } else if offer == .zoom {
                OutlinePillButton(title: "Add Zoom meeting") { addZoomMeeting() }
            } else if offer == .faceTime {
                OutlinePillButton(title: "Add FaceTime link") {
                    showsFaceTime = true
                    pasteFaceTimeLink(onlyIfFaceTime: true)
                }
            }
        }
    }

    /// The Zoom meeting scheduled in Zoom: its copied invitation (or just its link) pasted in, which PMail keeps the
    /// meeting's link from.
    private var zoomPasteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fields {
                TextField("Paste the Zoom invitation", text: $zoomPaste).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: compact ? .infinity : 300)
                    .onChange(of: zoomPaste) { _, text in takeZoomMeeting(from: text) }
            } buttons: {
                Button("Paste") { zoomPaste = NSPasteboard.general.string(forType: .string) ?? "" }
                Button("Open Zoom") { NSWorkspace.shared.open(VideoMeetingChoice.zoomSchedulePage) }
                IconButton(symbol: "xmark", help: "Don’t add a Zoom meeting", size: 28, iconSize: 11) {
                    showsZoomPaste = false
                    zoomPaste = ""
                }
            }
            Text("Schedule the meeting in Zoom, click Copy Invitation, then paste it here.")
                .font(.pm(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
            if !zoomPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("There’s no Zoom meeting link in that. Copy the invitation, or the meeting’s link, in Zoom.")
                    .font(.pm(11.5)).foregroundStyle(Theme.danger)
            }
        }
    }

    /// A field with its buttons beside it, or (compact) under it.
    @ViewBuilder
    private func fields(@ViewBuilder field: () -> some View, @ViewBuilder buttons: () -> some View) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                field()
                HStack(spacing: 8) { buttons() }
            }
        } else {
            HStack(spacing: 8) {
                field()
                buttons()
            }
        }
    }

    /// Add Zoom Meeting: the account's Personal Room at once where that's chosen in Settings, otherwise Zoom's page for
    /// scheduling a meeting, whose invitation is then pasted.
    private func addZoomMeeting() {
        if let room = model.videoMeeting.personalRoomMeeting {
            draft.conference = room
            draft.faceTimeLink = ""
            return
        }
        showsZoomPaste = true
        NSWorkspace.shared.open(VideoMeetingChoice.zoomSchedulePage)
    }

    private func takeZoomMeeting(from text: String) {
        guard let meeting = ConferenceDetector.zoomMeeting(in: text) else { return }
        draft.conference = meeting
        draft.faceTimeLink = ""
        showsZoomPaste = false
        zoomPaste = ""
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
}

/// Text tabs with a line under the chosen one, for the event editor's panes.
struct EditorTabs<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs, id: \.0) { tab, title in
                Button { selection = tab } label: {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.pm(13.5, selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Theme.accent : Theme.textSecondary)
                        Capsule().fill(selection == tab ? Theme.accent : .clear).frame(height: 3)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// Custom recurrence: every so many days, weeks (on which weekdays), months (on the day, or on the weekday of the
/// month) or years, ending never, on a day, or after so many times.
struct CustomRepeatSheet: View {
    private enum Ending: Hashable { case never, on, after }

    let start: Date
    let isAllDay: Bool
    let calendar: Calendar
    let done: (RepeatRule) -> Void
    @State private var frequency: RepeatRule.Frequency
    @State private var interval: Int
    @State private var weekdays: Set<Int>
    @State private var byWeekdayOfMonth: Bool
    @State private var ending: Ending
    @State private var endDay: Date
    @State private var count: Int
    @Environment(\.dismiss) private var dismiss

    init(start: Date, isAllDay: Bool, calendar: Calendar, rule: RepeatRule, done: @escaping (RepeatRule) -> Void) {
        self.start = start
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.done = done
        _frequency = State(initialValue: rule.frequency)
        _interval = State(initialValue: rule.interval)
        _weekdays = State(initialValue: rule.weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : rule.weekdays)
        _byWeekdayOfMonth = State(initialValue: rule.weekdayOfMonth != nil)
        // Ending three months on, or after 13 times, unless the rule says.
        let later = calendar.date(byAdding: .month, value: 3, to: calendar.startOfDay(for: start)) ?? start
        switch rule.end {
        case .never:
            (_ending, _endDay, _count) = (State(initialValue: .never), State(initialValue: later), State(initialValue: 13))
        case let .on(day):
            (_ending, _endDay, _count) = (State(initialValue: .on), State(initialValue: day), State(initialValue: 13))
        case let .after(times):
            (_ending, _endDay, _count) = (State(initialValue: .after), State(initialValue: later), State(initialValue: times))
        }
    }

    private var rule: RepeatRule {
        let end: RepeatRule.End = switch ending {
        case .never: .never
        case .on: .on(calendar.startOfDay(for: endDay))
        case .after: .after(max(1, count))
        }
        return RepeatRule(frequency: frequency, interval: interval, weekdays: frequency == .weekly ? weekdays : [],
                          weekdayOfMonth: frequency == .monthly && byWeekdayOfMonth ? RepeatRule.weekdayOfMonth(of: start, calendar: calendar) : nil,
                          end: end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Custom recurrence").font(.pm(22)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Text("Repeat every")
                TextField("Every", value: $interval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .accessibilityLabel("Repeat every")
                Stepper("Every", value: $interval, in: 1...99).labelsHidden()
                Picker("Unit", selection: $frequency) {
                    ForEach(RepeatRule.Frequency.allCases, id: \.self) { frequency in
                        Text(frequency.unit(plural: interval > 1)).tag(frequency)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if frequency == .weekly {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Repeat on")
                    HStack(spacing: 8) {
                        ForEach(orderedWeekdays, id: \.self) { weekday in weekdayButton(weekday) }
                    }
                }
            }
            if frequency == .monthly {
                Picker("Monthly", selection: $byWeekdayOfMonth) {
                    Text("Monthly on " + RepeatRule(frequency: .monthly).monthlyText(start: start, calendar: calendar)).tag(false)
                    Text("Monthly on " + RepeatRule(frequency: .monthly, weekdayOfMonth: RepeatRule.weekdayOfMonth(of: start, calendar: calendar))
                        .monthlyText(start: start, calendar: calendar)).tag(true)
                }
                .labelsHidden()
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Ends")
                endingRow(.never, "Never") { EmptyView() }
                endingRow(.on, "On") {
                    DatePicker("End day", selection: $endDay, in: calendar.startOfDay(for: start)..., displayedComponents: [.date]).labelsHidden()
                }
                endingRow(.after, "After") {
                    HStack(spacing: 6) {
                        TextField("Times", value: $count, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                            .accessibilityLabel("Occurrences")
                        Stepper("Times", value: $count, in: 1...999).labelsHidden()
                        Text(count == 1 ? "occurrence" : "occurrences").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text(rule.summary(start: start, calendar: calendar))
                .font(.pm(12))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .keyboardShortcut(.cancelAction)
                FilledPillButton(title: "Done") {
                    done(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.pm(13))
        .padding(28)
        .frame(width: 440)
        .background(Theme.surface)
        .onChange(of: interval) { interval = max(1, min(interval, 99)) }
        .onChange(of: count) { count = max(1, min(count, 999)) }
    }

    /// The weekdays in the order the calendar's weeks go.
    private var orderedWeekdays: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isOn = weekdays.contains(weekday)
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let name = calendar.standaloneWeekdaySymbols[weekday - 1]
        return Button {
            if isOn { if weekdays.count > 1 { weekdays.remove(weekday) } } else { weekdays.insert(weekday) }
        } label: {
            Text(letters[weekday - 1])
                .font(.pm(12, .medium))
                .foregroundStyle(isOn ? Theme.onAccent : Theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? Theme.accent : Theme.chip))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func endingRow(_ choice: Ending, _ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Button { ending = choice } label: {
                HStack(spacing: 8) {
                    Image(systemName: ending == choice ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(ending == choice ? Theme.accent : Theme.textTertiary)
                    Text(title).foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 90, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(ending == choice ? .isSelected : [])
            control()
                .disabled(ending != choice)
                .opacity(ending == choice ? 1 : 0.5)
        }
    }
}
