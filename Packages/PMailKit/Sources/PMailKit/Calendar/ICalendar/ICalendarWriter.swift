import Foundation

/// Writes PMail's events into iCalendar resources: whole new files for new events, and careful edits of existing
/// ones that change only what the person changed and keep every property and component PMail doesn't understand,
/// so nothing another program stored on the server is lost.
///
/// Timed events that don't repeat are written in UTC. Repeating ones are written in their own time zone (with a
/// VTIMEZONE), because a rule in UTC would drift an hour across daylight saving changes for everyone reading it.
struct ICalendarWriter {
    static let productID = "-//PuggleSoft//PMail//EN"

    let ownerEmail: String?
    let localTimeZone: TimeZone
    var now: Date

    private let localZone: ICalendarZone

    init(ownerEmail: String?, localTimeZone: TimeZone, now: Date = Date()) {
        self.ownerEmail = ownerEmail
        self.localTimeZone = localTimeZone
        self.now = now
        localZone = ICalendarZone(localTimeZone)
    }

    // MARK: New events

    /// A new VCALENDAR holding one event.
    func newCalendar(for event: CalendarEvent, uid: String) -> ICalendarComponent {
        var vevent = ICalendarComponent(name: "VEVENT", properties: [
            .text("UID", uid),
            ICalendarLine("DTSTAMP", value: utcText(now)),
            ICalendarLine("CREATED", value: utcText(now)),
            ICalendarLine("LAST-MODIFIED", value: utcText(now)),
            ICalendarLine("SEQUENCE", value: "0"),
        ])
        let repeats = !recurrenceLines(event.recurrence).isEmpty
        writeTimes(of: event, form: timeForm(for: event, existing: nil, repeats: repeats, resolver: nil), into: &vevent)
        for field in Field.allCases { write(field, of: event, into: &vevent, replacing: nil) }
        if repeats { setRecurrence(event.recurrence, in: &vevent) }
        var calendar = ICalendarComponent(name: "VCALENDAR", properties: [
            ICalendarLine("VERSION", value: "2.0"),
            ICalendarLine("PRODID", value: Self.productID),
            ICalendarLine("CALSCALE", value: "GREGORIAN"),
        ])
        calendar.components = [vevent]
        finish(&calendar)
        return calendar
    }

    // MARK: Exporting

    /// A repeating series as it is, for exporting: one VEVENT that repeats from the first of the times given, with the
    /// times that were moved or changed as overrides, and the times its rule gives before `end` that weren't given
    /// (they were deleted) left out with EXDATE. Times before the first one given aren't known, so a rule that ends
    /// after so many times (COUNT) ends at the last time given instead. Nil when the times don't fit a rule PMail reads.
    func exportedSeries(_ occurrences: [CalendarEvent], uid: String, through end: Date) -> ICalendarComponent? {
        let sorted = occurrences.sorted { ($0.occurrenceDate ?? $0.start) < ($1.occurrenceDate ?? $1.start) }
        guard let first = sorted.first, let last = sorted.last,
              let rules = sorted.first(where: { !recurrenceLines($0.recurrence).isEmpty })?.recurrence else { return nil }
        // The series: the first time at its original start, with the details of the first time that wasn't moved.
        let template = sorted.first { ($0.occurrenceDate ?? $0.start) == $0.start } ?? first
        var series = template
        series.start = first.occurrenceDate ?? first.start
        if series.isAllDay {
            var days = Calendar(identifier: .gregorian)
            days.timeZone = localTimeZone
            let length = days.dateComponents([.day], from: days.startOfDay(for: template.start), to: days.startOfDay(for: template.end)).day ?? 1
            series.end = days.date(byAdding: .day, value: max(length, 1), to: days.startOfDay(for: series.start)) ?? series.start.addingTimeInterval(86_400)
        } else {
            series.end = series.start.addingTimeInterval(template.end.timeIntervalSince(template.start))
        }
        series.recurrence = rules.map { endingAt(last.occurrenceDate ?? last.start, rule: $0, allDay: series.isAllDay) }
        var calendar = newCalendar(for: series, uid: uid)
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let written = reader.series.first, written.isRecurring, let master = written.master,
              let timing = reader.timing(of: master) else { return nil }
        var given = Set<Int64>()
        var changed: [CalendarEvent] = []
        for occurrence in sorted {
            var lookup = occurrence
            lookup.id = "export"
            lookup.uid = uid
            lookup.seriesID = uid
            guard let key = reader.key(for: lookup, in: written), reader.generates(written, key: key),
                  let instance = reader.instance(in: written, key: key) else { return nil }
            given.insert(key)
            let moved = ICalendarZone.seconds(of: occurrence.start) != instance.start || ICalendarZone.seconds(of: occurrence.end) != instance.end
            if moved || Field.allCases.contains(where: { !isSame($0, template, occurrence) }) { changed.append(lookup) }
        }
        // The rule's times that weren't given were deleted. The last day is left alone: where a window ends, the
        // provider and the rule may disagree about a time on its edge.
        let lower = timing.zone.instant(from: timing.start.wall)
        let upper = max(ICalendarZone.seconds(of: end) - 86_400, lower + 1)
        let missing = reader.instances(of: written, in: lower..<upper).compactMap(\.key).filter { !given.contains($0) }
        if !missing.isEmpty, let index = calendar.components.firstIndex(where: { isMaster($0, of: written) }) {
            let properties = calendar.components[index].properties
            let position = properties.lastIndex { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }.map { $0 + 1 } ?? properties.count
            calendar.components[index].properties.insert(contentsOf: missing.map { recurrenceValue(key: $0, timing: timing).line("EXDATE") },
                                                         at: position)
        }
        for occurrence in changed { _ = try? update(&calendar, with: occurrence, scope: .thisEvent) }
        finish(&calendar)
        return calendar
    }

