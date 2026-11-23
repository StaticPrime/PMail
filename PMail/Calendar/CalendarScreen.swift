import AppKit
import PMailKit
import SwiftUI

/// Calendar: the sidebar with Create, a small month and the calendars, and the day, week, month or schedule.
struct CalendarScreen: View {
    let app: AppModel
    let session: AccountSession
    let model: CalendarViewModel

    var body: some View {
        HStack(spacing: 0) {
            CalendarSidebar(app: app, model: model)
            Panel {
                VStack(spacing: 0) {
                    if model.needsSignIn {
                        Banner(text: "\(session.account.email) needs to be signed in again.", symbol: "person.crop.circle.badge.exclamationmark",
                               actionTitle: "Sign In…") { app.sheet = .addAccount(session.account.kind) }
                    } else if let error = model.error {
                        Banner(text: error, actionTitle: "Try Again") { model.start() }
                    } else if model.isOffline || app.sync?.isOnline == false {
                        OfflineBanner()
                    }
                    CalendarHeader(model: model)
                    Divider().overlay(Theme.divider)
                    let events = model.shownEvents(matching: app.searchText)
                    switch model.mode {
                    case .day, .week: TimeGridView(app: app, model: model, days: model.visibleDays, events: events)
                    case .month: MonthGridView(app: app, model: model, events: events)
                    case .schedule: ScheduleView(app: app, model: model, events: events, searching: !app.searchText.isEmpty)
                    }
                }
            }
        }
    }
}

/// Today, the arrows, what's showing and the view picker.
private struct CalendarHeader: View {
    let model: CalendarViewModel
    @State private var modeMenu = PopUpMenu()

