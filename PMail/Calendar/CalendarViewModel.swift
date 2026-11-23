import AppKit
import Observation
import PMailKit
import SwiftUI

/// A notification before an event: so many minutes, hours, days or weeks.
struct Reminder: Hashable {
    enum Unit: Int, CaseIterable {
        case minutes = 1
        case hours = 60
        case days = 1_440
        case weeks = 10_080

        func name(_ amount: Int) -> String {
            let one = amount == 1
            switch self {
            case .minutes: return one ? "minute" : "minutes"
            case .hours: return one ? "hour" : "hours"
            case .days: return one ? "day" : "days"
            case .weeks: return one ? "week" : "weeks"
            }
        }
    }

    var amount: Int
    var unit: Unit

    init(amount: Int, unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    /// The biggest unit the minutes come to evenly: 60 is 1 hour, 1,440 is 1 day.
    init(minutes: Int) {
        let unit = Unit.allCases.reversed().first { minutes > 0 && minutes % $0.rawValue == 0 } ?? .minutes
        self.init(amount: minutes / unit.rawValue, unit: unit)
    }

    var minutes: Int { max(0, amount) * unit.rawValue }
}

/// What became of a save: it reached the server, or it's kept on this Mac until the server can be reached.
enum SaveOutcome {
    case saved
    case waiting
}

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
    /// The description with its formatting, as simple HTML, when it has any (`EventDescription`).
    var notesHTML: String?
    var guests: [MailAddress] = []
    /// Make the calendar's own video meeting (Meet or Teams) when saving.
    var addsNativeConference = false
    /// A meeting already on the event, or a FaceTime link pasted in.
    var conference: Conference?
    var faceTimeLink = ""
    /// Its notifications, soonest first or as the person added them.
    var reminders: [Reminder] = [Reminder(minutes: 10)]
    /// How it repeats; nil for not at all.
    var repeatRule: RepeatRule?
    /// The event repeats by a rule the editor can't show, which is kept unless another is chosen.
    var keepsOwnRule = false
    var colorHex: String?
    var availability: EventAvailability = .busy
    var scope: RecurrenceScope = .thisEvent
    /// An event, a task, out of office or focus time.
    var type: EventType = .event
    /// Out of office and focus time: whether invitations for that time are declined, how, and whether the meetings
    /// already planned for it are declined too.
    var declinesInvitations = false
    var declineMessage = ""
    var declinesExisting = false
    /// A task: whether it's done.
    var isCompleted = false
    /// Why saving it failed, when it was opened again for that.
    var saveError: String?
    var visibility: EventVisibility = .default
    var guestsCanModify = false
    var guestsCanInviteOthers = true
    var guestsCanSeeOtherGuests = true

    var isNew: Bool { original == nil }
    /// Whether the person changed how it repeats (or made a new repeating event).
    var changesRepeat: Bool {
        guard let original else { return repeatRule != nil }
        if keepsOwnRule { return false }
        let before = RepeatRule(lines: original.recurrence, start: original.start)
        // A rule the editor couldn't show, replaced by another (or by none).
        if before == nil, !original.recurrence.isEmpty { return true }
        return repeatRule?.normalized(start: original.start) != before?.normalized(start: original.start)
    }
    var isTask: Bool { type == .task }
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
    @ObservationIgnored let cache: AccountCache?
    @ObservationIgnored weak var app: AppModel?
    var account: Account
    @ObservationIgnored let grid: CalendarGrid
    @ObservationIgnored var formatting: MailFormatting
    @ObservationIgnored var today: () -> Date