    /// A rule that ends after so many times (COUNT) made to end at a time instead (UNTIL): the last time's original
    /// start, in UTC, or its day for all-day events. Other lines as they are.
    private func endingAt(_ last: Date, rule text: String, allDay: Bool) -> String {
        guard var line = recurrenceLines([text]).first, line.name == "RRULE" else { return text }
        var parts = line.value.split(separator: ";").map(String.init)
        guard parts.contains(where: { $0.uppercased().hasPrefix("COUNT=") }) else { return text }
        parts.removeAll { $0.uppercased().hasPrefix("COUNT=") || $0.uppercased().hasPrefix("UNTIL=") }
        let seconds = ICalendarZone.seconds(of: last)
        let until = allDay ? WallClockTime(dayNumber: localZone.wall(fromInstant: seconds).dayNumber).dateText
                           : WallClockTime(seconds: seconds).dateTimeText + "Z"
        parts.append("UNTIL=" + until)
        line.value = parts.joined(separator: ";")
        return line.serialized
    }

    // MARK: Changes

    /// Saves an edit of an event into its resource: the whole series, or one occurrence (which gets an override
    /// VEVENT with a RECURRENCE-ID). Returns the key of the occurrence as it is now, for reading it back.
    func update(_ calendar: inout ICalendarComponent, with event: CalendarEvent, scope: RecurrenceScope) throws -> Int64? {
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let series = reader.series(for: event) else { throw PMailError.notFound }
        let key = reader.key(for: event, in: series)
        let masterIndex = calendar.components.firstIndex { isMaster($0, of: series) }
        let overrideIndex = key.flatMap { key in calendar.components.firstIndex { isOverride($0, of: series, key: key, reader: reader) } }

        guard series.isRecurring, let masterIndex else {
            // An event that doesn't repeat (it may start repeating now), or an occurrence whose series isn't here.
            guard let index = masterIndex ?? overrideIndex else { throw PMailError.notFound }
            var component = calendar.components[index]
            let old = reader.fields(of: component, calendarID: event.calendarID)
            for field in Field.allCases where !isSame(field, old, event) { write(field, of: event, into: &component, replacing: old) }
            var significant = old.status != event.status
            let startsRepeating = index == masterIndex && !sameRecurrence(component, event.recurrence)
            let existing = component.property("DTSTART").flatMap(ICalendarDateTime.init)
            if timesDiffer(old, event) || (startsRepeating && existing?.form == .utc) {
                let repeats = index == masterIndex && !recurrenceLines(event.recurrence).isEmpty
                let form = timeForm(for: event, existing: existing, repeats: repeats, resolver: reader.resolver)
                writeTimes(of: event, form: form, into: &component)
                significant = true
            }
            if startsRepeating {
                setRecurrence(event.recurrence, in: &component)
                significant = true
            }
            stamp(&component, significant: significant)
            calendar.components[index] = component
            finish(&calendar)
            return index == masterIndex ? nil : key
        }

        let master = calendar.components[masterIndex]
        guard let timing = reader.timing(of: master) else { throw PMailError.protocolError("the event has no start time") }
        switch scope {
        case .thisEvent:
            guard let key else { throw PMailError.notFound }
            if let overrideIndex {
                var override = calendar.components[overrideIndex]
                let old = reader.fields(of: override, calendarID: event.calendarID, fallback: timing.length)
                for field in Field.allCases where !isSame(field, old, event) { write(field, of: event, into: &override, replacing: old) }
                let moved = timesDiffer(old, event)
                if moved {
                    let existing = override.property("DTSTART").flatMap(ICalendarDateTime.init) ?? timing.start
                    // An override doesn't repeat itself, so it keeps its series' way of writing times.
                    let form = timeForm(for: event, existing: existing, repeats: false, resolver: reader.resolver)
                    writeTimes(of: event, form: form, into: &override)
                }
                stamp(&override, significant: moved || old.status != event.status)
                calendar.components[overrideIndex] = override
            } else {
                guard let instance = reader.instance(in: series, key: key) else { throw PMailError.notFound }
                var override = master
                override.properties.removeAll { ["RRULE", "RDATE", "EXDATE", "EXRULE", "RECURRENCE-ID"].contains($0.name) }
                let position = (override.properties.firstIndex { $0.name == "DTSTART" } ?? override.properties.count)
                override.properties.insert(recurrenceValue(key: key, timing: timing).line("RECURRENCE-ID"), at: position)
                var old = reader.fields(of: master, calendarID: event.calendarID)
                old.start = Date(timeIntervalSince1970: TimeInterval(instance.start))
                old.end = Date(timeIntervalSince1970: TimeInterval(instance.end))
                for field in Field.allCases where !isSame(field, old, event) { write(field, of: event, into: &override, replacing: old) }
                let form = timeForm(for: event, existing: timing.start, repeats: false, resolver: reader.resolver)
                writeTimes(of: event, form: form, into: &override)
                stamp(&override, significant: timesDiffer(old, event) || old.status != event.status)
                let last = calendar.components.lastIndex { belongs($0, to: series) } ?? masterIndex
                calendar.components.insert(override, at: last + 1)
            }
            finish(&calendar)
            return key

        case .allEvents:
            return try updateSeries(&calendar, series: series, masterIndex: masterIndex, overrideIndex: overrideIndex, key: key,
                                    timing: timing, event: event, reader: reader)
        }
    }