    var body: some View {
        HStack(spacing: 6) {
            OutlinePillButton(title: "Today") { model.goToday() }
                .help(model.formatting.eventTime(start: model.today(), end: model.today(), isAllDay: true))
                .padding(.trailing, 6)
            IconButton(symbol: "chevron.left", help: "Previous \(model.mode == .month ? "month" : model.mode == .day ? "day" : "week")") { model.step(-1) }
            IconButton(symbol: "chevron.right", help: "Next \(model.mode == .month ? "month" : model.mode == .day ? "day" : "week")") { model.step(1) }
            Text(model.title)
                .font(.pm(22))
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 8)
            if model.isLoading { ProgressView().controlSize(.small).padding(.leading, 8) }
            Spacer()
            Button {
                modeMenu.show(CalendarViewModel.Mode.allCases.map { mode in
                    PopUpMenu.Item(title: mode.title, isChecked: model.mode == mode, key: mode.key) { model.mode = mode }
                }, alignment: .trailing)
            } label: {
                HStack(spacing: 8) {
                    Text(model.mode.title).font(.pm(13, .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(0.6)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(MenuAnchor(menu: modeMenu))
            .fixedSize()
            .help("Day (D), Week (W), Month (M) or Schedule (A)")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }
}

/// Create, a small month to jump around with, and the calendars and task lists to show.
private struct CalendarSidebar: View {
    let app: AppModel
    let model: CalendarViewModel
    @State private var createMenu = PopUpMenu()
    @State private var subscribeMenu = PopUpMenu()

    var body: some View {
        let expanded = app.isSidebarExpanded
        VStack(alignment: .leading, spacing: 0) {
            // An event, task, out of office or focus time.
            BigActionButton(title: "Create", symbol: "plus", collapsed: !expanded, isMenu: true) { showCreateMenu() }
            .background(MenuAnchor(menu: createMenu))
            #if DEBUG
            // `-PMCreateMenu YES` opens the menu.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "PMCreateMenu") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showCreateMenu() } }
            }
            #endif
            .padding(.leading, 8)
            .padding(.bottom, 16)
            .help("Create an event (C), task, out of office or focus time")
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MiniMonth(model: model)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                        if !model.myCalendars.isEmpty { calendarSection("My calendars", model.myCalendars) }
                        if !model.taskLists.isEmpty || model.tasksProblem != nil { taskSection }
                        otherCalendarsSection
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .frame(width: expanded ? 256 : 80, alignment: .leading)
    }

    private func showCreateMenu() {
        createMenu.show(model.newTypes.map { type in PopUpMenu.Item(title: type.name, symbol: type.symbol) { create(type) } })
    }

    private func create(_ type: EventType) {
        if let draft = model.newDraft(type: type) { app.sheet = .eventEditor(draft) }
    }

    /// The task lists, and why the tasks couldn't be loaded if they couldn't (an account added before PMail showed
    /// tasks hasn't allowed them yet).
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.taskLists.isEmpty {
                Text("Tasks").font(.pm(14, .medium)).foregroundStyle(Theme.textPrimary).padding(.leading, 26).padding(.vertical, 8)
            } else {
                calendarSection("Tasks", model.taskLists).padding(.bottom, model.tasksProblem == nil ? 0 : -8)
            }
            if let problem = model.tasksProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tasks couldn’t be loaded: \(problem)")
                    Text("If this account was added before PMail showed tasks, sign in again to allow them.")
                    Button("Sign In Again…") { app.sheet = .addAccount(model.account.kind) }
                        .buttonStyle(.link)
                }
                .font(.pm(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
    }

    /// Calendars the account follows, with + to subscribe to another: someone's, or one from a web address.
    private var otherCalendarsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Other calendars").font(.pm(14, .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                IconButton(symbol: "plus", help: "Subscribe to a calendar", size: 26, iconSize: 12) { showSubscribeMenu() }
                    .background(MenuAnchor(menu: subscribeMenu))
                    .padding(.trailing, 10)
            }
            .padding(.leading, 26)
            .padding(.vertical, 4)
            ForEach(model.otherCalendars) { calendar in
                CalendarToggleRow(name: calendar.name, color: model.color(for: calendar), isOn: model.isVisible(calendar)) {
                    model.toggle(calendar)
                }
                .contextMenu {
                    if calendar.canUnsubscribe == true {
                        Button("Unsubscribe from “\(calendar.name)”") { model.unsubscribe(calendar) }
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func showSubscribeMenu() {
        var items: [PopUpMenu.Item] = []
        if model.canSubscribeToPeople {
            items.append(PopUpMenu.Item(title: "Subscribe to Calendar…", symbol: "person.crop.circle.badge.plus") {
                app.sheet = .subscribeToCalendar(.person)
            })
        }
        items.append(PopUpMenu.Item(title: "From URL…", symbol: "link") { app.sheet = .subscribeToCalendar(.address) })
        subscribeMenu.show(items)
    }

    private func calendarSection(_ title: String, _ calendars: [CalendarInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.pm(14, .medium)).foregroundStyle(Theme.textPrimary).padding(.leading, 26).padding(.vertical, 8)
            ForEach(calendars) { calendar in
                CalendarToggleRow(name: calendar.name, color: model.color(for: calendar), isOn: model.isVisible(calendar)) {
                    model.toggle(calendar)
                }
            }
        }
        .padding(.bottom, 12)
    }
}

private struct CalendarToggleRow: View {
    let name: String
    let color: Color
    let isOn: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(isOn ? color : .clear)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 2)
                    if isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 17, height: 17)
                Text(name).font(.pm(13.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 26)
            .frame(height: 32)
            .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 16, topTrailingRadius: 16)
                .fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? "shown" : "hidden")
    }
}

/// The small month in the sidebar: click a day to go to it.
struct MiniMonth: View {
    let model: CalendarViewModel

