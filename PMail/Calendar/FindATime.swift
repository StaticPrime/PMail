import PMailKit
import SwiftUI

/// Who's busy when, for the editor's Find a time and Suggested times: the person's own events (from their calendars)
/// and their guests' busy times (where the account can look them up), for a stretch of days.
@MainActor
@Observable
final class Availability {
    private(set) var mine: [CalendarEvent] = []
    /// Each guest's busy times, or why they aren't known, by lowercased address.
    private(set) var others: [String: FreeBusy] = [:]
    private(set) var isLoading = false
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var generation = 0

    /// Loads a stretch of days for some guests, unless it's what's loaded already.
    func load(_ model: CalendarViewModel, guests: [MailAddress], range: DateInterval, excluding eventID: String?) {
        let newKey = guests.map { $0.email.lowercased() }.sorted().joined(separator: ",") + "|\(range.start.timeIntervalSince1970)|\(range.end.timeIntervalSince1970)|\(eventID ?? "")"
        guard newKey != key else { return }
        key = newKey
        generation += 1
        let generation = self.generation
        isLoading = true
        Task {
            async let mine = model.myBusyEvents(in: range, excluding: eventID)
            async let others = model.busyTimes(for: guests, in: range)
            let (myEvents, theirs) = await (mine, others)
            guard generation == self.generation else { return }
            self.mine = myEvents
            self.others = Dictionary(theirs.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            isLoading = false
        }
    }

    func freeBusy(of guest: MailAddress) -> FreeBusy? { others[guest.email.lowercased()] }

    /// Everyone's busy stretches that are known: the person's own events and their guests' busy times.
    var allBusy: [DateInterval] {
        mine.filter { !$0.isAllDay }.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) } + others.values.flatMap(\.busy)
    }

    /// The guests whose busy times aren't known, with why.
    func unknown(among guests: [MailAddress]) -> [(MailAddress, String)] {
        guests.compactMap { guest in freeBusy(of: guest)?.problem.map { (guest, $0) } }
    }
}

extension CalendarViewModel {
    /// The person's own events in a stretch of days that make them busy (from their calendars, not others' or task
    /// lists; not free, declined or cancelled ones), without the event being changed.
    func myBusyEvents(in range: DateInterval, excluding eventID: String?) async -> [CalendarEvent] {
        let ids = myCalendars.map(\.id)
        guard !ids.isEmpty else { return [] }
        let loaded = (try? await service.loadEvents(in: ids, from: range.start, to: range.end))
            ?? events.filter { ids.contains($0.calendarID) && $0.start < range.end && $0.end > range.start }
        return loaded.filter { event in
            event.id != eventID && event.availability == .busy && event.status != .cancelled && event.myResponse != .declined && !event.isTask
        }
        .sorted { $0.start < $1.start }
    }