    /// Changes a whole series: the main VEVENT, and the overrides that hadn't changed the same things themselves.
    /// Moving an occurrence moves the series by as much, on the wall clock, along with its exceptions.
    private func updateSeries(_ calendar: inout ICalendarComponent, series: ICalendarSeries, masterIndex: Int, overrideIndex: Int?,
                              key: Int64?, timing: ICalendarTiming, event: CalendarEvent, reader: ICalendarReader) throws -> Int64? {
        var master = calendar.components[masterIndex]
        let masterView = reader.fields(of: master, calendarID: event.calendarID)
        // Compared before moving the series adjusts the rule, so only the person's own change to it counts.
        let recurrenceChanged = !sameRecurrence(master, event.recurrence)
        // The occurrence as the person saw it before they changed it.
        var source = masterView
        if let overrideIndex {
            source = reader.fields(of: calendar.components[overrideIndex], calendarID: event.calendarID, fallback: timing.length)
        } else if let key, let instance = reader.instance(in: series, key: key) {
            source.start = Date(timeIntervalSince1970: TimeInterval(instance.start))
            source.end = Date(timeIntervalSince1970: TimeInterval(instance.end))
        }
        let changed = Field.allCases.filter { !isSame($0, source, event) }
        for field in changed { write(field, of: event, into: &master, replacing: masterView) }
        var significant = changed.contains(.status)

        var shift: Int64 = 0
        var newTiming = timing
        if timesDiffer(source, event) {
            significant = true
            let form = timeForm(for: event, existing: timing.start, repeats: true, resolver: reader.resolver)
            shift = wall(of: event.start, in: form).seconds - timing.zone.wall(from: source.start).seconds
            let newStartWall = timing.start.wall.adding(seconds: shift)
            let newZone = zone(of: form)
            let start = newZone.date(from: form.isDate ? WallClockTime(dayNumber: newStartWall.dayNumber) : newStartWall)
            let end: Date
            if form.isDate {
                let days = max(1, localZone.wall(from: event.end).dayNumber - localZone.wall(from: event.start).dayNumber)
                end = localZone.date(from: WallClockTime(dayNumber: newStartWall.dayNumber + days))
            } else {
                end = start.addingTimeInterval(max(0, event.end.timeIntervalSince(event.start)))
            }
            writeTimes(start: start, end: end, form: form, into: &master)
            if let start = master.property("DTSTART").flatMap(ICalendarDateTime.init) {
                newTiming = ICalendarTiming(start: start, zone: newZone, length: timing.length)
            }
            if shift != 0 {
                adjustRules(in: &master, from: timing.start.wall, to: newStartWall)
                master.properties = master.properties.map { $0.name == "EXDATE" ? shiftedLine($0, by: shift, zone: timing.zone) : $0 }
            }
        }
        let keepsRepeating = !recurrenceLines(event.recurrence).isEmpty
        if recurrenceChanged {
            setRecurrence(event.recurrence, in: &master)
            significant = true
        }
        stamp(&master, significant: significant)
        calendar.components[masterIndex] = master

        // Carry the changes to the overrides.
        for index in calendar.components.indices where isOverrideOf(calendar.components[index], series: series) {
            var override = calendar.components[index]
            let view = reader.fields(of: override, calendarID: event.calendarID, fallback: timing.length)
            var touched = false
            for field in changed where index == overrideIndex || isSame(field, view, masterView) {
                write(field, of: event, into: &override, replacing: view)
                touched = true
            }
            if shift != 0, let line = override.property("RECURRENCE-ID"), let recurrenceID = ICalendarDateTime(line) {
                let unmoved = override.property("DTSTART").flatMap(ICalendarDateTime.init).map {
                    reader.resolver.instant($0) == reader.resolver.instant(recurrenceID)
                } ?? false
                override.setProperty(shiftedLine(line, by: shift, zone: timing.zone))
                if unmoved {
                    for name in ["DTSTART", "DTEND"] {
                        guard let original = override.property(name) else { continue }
                        override.setProperty(shiftedLine(original, by: shift, zone: timing.zone))
                    }
                }
                touched = true
            }
            if touched { stamp(&override, significant: shift != 0) }
            calendar.components[index] = override
        }
        if !keepsRepeating {
            // No longer repeating: the exceptions have nothing left to change.
            calendar.components.removeAll { isOverrideOf($0, series: series) }
        } else if recurrenceChanged {
            // A new rule: exceptions for dates it no longer gives would show as stray extra events.
            let after = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
            if let updated = after.series(for: event), let afterTiming = after.referenceTiming(of: updated) {
                calendar.components.removeAll { component in
                    guard isOverrideOf(component, series: series),
                          let recurrenceID = component.property("RECURRENCE-ID").flatMap(ICalendarDateTime.init) else { return false }
                    return !after.generates(updated, key: after.instanceKey(recurrenceID, timing: afterTiming))
                }
            }
        }
        finish(&calendar)
        guard keepsRepeating, let key else { return nil }
        let moved = shiftedValue(recurrenceValue(key: key, timing: timing), by: shift, zone: timing.zone)
        return reader.instanceKey(moved, timing: newTiming)
    }