    var body: some View {
        let weeks = model.grid.monthWeeks(of: model.miniMonth)
        let symbols = model.calendar.veryShortStandaloneWeekdaySymbols
        let first = model.calendar.firstWeekday - 1
        VStack(spacing: 2) {
            HStack {
                Text(monthTitle).font(.pm(13.5, .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                IconButton(symbol: "chevron.left", help: "Previous month", size: 26, iconSize: 11) { shift(-1) }
                IconButton(symbol: "chevron.right", help: "Next month", size: 26, iconSize: 11) { shift(1) }
            }
            .padding(.leading, 6)
            .padding(.bottom, 4)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + first) % 7]).font(.pm(10.5, .medium)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        MiniDay(day: day, model: model)
                    }
                }
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter.string(from: model.miniMonth)
    }

    private func shift(_ months: Int) {
        if let date = model.calendar.date(byAdding: .month, value: months, to: model.miniMonth) { model.miniMonth = date }
    }
}

private struct MiniDay: View {
    let day: Date
    let model: CalendarViewModel
    @State private var hovering = false

    var body: some View {
        let isToday = model.isToday(day)
        let isSelected = model.calendar.isDate(day, inSameDayAs: model.anchor) && !isToday
        let inMonth = model.grid.isSameMonth(day, model.miniMonth)
        Button { model.go(to: day) } label: {
            Text("\(model.calendar.component(.day, from: day))")
                .font(.pm(10.5, isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Theme.onAccent : (inMonth ? Theme.textPrimary : Theme.textTertiary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isToday ? Theme.accent : (isSelected ? Theme.selection : (hovering ? Theme.hover : .clear))))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(model.formatting.eventTime(start: day, end: day, isAllDay: true))
    }
}

// MARK: Day and week

/// The day or week view: a column per day, all-day events across the top, and timed events placed by the hour.
struct TimeGridView: View {
    let app: AppModel
    let model: CalendarViewModel
    let days: [Date]
    let events: [CalendarEvent]
    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 64

    var body: some View {
        let allDay = events.filter { $0.isAllDay || $0.end.timeIntervalSince($0.start) >= 86_400 }
        let timed = events.filter { !$0.isAllDay && $0.end.timeIntervalSince($0.start) < 86_400 }
        VStack(spacing: 0) {
            dayHeaders
            AllDayStrip(app: app, model: model, days: days, events: allDay, gutter: gutter)
            Divider().overlay(Theme.divider)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        GeometryReader { geometry in
                            let columnWidth = geometry.size.width / CGFloat(max(days.count, 1))
                            ZStack(alignment: .topLeading) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Rectangle().fill(Theme.divider).frame(height: 1).offset(y: CGFloat(hour) * hourHeight)
                                }
                                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                    DayColumn(app: app, model: model, day: day, events: model.events(on: day, from: timed), hourHeight: hourHeight)
                                        .frame(width: columnWidth, height: hourHeight * 24)
                                        .offset(x: CGFloat(index) * columnWidth)
                                    Rectangle().fill(Theme.divider).frame(width: 1, height: hourHeight * 24).offset(x: CGFloat(index) * columnWidth)
                                }
                            }
                        }
                        .frame(height: hourHeight * 24)
                    }
                    .overlay(alignment: .topLeading) {
                        // Invisible marks to scroll to.
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: hourHeight).id("hour-\(hour)") }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    let hour = days.contains(where: model.isToday) ? max(0, model.calendar.component(.hour, from: model.today()) - 2) : 7
                    proxy.scrollTo("hour-\(min(hour, 16))", anchor: .top)
                }
            }
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Text(timeZoneLabel).font(.pm(10)).foregroundStyle(Theme.textTertiary).frame(width: gutter, alignment: .bottomTrailing)
                .padding(.trailing, 8).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 4)
            ForEach(days, id: \.self) { day in
                let isToday = model.isToday(day)
                VStack(spacing: 2) {
                    Text(weekday(day)).font(.pm(11, .medium)).foregroundStyle(isToday ? Theme.accent : Theme.textSecondary)
                    Button {
                        model.go(to: day)
                        model.mode = .day
                    } label: {
                        Text("\(model.calendar.component(.day, from: day))")
                            .font(.pm(24, .regular))
                            .foregroundStyle(isToday ? Theme.onAccent : Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(isToday ? Theme.accent : .clear))
                    }
                    .buttonStyle(.plain)
                    .help("Show this day")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 76)
        .padding(.trailing, 14)
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : hourText(hour))
                    .font(.pm(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: gutter - 10, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
            }
        }
        .frame(width: gutter, alignment: .trailing)
    }

    private func hourText(_ hour: Int) -> String {
        let date = model.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: model.anchor) ?? model.anchor
        let text = model.formatting.shortTime(date)
        return text.hasSuffix("am") || text.hasSuffix("pm") ? String(text.dropLast(2)) + " " + text.suffix(2).uppercased() : text
    }

    private func weekday(_ day: Date) -> String {
        let symbols = model.calendar.shortStandaloneWeekdaySymbols
        return symbols[model.calendar.component(.weekday, from: day) - 1].uppercased()
    }

    private var timeZoneLabel: String {
        let seconds = model.calendar.timeZone.secondsFromGMT(for: model.anchor)
        let hours = seconds / 3600, minutes = abs(seconds / 60) % 60
        return String(format: "GMT%@%02d%@", hours < 0 ? "-" : "+", abs(hours), minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}

/// One day's column of timed events, with the red line for now on today. Clicking an empty slot makes an event
/// there.
private struct DayColumn: View {
    let app: AppModel
    let model: CalendarViewModel
    let day: Date
    let events: [CalendarEvent]
    let hourHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let placements = EventLayout.layout(events.map { ($0.id, max($0.start, startOfDay), min($0.end, endOfDay)) })
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in createEvent(at: location.y) }
                ForEach(events) { event in
                    let placement = placements[event.id] ?? EventLayout.Placement(column: 0, columns: 1, span: 1)
                    let top = y(for: max(event.start, startOfDay))
                    let bottom = y(for: min(event.end, endOfDay))
                    let width = (geometry.size.width - 10) / CGFloat(placement.columns)
                    EventBlock(app: app, model: model, event: event, height: max(bottom - top, 20))
                        .frame(width: max(width * CGFloat(placement.span) - 2, 20), height: max(bottom - top - 2, 18))
                        .offset(x: width * CGFloat(placement.column) + 1, y: top + 1)
                }
                if model.isToday(day) {
                    let nowY = y(for: model.today())
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.now).frame(height: 2)
                        Circle().fill(Theme.now).frame(width: 12, height: 12).offset(x: -6)
                    }
                    .offset(y: nowY - 1)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var startOfDay: Date { model.calendar.startOfDay(for: day) }
    private var endOfDay: Date { model.calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay }

    private func y(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(startOfDay) / 3600) * hourHeight
    }

    private func createEvent(at y: CGFloat) {
        let minutes = Int((y / hourHeight * 60 / 30).rounded(.down)) * 30
        guard let start = model.calendar.date(byAdding: .minute, value: minutes, to: startOfDay),
              let draft = model.newDraft(start: start) else { return }
        app.sheet = .eventEditor(draft)
    }
}

