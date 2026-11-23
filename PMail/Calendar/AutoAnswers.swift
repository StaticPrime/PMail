import Foundation
import PMailKit

/// Answering invitations on the account's behalf, as its settings say:
///
/// - An invitation that overlaps an event the account is going to gets the answer chosen under Settings ▸ Calendar ▸
///   Conflicting invitations (No or Maybe), with its message for the organizer.
/// - One during out of office or focus time that declines meetings is declined, with that time's message, where the
///   calendar doesn't do it itself (only a Google Workspace account's main calendar does). Saving such a time can
///   decline the meetings already planned for it too.
///
/// Only invitations that are new since then are answered, each once, so an answer changed by hand stays as it is. The
/// ones seen are kept in the account's defaults, by event and start (a moved invitation is a new one).
extension CalendarViewModel {
    /// How far ahead invitations are looked for.
    static let autoAnswerReach: TimeInterval = 366 * 86_400
    /// The fewest seconds between looks beside the mail checks.
    static let autoAnswerInterval: TimeInterval = 110

    /// The calendars whose events count as the account's own: not subscriptions, task lists or calendars shared with it.
    static func countsAsOwn(_ calendar: CalendarInfo) -> Bool {
        guard !calendar.isTaskList, !CalendarFeeds.isFeed(calendar.id) else { return false }
        return calendar.isPrimary || (!calendar.isOther && !calendar.isReadOnly && calendar.isOwned != false)
    }

    /// Whether the account's calendar answers one time of a repeating meeting on its own (Google and Microsoft do);
    /// elsewhere an answer is for the whole series, so repeating invitations are left to the person.
    var answersEachTime: Bool { account.kind == .google || account.kind == .microsoft }

    /// An invitation still waiting for the account's answer, as PMail answers them: a timed meeting someone else organizes.
    func isWaitingInvitation(_ event: CalendarEvent) -> Bool {
        event.myResponse == .needsAction && isMeeting(event)
    }

    /// A timed meeting someone else organizes, not canceled.
    func isMeeting(_ event: CalendarEvent) -> Bool {
        !event.isTask && event.type == .event && event.status != .cancelled && !event.isAllDay
            && (event.organizer.map { !$0.isSameMailbox(as: account.email) } ?? false)
    }

    /// An event the account is going to: its own (or one it organizes) or one it said yes to, that takes up its time.
    /// All-day events don't, except out of office.
    static func isConfirmed(_ event: CalendarEvent) -> Bool {
        !event.isTask && event.status != .cancelled && event.availability != .free
            && (event.myResponse == nil || event.myResponse == .accepted) && (!event.isAllDay || event.type == .outOfOffice)
    }

    static func overlaps(_ first: CalendarEvent, _ second: CalendarEvent) -> Bool {
        first.start < second.end && second.start < first.end
    }

    /// An invitation's key among the ones seen.
    static func autoAnswerKey(_ event: CalendarEvent) -> String {
        "\(event.id)|\(Int(event.start.timeIntervalSince1970))"
    }

    // MARK: The setting

    /// Turns automatic answers to conflicting invitations on (with an answer) or off. Turned on, the invitations waiting
    /// now are noted, so only new ones are answered.
    func setConflictReply(response: AttendeeResponse?) {
        let wasOn = preferences.conflictReply != nil
        if let response {
            let message = preferences.conflictReply?.message ?? "I have another event at this time."
            preferences.conflictReply = ConflictReply(response: response, message: message)
        } else {
            preferences.conflictReply = nil
        }
        savePreferences()
        if !wasOn, response != nil { Task { await answerInvitationsAutomatically(notingOnly: true) } }
    }

    func setConflictReply(message: String) {
        guard preferences.conflictReply != nil else { return }
        preferences.conflictReply?.message = message
        savePreferences()
    }

    // MARK: Looking

    /// Looks for invitations to answer, unless it looked a moment ago.
    func answerInvitationsIfDue() async {
        if let last = lastAutoAnswers, AppClock.now().timeIntervalSince(last) < Self.autoAnswerInterval { return }
        await answerInvitationsAutomatically()
    }

    /// Whether anything asks for answers: the conflicting-invitations setting, or out of office or focus time still to
    /// come that PMail declines meetings for.
    func wantsAutomaticAnswers() async -> Bool {
        if preferences.conflictReply != nil { return true }
        return await declineBook?.hasUpcoming(now: AppClock.now()) ?? false
    }

    private var declineBook: DeclineBook? { (service as? CalendarWithTasks)?.declines }