    /// Removes one occurrence of a repeating event: an EXDATE on the main VEVENT, and no override for it. Returns
    /// whether the resource has no events left (so it should be deleted instead).
    func deleteOccurrence(of event: CalendarEvent, from calendar: inout ICalendarComponent) throws -> Bool {
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let series = reader.series(for: event) else { throw PMailError.notFound }
        if series.isRecurring, let key = reader.key(for: event, in: series) {
            if let masterIndex = calendar.components.firstIndex(where: { isMaster($0, of: series) }),
               let timing = reader.timing(of: calendar.components[masterIndex]) {
                var master = calendar.components[masterIndex]
                let exception = recurrenceValue(key: key, timing: timing).line("EXDATE")
                let position = (master.properties.lastIndex { ["RRULE", "RDATE", "EXDATE"].contains($0.name) }).map { $0 + 1 }
                master.properties.insert(exception, at: position ?? master.properties.count)
                stamp(&master, significant: true)
                calendar.components[masterIndex] = master
            }
            calendar.components.removeAll { isOverride($0, of: series, key: key, reader: reader) }
            let after = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
            if let remaining = after.series(for: event), after.hasInstances(remaining) {
                finish(&calendar)
                return false
            }
        }
        calendar.components.removeAll { belongs($0, to: series) }
        finish(&calendar)
        return !calendar.components.contains { $0.name == "VEVENT" }
    }

    /// Sets the owner's answer on one time of a repeating event (`thisEvent`): in that time's override, made from the
    /// series as it is then when there's none yet, leaving the rest of the series as it was. The whole series, or an
    /// event that doesn't repeat, is answered on every VEVENT.
    func respond(_ response: AttendeeResponse, to event: CalendarEvent, in calendar: inout ICalendarComponent, scope: RecurrenceScope) throws {
        guard scope == .thisEvent else { return try respond(response, to: event, in: &calendar) }
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let series = reader.series(for: event) else { throw PMailError.notFound }
        guard series.isRecurring, let key = reader.key(for: event, in: series),
              let masterIndex = calendar.components.firstIndex(where: { isMaster($0, of: series) }),
              let timing = reader.timing(of: calendar.components[masterIndex]) else {
            return try respond(response, to: event, in: &calendar)
        }
        let notInvited = PMailError.notSupported("You aren’t on this event’s guest list, so there’s no invitation to answer.")
        if let index = calendar.components.firstIndex(where: { isOverride($0, of: series, key: key, reader: reader) }) {
            var override = calendar.components[index]
            guard setOwnerResponse(response, in: &override) else { throw notInvited }
            stamp(&override, significant: false)
            calendar.components[index] = override
        } else {
            guard let instance = reader.instance(in: series, key: key) else { throw PMailError.notFound }
            let master = calendar.components[masterIndex]
            var override = master
            override.properties.removeAll { ["RRULE", "RDATE", "EXDATE", "EXRULE", "RECURRENCE-ID"].contains($0.name) }
            let position = override.properties.firstIndex { $0.name == "DTSTART" } ?? override.properties.count
            override.properties.insert(recurrenceValue(key: key, timing: timing).line("RECURRENCE-ID"), at: position)
            var then = reader.fields(of: master, calendarID: event.calendarID)
            then.start = Date(timeIntervalSince1970: TimeInterval(instance.start))
            then.end = Date(timeIntervalSince1970: TimeInterval(instance.end))
            writeTimes(of: then, form: timeForm(for: then, existing: timing.start, repeats: false, resolver: reader.resolver), into: &override)
            guard setOwnerResponse(response, in: &override) else { throw notInvited }
            stamp(&override, significant: false)
            let last = calendar.components.lastIndex { belongs($0, to: series) } ?? masterIndex
            calendar.components.insert(override, at: last + 1)
        }
        finish(&calendar)
    }

    /// The calendar with just one time of a repeating event (its override) and its time zones, for answering that time
    /// alone. Nil when the event doesn't repeat or that time has no override.
    func occurrenceOnly(of event: CalendarEvent, in calendar: ICalendarComponent) -> ICalendarComponent? {
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let series = reader.series(for: event), series.isRecurring, let key = reader.key(for: event, in: series),
              let override = calendar.components.first(where: { isOverride($0, of: series, key: key, reader: reader) }) else { return nil }
        var only = calendar
        only.components = calendar.components.filter { $0.name == "VTIMEZONE" } + [override]
        return only
    }

    /// Sets the owner's answer on every VEVENT of the event (the whole series), as the PARTSTAT of their ATTENDEE.
    func respond(_ response: AttendeeResponse, to event: CalendarEvent, in calendar: inout ICalendarComponent) throws {
        let reader = ICalendarReader(calendar: calendar, ownerEmail: ownerEmail, localTimeZone: localTimeZone)
        guard let series = reader.series(for: event) else { throw PMailError.notFound }
        var found = false
        for index in calendar.components.indices where belongs(calendar.components[index], to: series) {
            var component = calendar.components[index]
            if setOwnerResponse(response, in: &component) {
                stamp(&component, significant: false)
                calendar.components[index] = component
                found = true
            }
        }
        guard found else {
            throw PMailError.notSupported("You aren’t on this event’s guest list, so there’s no invitation to answer.")
        }
        finish(&calendar)
    }