/// A timed event in the day or week view: its color, title and time. Click for its details.
private struct EventBlock: View {
    let app: AppModel
    let model: CalendarViewModel
    let event: CalendarEvent
    let height: CGFloat

    var body: some View {
        let color = model.color(for: event)
        let look = AnswerLook(event)
        Button { model.selectedEventID = event.id } label: {
            VStack(alignment: .leading, spacing: 1) {
                if height < 34 {
                    (eventTitle(event).fontWeight(.semibold) + Text(", " + model.formatting.shortTime(event.start)))
                        .font(.pm(11))
                        .strikethrough(look.isStruckThrough)
                        .lineLimit(1)
                } else {
                    eventTitle(event).font(.pm(11.5, .semibold)).lineLimit(height < 60 ? 1 : 2)
                        .strikethrough(look.isStruckThrough)
                    Text(model.formatting.eventTime(start: event.start, end: event.end, isAllDay: false))
                        .font(.pm(10.5))
                        .strikethrough(look.isStruckThrough)
                        .lineLimit(1)
                    if height > 70, let location = event.location, !location.isEmpty {
                        Text(location).font(.pm(10.5)).strikethrough(look.isStruckThrough).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(look.textColor(on: color))
            .padding(.horizontal, 6)
            .padding(.vertical, height < 34 ? 2 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A faint color sits on the page's own, so the hour lines don't run through the words.
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(look.fillOpacity)))
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(look == .pending ? color : Theme.surface, lineWidth: look == .pending ? 1.5 : 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: model.detailsBinding(for: event), arrowEdge: .trailing) {
            EventDetailsView(app: app, model: model, event: event)
        }
        .accessibilityLabel("\(event.type == .event ? "" : event.type.name + ": ")\(event.title), \(model.formatting.eventTime(start: event.start, end: event.end, isAllDay: false))\(AnswerLook(event).spoken)")
    }
}

/// All-day and multi-day events across the top of the day or week view, as bars over the days they cover.
private struct AllDayStrip: View {
    let app: AppModel
    let model: CalendarViewModel
    let days: [Date]
    let events: [CalendarEvent]
    let gutter: CGFloat

    var body: some View {
        let rows = layoutRows()
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: width, height: geometry.size.height)
                            .offset(x: CGFloat(index) * width)
                            .onTapGesture {
                                if let draft = model.newDraft(start: day, allDay: true) { app.sheet = .eventEditor(draft) }
                            }
                    }
                    ForEach(rows, id: \.event.id) { row in
                        AllDayBar(app: app, model: model, event: row.event)
                            .frame(width: CGFloat(row.span) * width - 4, height: 22)
                            .offset(x: CGFloat(row.first) * width + 2, y: CGFloat(row.row) * 24 + 2)
                    }
                }
            }
        }
        .frame(height: max(CGFloat(rows.map(\.row).max().map { $0 + 1 } ?? 0) * 24 + 6, 12))
        .padding(.trailing, 14)
    }

    private struct Row {
        let event: CalendarEvent
        let first: Int
        let span: Int
        let row: Int
    }

    /// Which day each bar starts on, how many days it covers, and which row it takes so bars don't overlap.
    private func layoutRows() -> [Row] {
        var rows: [Row] = []
        var taken: [[Bool]] = []
        let calendar = model.calendar
        for event in events.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
            guard let first = days.firstIndex(where: { day in
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return event.start < end && event.end > day
            }) else { continue }
            let last = days.lastIndex(where: { day in
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return event.start < end && event.end > day
            }) ?? first
            var row = 0
            while row < taken.count, taken[row][first...last].contains(true) { row += 1 }
            if row == taken.count { taken.append(Array(repeating: false, count: days.count)) }
            for index in first...last { taken[row][index] = true }
            rows.append(Row(event: event, first: first, span: last - first + 1, row: row))
        }
        return rows
    }
}

