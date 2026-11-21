import AppKit
import Observation
import PMailKit
import SwiftUI

/// An event being made or changed in the event editor.
struct EventDraft: Identifiable, Hashable {
    var id = UUID()
    /// The event being changed; nil for a new one.
    var original: CalendarEvent?
    var calendarID: String
    var title = ""
    var start: Date
    var end: Date
    var isAllDay = false
    var location = ""
    var notes = ""
    var guests: [MailAddress] = []
    /// Make the calendar's own video meeting (Meet or Teams) when saving.
    var addsNativeConference = false
    /// A meeting already on the event, or a FaceTime link pasted in.
    var conference: Conference?
    var faceTimeLink = ""
    var reminderMinutes: Int? = 10
    var colorHex: String?
    var availability: EventAvailability = .busy
    var scope: RecurrenceScope = .thisEvent

    var isNew: Bool { original == nil }
}

/// One account's calendars as the window shows them: which calendars are on, the view and the days showing, and the
/// events in them.
@Observable
final class CalendarViewModel {
    enum Mode: String, CaseIterable, Identifiable {
        case day, week, month, schedule
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var key: String {
            switch self {
            case .day: "D"
            case .week: "W"
            case .month: "M"
            case .schedule: "A"
            }
        }
    }

    @ObservationIgnored let service: any CalendarService
    @ObservationIgnored weak var app: AppModel?
    var account: Account
    @ObservationIgnored let grid: CalendarGrid
    @ObservationIgnored var formatting: MailFormatting
    @ObservationIgnored var today: () -> Date