    // MARK: Fields

    /// The parts of an event the writer compares and writes one at a time, in the order a new VEVENT has them.
    private enum Field: CaseIterable {
        case title, location, notes, conference, status, availability, color, organizer, attendees, myResponse, reminders, visibility
    }

    private func isSame(_ field: Field, _ first: CalendarEvent, _ second: CalendarEvent) -> Bool {
        switch field {
        case .title: return first.title == second.title
        case .location: return (first.location ?? "") == (second.location ?? "")
        case .notes: return (first.notes ?? "") == (second.notes ?? "") && first.notesHTML == second.notesHTML
        case .conference: return first.conference?.joinURL == second.conference?.joinURL
        case .status: return first.status == second.status
        case .availability: return first.availability == second.availability
        case .color: return first.colorHex.flatMap(ICalendarColor.normalizedHex) == second.colorHex.flatMap(ICalendarColor.normalizedHex)
        case .organizer:
            return first.organizer?.email.lowercased() == second.organizer?.email.lowercased()
                && first.organizer?.name == second.organizer?.name
        case .attendees: return attendeeSummary(first) == attendeeSummary(second)
        case .myResponse: return first.myResponse == second.myResponse
        case .reminders: return Set(first.reminderMinutes) == Set(second.reminderMinutes)
        case .visibility: return first.visibility == second.visibility
        }
    }

    private func attendeeSummary(_ event: CalendarEvent) -> [String] {
        event.attendees.map { attendee in
            [attendee.address.email.lowercased(), attendee.address.name ?? "", attendee.response.rawValue, String(attendee.isOptional)]
                .joined(separator: "\u{0}")
        }
    }

    /// Writes one field of an event into a VEVENT. `old` is what the VEVENT said before (nil for a new one).
    private func write(_ field: Field, of event: CalendarEvent, into component: inout ICalendarComponent, replacing old: CalendarEvent?) {
        switch field {
        case .title:
            component.setText("SUMMARY", event.title)
        case .location:
            component.setText("LOCATION", event.location)
            // The map place another program pinned belongs to the old location.
            component.removeProperties("X-APPLE-STRUCTURED-LOCATION")
        case .notes:
            component.setText("DESCRIPTION", event.notes)
            // The formatted copy (programs that read it show it instead of DESCRIPTION), or none, so an old one
            // doesn't show instead of the new description.
            component.removeProperties("X-ALT-DESC")
            if let html = event.notesHTML {
                component.setProperty(.text("X-ALT-DESC", "<html><body>\(html)</body></html>", parameters: [ICalendarParameter("FMTTYPE", "text/html")]))
            }
        case .conference:
            writeConference(event.conference, old: old?.conference, into: &component)
        case .status:
            if old == nil && event.status == .confirmed { return }
            component.setProperty(ICalendarLine("STATUS", value: ICalendarEventProperties.statusValue(event.status)))
        case .availability:
            component.setProperty(ICalendarLine("TRANSP", value: event.availability == .free ? "TRANSPARENT" : "OPAQUE"))
        case .color:
            if let hex = event.colorHex.flatMap(ICalendarColor.normalizedHex) {
                component.setProperty(.text("COLOR", ICalendarColor.value(forHex: hex)))
            } else {
                component.removeProperties("COLOR")
            }
        case .organizer:
            writeOrganizer(event.organizer, into: &component)
        case .attendees:
            writeAttendees(event.attendees, into: &component)
        case .myResponse:
            if let response = event.myResponse { setOwnerResponse(response, in: &component) }
        case .reminders:
            writeReminders(event.reminderMinutes, into: &component)
        case .visibility:
            // A private CONFIDENTIAL another program set stays as it is.
            if event.visibility == .private, component.property("CLASS")?.value.uppercased() == "CONFIDENTIAL" { return }
            switch event.visibility {
            case .default: component.removeProperties("CLASS")
            case .public: component.setProperty(ICalendarLine("CLASS", value: "PUBLIC"))
            case .private: component.setProperty(ICalendarLine("CLASS", value: "PRIVATE"))
            }
        }
    }

    /// Saves a meeting link in URL and, when the description doesn't have it yet, as a line of the description.
    /// Taking a link off removes it from both.
    private func writeConference(_ conference: Conference?, old: Conference?, into component: inout ICalendarComponent) {
        let link = conference?.joinURL.absoluteString
        let oldLink = old?.joinURL.absoluteString
        let description = component.property("DESCRIPTION")?.text ?? ""
        if let link {
            component.setProperty(ICalendarLine("URL", value: link))
            guard !description.contains(link) else { return }
            var text = oldLink.map { removingLine($0, from: description) } ?? description
            text = text.isEmpty ? link : text + "\n\n" + link
            component.setText("DESCRIPTION", text)
            component.removeProperties("X-ALT-DESC")
        } else if let oldLink {
            if component.property("URL")?.text.trimmingCharacters(in: .whitespaces) == oldLink { component.removeProperties("URL") }
            let text = removingLine(oldLink, from: description)
            if text != description {
                component.setText("DESCRIPTION", text)
                component.removeProperties("X-ALT-DESC")
            }
        }
    }