/// An all-day event as a colored bar; a task with its check circle, struck through once it's done.
struct AllDayBar: View {
    let app: AppModel
    let model: CalendarViewModel
    let event: CalendarEvent

    var body: some View {
        let color = model.color(for: event)
        let look = event.isTask ? AnswerLook.solid : AnswerLook(event)
        HStack(spacing: 0) {
            if event.isTask {
                TaskCheck(model: model, task: event, size: 12)
                    .padding(.leading, 6)
            }
            Button { model.selectedEventID = event.id } label: {
                eventTitle(event)
                    .font(.pm(11.5, .medium))
                    .strikethrough((event.isTask && event.isCompleted) || look.isStruckThrough)
                    .foregroundStyle(look.textColor(on: color))
                    .lineLimit(1)
                    .padding(.leading, event.isTask ? 5 : 8)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(event.isTask && event.isCompleted ? 0.55 : look.fillOpacity)))
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(look == .pending ? color : .clear, lineWidth: 1.5))
        .popover(isPresented: model.detailsBinding(for: event), arrowEdge: .bottom) {
            EventDetailsView(app: app, model: model, event: event)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Month

/// The month view: whole weeks, each day with as many events as fit and "N more" for the rest.
struct MonthGridView: View {
    let app: AppModel
    let model: CalendarViewModel
    let events: [CalendarEvent]

    var body: some View {
        let weeks = model.grid.monthWeeks(of: model.anchor)
        let symbols = model.calendar.shortStandaloneWeekdaySymbols
        let first = model.calendar.firstWeekday - 1
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + first) % 7].uppercased())
                        .font(.pm(11, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28)
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / CGFloat(max(weeks.count, 1))
                VStack(spacing: 0) {
                    ForEach(weeks, id: \.first) { week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                MonthDay(app: app, model: model, day: day, events: model.events(on: day, from: events), height: rowHeight)
                                    .frame(maxWidth: .infinity)
                                    .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
                            }
                        }
                        .frame(height: rowHeight)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                    }
                }
            }
        }
    }
}

