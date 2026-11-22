import AppKit
import PMailKit

/// What happens to new mail as it arrives, as Settings ▸ Junk Mail says. Mail from blocked senders goes first, then
/// junk: what PMail's junk filter (or a server's own marks) calls junk is marked or moved to the Junk folder, unless
/// it's from someone the person knows, or the Advanced rule decides instead.
///
/// It also starts the filter off on each account, once: a page of the inbox is learned as good mail and a page of the
/// spam folder as junk, and the Sent folder says who the account has written to.
final class NewMailFilter {
    /// What became of new mail.
    struct Result {
        /// Messages taken out of the inbox (to Junk, the Trash or another folder).
        var movedOut: Set<String> = []
        /// Messages not to announce: those moved out, and junk and blocked mail left in the inbox.
        var quiet: Set<String> = []
        /// Messages the Advanced rule asked to announce.
        var announce: [MessageSummary] = []
    }

    private let sessions: () -> [AccountSession]
    private var starting: Set<UUID> = []

    init(sessions: @escaping () -> [AccountSession]) {
        self.sessions = sessions
    }

    /// Deals with an account's new inbox messages. Junk is only judged when `judgesJunk` (not on an account's first
    /// check, which finds the whole inbox).
    func sort(_ messages: [MessageSummary], in session: AccountSession, judgesJunk: Bool) async -> Result {
        let settings = JunkSettings.shared
        let policy = settings.policy
        var result = Result()
        guard !messages.isEmpty else { return result }
        let storage = session.storage
        let service = session.services.mail
        let judging = judgesJunk && policy.filtersJunk
        if judging { Task { await startLearning(session) } }
        let blocked = policy.filtersBlocked ? Set(await storage.blockedSenders.blocked(among: messages).map(\.id)) : []
        guard judging || !blocked.isEmpty else { return result }
        let people = await knownPeople()
        var marks: [JunkMarks.Mark: [MessageSummary]] = [:]
        var moves: [MailAction: [MessageSummary]] = [:]
        for summary in messages {
            let fromBlocked = blocked.contains(summary.id)
            guard fromBlocked || judging else { continue }
            var facts = MessageFacts(summary: summary, account: session.account.email, fullName: session.account.name, now: AppClock.now())
            people.describe(summary.from?.email, in: &facts)
            if !fromBlocked {
                let serverSaysJunk = policy.trustsServerMarks && summary.senderHints?.serverMarkedJunk == true
                facts.isJunk = serverSaysJunk ? true : await settings.filter.verdict(for: summary).isJunk
                if policy.junkAction == .custom, policy.customRule.needsWholeMessage { facts.message = try? await service.loadMessage(summary) }
            }
            switch policy.outcome(for: facts, fromBlockedSender: fromBlocked) {
            case .nothing:
                continue
            case .markBlocked:
                marks[.blocked, default: []].append(summary)
                result.quiet.insert(summary.id)
            case .markJunk:
                marks[.junk, default: []].append(summary)
                result.quiet.insert(summary.id)
            case .moveToJunk:
                moves[.markSpam, default: []].append(summary)
                result.movedOut.insert(summary.id)
            case .moveToTrash:
                moves[.trash, default: []].append(summary)
                result.movedOut.insert(summary.id)
            case let .actions(actions):
                await perform(actions, on: summary, in: session, result: &result)
            }
        }
        for (mark, summaries) in marks { await storage.junkMarks.mark(summaries, as: mark) }
        for (action, summaries) in moves { try? await service.perform(action, on: summaries) }
        result.quiet.formUnion(result.movedOut)
        return result
    }