    private func removingLine(_ line: String, from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { $0.trimmingCharacters(in: .whitespaces) != line }
        guard kept.count != lines.count else { return text }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeOrganizer(_ organizer: MailAddress?, into component: inout ICalendarComponent) {
        guard let organizer else {
            component.removeProperties("ORGANIZER")
            return
        }
        let existing = component.property("ORGANIZER").flatMap { line in
            isAddress(of: line, email: organizer.email) ? line : nil
        }
        var line = existing ?? ICalendarLine("ORGANIZER", value: "mailto:" + organizer.email)
        line.setParameter("CN", organizer.name.map(ICalendarParameter.encode))
        component.setProperty(line)
    }

    /// Writes the guest list, keeping each remaining guest's line (and the parameters PMail doesn't use) and only
    /// changing their name, answer or role where those changed. An event with guests gets the owner as organizer
    /// if it has none.
    private func writeAttendees(_ attendees: [Attendee], into component: inout ICalendarComponent) {
        let existing = component.properties("ATTENDEE")
        var used = Set<Int>()
        var lines: [ICalendarLine] = []
        for attendee in attendees {
            let email = attendee.address.email
            if let index = existing.indices.first(where: { !used.contains($0) && isAddress(of: existing[$0], email: email) }) {
                used.insert(index)
                var line = existing[index]
                if let name = attendee.address.name, name != line.parameter("CN").map(ICalendarParameter.decode) {
                    line.setParameter("CN", ICalendarParameter.encode(name))
                }
                if ICalendarEventProperties.response(ofPartstat: line.parameter("PARTSTAT")) != attendee.response {
                    line.setParameter("PARTSTAT", ICalendarEventProperties.partstat(attendee.response))
                }
                if ICalendarEventProperties.isOptional(line) != attendee.isOptional {
                    line.setParameter("ROLE", attendee.isOptional ? "OPT-PARTICIPANT" : "REQ-PARTICIPANT")
                }
                lines.append(line)
            } else {
                var parameters: [ICalendarParameter] = []
                if let name = attendee.address.name { parameters.append(ICalendarParameter("CN", ICalendarParameter.encode(name))) }
                parameters.append(ICalendarParameter("PARTSTAT", ICalendarEventProperties.partstat(attendee.response)))
                let role = attendee.isOrganizer ? "CHAIR" : attendee.isOptional ? "OPT-PARTICIPANT" : "REQ-PARTICIPANT"
                parameters.append(ICalendarParameter("ROLE", role))
                if attendee.response == .needsAction && !attendee.isOrganizer { parameters.append(ICalendarParameter("RSVP", "TRUE")) }
                lines.append(ICalendarLine("ATTENDEE", parameters: parameters, value: "mailto:" + email))
            }
        }
        let position = component.properties.firstIndex { $0.name == "ATTENDEE" } ?? component.properties.count
        component.properties.removeAll { $0.name == "ATTENDEE" }
        component.properties.insert(contentsOf: lines, at: min(position, component.properties.count))
        if !attendees.isEmpty, component.property("ORGANIZER") == nil, let owner = ownerEmail, !owner.isEmpty {
            component.properties.insert(ICalendarLine("ORGANIZER", value: "mailto:" + owner), at: min(position, component.properties.count))
        }
    }

    /// Whether an ORGANIZER or ATTENDEE line names this address.
    private func isAddress(of line: ICalendarLine, email: String) -> Bool {
        ICalendarEventProperties.address(of: line).map { ICalendarEventProperties.isSameMailbox($0.email, email) } ?? false
    }

    @discardableResult
    private func setOwnerResponse(_ response: AttendeeResponse, in component: inout ICalendarComponent) -> Bool {
        guard let owner = ownerEmail else { return false }
        var found = false
        for index in component.properties.indices where component.properties[index].name == "ATTENDEE" {
            guard let address = ICalendarEventProperties.address(of: component.properties[index]),
                  ICalendarEventProperties.isSameMailbox(address.email, owner) else { continue }
            component.properties[index].setParameter("PARTSTAT", ICalendarEventProperties.partstat(response))
            found = true
        }
        return found
    }

    /// Writes the reminders: alarms PMail understands are kept where their time is still wanted and dropped where
    /// it isn't, new times get new alarms, and alarms PMail doesn't understand stay as they are.
    private func writeReminders(_ minutes: [Int], into component: inout ICalendarComponent) {
        var wanted = Array(Set(minutes.filter { $0 >= 0 })).sorted()
        var kept: [ICalendarComponent] = []
        for child in component.components {
            guard let minutes = ICalendarEventProperties.reminderMinutes(of: child) else {
                kept.append(child)
                continue
            }
            if let index = wanted.firstIndex(of: minutes) {
                wanted.remove(at: index)
                kept.append(child)
            }
        }
        kept += wanted.map { ICalendarEventProperties.alarm(minutesBefore: $0) }
        component.components = kept
    }

    // MARK: Recurrence

    /// The app's RRULE/RDATE/EXDATE lines as content lines; a bare "FREQ=…" counts as an RRULE.
    private func recurrenceLines(_ lines: [String]) -> [ICalendarLine] {
        lines.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let line = ICalendarLine(parsing: trimmed), ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains(line.name) { return line }
            if trimmed.uppercased().hasPrefix("FREQ=") { return ICalendarLine("RRULE", value: trimmed) }
            return nil
        }
    }