private struct MonthDay: View {
    let app: AppModel
    let model: CalendarViewModel
    let day: Date
    let events: [CalendarEvent]
    let height: CGFloat
    @State private var showsAll = false

    var body: some View {
        let isToday = model.isToday(day)
        let inMonth = model.grid.isSameMonth(day, model.anchor)
        let fits = max(0, Int((height - 34) / 22))
        let shown = events.count > fits ? Array(events.prefix(max(0, fits - 1))) : events
        VStack(spacing: 2) {
            Button {
                model.go(to: day)
                model.mode = .day
            } label: {
                Text(dayNumber)
                    .font(.pm(12, isToday ? .semibold : .medium))
                    .foregroundStyle(isToday ? Theme.onAccent : (inMonth ? Theme.textPrimary : Theme.textTertiary))
                    .padding(.horizontal, dayNumber.count > 2 ? 6 : 0)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(isToday ? Theme.accent : .clear))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            ForEach(shown) { event in
                MonthEventChip(app: app, model: model, event: event)
            }
            if events.count > shown.count {
                Button("\(events.count - shown.count) more") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(.pm(11.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .popover(isPresented: $showsAll) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.formatting.eventTime(start: day, end: day, isAllDay: true)).font(.pm(13, .medium)).padding(.bottom, 4)
                            ForEach(events) { event in MonthEventChip(app: app, model: model, event: event) }
                        }
                        .padding(14)
                        .frame(width: 260)
                        .background(Theme.surfaceRaised)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            if let draft = model.newDraft(start: day, allDay: true) { app.sheet = .eventEditor(draft) }
        }
    }

    private var dayNumber: String {
        let number = model.calendar.component(.day, from: day)
        guard number == 1 else { return "\(number)" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: day)
    }
}

/// An event in the month view: a bar for all-day events, a dot, time and title for the rest.
private struct MonthEventChip: View {
    let app: AppModel
    let model: CalendarViewModel
    let event: CalendarEvent
    @State private var hovering = false