    /// Guests' busy times, where the account's calendars can look them up.
    func busyTimes(for guests: [MailAddress], in range: DateInterval) async -> [String: FreeBusy] {
        let addresses = guests.map(\.email)
        guard !addresses.isEmpty else { return [:] }
        do {
            return try await service.freeBusy(for: addresses, from: range.start, to: range.end)
        } catch {
            let reason = describe(error)
            return Dictionary(addresses.map { ($0, FreeBusy.unknown(reason)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Times when everyone whose busy times are known is free, for an event that long: on weekdays from 9 to 5, on the
    /// hour or half hour, over two weeks from `day` (or from now, if that's later).
    func suggestedTimes(lasting duration: TimeInterval, from day: Date, busy: [DateInterval], count: Int = 8) -> [DateInterval] {
        let length = max(duration, 15 * 60)
        let now = today()
        var results: [DateInterval] = []
        var dayStart = calendar.startOfDay(for: max(day, now))
        for _ in 0..<14 where results.count < count {
            defer { dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400) }
            let weekday = calendar.component(.weekday, from: dayStart)
            guard weekday != 1, weekday != 7,
                  let open = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart),
                  let close = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart) else { continue }
            var slot = open
            while slot.addingTimeInterval(length) <= close, results.count < count {
                let candidate = DateInterval(start: slot, duration: length)
                if slot >= now, !busy.contains(where: { $0.start < candidate.end && $0.end > candidate.start }) {
                    results.append(candidate)
                    slot = slot.addingTimeInterval(max(length, 30 * 60))
                } else {
                    slot = slot.addingTimeInterval(30 * 60)
                }
            }
        }
        return results
    }
}

/// The colors people get in Find a time: the person in the accent color, guests in turn.
enum PersonColors {
    static let guests = ["#E8710A", "#188038", "#9334E6", "#D93025", "#129EE0", "#B06000", "#3B5BDB"]

    static func color(forGuest index: Int) -> Color {
        Theme.color(hexString: guests[index % guests.count]) ?? Theme.textSecondary
    }
}

/// The editor's Find a time: a week (or a day) of the person's own events and their guests' busy times, with the
/// event's time over them. Click a free time to move the event there.
struct FindATimeView: View {
    let model: CalendarViewModel
    @Binding var draft: EventDraft
    @State private var availability = Availability()
    @State private var showsWeek = true
    @State private var anchor: Date
    private let hourHeight: CGFloat = 40
    private let gutter: CGFloat = 52

    init(model: CalendarViewModel, draft: Binding<EventDraft>) {
        self.model = model
        _draft = draft
        _anchor = State(initialValue: draft.wrappedValue.start)
    }

    private var calendar: Calendar { model.calendar }
    private var days: [Date] {
        let first = showsWeek ? model.grid.startOfWeek(anchor) : calendar.startOfDay(for: anchor)
        return (0..<(showsWeek ? 7 : 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    private var range: DateInterval {
        let first = days.first ?? anchor
        return DateInterval(start: first, end: calendar.date(byAdding: .day, value: days.count, to: first) ?? first.addingTimeInterval(86_400))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if !draft.guests.isEmpty { legend.padding(.horizontal, 12).padding(.vertical, 8) }
            columnHeaders
            ScrollViewReader { reader in
                ScrollView { grid }
                    .onAppear {
                        // A couple of hours before the event, so it shows.
                        let hour = draft.isAllDay ? 8 : calendar.component(.hour, from: draft.start) - 2
                        reader.scrollTo("hour-\(min(max(hour, 0), 14))", anchor: .top)
                    }
            }
            if availability.isLoading {
                ProgressView().controlSize(.small).padding(6)
            }
        }
        .onAppear(perform: load)
        .onChange(of: range) { load() }
        .onChange(of: draft.guests) { load() }
    }

    private func load() {
        availability.load(model, guests: draft.guests, range: range, excluding: draft.original?.id)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            OutlinePillButton(title: "Today", height: 30) { anchor = model.today() }
            IconButton(symbol: "chevron.left", help: showsWeek ? "Previous week" : "Previous day", size: 30, iconSize: 12) { step(-1) }
            IconButton(symbol: "chevron.right", help: showsWeek ? "Next week" : "Next day", size: 30, iconSize: 12) { step(1) }
            Text(rangeTitle).font(.pm(14)).foregroundStyle(Theme.textPrimary).padding(.leading, 4)
            Spacer()
            Picker("View", selection: $showsWeek) {
                Text("Day").tag(false)
                Text("Week").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func step(_ direction: Int) {
        anchor = calendar.date(byAdding: .day, value: direction * (showsWeek ? 7 : 1), to: anchor) ?? anchor
    }

    private var rangeTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        if showsWeek, let first = days.first, let last = days.last {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            let year = calendar.component(.year, from: last)
            return "\(formatter.string(from: first)) – \(formatter.string(from: last)), \(year)"
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMdy")
        return formatter.string(from: anchor)
    }

    /// Who's who: the person and each guest in their color, and whose busy times aren't known.
    private var legend: some View {
        let unknown = availability.unknown(among: draft.guests)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                person("You", color: Theme.accent)
                ForEach(Array(draft.guests.enumerated()), id: \.offset) { index, guest in
                    person(guest.name ?? guest.email, color: PersonColors.color(forGuest: index),
                           unknown: availability.freeBusy(of: guest)?.problem != nil)
                }
                Spacer(minLength: 0)
            }
            if !unknown.isEmpty {
                Text("Busy times aren’t available for " + unknown.map { $0.0.name ?? $0.0.email }.joined(separator: ", ") + ": " + (unknown.first?.1 ?? ""))
                    .font(.pm(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
    }

    private func person(_ name: String, color: Color, unknown: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(unknown ? Theme.textTertiary.opacity(0.4) : color).frame(width: 10, height: 10)
            Text(name).font(.pm(11.5)).foregroundStyle(unknown ? Theme.textTertiary : Theme.textSecondary).lineLimit(1)
        }
    }

    // MARK: Grid

    /// The days (week) or the people (day) across the top.
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            if showsWeek {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 0) {
                        Text(weekdayText(day)).font(.pm(10.5, .medium))
                        Text("\(calendar.component(.day, from: day))").font(.pm(17))
                    }
                    .foregroundStyle(model.isToday(day) ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text("You").font(.pm(11.5, .medium)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
                ForEach(Array(draft.guests.enumerated()), id: \.offset) { index, guest in
                    Text(guest.name ?? guest.email).font(.pm(11.5, .medium)).foregroundStyle(PersonColors.color(forGuest: index))
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 12)
    }

    private func weekdayText(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: day).uppercased()
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour == 0 ? "" : hourText(hour))
                        .font(.pm(10))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .id("hour-\(hour)")
                }
            }
            .frame(width: gutter, alignment: .leading)
            if showsWeek {
                ForEach(days, id: \.self) { day in weekColumn(day) }
            } else {
                personColumn(nil, index: 0)
                ForEach(Array(draft.guests.enumerated()), id: \.offset) { index, guest in personColumn(guest, index: index) }
            }
        }
        .padding(.trailing, 12)
        .frame(height: hourHeight * 24)
    }

    private func hourText(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: anchor) ?? anchor
        return formatter.string(from: date)
    }

    /// A day in the week: the person's events in their lane, each guest's busy times in a narrower lane of their
    /// own, and the event's time over them all.
    private func weekColumn(_ day: Date) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let lanes = CGFloat(2 + draft.guests.count)
            let myWidth = draft.guests.isEmpty ? width - 4 : width * 2 / lanes
            let guestWidth = draft.guests.isEmpty ? 0 : (width - myWidth - 2) / CGFloat(draft.guests.count)
            ZStack(alignment: .topLeading) {
                hourLines(width: width)
                ForEach(events(on: day, in: availability.mine)) { event in
                    myBlock(event, day: day).frame(width: myWidth - 2).offset(x: 1)
                }
                ForEach(Array(draft.guests.enumerated()), id: \.offset) { index, guest in
                    ForEach(stretches(of: guest, on: day), id: \.start) { stretch in
                        busyBlock(stretch, day: day, color: PersonColors.color(forGuest: index), label: nil)
                            .frame(width: max(guestWidth - 2, 3))
                            .offset(x: myWidth + CGFloat(index) * guestWidth)
                    }
                }
                draftBlock(on: day, width: width)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in move(to: day, y: location.y) }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    /// One person's column in the day view.
    private func personColumn(_ guest: MailAddress?, index: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let day = calendar.startOfDay(for: anchor)
            ZStack(alignment: .topLeading) {
                hourLines(width: width)
                if let guest {
                    ForEach(stretches(of: guest, on: day), id: \.start) { stretch in
                        busyBlock(stretch, day: day, color: PersonColors.color(forGuest: index), label: "Busy").frame(width: width - 4).offset(x: 2)
                    }
                } else {
                    ForEach(events(on: day, in: availability.mine)) { event in
                        myBlock(event, day: day).frame(width: width - 4).offset(x: 2)
                    }
                }
                draftBlock(on: day, width: width)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in move(to: day, y: location.y) }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    private func hourLines(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle().fill(Theme.divider.opacity(0.7)).frame(height: 1).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: width, height: hourHeight * 24)
    }

    private func events(on day: Date, in list: [CalendarEvent]) -> [CalendarEvent] {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return list.filter { !$0.isAllDay && $0.start < end && $0.end > day }
    }

    private func stretches(of guest: MailAddress, on day: Date) -> [DateInterval] {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return (availability.freeBusy(of: guest)?.busy ?? []).filter { $0.start < end && $0.end > day }
    }

    private func y(_ date: Date, on day: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(day), 0), 86_400) / 3_600) * hourHeight
    }

    private func myBlock(_ event: CalendarEvent, day: Date) -> some View {
        let top = y(event.start, on: day)
        let height = max(y(event.end, on: day) - top, 14)
        return Text(event.shownTitle + ", " + model.formatting.shortTime(event.start))
            .font(.pm(10.5, .medium))
            .foregroundStyle(.white)
            .lineLimit(height > 28 ? 2 : 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(model.color(for: event)))
            .offset(y: top)
            .allowsHitTesting(false)
    }

    private func busyBlock(_ stretch: DateInterval, day: Date, color: Color, label: String?) -> some View {
        let top = y(stretch.start, on: day)
        let height = max(y(stretch.end, on: day) - top, 6)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.35))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .overlay(alignment: .topLeading) {
                if let label, height > 18 { Text(label).font(.pm(10.5, .medium)).foregroundStyle(color).padding(.leading, 7).padding(.top, 2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(height: height)
            .offset(y: top)
            .allowsHitTesting(false)
    }

    /// The event's own time, across the whole column.
    @ViewBuilder
    private func draftBlock(on day: Date, width: CGFloat) -> some View {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        if !draft.isAllDay, draft.start < end, draft.end > day {
            let top = y(draft.start, on: day)
            let height = max(y(draft.end, on: day) - top, 12)
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.textSecondary.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.textSecondary.opacity(0.7), lineWidth: 1.5))
                .overlay(alignment: .topLeading) {
                    Text(draft.title.isEmpty ? "(No title)" : draft.title)
                        .font(.pm(10.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
                .frame(width: width - 2, height: height)
                .offset(x: 1, y: top)
                .allowsHitTesting(false)
        }
    }

    /// Moves the event to the half hour clicked, keeping its length.
    private func move(to day: Date, y position: CGFloat) {
        guard !draft.isAllDay else { return }
        let minutes = Int((position / hourHeight * 60 / 30).rounded(.down)) * 30
        guard let start = calendar.date(byAdding: .minute, value: max(0, min(minutes, 23 * 60 + 30)), to: day) else { return }
        let length = draft.end.timeIntervalSince(draft.start)
        draft.start = start
        draft.end = start.addingTimeInterval(max(length, 15 * 60))
    }
}

/// The editor's Suggested times: times in the next two weeks when the person and their guests are all free.
struct SuggestedTimesView: View {
    let model: CalendarViewModel
    @Binding var draft: EventDraft
    @State private var availability = Availability()
    /// Where the two weeks start: the event's day (or today) when the list opened, so choosing a time doesn't move
    /// the list; it moves only when the event goes outside it.
    @State private var firstDay: Date?

    private var range: DateInterval {
        let first = firstDay ?? model.calendar.startOfDay(for: max(draft.start, model.today()))
        return DateInterval(start: first, end: model.calendar.date(byAdding: .day, value: 14, to: first) ?? first.addingTimeInterval(14 * 86_400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.isAllDay {
                note("Suggested times are for events with a start and end time.")
            } else {
                note(draft.guests.isEmpty ? "When you’re free, on weekdays from 9 to 5." : "When you and your guests are free, on weekdays from 9 to 5.")
                if availability.isLoading, availability.mine.isEmpty {
                    ProgressView().controlSize(.small)
                }
                let suggestions = model.suggestedTimes(lasting: draft.end.timeIntervalSince(draft.start), from: range.start, busy: availability.allBusy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions, id: \.start) { slot in suggestion(slot) }
                    }
                }
                if suggestions.isEmpty, !availability.isLoading {
                    note("No time in the next two weeks suits everyone.")
                }
                let unknown = availability.unknown(among: draft.guests)
                if !unknown.isEmpty {
                    note("Not counting " + unknown.map { $0.0.name ?? $0.0.email }.joined(separator: ", ") + ", whose busy times aren’t available.")
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            firstDay = range.start
            load()
        }
        .onChange(of: draft.guests) { load() }
        .onChange(of: draft.start) {
            guard !range.contains(draft.start) else { return }
            firstDay = model.calendar.startOfDay(for: max(draft.start, model.today()))
            load()
        }
    }

    private func load() {
        availability.load(model, guests: draft.guests, range: range, excluding: draft.original?.id)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.pm(11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func suggestion(_ slot: DateInterval) -> some View {
        let isChosen = slot.start == draft.start
        return Button {
            draft.start = slot.start
            draft.end = slot.end
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(dayText(slot.start)).font(.pm(12.5, .medium)).foregroundStyle(isChosen ? Theme.onSelection : Theme.textPrimary)
                Text(model.formatting.eventTime(start: slot.start, end: slot.end, isAllDay: false))
                    .font(.pm(11.5))
                    .foregroundStyle(isChosen ? Theme.onSelection : Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isChosen ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Move the event to this time")
    }

    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = model.calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}