    private func sameRecurrence(_ component: ICalendarComponent, _ lines: [String]) -> Bool {
        ICalendarReader.recurrenceLines(of: component) == recurrenceLines(lines).map(\.serialized)
    }

    private func setRecurrence(_ lines: [String], in component: inout ICalendarComponent) {
        let position = component.properties.firstIndex { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }
        component.properties.removeAll { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }
        let index = min(position ?? component.properties.count, component.properties.count)
        component.properties.insert(contentsOf: recurrenceLines(lines), at: index)
    }

    /// Keeps a rule that names DTSTART's weekday or day of the month on the moved start's, when a series moves to
    /// another day ("every Monday" becomes "every Tuesday").
    private func adjustRules(in component: inout ICalendarComponent, from oldStart: WallClockTime, to newStart: WallClockTime) {
        guard oldStart.dayNumber != newStart.dayNumber else { return }
        let weekdayNames = ICalendarRecurrenceRule.weekdayNames
        for index in component.properties.indices where component.properties[index].name == "RRULE" {
            var parts = component.properties[index].value.split(separator: ";").map(String.init)
            for partIndex in parts.indices {
                let pieces = parts[partIndex].split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { continue }
                switch pieces[0].uppercased() {
                case "BYDAY" where pieces[1].uppercased() == weekdayNames[oldStart.weekday]:
                    parts[partIndex] = "BYDAY=" + weekdayNames[newStart.weekday]
                case "BYMONTHDAY" where Int(pieces[1]) == oldStart.date.day:
                    parts[partIndex] = "BYMONTHDAY=\(newStart.date.day)"
                default:
                    break
                }
            }
            component.properties[index].value = parts.joined(separator: ";")
        }
    }

    // MARK: Times

    /// How a VEVENT's times are written.
    private enum TimeForm {
        case date
        case utc
        case floating
        case zoned(String, ICalendarZone)

        var isDate: Bool {
            if case .date = self { true } else { false }
        }
    }

    /// All-day events as dates; repeating events in their own zone; events already written in a zone (or floating)
    /// stay that way; other timed events in UTC.
    private func timeForm(for event: CalendarEvent, existing: ICalendarDateTime?, repeats: Bool,
                          resolver: ICalendarZoneResolver?) -> TimeForm {
        if event.isAllDay { return .date }
        if let identifier = event.timeZone, let timeZone = TimeZone(identifier: identifier), repeats || existing?.tzid != nil {
            return .zoned(identifier, ICalendarZone(timeZone))
        }
        if let existing {
            switch existing.form {
            case let .zoned(tzid): return .zoned(tzid, resolver?.zone(for: existing.form) ?? localZone)
            case .floating: return .floating
            case .utc, .date: break
            }
        }
        return repeats ? .zoned(localTimeZone.identifier, localZone) : .utc
    }

    private func zone(of form: TimeForm) -> ICalendarZone {
        switch form {
        case .date, .floating: localZone
        case .utc: .utc
        case let .zoned(_, zone): zone
        }
    }

    private func wall(of date: Date, in form: TimeForm) -> WallClockTime {
        zone(of: form).wall(from: date)
    }

    private func value(for date: Date, in form: TimeForm) -> ICalendarDateTime {
        switch form {
        case .date: ICalendarDateTime(wall: WallClockTime(dayNumber: localZone.wall(from: date).dayNumber), form: .date)
        case .utc: ICalendarDateTime(wall: ICalendarZone.utc.wall(from: date), form: .utc)
        case .floating: ICalendarDateTime(wall: localZone.wall(from: date), form: .floating)
        case let .zoned(tzid, zone): ICalendarDateTime(wall: zone.wall(from: date), form: .zoned(tzid))
        }
    }

    private func writeTimes(of event: CalendarEvent, form: TimeForm, into component: inout ICalendarComponent) {
        writeTimes(start: event.start, end: event.end, form: form, into: &component)
    }

    private func writeTimes(start: Date, end: Date, form: TimeForm, into component: inout ICalendarComponent) {
        let startValue = value(for: start, in: form)
        var endValue = value(for: max(end, start), in: form)
        if form.isDate, endValue.wall.dayNumber <= startValue.wall.dayNumber {
            endValue.wall = WallClockTime(dayNumber: startValue.wall.dayNumber + 1)
        }
        component.setProperty(startValue.line("DTSTART"))
        component.removeProperties("DURATION")
        component.setProperty(endValue.line("DTEND"))
    }

    private func timesDiffer(_ old: CalendarEvent, _ new: CalendarEvent) -> Bool {
        ICalendarZone.seconds(of: old.start) != ICalendarZone.seconds(of: new.start)
            || ICalendarZone.seconds(of: old.end) != ICalendarZone.seconds(of: new.end)
            || old.isAllDay != new.isAllDay
            || (new.timeZone != nil && old.timeZone != nil && !new.isAllDay && new.timeZone != old.timeZone)
    }

    /// An occurrence's original start written the way its series' DTSTART is (date, UTC, floating or zoned).
    private func recurrenceValue(key: Int64, timing: ICalendarTiming) -> ICalendarDateTime {
        switch timing.start.form {
        case .date: ICalendarDateTime(wall: WallClockTime(dayNumber: WallClockTime(seconds: key).dayNumber), form: .date)
        case .utc: ICalendarDateTime(wall: WallClockTime(seconds: key), form: .utc)
        case .floating: ICalendarDateTime(wall: timing.zone.wall(fromInstant: key), form: .floating)
        case let .zoned(tzid): ICalendarDateTime(wall: timing.zone.wall(fromInstant: key), form: .zoned(tzid))
        }
    }