    var body: some View {
        if event.isAllDay {
            AllDayBar(app: app, model: model, event: event).frame(height: 20)
        } else {
            Button { model.selectedEventID = event.id } label: {
                let look = AnswerLook(event)
                HStack(spacing: 5) {
                    AnswerDot(look: look, color: model.color(for: event), size: 8)
                    Text(model.formatting.shortTime(event.start)).font(.pm(11.5)).foregroundStyle(Theme.textSecondary)
                        .strikethrough(look.isStruckThrough)
                    eventTitle(event).font(.pm(11.5, .medium))
                        .foregroundStyle(look.isStruckThrough ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough(look.isStruckThrough)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: model.detailsBinding(for: event), arrowEdge: .trailing) {
                EventDetailsView(app: app, model: model, event: event)
            }
        }
    }
}

// MARK: Schedule

/// The schedule: the next thirty days' events as a list, a day at a time (or everything the search finds).
struct ScheduleView: View {
    let app: AppModel
    let model: CalendarViewModel
    let events: [CalendarEvent]
    let searching: Bool

    var body: some View {
        let days = scheduleDays
        if days.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: searching ? "magnifyingglass" : "calendar").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text(searching ? "No events matched your search." : "Nothing planned for the next 30 days.").font(.pm(14)).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.day) { entry in
                        HStack(alignment: .top, spacing: 0) {
                            let isToday = model.isToday(entry.day)
                            HStack(spacing: 10) {
                                Text("\(model.calendar.component(.day, from: entry.day))")
                                    .font(.pm(22))
                                    .foregroundStyle(isToday ? Theme.onAccent : Theme.textPrimary)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(isToday ? Theme.accent : .clear))
                                Text(dayLabel(entry.day)).font(.pm(11, .medium)).foregroundStyle(isToday ? Theme.accent : Theme.textSecondary)
                            }
                            .frame(width: 150, alignment: .leading)
                            .padding(.top, 6)
                            VStack(spacing: 0) {
                                ForEach(entry.events) { event in ScheduleRow(app: app, model: model, event: event) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        Divider().overlay(Theme.divider)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var scheduleDays: [(day: Date, events: [CalendarEvent])] {
        let source = searching ? events : events.filter { $0.end > model.anchor && $0.start < model.visibleInterval.end }
        var days: [Date: [CalendarEvent]] = [:]
        for event in source {
            let day = model.calendar.startOfDay(for: max(event.start, searching ? event.start : model.anchor))
            days[day, default: []].append(event)
        }
        return days.keys.sorted().map { day in
            (day, days[day]!.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(searching ? "MMMyEEE" : "MMMEEE")
        return formatter.string(from: day).uppercased()
    }
}

private struct ScheduleRow: View {
    let app: AppModel
    let model: CalendarViewModel
    let event: CalendarEvent
    @State private var hovering = false

    var body: some View {
        // A task's check circle is its own button, beside the one that shows the details.
        HStack(spacing: 0) {
            if event.isTask {
                TaskCheck(model: model, task: event, size: 13, color: model.color(for: event))
                    .frame(width: 11)
                    .padding(.leading, 10)
            }
            Button { model.selectedEventID = event.id } label: {
                let look = event.isTask ? AnswerLook.solid : AnswerLook(event)
                HStack(spacing: 14) {
                    if !event.isTask {
                        AnswerDot(look: look, color: model.color(for: event), size: 11)
                    }
                    Text(event.isTask ? "Task" : event.isAllDay ? "All day" : model.formatting.eventTime(start: event.start, end: event.end, isAllDay: false))
                        .font(.pm(13))
                        .foregroundStyle(Theme.textSecondary)
                        .strikethrough(look.isStruckThrough)
                        .frame(width: 170, alignment: .leading)
                    eventTitle(event).font(.pm(13.5, .medium))
                        .foregroundStyle((event.isTask && event.isCompleted) || look.isStruckThrough ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough((event.isTask && event.isCompleted) || look.isStruckThrough)
                        .lineLimit(1)
                    if let conference = event.conference {
                        Image(systemName: conference.kind == .faceTime ? "video.fill" : "video").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .padding(.leading, event.isTask ? 14 : 10)
                .padding(.trailing, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
        .popover(isPresented: model.detailsBinding(for: event), arrowEdge: .leading) {
            EventDetailsView(app: app, model: model, event: event)
        }
    }
}

extension CalendarViewModel {
    /// Whether an event's details popover is showing, as a binding for `.popover`.
    func detailsBinding(for event: CalendarEvent) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.selectedEventID == event.id },
                set: { [weak self] showing in if !showing, self?.selectedEventID == event.id { self?.selectedEventID = nil } })
    }
}