    private(set) var calendars: [CalendarInfo] = []
    private(set) var hiddenCalendarIDs: Set<String>
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "CalendarMode"); loadIfNeeded() } }
    @ObservationIgnored let defaults: UserDefaults
    private(set) var anchor: Date
    var miniMonth: Date
    private(set) var events: [CalendarEvent] = []
    @ObservationIgnored private var loadedInterval: DateInterval?
    @ObservationIgnored private var loadGeneration = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var needsSignIn = false
    /// The event whose details are showing in a popover.
    var selectedEventID: String?

    init(account: Account, service: any CalendarService, calendar: Calendar = .current, defaults: UserDefaults = .standard,
         today: @escaping () -> Date = Date.init) {
        self.account = account
        self.service = service
        self.defaults = defaults
        grid = CalendarGrid(calendar: calendar)
        formatting = MailFormatting(calendar: calendar)
        self.today = today
        let now = today()
        anchor = calendar.startOfDay(for: now)
        miniMonth = CalendarGrid(calendar: calendar).startOfMonth(now)
        mode = Mode(rawValue: defaults.string(forKey: "CalendarMode") ?? "") ?? .week
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: "HiddenCalendars-\(account.id.uuidString)") ?? [])
    }

    var calendar: Calendar { grid.calendar }

    // MARK: Loading

    func start() {
        Task {
            do {
                calendars = try await service.loadCalendars()
                needsSignIn = false
                reload()
            } catch {
                self.error = describe(error)
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    /// Loads the events around what's showing again.
    func reload() {
        loadedInterval = nil
        loadIfNeeded()
    }

    /// Loads events when what's showing goes past what's loaded: a few weeks either side, so moving a week or a
    /// month along rarely waits.
    func loadIfNeeded() {
        let visible = visibleInterval
        if let loadedInterval, loadedInterval.start <= visible.start, loadedInterval.end >= visible.end { return }
        guard !calendars.isEmpty else { return }
        let start = calendar.date(byAdding: .day, value: -14, to: grid.startOfWeek(grid.startOfMonth(visible.start))) ?? visible.start
        let end = calendar.date(byAdding: .day, value: 45, to: visible.end) ?? visible.end
        let interval = DateInterval(start: start, end: end)
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let ids = calendars.map(\.id)
        Task {
            do {
                let loaded = try await service.loadEvents(in: ids, from: interval.start, to: interval.end)
                guard generation == loadGeneration else { return }
                events = loaded
                loadedInterval = interval
                isLoading = false
                error = nil
            } catch {
                guard generation == loadGeneration else { return }
                isLoading = false
                self.error = describe(error)
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    // MARK: Moving around

    var visibleInterval: DateInterval {
        switch mode {
        case .day:
            return DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor)
        case .week:
            let start = grid.startOfWeek(anchor)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            let weeks = grid.monthWeeks(of: anchor)
            let start = weeks.first?.first ?? anchor
            let last = weeks.last?.last ?? anchor
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
        case .schedule:
            return DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 30, to: anchor) ?? anchor)
        }
    }

    /// The days the day or week view shows.
    var visibleDays: [Date] {
        mode == .day ? [anchor] : grid.week(of: anchor)
    }

    func goToday() {
        go(to: today())
    }

    func go(to date: Date) {
        anchor = calendar.startOfDay(for: date)
        miniMonth = grid.startOfMonth(date)
        loadIfNeeded()
    }

    /// Steps a day, a week or a month forward (1) or back (-1).
    func step(_ direction: Int) {
        let next: Date? = switch mode {
        case .day: calendar.date(byAdding: .day, value: direction, to: anchor)
        case .week: calendar.date(byAdding: .day, value: 7 * direction, to: anchor)
        case .month: calendar.date(byAdding: .month, value: direction, to: grid.startOfMonth(anchor))
        case .schedule: calendar.date(byAdding: .day, value: 30 * direction, to: anchor)
        }
        if let next { go(to: next) }
    }

    /// "November 2026", or "Nov – Dec 2026" for a week across two months.
    var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch mode {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("MMMMdy")
            return formatter.string(from: anchor)
        case .week:
            let days = grid.week(of: anchor)
            guard let first = days.first, let last = days.last else { return "" }
            if grid.isSameMonth(first, last) {
                formatter.setLocalizedDateFormatFromTemplate("MMMMy")
                return formatter.string(from: first)
            }
            let sameYear = calendar.component(.year, from: first) == calendar.component(.year, from: last)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM" : "MMMy")
            let start = formatter.string(from: first)
            formatter.setLocalizedDateFormatFromTemplate("MMMy")
            return "\(start) – \(formatter.string(from: last))"
        case .month, .schedule:
            formatter.setLocalizedDateFormatFromTemplate("MMMMy")
            return formatter.string(from: anchor)
        }
    }

    func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: today()) }

    // MARK: Calendars

    var myCalendars: [CalendarInfo] { calendars.filter { !$0.isOther } }
    var otherCalendars: [CalendarInfo] { calendars.filter(\.isOther) }
    var writableCalendars: [CalendarInfo] { calendars.filter { !$0.isReadOnly } }
    var defaultCalendar: CalendarInfo? { writableCalendars.first(where: \.isPrimary) ?? writableCalendars.first }

    func isVisible(_ calendar: CalendarInfo) -> Bool { !hiddenCalendarIDs.contains(calendar.id) }

    func toggle(_ calendar: CalendarInfo) {
        if hiddenCalendarIDs.contains(calendar.id) { hiddenCalendarIDs.remove(calendar.id) } else { hiddenCalendarIDs.insert(calendar.id) }
        defaults.set(Array(hiddenCalendarIDs), forKey: "HiddenCalendars-\(account.id.uuidString)")
    }

    func calendarInfo(_ id: String) -> CalendarInfo? { calendars.first { $0.id == id } }

    // MARK: Events

    /// Events from the calendars that are on, minus cancelled ones, matching the search if there is one.
    func shownEvents(matching search: String = "") -> [CalendarEvent] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return events.filter { event in
            guard !hiddenCalendarIDs.contains(event.calendarID), event.status != .cancelled else { return false }
            guard !words.isEmpty else { return true }
            let text = [event.title, event.location ?? "", event.notes ?? "", event.attendees.map(\.address.displayName).joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Events that touch a day, all-day events first, then by start.
    func events(on day: Date, from list: [CalendarEvent]) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return list.filter { $0.start < end && ($0.end > start || ($0.end == $0.start && $0.start >= start)) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func event(_ id: String?) -> CalendarEvent? { id.flatMap { id in events.first { $0.id == id } } }

    /// The event's color: its own, or its calendar's.
    func color(for event: CalendarEvent) -> Color {
        Theme.color(hexString: event.colorHex) ?? Theme.color(hexString: calendarInfo(event.calendarID)?.colorHex) ?? Theme.accent
    }

    func color(for calendar: CalendarInfo) -> Color { Theme.color(hexString: calendar.colorHex) ?? Theme.accent }

    // MARK: Making and changing events

    /// A new event starting at `start` (an hour long), or the next half hour.
    func newDraft(start: Date? = nil, end: Date? = nil, allDay: Bool = false, guests: [MailAddress] = []) -> EventDraft? {
        guard let calendarInfo = defaultCalendar else { return nil }
        let begin: Date
        if let start {
            begin = start
        } else {
            let now = today()
            let base = calendar.isDate(anchor, inSameDayAs: now) ? now : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: anchor) ?? anchor)
            let minutes = calendar.component(.minute, from: base)
            begin = calendar.date(byAdding: .minute, value: minutes < 30 ? 30 - minutes : 60 - minutes, to: base)
                .map { calendar.date(bySetting: .second, value: 0, of: $0) ?? $0 } ?? base
        }
        let finish = end ?? (allDay ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: begin)) ?? begin)
                                    : begin.addingTimeInterval(3600))
        var draft = EventDraft(calendarID: calendarInfo.id, start: allDay ? calendar.startOfDay(for: begin) : begin, end: finish,
                               isAllDay: allDay, guests: guests)
        draft.reminderMinutes = allDay ? nil : 10
        return draft
    }

    func draft(for event: CalendarEvent) -> EventDraft {
        var draft = EventDraft(original: event, calendarID: event.calendarID, title: event.title, start: event.start, end: event.end,
                               isAllDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
                               guests: event.attendees.filter { !$0.address.isSameMailbox(as: account.email) }.map(\.address),
                               conference: event.conference, reminderMinutes: event.reminderMinutes.first,
                               colorHex: event.colorHex, availability: event.availability)
        if event.conference?.kind == .faceTime { draft.faceTimeLink = event.conference?.joinURL.absoluteString ?? "" }
        return draft
    }

    /// Saves a draft: makes the event, or changes it, creating its video meeting if asked.
    func save(_ draft: EventDraft) async throws {
        var event = draft.original ?? CalendarEvent(calendarID: draft.calendarID, start: draft.start, end: draft.end)
        event.calendarID = draft.calendarID
        event.title = draft.title.trimmingCharacters(in: .whitespaces)
        event.start = draft.start
        event.end = max(draft.end, draft.isAllDay ? draft.start.addingTimeInterval(86_400) : draft.start.addingTimeInterval(60))
        event.isAllDay = draft.isAllDay
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        let me = Attendee(address: account.address, response: .accepted, isOrganizer: true)
        let existing = Dictionary(event.attendees.map { ($0.address.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        event.attendees = draft.guests.isEmpty ? [] : [existing[account.email.lowercased()] ?? me]
            + draft.guests.map { existing[$0.email.lowercased()] ?? Attendee(address: $0) }
        if draft.original == nil, !draft.guests.isEmpty { event.organizer = account.address }
        let link = draft.faceTimeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty, let url = URL(string: link) {
            event.conference = Conference(kind: ConferenceDetector.kind(of: url) ?? .other, joinURL: url)
        } else if draft.conference == nil {
            event.conference = nil
        }
        event.reminderMinutes = draft.reminderMinutes.map { [$0] } ?? []
        event.colorHex = draft.colorHex
        event.availability = draft.availability
        let saved: CalendarEvent
        if draft.original == nil {
            saved = try await service.create(event, addingConference: draft.addsNativeConference)
        } else {
            saved = try await service.update(event, scope: draft.scope, addingConference: draft.addsNativeConference)
        }
        if draft.original != nil, draft.scope == .allEvents || draft.original?.calendarID != saved.calendarID {
            reload()
        } else {
            events.removeAll { $0.id == saved.id || $0.id == draft.original?.id }
            events.append(saved)
        }
    }

    func delete(_ event: CalendarEvent, scope: RecurrenceScope) {
        let snapshot = events
        if scope == .allEvents, let series = event.seriesID {
            events.removeAll { $0.seriesID == series || $0.id == event.id }
        } else {
            events.removeAll { $0.id == event.id }
        }
        selectedEventID = nil
        let service = self.service
        Task {
            do {
                try await service.delete(event, scope: scope)
                app?.show("Event deleted.")
            } catch {
                events = snapshot
                app?.report(error, doing: "Deleting the event")
            }
        }
    }

    func respond(to event: CalendarEvent, with response: AttendeeResponse) {
        if let index = events.firstIndex(where: { $0.id == event.id }) { events[index].myResponse = response }
        let service = self.service
        Task {
            do {
                try await service.respond(to: event, with: response)
            } catch {
                app?.report(error, doing: "Answering the invitation")
                reload()
            }
        }
    }

    /// What "Add video conferencing" makes on a calendar: its own meeting, or a FaceTime link pasted in.
    func conferenceKind(for calendarID: String) -> Conference.Kind? { calendarInfo(calendarID)?.nativeConference }

    func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