    /// The Advanced rule's actions: marks, stars, labels and the rest first, then the first move (after which the
    /// message is somewhere else).
    private func perform(_ actions: [RuleAction], on summary: MessageSummary, in session: AccountSession, result: inout Result) async {
        let service = session.services.mail
        let staying = actions.filter { !$0.kind.movesOut }
        let move = actions.first { $0.kind.movesOut }
        for action in staying + [move].compactMap({ $0 }) {
            switch action.kind {
            case .markJunk:
                await session.storage.junkMarks.mark([summary], as: .junk)
                result.quiet.insert(summary.id)
            case .addLabel:
                guard let label = await label(named: action.value, in: session) else { continue }
                try? await service.perform(.addLabel(label.id), on: [summary])
            case .markRead: try? await service.perform(.markRead, on: [summary])
            case .star: try? await service.perform(.star, on: [summary])
            case .notify: result.announce.append(summary)
            case .playSound: NSSound(named: NSSound.Name(action.value.isEmpty ? "Glass" : action.value))?.play()
            case .bounceDockIcon: NSApp.requestUserAttention(.informationalRequest)
            case .moveToJunk, .moveToTrash, .archive:
                let move: MailAction = action.kind == .moveToJunk ? .markSpam : action.kind == .moveToTrash ? .trash : .archive
                guard (try? await service.perform(move, on: [summary])) != nil else { continue }
                result.movedOut.insert(summary.id)
            }
        }
    }

    /// The account's label with a name, ignoring case.
    private func label(named name: String, in session: AccountSession) async -> MailFolder? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty, let folders = try? await session.services.mail.loadFolders() else { return nil }
        let named = folders.filter { $0.name.lowercased() == wanted || session.mail.displayName(for: $0).lowercased() == wanted }
        return named.first { $0.kind == .label } ?? named.first
    }

    // MARK: Who the person knows

    struct KnownPeople {
        var contacts: Set<String> = []
        var starred: Set<String> = []
        var labels: [String: Set<String>] = [:]
        var writtenTo: Set<String> = []

        func describe(_ sender: String?, in facts: inout MessageFacts) {
            guard let sender = sender?.lowercased() else { return }
            facts.senderInContacts = contacts.contains(sender)
            facts.senderIsStarred = starred.contains(sender)
            facts.senderLabels = labels[sender] ?? []
            facts.senderInPreviousRecipients = writtenTo.contains(sender)
        }
    }

    /// Everyone in every account's contacts, and everyone any account has written to (its own addresses included).
    func knownPeople() async -> KnownPeople {
        var people = KnownPeople()
        for session in sessions() {
            people.writtenTo.insert(session.account.email.lowercased())
            people.writtenTo.formUnion(await session.storage.recipients.all())
            for contact in await session.storage.cache.contacts() ?? [] where contact.kind == .contact {
                for email in contact.emails.map({ $0.value.trimmingCharacters(in: .whitespaces).lowercased() }) where !email.isEmpty {
                    people.contacts.insert(email)
                    if contact.isStarred { people.starred.insert(email) }
                    people.labels[email, default: []].formUnion(contact.labels.map { $0.lowercased() })
                }
            }
        }
        return people
    }

    // MARK: Starting the filter off

    /// Starts the junk filter off on an account, once: a page of its inbox is learned as good mail and a page of its
    /// spam folder as junk, and its Sent folder says who it has written to. If a folder can't be listed, it's tried
    /// again next time.
    func startLearning(_ session: AccountSession) async {
        let filter = JunkSettings.shared.filter
        let key = session.id.uuidString
        guard JunkSettings.shared.policy.filtersJunk, !starting.contains(session.id), await !filter.hasStarted(account: key) else { return }
        starting.insert(session.id)
        defer { starting.remove(session.id) }
        let service = session.services.mail
        guard let folders = try? await service.loadFolders() else { return }
        func messages(in role: FolderRole) async -> [MessageSummary]? {
            guard let folder = folders.first(where: { $0.role == role }) else { return [] }
            return try? await service.listConversations(ListRequest(folderID: folder.id, pageSize: 100)).conversations.flatMap(\.messages)
        }
        guard let junk = await messages(in: .spam), let inbox = await messages(in: .inbox), let sent = await messages(in: .sent) else { return }
        let marked = await session.storage.junkMarks.marks(for: inbox)
        await filter.learn(junk, asJunk: true)
        await filter.learn(inbox.filter { marked[$0.id] == nil }, asJunk: false)
        await session.storage.recipients.record(sent.flatMap { $0.to + $0.cc }.map(\.email))
        await filter.markStarted(account: key)
    }
}