    private(set) var calendars: [CalendarInfo] = [] {
        didSet { forgetColorsChangedElsewhere() }
    }
    private(set) var hiddenCalendarIDs: Set<String>
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "CalendarMode"); loadIfNeeded() } }
    @ObservationIgnored let defaults: UserDefaults
    private(set) var anchor: Date
    var miniMonth: Date
    private(set) var events: [CalendarEvent] = []
    @ObservationIgnored private var loadedInterval: DateInterval?
    @ObservationIgnored private var loadGeneration = 0
    /// Counts changes made here (and the server's answers to them), so a load that may have missed one is done again.
    @ObservationIgnored private var changeCount = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var needsSignIn = false
    /// Why the account's tasks couldn't be shown (it may need signing in again, to allow them), if they couldn't.
    private(set) var tasksProblem: String?
    /// Changes made while the calendar couldn't be reached, waiting to be sent (kept in the account's folder).
    @ObservationIgnored let pending: PendingChanges<CalendarChange>?
    /// What's waiting, as the window shows it.
    private(set) var waiting: [CalendarChange] = []
    /// The event whose details are showing in a popover.
    var selectedEventID: String?

    init(account: Account, service: any CalendarService, cache: AccountCache? = nil, changes: PendingChanges<CalendarChange>? = nil,
         calendar: Calendar = .current, defaults: UserDefaults = .standard, today: @escaping () -> Date = Date.init) {
        self.account = account
        self.service = service
        self.cache = cache
        pending = changes
        self.defaults = defaults
        grid = CalendarGrid(calendar: calendar)
        formatting = MailFormatting(calendar: calendar)
        self.today = today
        let now = today()
        anchor = calendar.startOfDay(for: now)
        miniMonth = CalendarGrid(calendar: calendar).startOfMonth(now)
        mode = Mode(rawValue: defaults.string(forKey: "CalendarMode") ?? "") ?? .week
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: "HiddenCalendars-\(account.id.uuidString)") ?? [])
        preferences = defaults.data(forKey: "CalendarPreferences-\(account.id.uuidString)")
            .flatMap { try? JSONDecoder().decode(CalendarPreferences.self, from: $0) } ?? CalendarPreferences()
    }

    var calendar: Calendar { grid.calendar }

    // MARK: Loading

    /// Whether what's showing is a copy, because the server couldn't be reached.
    private(set) var isOffline = false

    func start() {
        Task {
            waiting = await pending?.all() ?? []
            // What was loaded last time shows at once, with the changes made offline.
            if calendars.isEmpty, let cached = await cache?.calendars() {
                calendars = cached
                if let stored = await cache?.events() { events = CalendarChange.applying(waiting, to: stored.events) }
            }
            do {
                let loaded = try await service.loadCalendars()
                calendars = loaded
                tasksProblem = (service as? CalendarWithTasks)?.tasksProblem
                needsSignIn = false
                isOffline = false
                error = nil
                await cache?.save(calendars: loaded)
                reload()
            } catch {
                if MailViewModel.isConnectionProblem(error), !calendars.isEmpty {
                    isOffline = true
                } else {
                    self.error = describe(error)
                }
                needsSignIn = (error as? PMailError)?.needsSignIn ?? false
            }
        }
    }

    // MARK: Subscriptions

    /// Whether another person's calendar can be followed by their address.
    var canSubscribeToPeople: Bool { service.canSubscribeToPeople }

    /// Follows another person's calendar, shows it, and returns it.
    func subscribe(toCalendarOf email: String) async throws -> CalendarInfo {
        let calendar = try await service.subscribe(toCalendarOf: email.trimmingCharacters(in: .whitespacesAndNewlines))
        await calendarsChanged(showing: calendar.id)
        return calendar
    }

    /// Follows a calendar from a web address, shows it, and returns it.
    func subscribe(toFeed address: String, name: String) async throws -> CalendarInfo {
        guard let withFeeds = service as? CalendarWithTasks else {
            throw PMailError.notSupported("This account can’t follow calendars from web addresses.")
        }
        let calendar = try await withFeeds.subscribe(toFeed: address, name: name)
        await calendarsChanged(showing: calendar.id)
        return calendar
    }

    /// The calendars a file's events can be imported into: the account's own that can be changed.
    var importTargets: [CalendarInfo] {
        calendars.filter { !$0.isReadOnly && !$0.isOther && !$0.isTaskList && !CalendarFeeds.isFeed($0.id) }
    }

    /// Adds events read from a file to a calendar, one by one; offline, they wait to be sent like events made then.
    func importEvents(_ imported: [CalendarEvent], into calendarID: String) async -> (added: Int, failed: Int) {
        var added = 0
        var failed = 0
        for var event in imported {
            event.calendarID = calendarID
            event.id = UUID().uuidString
            if app?.sync?.isOnline == false && !service.emailsInvitations {
                var made = event
                made.id = LocalID.make()
                if await keep(.create(made, addingConference: false)) { added += 1 } else { failed += 1 }
                continue
            }
            do {
                _ = try await service.create(event, addingConference: false)
                added += 1
            } catch let error where PMailError.isConnectionProblem(error) {
                var made = event
                made.id = LocalID.make()
                if await keep(.create(made, addingConference: false)) { added += 1 } else { failed += 1 }
            } catch {
                failed += 1
            }
        }
        changeCount += 1
        reload()
        return (added, failed)
    }

    /// Stops following a calendar.
    func unsubscribe(_ calendar: CalendarInfo) {
        Task {
            do {
                try await service.unsubscribe(from: calendar.id)
                app?.show("Unsubscribed from “\(calendar.name)”.")
                await calendarsChanged(showing: nil)
            } catch {
                app?.report(error, doing: "Unsubscribing from “\(calendar.name)”")
            }
        }
    }

    /// The calendars again after one is added or taken away (a new one shown), and their events.
    private func calendarsChanged(showing id: String?) async {
        if let loaded = try? await service.loadCalendars() {
            calendars = loaded
            await cache?.save(calendars: loaded)
        }
        if let id, hiddenCalendarIDs.contains(id) {
            hiddenCalendarIDs.remove(id)
            defaults.set(Array(hiddenCalendarIDs), forKey: "HiddenCalendars-\(account.id.uuidString)")
        }
        changeCount += 1
        reload()
    }

    /// Loads the events around what's showing again.
    func reload() {
        loadedInterval = nil
        loadIfNeeded()
    }

    /// Gets the latest calendars and events without showing it's busy (beside each mail check), keeping what's showing
    /// when the server can't be reached.
    func refreshQuietly() {
        guard !calendars.isEmpty else { return }
        Task {
            if let loaded = try? await service.loadCalendars() {
                calendars = loaded
                tasksProblem = (service as? CalendarWithTasks)?.tasksProblem
                await cache?.save(calendars: loaded)
            }
            loadedInterval = nil
            loadIfNeeded(quietly: true)
        }
    }

    /// Loads events when what's showing goes past what's loaded: a few weeks either side, so moving a week or a
    /// month along rarely waits. Quietly (a refresh in the background), it shows no progress and no errors.
    func loadIfNeeded(quietly: Bool = false) {
        let visible = visibleInterval
        if let loadedInterval, loadedInterval.start <= visible.start, loadedInterval.end >= visible.end { return }
        guard !calendars.isEmpty else { return }
        let start = calendar.date(byAdding: .day, value: -14, to: grid.startOfWeek(grid.startOfMonth(visible.start))) ?? visible.start
        let end = calendar.date(byAdding: .day, value: 45, to: visible.end) ?? visible.end
        let interval = DateInterval(start: start, end: end)
        loadGeneration += 1
        let generation = loadGeneration
        if !quietly { isLoading = true }
        let ids = calendars.map(\.id)
        let changes = changeCount
        Task {
            do {
                let loaded = try await service.loadEvents(in: ids, from: interval.start, to: interval.end)
                guard generation == loadGeneration else { return }
                // Something was saved, changed or deleted while this loaded, which it may not include: load again.
                guard changes == changeCount else {
                    loadedInterval = nil
                    return loadIfNeeded(quietly: quietly)
                }
                events = CalendarChange.applying(waiting + undoable.values.flatMap { $0 }, to: loaded)
                tasksProblem = (service as? CalendarWithTasks)?.tasksProblem
                loadedInterval = interval
                isLoading = false
                isOffline = false
                error = nil
                await cache?.save(events: loaded, covering: interval)
            } catch {
                guard generation == loadGeneration else { return }
                isLoading = false
                if MailViewModel.isConnectionProblem(error), !events.isEmpty || quietly {
                    isOffline = true
                } else if !quietly {
                    self.error = describe(error)
                }
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

    var myCalendars: [CalendarInfo] { calendars.filter { !$0.isOther && !$0.isTaskList } }
    var otherCalendars: [CalendarInfo] { calendars.filter(\.isOther) }
    /// The calendars events can be added to.
    var eventCalendars: [CalendarInfo] { calendars.filter { !$0.isReadOnly && !$0.isTaskList } }
    /// The account's task lists (each shown as a calendar of tasks).
    var taskLists: [CalendarInfo] { calendars.filter(\.isTaskList) }
    var defaultCalendar: CalendarInfo? { eventCalendars.first(where: \.isPrimary) ?? eventCalendars.first }
    /// Where new tasks go: the list the provider makes the default.
    var defaultTaskList: CalendarInfo? { taskLists.first(where: \.isPrimary) ?? taskLists.first }

    /// What the account's calendars keep for an event: how many notifications, which visibilities and guest
    /// permissions, and whether other people's busy times can be looked up.
    var features: CalendarFeatures {
        switch account.kind {
        case .google: .google
        case .microsoft: .microsoft
        case .icloud: .basic
        case .other: account.calendarServer == nil ? .basic : .calDAV
        }
    }

    func isVisible(_ calendar: CalendarInfo) -> Bool { !hiddenCalendarIDs.contains(calendar.id) }

    func toggle(_ calendar: CalendarInfo) {
        if hiddenCalendarIDs.contains(calendar.id) { hiddenCalendarIDs.remove(calendar.id) } else { hiddenCalendarIDs.insert(calendar.id) }
        defaults.set(Array(hiddenCalendarIDs), forKey: "HiddenCalendars-\(account.id.uuidString)")
    }

    func calendarInfo(_ id: String) -> CalendarInfo? { calendars.first { $0.id == id } }

    // MARK: Events

    /// Events from the calendars that are on (canceled ones too, marked), matching the search if there is one. An
    /// invitation the account said No to isn't shown: saying No takes it off the calendar.
    func shownEvents(matching search: String = "") -> [CalendarEvent] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return events.filter { event in
            guard !hiddenCalendarIDs.contains(event.calendarID), event.myResponse != .declined else { return false }
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
        Theme.color(hexString: event.colorHex) ?? Theme.color(hexString: calendarInfo(event.calendarID).map(colorHex(of:))) ?? Theme.accent
    }

    func color(for calendar: CalendarInfo) -> Color { Theme.color(hexString: colorHex(of: calendar)) ?? Theme.accent }

    /// A calendar's color: the one chosen here (exactly, whatever the provider keeps of it), else the provider's.
    func colorHex(of calendar: CalendarInfo) -> String {
        guard let chosen = preferences.colors[calendar.id], !chosen.wasChanged(in: calendar) else { return calendar.colorHex }
        return chosen.hex
    }

    // MARK: Calendar settings

    /// What PMail keeps on this Mac about each calendar, by ID: the color chosen and the notifications new events get
    /// where the provider doesn't keep them.
    struct CalendarPreferences: Codable {
        var colors: [String: ChosenColor] = [:]
        var eventReminders: [String: [Int]] = [:]
        var allDayReminders: [String: [AllDayReminder]] = [:]
        /// How invitations that overlap an event the account is going to are answered, if PMail answers them.
        var conflictReply: ConflictReply?
    }

    /// An automatic answer to invitations that overlap another event: No or Maybe, with a message for the organizer.
    struct ConflictReply: Codable, Hashable {
        var response: AttendeeResponse
        var message: String
    }

    /// A color chosen here, with the color the provider gave the calendar once it was saved (on Outlook, the nearest
    /// of its own). The calendar shows the one chosen until the provider's changes: then it was changed somewhere else.
    struct ChosenColor: Codable, Hashable {
        var hex: String
        var provider: String?

        func wasChanged(in calendar: CalendarInfo) -> Bool {
            provider.map { $0.caseInsensitiveCompare(calendar.colorHex) != .orderedSame } ?? false
        }
    }

    var preferences = CalendarPreferences()
    /// Answering invitations automatically: whether a look is under way, and when the last one began.
    @ObservationIgnored var autoAnswering = false
    @ObservationIgnored var autoAnswerAgain = false
    @ObservationIgnored var lastAutoAnswers: Date?

    func savePreferences() {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: "CalendarPreferences-\(account.id.uuidString)")
    }

    /// Colors chosen here for calendars whose color has since been changed somewhere else give way to it.
    private func forgetColorsChangedElsewhere() {
        let changed = calendars.filter { preferences.colors[$0.id]?.wasChanged(in: $0) == true }
        guard !changed.isEmpty else { return }
        for calendar in changed { preferences.colors[calendar.id] = nil }
        savePreferences()
    }

    /// Notes the color the provider gave a calendar after a new one was chosen, from a fresh list of calendars.
    private func noteProviderColor(of calendarID: String, in loaded: [CalendarInfo]) {
        guard preferences.colors[calendarID]?.provider == nil, let now = loaded.first(where: { $0.id == calendarID }) else { return }
        preferences.colors[calendarID]?.provider = now.colorHex
        savePreferences()
    }

    /// The notifications new events on a calendar get: the provider's defaults for the calendar where it keeps them,
    /// else the ones chosen in its settings here (and all-day events' always those).
    func defaultReminders(for calendarID: String, allDay: Bool) -> [Reminder] {
        if allDay { return (preferences.allDayReminders[calendarID] ?? []).filter { $0.minutesBefore >= 0 }.map { Reminder(minutes: $0.minutesBefore) } }
        if let calendar = calendarInfo(calendarID), service.settingsSupport(for: calendar).eventReminders, let minutes = calendar.defaultReminders {
            return minutes.map { Reminder(minutes: $0) }
        }
        return (preferences.eventReminders[calendarID] ?? [10]).map { Reminder(minutes: $0) }
    }

    /// Shows just one calendar, hiding the account's others.
    func showOnly(_ calendar: CalendarInfo) {
        hiddenCalendarIDs = Set(calendars.map(\.id)).subtracting([calendar.id])
        defaults.set(Array(hiddenCalendarIDs), forKey: "HiddenCalendars-\(account.id.uuidString)")
    }

    /// Gives a calendar a color: shown here at once, and kept by the provider where it keeps colors.
    func setColor(_ calendar: CalendarInfo, to hex: String) {
        let keeps = service.settingsSupport(for: calendar).color
        let current = calendarInfo(calendar.id) ?? calendar
        preferences.colors[calendar.id] = ChosenColor(hex: hex, provider: keeps ? nil : current.colorHex)
        savePreferences()
        changeCount += 1
        guard keeps else { return }
        let service = self.service
        Task {
            do {
                var settings = try await service.loadSettings(for: calendar)
                settings.colorHex = hex
                try await service.saveSettings(settings, for: calendar)
                if let loaded = try? await service.loadCalendars() {
                    noteProviderColor(of: calendar.id, in: loaded)
                    calendars = loaded
                    await cache?.save(calendars: loaded)
                }
            } catch {
                app?.report(error, doing: "Saving “\(calendar.name)”’s color")
            }
        }
    }

    /// What the provider keeps of a calendar's settings.
    func settingsSupport(for calendar: CalendarInfo) -> CalendarSettingsSupport { service.settingsSupport(for: calendar) }

    /// A calendar's settings: the provider's, with what's kept on this Mac.
    func settings(for calendar: CalendarInfo) async throws -> CalendarSettings {
        var settings = try await service.loadSettings(for: calendar)
        let support = service.settingsSupport(for: calendar)
        if let chosen = preferences.colors[calendar.id], !chosen.wasChanged(in: calendarInfo(calendar.id) ?? calendar) { settings.colorHex = chosen.hex }
        if !support.eventReminders { settings.eventReminders = preferences.eventReminders[calendar.id] ?? [10] }
        settings.allDayReminders = preferences.allDayReminders[calendar.id] ?? []
        return settings
    }

    /// Saves a calendar's settings: what the provider keeps goes to it, and the rest is kept on this Mac.
    func saveSettings(_ settings: CalendarSettings, for calendar: CalendarInfo) async throws {
        let support = service.settingsSupport(for: calendar)
        let current = calendarInfo(calendar.id) ?? calendar
        if settings.colorHex.caseInsensitiveCompare(colorHex(of: current)) != .orderedSame {
            preferences.colors[calendar.id] = ChosenColor(hex: settings.colorHex, provider: support.color ? nil : current.colorHex)
        }
        if !support.eventReminders { preferences.eventReminders[calendar.id] = settings.eventReminders }
        preferences.allDayReminders[calendar.id] = settings.allDayReminders
        savePreferences()
        changeCount += 1
        try await service.saveSettings(settings, for: calendar)
        if let loaded = try? await service.loadCalendars() {
            if support.color { noteProviderColor(of: calendar.id, in: loaded) }
            calendars = loaded
            await cache?.save(calendars: loaded)
        }
    }

    /// The events of a calendar as one iCalendar file: from a year back to two years ahead, each series once, without
    /// the invitations the account said No to (as the calendar shows them).
    func exportDocument(for calendar: CalendarInfo) async throws -> String {
        let now = today()
        let start = self.calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let end = self.calendar.date(byAdding: .year, value: 2, to: now) ?? now
        let events = try await service.loadEvents(in: [calendar.id], from: start, to: end).filter { !$0.isTask && $0.myResponse != .declined }
        return ICalendar.exportDocument(for: events, ownerEmail: account.email, through: end)
    }

    // MARK: Making and changing events

    /// A new event starting at `start` (an hour long), or the next half hour; or a new item of another kind there (a
    /// task, out of office, focus time).
    func newDraft(start: Date? = nil, end: Date? = nil, allDay: Bool = false, guests: [MailAddress] = [], type: EventType = .event) -> EventDraft? {
        guard let calendarInfo = defaultCalendar ?? (type == .task ? defaultTaskList : nil) else { return nil }
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
        draft.reminders = defaultReminders(for: calendarInfo.id, allDay: allDay)
        if type != .event {
            guard type != .task || defaultTaskList != nil else { return nil }
            retype(&draft, as: type)
        }
        return draft
    }

    /// The kinds a draft can be. Something new can be any (a task where the account has task lists, the rest where it
    /// has a calendar to put them in). An event can become out of office or focus time and back, unless it's a
    /// meeting; a task stays a task, since it lives in a task list rather than a calendar.
    func types(for draft: EventDraft) -> [EventType] {
        guard let original = draft.original else { return newTypes }
        if original.isTask { return [.task] }
        let isMeeting = original.attendees.contains { !$0.address.isSameMailbox(as: account.email) }
        return isMeeting ? [draft.type] : [.event, .outOfOffice, .focusTime]
    }

    /// The kinds of thing that can be made: a task where the account has task lists, the rest where it has a calendar
    /// to put them in.
    var newTypes: [EventType] {
        var types: [EventType] = defaultCalendar == nil ? [] : [.event]
        if defaultTaskList != nil { types.append(.task) }
        if defaultCalendar != nil { types += [.outOfOffice, .focusTime] }
        return types
    }

    /// Whether the calendar can decline invitations for out of office or focus time itself: a Google account's main
    /// calendar can, where the account is a work or school one (not for an event whose kind it couldn't keep).
    /// Whether out of office or focus time can decline meetings: on any of the account's own calendars. A Google
    /// Workspace account's main calendar does it itself; elsewhere PMail does.
    func canDecline(_ draft: EventDraft) -> Bool {
        guard draft.type == .outOfOffice || draft.type == .focusTime, let calendar = calendarInfo(draft.calendarID) else { return false }
        return Self.countsAsOwn(calendar)
    }

    /// Whether the calendar itself declines meetings during this out of office or focus time (a Google account's main
    /// calendar, where it keeps the kind), rather than PMail.
    func providerDeclines(_ draft: EventDraft) -> Bool {
        account.kind == .google && calendarInfo(draft.calendarID)?.isPrimary == true && draft.original?.isTypeLocal != true
    }

    /// Makes a draft another kind. Something new gets what suits the kind: a task is all day on its day in the default
    /// task list, out of office takes the whole day, focus time a couple of hours, and none of them has guests or a
    /// video meeting. An event that's already saved keeps its time and calendar.
    func retype(_ draft: inout EventDraft, as type: EventType) {
        let previous = draft.type
        guard previous != type else { return }
        draft.type = type
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.title == previous.defaultTitle { draft.title = type.defaultTitle }
        guard draft.isNew else { return }
        let day = calendar.startOfDay(for: draft.start)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        if type != .task, previous == .task, let calendarInfo = defaultCalendar { draft.calendarID = calendarInfo.id }
        if type != .event {
            draft.guests = []
            draft.addsNativeConference = false
            draft.availability = .busy
        }
        switch type {
        case .task:
            if let list = defaultTaskList { draft.calendarID = list.id }
            (draft.isAllDay, draft.start, draft.end, draft.reminders, draft.repeatRule) = (true, day, nextDay, [], nil)
        case .outOfOffice:
            (draft.isAllDay, draft.start, draft.end, draft.reminders) = (true, day, nextDay, [])
        case .focusTime:
            if draft.isAllDay {
                draft.start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            }
            (draft.isAllDay, draft.end, draft.reminders) = (false, draft.start.addingTimeInterval(2 * 3_600), [Reminder(minutes: 10)])
        case .event:
            if draft.isAllDay {
                draft.start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
                (draft.isAllDay, draft.end, draft.reminders) = (false, draft.start.addingTimeInterval(3_600), [Reminder(minutes: 10)])
            }
        }
    }

    func draft(for event: CalendarEvent) -> EventDraft {
        var draft = EventDraft(original: event, calendarID: event.calendarID, title: event.title, start: event.start, end: event.end,
                               isAllDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "", notesHTML: event.notesHTML,
                               guests: event.attendees.filter { !$0.address.isSameMailbox(as: account.email) }.map(\.address),
                               conference: event.conference, reminders: event.reminderMinutes.map(Reminder.init(minutes:)),
                               colorHex: event.colorHex, availability: event.availability, type: event.type,
                               declinesInvitations: event.declinesInvitations, declineMessage: event.declineMessage ?? "",
                               declinesExisting: event.declinesExisting,
                               isCompleted: event.isCompleted, visibility: event.visibility, guestsCanModify: event.guestsCanModify,
                               guestsCanInviteOthers: event.guestsCanInviteOthers, guestsCanSeeOtherGuests: event.guestsCanSeeOtherGuests)
        if !event.recurrence.isEmpty {
            draft.repeatRule = RepeatRule(lines: event.recurrence, start: event.start, calendar: calendar)
            draft.keepsOwnRule = draft.repeatRule == nil
        }
        if event.conference?.kind == .faceTime { draft.faceTimeLink = event.conference?.joinURL.absoluteString ?? "" }
        return draft
    }

    /// The account's contacts, which guests newly invited are added to (or asked about).
    @ObservationIgnored weak var contacts: ContactsViewModel?
    /// Emails invitations, answers and cancellations when the calendar has no server to send them.
    @ObservationIgnored weak var mailer: InvitationMailer?
    /// The account's mail, whose invitation emails are marked read once they're answered here.
    @ObservationIgnored weak var mailModel: MailViewModel?
    /// Changes made a moment ago that Undo can still take back, by their note along the bottom: what sends the messages
    /// PMail keeps from guests once the pause is over (or deletes the event, where its calendar couldn't put it back).
    @ObservationIgnored private var undoableWork: [UUID: Task<Void, Never>] = [:]
    /// Changes being made, shown already: a load meanwhile still shows them.
    @ObservationIgnored private var undoable: [UUID: [CalendarChange]] = [:]
    /// How long Undo is offered after a change, instead of Undo Send's (the self-test makes it short).
    @ObservationIgnored var undoDelay: TimeInterval?

    /// How long Undo is offered after a change: as long as messages wait before they go (Settings ▸ Mail ▸ Undo Send).
    private var undoPause: TimeInterval { undoDelay ?? UndoSend.seconds }

    /// When messages kept from guests for Undo go, for a change made now.
    private var undoDeadline: Date { AppClock.now().addingTimeInterval(undoPause) }

    /// What a save did: whether it reached the calendar, the event as saved, and the messages PMail keeps from its
    /// guests until Undo has gone.
    struct SavedChange {
        var outcome: SaveOutcome
        var saved: CalendarEvent?
        var held: [UUID] = []
    }

    /// Saves a draft at once, then says so with Undo for as long as Undo Send's pause (Settings ▸ Mail). Undo puts the
    /// event back as it was, or takes a new one away; the invitations PMail emails its guests wait until the pause is
    /// over, so Undo stops them too. A save that fails opens it again, saying why.
    func saveWithUndo(_ draft: EventDraft) {
        Task { await saveNow(draft) }
    }

    private func saveNow(_ draft: EventDraft) async {
        // What Undo puts back: the event as its calendar has it now.
        var snapshot: CalendarSnapshot?
        if let original = draft.original { snapshot = await service.snapshot(of: original) }
        do {
            let change = try await save(draft, holdingUntil: undoDeadline)
            guard change.outcome == .saved else {
                app?.show("Saved on this Mac. It’ll go to your \(draft.isTask ? "tasks" : "calendar") when you’re back online.")
                return
            }
            offerUndo(draft.isNew ? (draft.isTask ? "Task saved." : "Event saved.") : "Changes saved.",
                      undone: draft.isNew ? "Saving undone." : "Changes undone.", held: change.held) { [weak self] in
                await self?.takeBack(draft, saved: change.saved, snapshot: snapshot, showing: draft.original.map { [$0] } ?? [])
            }
        } catch {
            var again = draft
            again.saveError = "It wasn’t saved: \(describe(error))"
            if app?.sheet == nil {
                app?.sheet = .eventEditor(again)
            } else {
                app?.show("“\(draft.title.isEmpty ? "(No title)" : draft.title)” wasn’t saved: \(describe(error))", actionTitle: "Edit") { [weak self] in
                    self?.app?.sheet = .eventEditor(again)
                }
            }
        }
    }

    /// Says a change was made, with Undo for as long as Undo Send's pause. Once the pause is over, the messages PMail kept
    /// from guests (`held`) go; Undo drops them and puts things back (`takeBack`).
    private func offerUndo(_ note: String, undone: String, held: [UUID], takeBack: @escaping () async -> Void) {
        let id = UUID()
        let pause = undoPause
        undoableWork[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled, let self else { return }
            self.undoableWork[id] = nil
            for message in held { await self.mailer?.release(message) }
        }
        app?.show(note, actionTitle: "Undo", duration: pause) { [weak self] in
            guard let self, let waiting = self.undoableWork.removeValue(forKey: id) else { return }
            waiting.cancel()
            Task {
                for message in held { await self.mailer?.drop(message) }
                await takeBack()
                self.app?.show(undone)
            }
        }
    }

    /// Undo for a save: a new event or task is taken away; a changed one is put back as its calendar had it (exactly,
    /// where the calendar can), else changed back. It shows as it was at once (`originals`), and nothing is emailed.
    private func takeBack(_ draft: EventDraft, saved: CalendarEvent?, snapshot: CalendarSnapshot?, showing originals: [CalendarEvent]) async {
        guard let saved else { return }
        events.removeAll { $0.id == saved.id }
        restore(originals)
        do {
            if draft.original == nil {
                try await service.delete(saved, scope: .allEvents)
            } else if let snapshot {
                try await service.restore(snapshot, removing: saved)
            } else if let original = draft.original {
                var back = original
                (back.id, back.seriesID, back.resourceHref, back.etag) = (saved.id, saved.seriesID, saved.resourceHref, saved.etag)
                _ = try await service.update(back, scope: draft.scope, addingConference: false)
            }
        } catch {
            app?.report(error, doing: "Undoing the change")
        }
        changeCount += 1
        reload()
    }

    /// Puts events back as they were, in place of any copy showing.
    private func restore(_ originals: [CalendarEvent]) {
        events.removeAll { event in originals.contains { $0.id == event.id } }
        events += originals
    }

    /// Emails guests about an event now, or keeps the message on this Mac until a time (Undo's pause) when one is given;
    /// the kept message's ID.
    private func tell(_ method: Invitation.Method, text: String, about event: CalendarEvent, to guests: [MailAddress],
                      holdingUntil deadline: Date?) async -> [UUID] {
        guard let mailer, !guests.isEmpty else { return [] }
        guard let deadline else {
            mailer.send(method, text: text, about: event, to: guests)
            return []
        }
        return await mailer.hold(method, text: text, about: event, to: guests, until: deadline).map { [$0] } ?? []
    }

    // MARK: Dragging

    /// A repeating event dropped somewhere new, waiting to hear whether that time moves or every time.
    struct PendingMove: Identifiable {
        let id = UUID()
        let event: CalendarEvent
        let start: Date
        let end: Date
    }

    var pendingMove: PendingMove?
    /// Whether an event is being dragged, and when the last drag ended: letting go of a drag also clicks the event,
    /// which mustn't open its details.
    @ObservationIgnored private var isDraggingEvent = false
    @ObservationIgnored private var dragEndedAt: Date?

    /// Whether an event can be dragged somewhere else: one on a calendar that can be changed, that isn't called off or
    /// someone else's meeting (theirs to move).
    func canMove(_ event: CalendarEvent) -> Bool {
        guard calendarInfo(event.calendarID)?.isReadOnly == false, event.status != .cancelled else { return false }
        return event.organizer.map { $0.isSameMailbox(as: account.email) } ?? true
    }

    /// Shows an event's details, unless it was just dragged.
    func select(_ event: CalendarEvent) {
        guard !isDraggingEvent, dragEndedAt.map({ Date().timeIntervalSince($0) > 0.3 }) ?? true else { return }
        selectedEventID = event.id
    }

    /// An event starts being dragged: its details close, and the pointer is a closed hand.
    func dragStarted() {
        guard !isDraggingEvent else { return }
        isDraggingEvent = true
        selectedEventID = nil
        NSCursor.closedHand.push()
    }

    func dragEnded() {
        guard isDraggingEvent else { return }
        isDraggingEvent = false
        dragEndedAt = Date()
        NSCursor.pop()
    }

    /// Moves an event dropped somewhere new in the day, week or month view. A repeating event asks first whether that
    /// time moves or every time.
    func drop(_ event: CalendarEvent, start: Date, end: Date) {
        guard start != event.start || end != event.end else { return }
        if event.isRecurring {
            pendingMove = PendingMove(event: event, start: start, end: end)
        } else {
            move(event, start: start, end: end, scope: .thisEvent)
        }
    }

    /// Moves an event (or every time of a repeating one, by as much) to start and end at other times. It shows there at
    /// once and is saved at once, then says so with Undo for as long as Undo Send's pause: Undo puts it back, and the
    /// updates PMail emails its guests wait until the pause is over.
    func move(_ event: CalendarEvent, start: Date, end: Date, scope: RecurrenceScope) {
        pendingMove = nil
        var draft = draft(for: event)
        (draft.start, draft.end, draft.scope) = (start, end, scope)
        // Every time of the series moves on the wall clock by whole days, or by the same stretch of time.
        let days = calendar.dateComponents([.day], from: event.start, to: start).day ?? 0
        let byDays = calendar.date(byAdding: .day, value: days, to: event.start) == start
        let shift = start.timeIntervalSince(event.start)
        let originals = events.filter { $0.id == event.id || (scope == .allEvents && event.seriesID != nil && $0.seriesID == event.seriesID) }
        let changes = originals.map { occurrence -> CalendarChange in
            var moved = occurrence
            if occurrence.id == event.id {
                (moved.start, moved.end) = (start, end)
            } else if byDays {
                moved.start = calendar.date(byAdding: .day, value: days, to: occurrence.start) ?? occurrence.start
                moved.end = calendar.date(byAdding: .day, value: days, to: occurrence.end) ?? occurrence.end
            } else {
                (moved.start, moved.end) = (occurrence.start.addingTimeInterval(shift), occurrence.end.addingTimeInterval(shift))
            }
            return .update(moved, scope: .thisEvent, addingConference: false)
        }
        events = CalendarChange.applying(changes, to: events)
        let shown = UUID()
        undoable[shown] = changes
        let title = event.shownTitle
        Task {
            let snapshot = await service.snapshot(of: event)
            do {
                let change = try await save(draft, holdingUntil: undoDeadline)
                undoable[shown] = nil
                guard change.outcome == .saved else {
                    app?.show("Moved on this Mac. It’ll go to your \(draft.isTask ? "tasks" : "calendar") when you’re back online.")
                    return
                }
                offerUndo(draft.isTask ? "Task moved." : "Event moved.", undone: "Move undone.", held: change.held) {
                    await self.takeBack(draft, saved: change.saved, snapshot: snapshot, showing: originals)
                }
            } catch {
                undoable[shown] = nil
                restore(originals)
                app?.show("“\(title)” wasn’t moved: \(describe(error))")
            }
        }
    }

    /// Saves a draft: makes the event (or task), or changes it, creating its video meeting if asked, and emails the
    /// invitations PMail sends. When the calendar can't be reached, the change is kept on this Mac and sent once it
    /// can. Guests just invited who aren't in contacts are added (or asked about), as people written to are.
    @discardableResult
    func save(_ draft: EventDraft) async throws -> SaveOutcome {
        try await save(draft, holdingUntil: nil).outcome
    }

    /// The same, keeping the invitations PMail emails on this Mac until a time (Undo's pause), when one is given.
    private func save(_ draft: EventDraft, holdingUntil deadline: Date?) async throws -> SavedChange {
        if draft.isTask { return try await saveTask(draft) }
        let change = try await saveEvent(draft, holdingUntil: deadline)
        let invited = draft.guests.filter { guest in
            !(draft.original?.attendees.contains { $0.address.isSameMailbox(as: guest.email) } ?? false)
        }
        if let contacts, !invited.isEmpty { Task { await contacts.addPeopleWritten(to: invited) } }
        return change
    }

    private func saveEvent(_ draft: EventDraft, holdingUntil deadline: Date?) async throws -> SavedChange {
        var event = draft.original ?? CalendarEvent(calendarID: draft.calendarID, start: draft.start, end: draft.end)
        event.calendarID = draft.calendarID
        event.title = draft.title.trimmingCharacters(in: .whitespaces)
        event.start = draft.start
        event.end = max(draft.end, draft.isAllDay ? draft.start.addingTimeInterval(86_400) : draft.start.addingTimeInterval(60))
        event.isAllDay = draft.isAllDay
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.notesHTML = draft.notes.isEmpty ? nil : draft.notesHTML
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
        // Each notification once, as many as the calendar keeps.
        var minutes: [Int] = []
        for reminder in draft.reminders where !minutes.contains(reminder.minutes) { minutes.append(reminder.minutes) }
        event.reminderMinutes = Array(minutes.prefix(features.maximumReminders))
        if draft.changesRepeat {
            // A new rule keeps the dates taken out one at a time.
            let exceptions = event.recurrence.filter { $0.uppercased().hasPrefix("EXDATE") }
            let first = draft.original?.isRecurring == true ? (draft.original?.start ?? draft.start) : draft.start
            event.recurrence = draft.repeatRule.map { exceptions + [$0.rrule(start: first, isAllDay: draft.isAllDay, calendar: calendar)] } ?? []
        }
        event.visibility = features.visibilities.contains(draft.visibility) ? draft.visibility : .default
        event.guestsCanModify = draft.guestsCanModify
        event.guestsCanInviteOthers = draft.guestsCanInviteOthers
        event.guestsCanSeeOtherGuests = draft.guestsCanSeeOtherGuests
        event.colorHex = draft.colorHex
        event.availability = draft.availability
        event.type = draft.type
        event.declinesInvitations = draft.type != .event && draft.declinesInvitations
        let message = draft.declineMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        event.declineMessage = event.declinesInvitations && !message.isEmpty ? message : nil
        event.declinesExisting = event.declinesInvitations && draft.declinesExisting
        let saved: CalendarEvent
        // A new rule for a repeating event is for the whole series.
        let scope = draft.changesRepeat && draft.original?.isRecurring == true ? .allEvents : draft.scope
        let later: CalendarChange
        if draft.original == nil {
            var made = event
            made.id = LocalID.make()
            later = .create(made, addingConference: draft.addsNativeConference)
        } else {
            later = .update(event, scope: scope, addingConference: draft.addsNativeConference)
        }
        if waits(event.id), await keep(later) { return SavedChange(outcome: .waiting) }
        do {
            if draft.original == nil {
                saved = try await service.create(event, addingConference: draft.addsNativeConference)
            } else {
                saved = try await service.update(event, scope: scope, addingConference: draft.addsNativeConference)
            }
        } catch let error where PMailError.isConnectionProblem(error) {
            if await keep(later) { return SavedChange(outcome: .waiting) }
            throw error
        }
        changeCount += 1
        // Invitations PMail emails: all of them on a calendar without a server, else those to guests a calendar server on
        // an IMAP/POP account doesn't invite, and on iCloud when the Apple Account's email isn't an iCloud address.
        // Google, Microsoft and iCloud otherwise send every one of theirs.
        // With Undo offered, they wait until it's gone.
        var held: [UUID] = []
        if service.emailsInvitations || saved.attendees.contains(where: \.invitedByEmail) || (draft.original?.attendees.contains(where: \.invitedByEmail) ?? false) {
            if let deadline {
                held = await emailInvitations(for: saved, before: draft.original, holdingUntil: deadline)
            } else {
                Task { await emailInvitations(for: saved, before: draft.original) }
            }
        }
        // Out of office or focus time that PMail declines meetings for: the ones already planned, if it says so.
        if saved.type == .outOfOffice || saved.type == .focusTime { Task { await declinePeriodSaved(saved) } }
        // A repeating event's other times come with the next load.
        if draft.changesRepeat || (draft.original != nil && (scope == .allEvents || draft.original?.calendarID != saved.calendarID)) {
            if draft.repeatRule == nil { events.removeAll { $0.id == saved.id || $0.id == draft.original?.id } }
            reload()
        } else {
            events.removeAll { $0.id == saved.id || $0.id == draft.original?.id }
            events.append(saved)
        }
        return SavedChange(outcome: .saved, saved: saved, held: held)
    }

    /// Saves a task: on its day in its list, with its notes and whether it's done.
    private func saveTask(_ draft: EventDraft) async throws -> SavedChange {
        let day = calendar.startOfDay(for: draft.start)
        var task = draft.original ?? CalendarEvent(calendarID: draft.calendarID, start: day, end: day, type: .task)
        task.calendarID = draft.calendarID
        task.title = draft.title.trimmingCharacters(in: .whitespaces)
        task.start = day
        task.end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        task.isAllDay = true
        task.notes = draft.notes.isEmpty ? nil : draft.notes
        task.isCompleted = draft.isCompleted
        task.type = .task
        var made = task
        made.id = LocalID.make()
        let later: CalendarChange = draft.original == nil ? .create(made, addingConference: false) : .update(task, scope: .thisEvent, addingConference: false)
        if waits(task.id), await keep(later) { return SavedChange(outcome: .waiting) }
        let saved: CalendarEvent
        do {
            saved = draft.original == nil ? try await service.create(task, addingConference: false)
                : try await service.update(task, scope: .thisEvent, addingConference: false)
        } catch let error where PMailError.isConnectionProblem(error) {
            if await keep(later) { return SavedChange(outcome: .waiting) }
            throw error
        }
        changeCount += 1
        events.removeAll { $0.id == saved.id || $0.id == draft.original?.id }
        events.append(saved)
        return SavedChange(outcome: .saved, saved: saved)
    }

    /// Ticks a task off (or back on): here at once, then in its list.
    func setCompleted(_ task: CalendarEvent, _ done: Bool) {
        guard let index = events.firstIndex(where: { $0.id == task.id }) else { return }
        events[index].isCompleted = done
        changeCount += 1
        var changed = task
        changed.isCompleted = done
        let service = self.service
        let later = CalendarChange.update(changed, scope: .thisEvent, addingConference: false)
        Task {
            if waits(task.id), await keep(later) { return }
            do {
                let saved = try await service.update(changed, scope: .thisEvent, addingConference: false)
                changeCount += 1
                if let index = events.firstIndex(where: { $0.id == task.id }) { events[index] = saved }
            } catch {
                if PMailError.isConnectionProblem(error), await keep(later) { return }
                if let index = events.firstIndex(where: { $0.id == task.id }) { events[index].isCompleted = !done }
                app?.report(error, doing: done ? "Marking the task done" : "Marking the task not done")
            }
        }
    }

    /// Deletes an event (one time of a repeating event, or all of them): it's gone from the window at once, and from its
    /// calendar at once where the calendar can put it back exactly, then Undo is offered for as long as Undo Send's
    /// pause. Undo puts it back; the cancellations PMail emails its guests wait until the pause is over. A calendar
    /// that can't put it back (Google, Microsoft, a task list) gets the deletion once the pause is over instead.
    func delete(_ event: CalendarEvent, scope: RecurrenceScope) {
        let later = CalendarChange.delete(event, scope: scope)
        let removed = events.filter { shown in !CalendarChange.applying([later], to: [shown]).contains { $0.id == shown.id } }
        events = CalendarChange.applying([later], to: events)
        changeCount += 1
        selectedEventID = nil
        let shown = UUID()
        undoable[shown] = [later]
        let restored = event.isTask ? "Task restored." : "Event restored."
        Task {
            guard let snapshot = await service.snapshot(of: event) else {
                return deleteAfterPause(event, scope: scope, removed: removed, shown: shown, restored: restored)
            }
            let result = await finishDeleting(event, scope: scope, restoring: removed, holdingUntil: undoDeadline)
            undoable[shown] = nil
            guard result.deleted else { return }
            offerUndo(event.isTask ? "Task deleted." : "Event deleted.", undone: restored, held: result.held) {
                self.restore(removed)
                do {
                    try await self.service.restore(snapshot, removing: nil)
                } catch {
                    self.app?.report(error, doing: "Putting the event back")
                }
                self.changeCount += 1
                self.reload()
            }
        }
    }

    /// Deletes an event once Undo's pause is over, for a calendar that can't put it back afterwards: it's gone from the
    /// window already, and neither the calendar nor the guests hear of it before then.
    private func deleteAfterPause(_ event: CalendarEvent, scope: RecurrenceScope, removed: [CalendarEvent], shown: UUID, restored: String) {
        let pause = undoPause
        undoableWork[shown] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled, let self else { return }
            self.undoableWork[shown] = nil
            await self.finishDeleting(event, scope: scope, restoring: removed, holdingUntil: nil)
            self.undoable[shown] = nil
        }
        app?.show(event.isTask ? "Task deleted." : "Event deleted.", actionTitle: "Undo", duration: pause) { [weak self] in
            guard let self, let waiting = self.undoableWork.removeValue(forKey: shown) else { return }
            waiting.cancel()
            self.undoable[shown] = nil
            self.restore(removed)
            self.app?.show(restored)
        }
    }

    /// Deletes an event from its calendar, and tells the guests PMail invites by email (at once, or keeping the messages
    /// until `deadline`). Offline, the deletion waits on this Mac; if the calendar turns it down, the event comes back.
    /// Whether it was deleted from the calendar, and the messages kept.
    @discardableResult
    private func finishDeleting(_ event: CalendarEvent, scope: RecurrenceScope, restoring removed: [CalendarEvent],
                                holdingUntil deadline: Date?) async -> (deleted: Bool, held: [UUID]) {
        let service = self.service
        let later = CalendarChange.delete(event, scope: scope)
        let waitingText = "Deleted on this Mac. It’ll be deleted from your calendar when you’re back online."
        if waits(event.id), await keep(later) {
            if !LocalID.isLocal(event.id) { app?.show(waitingText) }
            return (false, [])
        }
        // Called off for everyone PMail invites by email (everyone, on a calendar without a server); asked for while
        // the event's still there.
        let guests = Self.invitedByEmail(guestsToTell(about: event), in: event, all: service.emailsInvitations)
        let wholeEvent = scope == .allEvents || !event.isRecurring
        let cancellation = !guests.isEmpty && wholeEvent
            ? try? await service.invitationText(for: event, method: .cancel, attendees: nil) : nil
        do {
            try await service.delete(event, scope: scope)
            changeCount += 1
            var held: [UUID] = []
            if let cancellation { held += await tell(.cancel, text: cancellation, about: event, to: guests, holdingUntil: deadline) }
            // One time of a repeating meeting: guests get the series without it.
            if !guests.isEmpty, !wholeEvent, let update = try? await service.invitationText(for: event, method: .request, attendees: nil) {
                held += await tell(.request, text: update, about: event, to: guests, holdingUntil: deadline)
            }
            return (true, held)
        } catch {
            if PMailError.isConnectionProblem(error), await keep(later) {
                app?.show(waitingText)
                return (false, [])
            }
            restore(removed)
            app?.report(error, doing: "Deleting the event")
            return (false, [])
        }
    }

    /// Answers an invitation by hand: one time of a repeating meeting, or all of them.
    func respond(to event: CalendarEvent, with response: AttendeeResponse, scope: RecurrenceScope) {
        respond(to: event, with: response, comment: nil, scope: scope, automatically: false)
    }

    /// Answers an invitation (one time of a repeating meeting, or all of them): on the calendar at once, then through
    /// the provider, with a message for the organizer where one's given. Answered by hand, its email is marked read; an
    /// answer PMail gave on its own leaves it unread, so it's still seen.
    func respond(to event: CalendarEvent, with response: AttendeeResponse, comment: String?, scope: RecurrenceScope, automatically: Bool) {
        let series = scope == .allEvents ? event.seriesID : nil
        for index in events.indices where events[index].id == event.id || (series != nil && events[index].seriesID == series) {
            events[index].myResponse = response
        }
        // Said No to, it leaves the calendar, and its details close.
        if response == .declined, selectedEventID == event.id { selectedEventID = nil }
        changeCount += 1
        let service = self.service
        let later = CalendarChange.answer(event, response: response, scope: scope)
        Task {
            if waits(event.id), await keep(later) { return }
            do {
                try await service.respond(to: event, with: response, comment: comment, scope: scope)
                changeCount += 1
                // Answered here, the invitation email needn't wait unread.
                if !automatically, let mailModel, event.organizer.map({ !$0.isSameMailbox(as: account.email) }) ?? false {
                    Task { await mailModel.markInvitationRead(for: event) }
                }
                // The answer goes to the organizer by email when no server sends it (a calendar kept on this Mac, or
                // an invitation PMail took in from an email).
                if service.takesInEmailedInvitations, let organizer = event.organizer, !organizer.isSameMailbox(as: account.email),
                   var reply = try? await service.replyText(for: event, response: response, scope: scope) {
                    if let comment { reply = InvitationText.withComment(reply, comment: comment) }
                    mailer?.send(.reply, text: reply, about: event, to: [organizer], answer: response, note: comment)
                }
            } catch {
                if PMailError.isConnectionProblem(error), await keep(later) { return }
                app?.report(error, doing: "Answering the invitation")
                reload()
            }
        }
    }

    // MARK: Invitations by email

    /// The guests of a meeting the account organizes, who hear about its changes (not the account itself).
    func guestsToTell(about event: CalendarEvent) -> [MailAddress] {
        guard event.organizer.map({ $0.isSameMailbox(as: account.email) }) ?? true else { return [] }
        return event.attendees.filter { !$0.isOrganizer && !$0.address.isSameMailbox(as: account.email) }.map(\.address)
    }

    /// The guests PMail invites by email: all of them on a calendar without a server (`all`), else the ones the
    /// server leaves to PMail.
    static func invitedByEmail(_ guests: [MailAddress], in event: CalendarEvent, all: Bool) -> [MailAddress] {
        all ? guests : guests.filter { guest in event.attendees.contains { $0.invitedByEmail && $0.address.isSameMailbox(as: guest.email) } }
    }

    /// Emails a saved meeting's invitation to the guests PMail invites by email (everyone, for a calendar with no
    /// server to send it): to each of them when something they'd want to know changed (or it's new), else to those PMail
    /// has just started inviting (new guests, and ones the server had and left to PMail); guests taken off get a
    /// cancellation. With a `deadline` (Undo's pause), the messages are kept on this Mac until then; their IDs.
    @discardableResult
    private func emailInvitations(for saved: CalendarEvent, before original: CalendarEvent?, holdingUntil deadline: Date? = nil) async -> [UUID] {
        guard mailer != nil else { return [] }
        let all = service.emailsInvitations
        let current = guestsToTell(about: saved)
        let guests = Self.invitedByEmail(current, in: saved, all: all)
        let earlier = original.map(guestsToTell(about:)) ?? []
        let invitedBefore = original.map { Self.invitedByEmail(earlier, in: $0, all: all) } ?? []
        let added = guests.filter { guest in !invitedBefore.contains { $0.isSameMailbox(as: guest.email) } }
        let removed = invitedBefore.filter { guest in !current.contains { $0.isSameMailbox(as: guest.email) } }
        let matters = original.map { old in
            old.title != saved.title || old.start != saved.start || old.end != saved.end || old.isAllDay != saved.isAllDay
                || old.location != saved.location || old.notes != saved.notes || old.recurrence != saved.recurrence
                || old.conference?.joinURL != saved.conference?.joinURL
        } ?? true
        let invited = matters ? guests : added
        var held: [UUID] = []
        if !invited.isEmpty, let text = try? await service.invitationText(for: saved, method: .request, attendees: nil) {
            held += await tell(.request, text: text, about: saved, to: invited, holdingUntil: deadline)
        }
        if !removed.isEmpty, let text = try? await service.invitationText(for: saved, method: .cancel, attendees: removed) {
            held += await tell(.cancel, text: text, about: saved, to: removed, holdingUntil: deadline)
        }
        return held
    }

    /// Answers an invitation that came by email. The calendar's own copy is answered when it has one (its server, or
    /// PMail for a calendar without one, tells the organizer); a calendar without a server takes the invitation in
    /// first; otherwise the answer goes to the organizer by email.
    func answer(_ invitation: Invitation, with response: AttendeeResponse) {
        // An invitation to a repeating meeting is answered for all of it; one for a single time of it, for that time.
        let scope: RecurrenceScope = invitation.event.recurrence.isEmpty ? .thisEvent : .allEvents
        Task {
            // The calendar's copy is brought up to this invitation first (added, or updated when this is newer), so the
            // answer goes on the version it's for.
            if service.takesInEmailedInvitations {
                let existing = await event(withUID: invitation.uid, near: invitation.event)
                if existing.map({ Self.differs($0, from: invitation.event) }) ?? true {
                    do {
                        try await service.receive(invitation)
                    } catch {
                        app?.report(error, doing: "Adding the invitation to your calendar")
                        return
                    }
                }
                if let event = await event(withUID: invitation.uid, near: invitation.event, fresh: true) {
                    respond(to: event, with: response, scope: scope)
                    reload()
                    return
                }
            } else if let event = await event(withUID: invitation.uid, near: invitation.event) {
                return respond(to: event, with: response, scope: scope)
            }
            guard let organizer = invitation.organizer,
                  let reply = InvitationText.reply(to: invitation.text, from: account.address, response: response) else {
                app?.show("This invitation doesn’t say who to answer.")
                return
            }
            mailer?.send(.reply, text: reply, about: invitation.event, to: [organizer], answer: response)
            answeredByEmail[invitation.uid] = response
        }
    }

    /// Answers given by email to invitations the calendar doesn't have, by UID, for the message to show.
    var answeredByEmail: [String: AttendeeResponse] = [:]

    /// Takes an invitation from an email into the calendar, when the calendar takes them in: one it doesn't have yet,
    /// a change to one it has (whatever changed: the time, place, guests, description…), or a cancellation, which
    /// marks it canceled. It goes in only when the account is one of its guests.
    func takeIn(_ invitation: Invitation) async {
        guard service.takesInEmailedInvitations, invitation.method != .other else { return }
        // A guest's answer to a meeting the account organizes goes on their line.
        if invitation.method == .reply {
            guard (try? await service.receive(invitation)) != nil else { return }
            changeCount += 1
            return reload()
        }
        let existing = await event(withUID: invitation.uid, near: invitation.event)
        if invitation.method == .request {
            // Unchanged and still waiting for an answer, there's nothing to do. An answered copy is looked at again: an
            // answer given before something else (Calendar on a Mac, say) took a move in waits again.
            if let existing, !Self.differs(existing, from: invitation.event), existing.myResponse == .needsAction || existing.myResponse == nil {
                return
            }
        } else {
            guard let existing, existing.status != .cancelled else { return }
        }
        guard (try? await service.receive(invitation)) != nil else { return }
        changeCount += 1
        reload()
    }

    /// Whether an invitation says something about its event that the calendar's copy doesn't: a change since.
    static func differs(_ event: CalendarEvent, from invited: CalendarEvent) -> Bool {
        event.title != invited.title || event.start != invited.start || event.end != invited.end || event.isAllDay != invited.isAllDay
            || event.location != invited.location || event.notes != invited.notes || event.status != invited.status
            || Set(event.attendees.map { $0.address.email.lowercased() }) != Set(invited.attendees.map { $0.address.email.lowercased() })
    }

    /// The account's answer to an invitation, as far as PMail knows: the calendar's copy, or an answer sent by email.
    func currentAnswer(to invitation: Invitation) -> AttendeeResponse? {
        events.first { $0.uid == invitation.uid && !$0.isTask }?.myResponse ?? answeredByEmail[invitation.uid]
    }

    /// When the calendar's copy of an invitation happens now, if that's not when this email says (it changed since).
    func changedTime(of invitation: Invitation) -> CalendarEvent? {
        guard let copy = events.first(where: { $0.uid == invitation.uid && !$0.isTask }),
              copy.start != invitation.event.start || copy.end != invitation.event.end else { return nil }
        return copy
    }

    /// The calendar's event with an iCalendar UID: one already loaded (unless `fresh`), or one found around the
    /// invitation's time.
    func event(withUID uid: String, near reference: CalendarEvent, fresh: Bool = false) async -> CalendarEvent? {
        if !fresh, let loaded = events.first(where: { $0.uid == uid && !$0.isTask }) { return loaded }
        let ids = calendars.filter { !$0.isTaskList }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let found = try? await service.loadEvents(in: ids, from: reference.start.addingTimeInterval(-86_400), to: reference.end.addingTimeInterval(86_400))
        return found?.first { $0.uid == uid && !$0.isTask }
    }

    // MARK: Changes made offline

    /// Whether a change waits instead of going now: the Mac is offline, the event was made here and hasn't reached
    /// the server, or it has changes waiting already (so they go in order).
    private func waits(_ id: String) -> Bool {
        // A calendar kept on this Mac (the one kind that emails its own invitations) needs no network; the invitations
        // it emails wait in the Outbox instead.
        let offline = app?.sync?.isOnline == false && !service.emailsInvitations
        return offline || LocalID.isLocal(id) || waiting.contains { $0.event.id == id }
    }

    /// Keeps a change on this Mac until the calendar can be reached, and shows it. False when there's nowhere to keep it.
    private func keep(_ change: CalendarChange) async -> Bool {
        guard let pending else { return false }
        await pending.add(change, merging: CalendarChange.adding)
        waiting = await pending.all()
        events = CalendarChange.applying([change], to: events)
        changeCount += 1
        return true
    }

    /// Whether an event has changes waiting to be sent.
    func isWaiting(_ event: CalendarEvent) -> Bool { waiting.contains { $0.event.id == event.id } }

    /// Sends the changes made offline, oldest first, shows them as the server saved them, and says what it turned down.
    func sendWaitingChanges() async {
        guard let pending, !(await pending.all()).isEmpty else { return }
        let result = await pending.send(using: service)
        waiting = await pending.all()
        guard result.sent > 0 || !result.refused.isEmpty else { return }
        changeCount += 1
        for (id, saved) in result.saved {
            if let index = events.firstIndex(where: { $0.id == id }) { events[index] = saved }
            // A meeting made offline: its guests PMail invites by email get their invitations now.
            if LocalID.isLocal(id), !service.emailsInvitations, saved.attendees.contains(where: \.invitedByEmail) {
                Task { await emailInvitations(for: saved, before: nil) }
            }
        }
        events.removeAll { result.deleted.contains($0.id) }
        for refusal in result.refused {
            app?.show("“\(refusal.title.isEmpty ? "(No title)" : refusal.title)” couldn’t be saved to your calendar: \(refusal.reason)")
        }
        if !calendars.isEmpty {
            loadedInterval = nil
            loadIfNeeded(quietly: true)
        }
    }

    /// What "Add video conferencing" makes on a calendar: its own meeting, or a FaceTime link pasted in.
    func conferenceKind(for calendarID: String) -> Conference.Kind? { calendarInfo(calendarID)?.nativeConference }

    func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