    /// Answers the new invitations of the coming year that the settings answer, or (`notingOnly`) just notes the ones
    /// there are, as seen.
    func answerInvitationsAutomatically(notingOnly: Bool = false) async {
        // Asked again while looking (an invitation taken in meanwhile), it looks once more afterwards.
        guard !autoAnswering else {
            autoAnswerAgain = true
            return
        }
        if !notingOnly {
            guard await wantsAutomaticAnswers() else { return }
        }
        autoAnswering = true
        defer {
            autoAnswering = false
            if autoAnswerAgain {
                autoAnswerAgain = false
                Task { await answerInvitationsAutomatically() }
            }
        }
        let now = AppClock.now()
        lastAutoAnswers = now
        let known = calendars.isEmpty ? ((try? await service.loadCalendars()) ?? []) : calendars
        let mine = known.filter(Self.countsAsOwn).map(\.id)
        guard !mine.isEmpty, let found = try? await service.loadEvents(in: mine, from: now, to: now.addingTimeInterval(Self.autoAnswerReach))
        else { return }
        var periods: [CalendarEvent] = []
        if let declineBook {
            for event in found where (event.type == .outOfOffice || event.type == .focusTime) && event.declinesInvitations && event.end > now {
                if await declineBook.entry(for: event) != nil { periods.append(event) }
            }
        }
        let rule = preferences.conflictReply
        var seen = autoAnswersSeen()
        var answered: [(CalendarEvent, AttendeeResponse)] = []
        for invitation in found where isWaitingInvitation(invitation) {
            let key = Self.autoAnswerKey(invitation)
            guard seen[key] == nil else { continue }
            seen[key] = invitation.end
            guard !notingOnly, answersEachTime || !invitation.isRecurring else { continue }
            if let period = periods.first(where: { Self.overlaps($0, invitation) }) {
                respond(to: invitation, with: .declined, comment: period.declineMessage, automatically: true)
                answered.append((invitation, .declined))
            } else if let rule, found.contains(where: { other in
                other.id != invitation.id && (other.uid == nil || other.uid != invitation.uid) && Self.isConfirmed(other)
                    && Self.overlaps(other, invitation)
            }) {
                respond(to: invitation, with: rule.response, comment: rule.message, automatically: true)
                answered.append((invitation, rule.response))
            }
        }
        saveAutoAnswersSeen(seen, now: now)
        if !answered.isEmpty { app?.show(Self.note(for: answered)) }
    }

    /// Out of office or focus time that PMail declines meetings for was saved. When it says so, the meetings already
    /// planned for it are declined (each time of a repeating one, over the coming year); otherwise the invitations
    /// waiting for it now are noted, so only new ones are.
    func declinePeriodSaved(_ saved: CalendarEvent) async {
        guard saved.declinesInvitations, let declineBook, await declineBook.entry(for: saved) != nil else { return }
        let now = AppClock.now()
        let mine = calendars.filter(Self.countsAsOwn).map(\.id)
        let until = saved.isRecurring ? now.addingTimeInterval(Self.autoAnswerReach) : saved.end
        guard until > now, !mine.isEmpty, let found = try? await service.loadEvents(in: mine, from: max(now, saved.start), to: until) else { return }
        let series = saved.seriesID ?? saved.id
        let periods = saved.isRecurring ? found.filter { ($0.seriesID ?? $0.id) == series } + [saved] : [saved]
        var seen = autoAnswersSeen()
        var declined: [(CalendarEvent, AttendeeResponse)] = []
        for event in found where isMeeting(event) && event.myResponse != .declined && periods.contains(where: { Self.overlaps($0, event) }) {
            seen[Self.autoAnswerKey(event)] = event.end
            guard saved.declinesExisting, answersEachTime || !event.isRecurring else { continue }
            respond(to: event, with: .declined, comment: saved.declineMessage, automatically: true)
            declined.append((event, .declined))
        }
        saveAutoAnswersSeen(seen, now: now)
        if !declined.isEmpty { app?.show(Self.note(for: declined)) }
    }

    /// What PMail says it did.
    static func note(for answered: [(CalendarEvent, AttendeeResponse)]) -> String {
        guard answered.count == 1, let (event, response) = answered.first else { return "Answered \(answered.count) invitations for you." }
        return response == .declined ? "Declined “\(event.shownTitle)” for you." : "Answered Maybe to “\(event.shownTitle)” for you."
    }

    // MARK: The invitations seen

    private var autoAnswersKey: String { "AutoAnswered-\(account.id.uuidString)" }

    /// The invitations seen, by key, with when each ends.
    func autoAnswersSeen() -> [String: Date] {
        defaults.data(forKey: autoAnswersKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    /// Saves the invitations seen, forgetting the ones that are over.
    private func saveAutoAnswersSeen(_ seen: [String: Date], now: Date) {
        let kept = seen.filter { $0.value > now.addingTimeInterval(-86_400) }
        defaults.set(try? JSONEncoder().encode(kept), forKey: autoAnswersKey)
    }
}