    /// A value moved by some seconds on the series' wall clock. UTC values move on the series' clock too, so they
    /// keep matching their occurrences across daylight saving changes.
    private func shiftedValue(_ value: ICalendarDateTime, by shift: Int64, zone: ICalendarZone) -> ICalendarDateTime {
        switch value.form {
        case .utc:
            let moved = zone.wall(fromInstant: value.wall.seconds).adding(seconds: shift)
            return ICalendarDateTime(wall: WallClockTime(seconds: zone.instant(from: moved)), form: .utc)
        case .date:
            return ICalendarDateTime(wall: WallClockTime(dayNumber: value.wall.adding(seconds: shift).dayNumber), form: .date)
        case .floating, .zoned:
            return ICalendarDateTime(wall: value.wall.adding(seconds: shift), form: value.form)
        }
    }

    /// A DTSTART, DTEND, RECURRENCE-ID or EXDATE line with every value on it moved.
    private func shiftedLine(_ line: ICalendarLine, by shift: Int64, zone: ICalendarZone) -> ICalendarLine {
        let tzid = line.parameter("TZID")
        let isDate = line.parameter("VALUE")?.uppercased() == "DATE"
        var moved = line
        moved.value = line.value.split(separator: ",", omittingEmptySubsequences: false).map { item in
            guard let value = ICalendarDateTime(text: item, tzid: tzid, isDate: isDate) else { return String(item) }
            return shiftedValue(value, by: shift, zone: zone).text
        }.joined(separator: ",")
        return moved
    }

    // MARK: Bookkeeping

    private func belongs(_ component: ICalendarComponent, to series: ICalendarSeries) -> Bool {
        guard component.name == "VEVENT" else { return false }
        if let uid = series.uid { return component.uid == uid }
        return component == series.master || series.overrides.contains(component)
    }

    private func isMaster(_ component: ICalendarComponent, of series: ICalendarSeries) -> Bool {
        belongs(component, to: series) && component.property("RECURRENCE-ID") == nil
    }

    private func isOverrideOf(_ component: ICalendarComponent, series: ICalendarSeries) -> Bool {
        belongs(component, to: series) && component.property("RECURRENCE-ID") != nil
    }

    private func isOverride(_ component: ICalendarComponent, of series: ICalendarSeries, key: Int64, reader: ICalendarReader) -> Bool {
        guard isOverrideOf(component, series: series), let timing = reader.referenceTiming(of: series),
              let recurrenceID = component.property("RECURRENCE-ID").flatMap(ICalendarDateTime.init) else { return false }
        return reader.instanceKey(recurrenceID, timing: timing) == key
    }

    /// Marks a VEVENT as changed now. Significant changes (times, repeats, status) by the organizer raise SEQUENCE,
    /// so guests' programs take the new version.
    private func stamp(_ component: inout ICalendarComponent, significant: Bool) {
        component.setProperty(ICalendarLine("DTSTAMP", value: utcText(now)))
        if component.property("LAST-MODIFIED") != nil { component.setProperty(ICalendarLine("LAST-MODIFIED", value: utcText(now))) }
        guard significant, ownerOrganizes(component) else { return }
        let sequence = component.property("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        component.setProperty(ICalendarLine("SEQUENCE", value: String(sequence + 1)))
    }

    private func ownerOrganizes(_ component: ICalendarComponent) -> Bool {
        guard let organizer = component.property("ORGANIZER").flatMap(ICalendarEventProperties.address) else { return true }
        guard let owner = ownerEmail else { return false }
        return ICalendarEventProperties.isSameMailbox(organizer.email, owner)
    }

    /// Brings the VCALENDAR's own properties up to date and adds a VTIMEZONE for each system time zone a TZID names
    /// that the file doesn't describe yet.
    private func finish(_ calendar: inout ICalendarComponent) {
        if calendar.property("VERSION") == nil { calendar.properties.insert(ICalendarLine("VERSION", value: "2.0"), at: 0) }
        calendar.setProperty(ICalendarLine("PRODID", value: Self.productID))
        var described = Set(calendar.components.filter { $0.name == "VTIMEZONE" }.compactMap {
            $0.property("TZID")?.text.trimmingCharacters(in: .whitespaces)
        })
        let year = localZone.wall(from: now).date.year
        var added: [ICalendarComponent] = []
        for component in calendar.components where component.name == "VEVENT" {
            for property in component.properties {
                guard let tzid = property.parameter("TZID"), !described.contains(tzid),
                      let timeZone = ICalendarZoneResolver.systemTimeZone(named: tzid) else { continue }
                described.insert(tzid)
                var vtimezone = ICalendarZoneResolver.vtimezone(for: timeZone, year: year)
                vtimezone.setProperty(.text("TZID", tzid))
                added.append(vtimezone)
            }
        }
        if !added.isEmpty {
            let index = calendar.components.firstIndex { $0.name != "VTIMEZONE" } ?? calendar.components.endIndex
            calendar.components.insert(contentsOf: added, at: index)
        }
    }

    private func utcText(_ date: Date) -> String {
        ICalendarDateTime(wall: ICalendarZone.utc.wall(from: date), form: .utc).text
    }
}
