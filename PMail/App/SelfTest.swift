#if DEBUG
import AppKit
import PMailKit

/// `-PMSelfTest YES`: drives the main window on the sample accounts and prints SELFTEST PASS/FAIL lines. Each step
/// runs in its own turn of the run loop; `wait` holds the next step until something finishes.
enum SelfTest {
    nonisolated(unsafe) static var isRunning = false
    private static var failures = 0
    private static var passes = 0
    private static var steps: [() -> Void] = []
    private static var holding: (condition: () -> Bool, deadline: Date, name: String)?

    static func runIfRequested(_ delegate: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "PMSelfTest") else { return }
        isRunning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(delegate) }
    }

    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("SELFTEST PASS: \(name)")
        } else {
            failures += 1
            print("SELFTEST FAIL: \(name) — \(detail())")
        }
        fflush(stdout)
    }

    static func step(_ body: @escaping () -> Void) { steps.append(body) }

    /// Holds the next step until `condition` holds or `timeout` seconds pass (then the step after it fails its checks).
    static func wait(_ name: String = "", upTo timeout: Double = 5, until condition: @escaping () -> Bool) {
        holding = (condition, Date().addingTimeInterval(timeout), name)
    }

    private static func continueSteps(from index: Int) {
        if let hold = holding, !hold.condition(), Date() < hold.deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { continueSteps(from: index) }
            return
        }
        if let hold = holding, !hold.condition(), !hold.name.isEmpty { print("SELFTEST NOTE: gave up waiting for \(hold.name)") }
        holding = nil
        runSteps(from: index)
    }

    private static func runSteps(from index: Int = 0) {
        guard index < steps.count else {
            print(failures == 0 ? "SELFTEST DONE: all \(passes) passed" : "SELFTEST DONE: \(failures) failed, \(passes) passed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        steps[index]()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { continueSteps(from: index + 1) }
    }

    /// Asks the window about every menu bar item it answers for, as macOS does for every menu at once whenever it
    /// likes. Returns how many it asked about.
    @discardableResult
    static func validateEveryMenuItem(_ controller: MainWindowController) -> Int {
        var count = 0
        func validate(_ menu: NSMenu) {
            DynamicMenus.shared.menuNeedsUpdate(menu)
            for item in menu.items {
                if item.target == nil, let action = item.action, controller.responds(to: action) {
                    _ = controller.validateMenuItem(item)
                    count += 1
                }
                if let submenu = item.submenu { validate(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { validate(menu) }
        return count
    }

    /// A key press as the window's key monitor sees it.
    static func key(_ characters: String, shift: Bool = false, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
    }

    /// Reads a value from one of the sample services (they're actors), blocking until it arrives.
    /// The invitation the self-test answers by email.
    static var gardenParty: Invitation?
    /// Why following a calendar was refused.
    static var subscribeRefusal: String?
    /// The main calendar, exported.
    static var exportedCalendar: String?
    /// The day the automatic answers' events are on.
    static var autoAnswerDay: Date?
    /// The ID of a message taken out of junk, arriving in the inbox again.
    static var movedBackID: String?

    /// A time on a day.
    static func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        day.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    /// An invitation from someone on the main calendar, waiting for the account's answer (or answered), as a calendar
    /// lists it.
    static func invitationEvent(_ id: String, _ title: String, from start: Date, to end: Date, organizer: MailAddress, guest: MailAddress,
                                answer: AttendeeResponse = .needsAction) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: "primary", title: title, start: start, end: end,
                      attendees: [Attendee(address: organizer, response: .accepted, isOrganizer: true), Attendee(address: guest, response: answer)],
                      organizer: organizer, myResponse: answer, uid: "\(id)@example.com")
    }
    /// The invitation the self-test takes into a calendar, and the ID of its email.
    static var picnic: Invitation?
    static var picnicMessage: String?
    /// Unread messages with the picnic's title that answering it must leave unread.
    static var picnicDecoys: [String] = []

    /// An emailed invitation's iCalendar text, as another calendar would send it.
    static func invitation(uid: String, title: String, start: Date, end: Date, organizer: String, guest: String,
                           method: String = "REQUEST", sequence: Int = 0, location: String? = nil) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Calendar//EN", "METHOD:\(method)", "BEGIN:VEVENT", "UID:\(uid)",
                "DTSTAMP:\(format.string(from: start))", "DTSTART:\(format.string(from: start))", "DTEND:\(format.string(from: end))",
                "SUMMARY:\(title)", "SEQUENCE:\(sequence)"] + (location.map { ["LOCATION:\($0)"] } ?? [])
            + ["ORGANIZER:mailto:\(organizer)", "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(guest)",
               "END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    static func read<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        // The services never need the main thread, so waiting here is safe.
        guard semaphore.wait(timeout: .now() + 5) == .success else { return nil }
        return box.value
    }

    private nonisolated final class ResultBox<T>: @unchecked Sendable { var value: T? }

    // swiftlint:disable:next function_body_length
    private static func run(_ delegate: AppDelegate) {
        guard let controller = delegate.windowController, let window = controller.window else {
            print("SELFTEST FAIL: no main window")
            exit(1)
        }
        let app = delegate.app!
        window.makeKeyAndOrderFront(nil)
        var session: AccountSession { app.current! }
        var mail: MailViewModel { session.mail }
        var sampleMail: SampleMailService? { session.services.mail as? SampleMailService }
        func actions() -> [String] {
            guard let service = sampleMail else { return [] }
            return read { await service.actionLog.map { "\($0.0)" } } ?? []
        }
        func sentCount() -> Int {
            guard let service = sampleMail else { return -1 }
            return read { await service.sentMessages.count } ?? -1
        }

        // MARK: Starting up
        step { wait("the first account's inbox", upTo: 8) { app.current?.mail.conversations.isEmpty == false } }
        step {
            // Calendar changes offer Undo only a moment, so the checks go on.
            for each in app.accounts.sessions.values { each.calendar.undoDelay = 0.05 }
            check(app.accounts.accounts.count == 3, "three sample accounts", "\(app.accounts.accounts.count)")
            check(session.account.kind == .google, "the first account shows first", "\(session.account.kind)")
            check(app.module == .mail, "PMail opens on mail")
            let count = validateEveryMenuItem(controller)
            check(count >= 30, "every menu item can be checked right after launch", "\(count) items")
            check(mail.currentFolder?.role == .inbox, "the inbox is chosen")
            check(mail.selectedTabID == mail.inboxTabs.first?.id, "the first inbox tab is chosen")
            check(mail.conversations.count == 50, "fifty conversations to a page", "\(mail.conversations.count)")
            check(mail.rangeText.hasPrefix("1–50 of "), "the page says which conversations it shows", mail.rangeText)
            check(mail.canGoForward && !mail.canGoBack, "there's an older page and no newer one")
            check(mail.unreadInbox == 6, "the inbox counts its unread messages", "\(mail.unreadInbox)")
            check(window.firstResponder === window || !(window.firstResponder is NSTextView), "nothing is typed into at first")
        }

        // MARK: Pages and tabs
        step {
            mail.nextPage()
            wait("the second page") { mail.pageIndex == 1 && !mail.isLoadingList && !mail.conversations.isEmpty }
        }
        step {
            check(mail.rangeText.hasPrefix("51–"), "the second page follows the first", mail.rangeText)
            check(!mail.canGoForward && mail.canGoBack, "the last page has no older page")
            mail.previousPage()
            wait("the first page again") { mail.pageIndex == 0 && !mail.isLoadingList && mail.conversations.count == 50 }
        }
        step {
            mail.select(tabID: "CATEGORY_PROMOTIONS")
            wait("the Promotions tab") { !mail.isLoadingList && mail.conversations.contains { $0.subject.contains("winter dog jackets") } }
        }
        step {
            check(mail.conversations.allSatisfy { $0.labelIDs.contains("CATEGORY_PROMOTIONS") }, "a tab lists only its own kind of mail")
            mail.select(tabID: "CATEGORY_PERSONAL")
            wait("the Primary tab") { !mail.isLoadingList && mail.conversations.count == 50 }
        }

        // MARK: Reading
        step {
            guard let roadmap = mail.conversations.first(where: { $0.subject == "Q4 roadmap draft" }) else {
                return check(false, "the roadmap conversation is listed")
            }
            check(roadmap.messageCount == 3 && roadmap.isUnread, "a conversation counts its messages and is unread", "\(roadmap.messageCount)")
            mail.open(roadmap)
            wait("the conversation to open") { mail.openMessages.count == 3 }
        }
        step {
            check(mail.openMessages.map(\.summary.from?.shortName) == ["Priya", "Jamie", "Priya"], "a conversation shows its messages oldest first",
                  "\(mail.openMessages.map(\.summary.from?.shortName))")
            check(mail.expandedMessageIDs.contains(mail.openMessages.last!.id), "the newest message starts open")
            check(!mail.expandedMessageIDs.contains(mail.openMessages[1].id), "read older messages start folded")
            check(mail.positionText.hasSuffix("of 57"), "the reading toolbar says where it is", mail.positionText)
            wait("reading to mark it read") { actions().contains("markRead") }
        }
        step {
            check(actions().contains("markRead"), "opening a conversation marks it read on the server")
            check(mail.unreadInbox == 5, "and the inbox count goes down", "\(mail.unreadInbox)")
            check(mail.openConversation?.isUnread == false, "and the conversation is read")
            let message = mail.openMessages.last!
            check(!mail.showsImages(for: message), "pictures from the internet don't load by themselves")
            let html = MessageHTML.document(for: MailMessage(summary: message.summary, htmlBody: "<p>Hi<img src=\"https://tracker.example/p.gif\"></p>"))
            check(html.contains("Content-Security-Policy") && html.contains("img-src cid: data:;"), "message pages refuse anything from the internet")
            check(MessageHTML.document(for: message, allowsRemote: true).contains("img-src cid: data: pmail-remote:;"),
                  "until pictures are asked for, and then only through PMail's loader")
        }
        step {
            // Single-key shortcuts: S stars the open conversation, U goes back to the list.
            let starred = mail.openConversation?.isStarred ?? false
            if let event = key("s", window: window) { _ = controller.handleKey(event) }
            check(mail.openConversation?.isStarred == !starred, "S stars or unstars the conversation")
            if let event = key("s", window: window) { _ = controller.handleKey(event) }
            check(mail.openConversation?.isStarred == starred, "and S again turns it back")
            // ⌘⌫ deletes text while typing, never the conversation behind it.
            let trash = NSMenuItem(title: "Move to Trash", action: #selector(MainWindowController.pmTrash(_:)), keyEquivalent: "\u{8}")
            check(controller.validateMenuItem(trash), "Move to Trash works on the open conversation")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            window.contentView?.addSubview(field)
            window.makeFirstResponder(field)
            check(!controller.validateMenuItem(trash), "but not while text is being typed")
            field.removeFromSuperview()
            window.makeFirstResponder(nil)
            if let event = key("u", window: window) { _ = controller.handleKey(event) }
            check(mail.openConversation == nil, "U goes back to the list")
        }

        // MARK: Archiving, with and without Undo
        step {
            mail.undoDelay = 30
            guard let target = mail.conversations.first(where: { $0.subject == "Thanksgiving pie plans 🥧" }) else {
                return check(false, "Grandma's message is listed")
            }
            let before = mail.conversations.count
            mail.perform(.archive, on: [target])
            check(mail.conversations.count == before - 1 && !mail.conversations.contains { $0.id == target.id }, "archiving takes a conversation out of the inbox at once")
            check(app.toast?.text == "Conversation archived." && app.toast?.actionTitle == "Undo", "and offers Undo", app.toast?.text ?? "no note")
            // New mail can load the list again while Undo is offered, when the server still has it in the inbox.
            mail.loadList()
            wait("the inbox to load again") { !mail.isLoadingList }
        }
        step {
            check(!mail.conversations.contains { $0.subject == "Thanksgiving pie plans 🥧" },
                  "loading the inbox again while Undo is offered leaves the archived conversation out")
            app.toast?.action?()
            check(mail.conversations.contains { $0.subject == "Thanksgiving pie plans 🥧" }, "Undo puts it back")
            check(!actions().contains("archive"), "and nothing reached the server")
        }
        step {
            mail.undoDelay = 0.2
            guard let target = mail.conversations.first(where: { $0.subject == "Thanksgiving pie plans 🥧" }) else { return }
            mail.perform(.archive, on: [target])
            wait("the archive to reach the server") { actions().contains("archive") }
        }
        step {
            check(actions().contains("archive"), "without Undo, the archive reaches the server a moment later")
            mail.select(folderID: nil)
            wait("All Mail") { mail.selectedFolderID == nil && !mail.isLoadingList && !mail.conversations.isEmpty }
        }
        step {
            check(mail.conversations.contains { $0.subject == "Thanksgiving pie plans 🥧" }, "an archived conversation is still in All Mail")
            check(mail.listTitle == "All Mail", "the list says it's All Mail", mail.listTitle)
            mail.select(folderID: mail.folder(role: .sent)?.id)
            wait("Sent") { mail.currentFolder?.role == .sent && !mail.isLoadingList && !mail.conversations.isEmpty }
        }
        step {
            check(mail.listShowsRecipients, "Sent lists who messages went to")
            mail.search("waffles")
            wait("the search") { mail.activeSearch == "waffles" && !mail.isLoadingList }
        }
        step {
            check(!mail.conversations.isEmpty && mail.listTitle.contains("waffles"), "search finds messages", "\(mail.conversations.count)")
            mail.clearSearch()
            mail.select(folderID: mail.inbox?.id)
            wait("the inbox again") { mail.currentFolder?.role == .inbox && !mail.isLoadingList && !mail.conversations.isEmpty }
        }

        // MARK: Writing and sending
        step {
            let before = sentCount()
            guard let composer = app.compose(to: [MailAddress(name: "Alex Kim", email: "alex.kim@example.com")], subject: "Self-test hello",
                                             body: "Hello from the self-test.") else { return check(false, "a compose window opens") }
            check(app.composers.count == 1, "a compose window opens")
            composer.undoSendDelay = 0.2
            composer.send()
            check(app.composers.isEmpty && app.toast?.actionTitle == "Undo", "sending closes the window and offers Undo")
            wait("the message to go") { sentCount() == before + 1 }
        }
        step {
            check(sentCount() >= 1, "the message is sent a moment later")
            if let service = sampleMail, let last = read({ await service.sentMessages.last }) ?? nil {
                check(last.subject == "Self-test hello" && last.to.first?.email == "alex.kim@example.com", "with its subject and recipient")
                check(last.htmlBody?.contains("Hello from the self-test.") == true && last.textBody.contains("Hello from the self-test."),
                      "in both formatted and plain text")
                check(last.messageID.hasPrefix("<") && last.messageID.hasSuffix("@example.com>"), "with a Message-ID on the sender's domain", last.messageID)
            }
            let before = sentCount()
            guard let composer = app.compose(to: [MailAddress(email: "sam.rivera@example.net")], subject: "Never mind") else { return }
            composer.undoSendDelay = 30
            composer.send()
            composer.undoSend()
            check(app.composers.contains { $0 === composer }, "Undo Send opens the message again")
            check(sentCount() == before, "and doesn't send it")
            composer.to = []
            composer.send()
            check(composer.error == "Add at least one recipient.", "a message with nobody to send to isn't sent", composer.error ?? "")
            composer.to = [MailAddress(email: "not-an-address")]
            composer.send()
            check(composer.error?.contains("isn’t a complete email address") == true, "nor one to something that isn't an address")
            composer.discard()
            check(app.composers.isEmpty, "Discard closes it")
        }
        step {
            guard let roadmap = mail.conversations.first(where: { $0.subject == "Q4 roadmap draft" }) else { return }
            mail.open(roadmap)
            wait("the conversation") { mail.openMessages.count == 3 }
        }
        step {
            if let event = key("r", window: window) { _ = controller.handleKey(event) }
            guard let reply = app.composers.last else { return check(false, "R starts a reply") }
            check(reply.subject == "Re: Q4 roadmap draft", "a reply's subject starts with Re:", reply.subject)
            check(reply.to.map(\.email) == ["priya@example.com"], "a reply goes to the sender", "\(reply.to.map(\.email))")
            check(reply.inReplyTo == mail.openMessages.last?.summary.messageIDHeader, "and threads under the message")
            check(reply.quotedText?.contains("> Good call") == true, "and quotes it")
            reply.discard()
            if let event = key("a", window: window) { _ = controller.handleKey(event) }
            if let all = app.composers.last {
                check(Set(all.to.map(\.email)) == ["priya@example.com", "alex.kim@example.com"], "reply all adds everyone else",
                      "\(all.to.map(\.email))")
                all.discard()
            }
            app.handleMailto(URL(string: "mailto:waffles@example.com?subject=Woof&body=Hi%20there&cc=sam@example.com")!)
            if let link = app.composers.last {
                check(link.to.first?.email == "waffles@example.com" && link.subject == "Woof" && link.cc.first?.email == "sam@example.com"
                      && link.body.string == "Hi there", "a mailto: link opens a filled-in message")
                link.discard()
            }
            mail.closeConversation()
        }

        // MARK: Calendar, with each provider's meetings
        step {
            app.show(.calendar)
            session.calendar.mode = .week
            session.calendar.goToday()
            wait("this week's events") { !session.calendar.events.isEmpty }
        }
        step {
            let calendar = session.calendar
            check(calendar.calendars.count == 6, "the account's calendars and task lists load", "\(calendar.calendars.count)")
            check(calendar.defaultCalendar?.nativeConference == .meet, "its main calendar makes Meet meetings")
            check(calendar.visibleDays.count == 7, "the week shows seven days")
            let standups = calendar.shownEvents().filter { $0.title == "Team standup" }
            check(standups.count == 5 && standups.allSatisfy { $0.conference?.kind == .meet }, "this week's standups have their meeting links", "\(standups.count)")
            check(calendar.title == "November 2026", "the week's title", calendar.title)
            calendar.toggle(calendar.calendars.first { $0.id == "family" }!)
            check(!calendar.shownEvents().contains { $0.calendarID == "family" }, "turning a calendar off hides its events")
            calendar.toggle(calendar.calendars.first { $0.id == "family" }!)
            // Invitations show their answers: waiting and Maybe; your own events are solid. One you said No to isn't there.
            let looks = ["Vendor demo", "Product sync", "Design review"].map { title in
                calendar.shownEvents().first { $0.title == title }.map(AnswerLook.init)
            }
            check(looks == [.pending, .maybe, .solid], "invitations show as waiting and Maybe", "\(looks)")
            check(!calendar.shownEvents().contains { $0.title == "Budget review" } && calendar.events.contains { $0.title == "Budget review" },
                  "an invitation you said No to isn't on the calendar")
            check(calendar.shownEvents().first { $0.title == "Product sync" }.map { eventTitleString($0) } == "Product sync (Maybe)",
                  "Maybe shows after the title")
            if let demo = calendar.shownEvents().first(where: { $0.title == "Vendor demo" }) {
                calendar.respond(to: demo, with: .accepted, scope: .thisEvent)
                check(calendar.shownEvents().first { $0.title == "Vendor demo" }.map(AnswerLook.init) == .solid, "answering Yes makes it solid")
                // Saying No takes it off the calendar.
                calendar.selectedEventID = demo.id
                calendar.respond(to: demo, with: .declined, scope: .thisEvent)
                check(!calendar.shownEvents().contains { $0.title == "Vendor demo" } && calendar.selectedEventID == nil,
                      "saying No takes an invitation off the calendar, and closes its details")
            }
            guard var draft = calendar.newDraft() else { return check(false, "a new event can be started") }
            draft.title = "Self-test sync"
            draft.addsNativeConference = true
            draft.guests = [SampleData.person("Alex Kim")]
            Task {
                do { try await calendar.save(draft) } catch { check(false, "saving an event", "\(error)") }
            }
            wait("the new event") { calendar.events.contains { $0.title == "Self-test sync" } }
        }
        step {
            // An invitation that came by email is answered on the calendar's own copy, whose server tells the organizer.
            let calendar = session.calendar
            let services = session.services.calendar as? CalendarWithTasks
            let club = read { await (services?.calendars as? SampleCalendarService)?.allEvents.first { $0.title == "Book club" } } ?? nil
            guard let club, let uid = club.uid else { return check(false, "an invited event has a UID") }
            let text = Self.invitation(uid: uid, title: "Book club", start: club.start, end: club.end, organizer: "hannah.brooks@example.com",
                                       guest: session.account.email)
            let invitation = Invitation.read(Data(text.utf8), ownerEmail: session.account.email)
            check(invitation?.method == .request && invitation?.event.myResponse == .needsAction && invitation?.organizer?.email == "hannah.brooks@example.com",
                  "an emailed invitation is read")
            if let invitation { calendar.answer(invitation, with: .tentative) }
            wait("the emailed invitation answered on the calendar") {
                read { await (services?.calendars as? SampleCalendarService)?.allEvents.first { $0.id == club.id }?.myResponse } == .tentative
            }
        }
        step {
            // One the calendar doesn't have is answered by email, to the organizer.
            let calendar = session.calendar
            let mailService = sampleMail
            let start = AppClock.now().addingTimeInterval(3 * 86_400)
            let text = Self.invitation(uid: "not-on-the-calendar@example.com", title: "Garden party", start: start, end: start.addingTimeInterval(7_200),
                                       organizer: "olivia.chen@example.com", guest: session.account.email)
            guard let invitation = Invitation.read(Data(text.utf8), ownerEmail: session.account.email) else {
                return check(false, "an invitation the calendar doesn't have is read")
            }
            calendar.answer(invitation, with: .declined)
            gardenParty = invitation
            wait("the answer emailed to the organizer") {
                read { await mailService?.sentMessages.last?.calendar?.method } == "REPLY"
            }
        }
        step {
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.to.map(\.email) == ["olivia.chen@example.com"] && last?.subject.hasPrefix("Declined: Garden party") == true,
                  "the answer goes to the organizer", last?.subject ?? "nothing sent")
            check(last?.calendar?.text.contains("PARTSTAT=DECLINED") == true && gardenParty.map(session.calendar.currentAnswer(to:)) == .declined,
                  "with the answer, which the message then shows")
        }
        step {
            // A calendar with no server emails its own invitations: the guests get one when the meeting's made.
            let calendar = session.calendar
            let mailService = sampleMail
            ((session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService)?.emailing.withLock { $0 = true }
            guard var draft = calendar.newDraft() else { return check(false, "a meeting to email can be started") }
            draft.title = "Self-test emailed meeting"
            draft.guests = [SampleData.person("Alex Kim"), SampleData.person("Priya Shah")]
            Task { try? await calendar.save(draft) }
            wait("the invitation emailed") {
                read { await mailService?.sentMessages.last?.subject }??.hasPrefix("Invitation: Self-test emailed meeting") == true
            }
        }
        step {
            let calendar = session.calendar
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.calendar?.method == "REQUEST" && last?.to.map(\.name) == ["Alex Kim", "Priya Shah"], "the guests get the invitation",
                  last?.subject ?? "nothing sent")
            // Priya is taken off: she gets a cancellation, and Alex isn't told again about nothing new.
            guard let made = calendar.events.first(where: { $0.title == "Self-test emailed meeting" }) else {
                return check(false, "the emailed meeting is on the calendar")
            }
            var draft = calendar.draft(for: made)
            draft.guests = [SampleData.person("Alex Kim")]
            Task { try? await calendar.save(draft) }
            wait("the cancellation emailed") {
                read { await mailService?.sentMessages.last?.calendar?.method } == "CANCEL"
            }
        }
        step {
            let calendar = session.calendar
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.to.map(\.name) == ["Priya Shah"] && last?.subject.hasPrefix("Canceled: Self-test emailed meeting") == true,
                  "a guest taken off gets a cancellation", last?.subject ?? "nothing sent")
            let sentCount = { () -> Int in (read { await mailService?.sentMessages.count ?? 0 }) ?? 0 }
            let count = sentCount()
            // Deleting it: everyone still invited gets a cancellation.
            guard let made = calendar.events.first(where: { $0.title == "Self-test emailed meeting" }) else {
                return check(false, "the emailed meeting is still on the calendar")
            }
            calendar.delete(made, scope: .allEvents)
            wait("the meeting called off") { sentCount() > count }
        }
        step {
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.calendar?.method == "CANCEL" && last?.to.map(\.name) == ["Alex Kim"], "deleting it calls it off for everyone invited",
                  last?.subject ?? "nothing sent")
            // A calendar that doesn't take emailed invitations in itself: PMail does, waiting for an answer.
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            let start = AppClock.now().addingTimeInterval(4 * 86_400)
            let text = Self.invitation(uid: "picnic@example.com", title: "Self-test picnic", start: start, end: start.addingTimeInterval(7_200),
                                       organizer: "olivia.chen@example.com", guest: session.account.email)
            guard let invitation = Invitation.read(Data(text.utf8), ownerEmail: session.account.email) else {
                return check(false, "an invitation to take in is read")
            }
            picnic = invitation
            // Its email waits unread in the inbox, with the invitation attached.
            let file = Attachment(id: "invite", filename: "invite.ics", mimeType: "text/calendar", size: text.utf8.count, data: Data(text.utf8))
            let olivia = SampleData.person("Olivia Chen")
            let now = AppClock.now()
            picnicMessage = read {
                await mailService?.deliver(from: olivia, subject: "Invitation: Self-test picnic", text: "Bring a blanket!", attachments: [file], at: now)
            } ?? nil
            // Another invitation with the same title (a different event), and a message about it with no invitation.
            let other = Self.invitation(uid: "another-picnic@example.com", title: "Self-test picnic", start: start.addingTimeInterval(7 * 86_400),
                                        end: start.addingTimeInterval(7 * 86_400 + 7_200), organizer: "olivia.chen@example.com",
                                        guest: session.account.email)
            let otherFile = Attachment(id: "invite", filename: "invite.ics", mimeType: "text/calendar", size: other.utf8.count, data: Data(other.utf8))
            picnicDecoys = [
                read { await mailService?.deliver(from: olivia, subject: "Invitation: Self-test picnic", text: "Next week too!", attachments: [otherFile],
                                                  at: now) } ?? nil,
                read { await mailService?.deliver(from: olivia, subject: "Re: Self-test picnic", text: "I'll bring lemonade.", at: now) } ?? nil,
            ].compactMap { $0 }
            let calendar = session.calendar
            Task { await calendar.takeIn(invitation) }
            wait("the emailed invitation on the calendar") {
                read { await service?.allEvents.contains { $0.uid == "picnic@example.com" && $0.myResponse == .needsAction } } == true
            }
        }
        step {
            let mailService = sampleMail
            guard let picnic else { return check(false, "the invitation taken in") }
            check(true, "an emailed invitation for the account goes on its calendar, waiting for an answer")
            session.calendar.answer(picnic, with: .accepted)
            let message = picnicMessage ?? ""
            wait("the answer to the emailed invitation, and its email read") {
                read { await mailService?.sentMessages.last?.subject }??.hasPrefix("Accepted: Self-test picnic") == true
                    && read { await mailService?.summary(id: message)?.isUnread } == false
            }
        }
        step {
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.calendar?.method == "REPLY" && last?.to.map(\.email) == ["olivia.chen@example.com"],
                  "answering it emails the organizer", last?.subject ?? "nothing sent")
            let message = picnicMessage ?? ""
            check(read { await mailService?.summary(id: message)?.isUnread } == false, "and marks the invitation email read")
            let decoys = picnicDecoys
            let stillUnread = read { () async -> Bool in
                var all = true
                for id in decoys where await mailService?.summary(id: id)?.isUnread != true { all = false }
                return all
            }
            check(decoys.count == 2 && stillUnread == true, "but not another event's invitation with the same title, or a message about it with none")
            // The organizer changes it: a day later, somewhere else. The calendar follows, and asks again.
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            guard let picnic else { return }
            let moved = picnic.event.start.addingTimeInterval(86_400)
            let text = Self.invitation(uid: picnic.uid, title: "Self-test picnic", start: moved, end: moved.addingTimeInterval(7_200),
                                       organizer: "olivia.chen@example.com", guest: session.account.email, sequence: 1, location: "Laurelhurst Park")
            if let change = Invitation.read(Data(text.utf8), ownerEmail: session.account.email) {
                let calendar = session.calendar
                Task { await calendar.takeIn(change) }
            }
            wait("the changed invitation") {
                read { await service?.allEvents.first { $0.uid == "picnic@example.com" }?.location } == "Laurelhurst Park"
            }
        }
        step {
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            let changed = read { await service?.allEvents.first { $0.uid == "picnic@example.com" } } ?? nil
            check(changed?.location == "Laurelhurst Park" && changed?.start == picnic.map { $0.event.start.addingTimeInterval(86_400) }
                  && changed?.myResponse == .needsAction, "a changed invitation updates the event, and asks again when its time moves")
            // The organizer calls it off: it stays, marked canceled.
            guard let picnic, let start = changed?.start else { return }
            let text = Self.invitation(uid: picnic.uid, title: "Self-test picnic", start: start, end: start.addingTimeInterval(7_200),
                                       organizer: "olivia.chen@example.com", guest: session.account.email, method: "CANCEL", sequence: 2)
            if let cancellation = Invitation.read(Data(text.utf8), ownerEmail: session.account.email) {
                let calendar = session.calendar
                Task { await calendar.takeIn(cancellation) }
            }
            wait("the canceled invitation") {
                read { await service?.allEvents.first { $0.uid == "picnic@example.com" }?.status } == .cancelled
            }
        }
        step {
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            guard let canceled = read({ await service?.allEvents.first { $0.uid == "picnic@example.com" } }) ?? nil else {
                return check(false, "a cancellation keeps the event")
            }
            check(AnswerLook(canceled) == .canceled && eventTitleString(canceled) == "Self-test picnic (Canceled)" && AnswerLook.canceled.isStruckThrough,
                  "a cancellation keeps the event, marked (Canceled) and struck through")
            // Deleting it takes it off.
            session.calendar.delete(canceled, scope: .thisEvent)
            wait("the canceled invitation deleted") {
                read { await service?.allEvents.contains { $0.uid == "picnic@example.com" } } == false
            }
        }
        step {
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            check(read { await service?.allEvents.contains { $0.uid == "picnic@example.com" } } == false, "and deleting it takes it off")
            service?.emailing.withLock { $0 = false }
        }
        step {
            // A calendar server on an IMAP/POP account that keeps meetings without inviting anyone: PMail emails the
            // invitation, and the cancellation, to those guests itself. (Google and Microsoft send their own, and so does
            // iCloud when the Apple Account's email is an iCloud address.)
            let calendar = session.calendar
            let mailService = sampleMail
            ((session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService)?.invitesNoOne.withLock { $0 = true }
            guard var draft = calendar.newDraft() else { return check(false, "a meeting can be started") }
            draft.title = "Self-test uninvited meeting"
            draft.guests = [SampleData.person("Alex Kim")]
            Task { try? await calendar.save(draft) }
            wait("the invitation the server didn't send") {
                read { await mailService?.sentMessages.last?.subject }??.hasPrefix("Invitation: Self-test uninvited meeting") == true
            }
        }
        step {
            let calendar = session.calendar
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.calendar?.method == "REQUEST" && last?.to.map(\.name) == ["Alex Kim"],
                  "guests a calendar server doesn't invite get PMail’s invitation by email", last?.subject ?? "nothing sent")
            guard let made = calendar.events.first(where: { $0.title == "Self-test uninvited meeting" }) else {
                return check(false, "the meeting is on the calendar")
            }
            check(made.attendees.contains { $0.invitedByEmail && $0.address.name == "Alex Kim" }, "and the meeting says PMail invites them")
            calendar.delete(made, scope: .thisEvent)
            wait("the cancellation the server didn't send") {
                read { await mailService?.sentMessages.last?.subject }??.hasPrefix("Canceled: Self-test uninvited meeting") == true
            }
        }
        step {
            let mailService = sampleMail
            let last = read { await mailService?.sentMessages.last } ?? nil
            check(last?.calendar?.method == "CANCEL" && last?.to.map(\.name) == ["Alex Kim"], "and the cancellation when it's deleted")
            ((session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService)?.invitesNoOne.withLock { $0 = false }
        }
        step {
            // Following someone's calendar: it shows under Other calendars, on, with its events.
            let calendar = session.calendar
            check(calendar.canSubscribeToPeople, "a Google account can follow other people’s calendars")
            Task { _ = try? await calendar.subscribe(toCalendarOf: "sam.rivera@example.com") }
            wait("the followed calendar and its events") {
                calendar.events.contains { $0.calendarID == FollowedCalendars.calendarID(for: "sam.rivera@example.com") }
            }
        }
        step {
            let calendar = session.calendar
            let followed = calendar.otherCalendars.first { $0.id == FollowedCalendars.calendarID(for: "sam.rivera@example.com") }
            check(followed?.canUnsubscribe == true && followed.map(calendar.isVisible) == true && followed?.isReadOnly == true,
                  "a followed calendar shows under Other calendars, on, with its events")
            // Someone who hasn't shared their calendar: it says so.
            subscribeRefusal = nil
            Task {
                do { _ = try await calendar.subscribe(toCalendarOf: "stranger@elsewhere.example") } catch { subscribeRefusal = "\(error)" }
            }
            // And a calendar from a web address.
            Task { _ = try? await calendar.subscribe(toFeed: "webcal://calendars.example.com/rovers.ics", name: "") }
            wait("the refusal and the calendar from a web address") {
                subscribeRefusal != nil && calendar.events.contains { $0.title == "Rovers game" }
            }
        }
        step {
            let calendar = session.calendar
            check(subscribeRefusal?.contains("hasn’t shared their calendar") == true, "following someone who hasn’t shared says so", subscribeRefusal ?? "")
            let feed = calendar.otherCalendars.first { $0.name == "Riverside Rovers" }
            check(feed.map { CalendarFeeds.isFeed($0.id) && $0.isReadOnly && $0.canUnsubscribe == true } == true,
                  "a calendar from a web address is named from the feed, under Other calendars, read-only")
            check(calendar.events.contains { $0.title == "Rovers game" && $0.location == "Riverside Park" }, "with its events, repeats and all")
            // Unsubscribing from both.
            for subscribed in calendar.otherCalendars where subscribed.canUnsubscribe == true && subscribed.id != "holidays" { calendar.unsubscribe(subscribed) }
            wait("both unsubscribed") {
                !calendar.otherCalendars.contains { $0.name == "Riverside Rovers" || $0.id.hasPrefix(FollowedCalendars.prefix) }
                    && !calendar.events.contains { $0.title == "Rovers game" }
            }
        }
        step {
            let calendar = session.calendar
            check(!calendar.otherCalendars.contains { $0.name == "Riverside Rovers" || $0.id.hasPrefix(FollowedCalendars.prefix) }
                  && !calendar.events.contains { $0.title == "Rovers game" }, "unsubscribing takes a calendar and its events away")
        }
        step {
            // Importing a file's events into one of the account's own calendars.
            let calendar = session.calendar
            let csv = "Subject,Start Date,Start Time,End Time\nImported dentist,11/19/2026,3:00 PM,4:00 PM\nImported lunch,11/20/2026,12:00 PM,1:00 PM\n"
            guard let result = try? CalendarImport.events(from: Data(csv.utf8), fileExtension: "csv"),
                  let target = calendar.importTargets.first(where: \.isPrimary) else { return check(false, "a file’s events are read") }
            check(result.events.count == 2 && !calendar.importTargets.contains { $0.isOther || $0.isReadOnly || $0.isTaskList },
                  "a file’s events are read, to go in the account’s own calendars")
            Task { _ = await calendar.importEvents(result.events, into: target.id) }
            wait("the imported events") { calendar.events.filter { $0.title.hasPrefix("Imported ") }.count == 2 }
        }
        step {
            let calendar = session.calendar
            let imported = calendar.events.filter { $0.title.hasPrefix("Imported ") }
            check(imported.count == 2 && imported.allSatisfy { $0.calendarID == "primary" && $0.attendees.isEmpty },
                  "importing adds them to the calendar chosen")
            for event in imported { calendar.delete(event, scope: .thisEvent) }
            wait("the imported events deleted") { !calendar.events.contains { $0.title.hasPrefix("Imported ") } }
        }
        step {
            // A calendar's color, chosen from its ⋯ menu: shown at once, and kept by the provider.
            let calendar = session.calendar
            guard let family = calendar.calendars.first(where: { $0.id == "family" }) else { return check(false, "the Family calendar") }
            calendar.setColor(family, to: "#8E24AA")
            check(calendar.colorHex(of: family) == "#8E24AA", "a calendar’s new color shows at once")
            // Display this only, then everything again.
            calendar.showOnly(family)
            check(calendar.calendars.filter(calendar.isVisible).map(\.id) == ["family"], "Display This Only hides the account’s other calendars")
            for other in calendar.calendars where !calendar.isVisible(other) { calendar.toggle(other) }
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            wait("the color kept by the provider") { read { await service?.keptSettings("family")?.colorHex } == "#8E24AA" }
        }
        step {
            // Changed somewhere else afterwards, the calendar takes that color.
            let calendar = session.calendar
            wait("the provider's color noted") { calendar.preferences.colors["family"]?.provider != nil }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            _ = read { await service?.recolorElsewhere("family", to: "#039BE5") }
            calendar.refreshQuietly()
            wait("the color changed elsewhere") { calendar.calendars.first { $0.id == "family" }.map(calendar.colorHex(of:)) == "#039BE5" }
        }
        step {
            check(session.calendar.preferences.colors["family"] == nil, "a color changed somewhere else replaces the one chosen here")
        }
        step {
            // Settings ▸ Calendar: what the provider keeps goes to it, and new events start with the notifications chosen.
            let calendar = session.calendar
            guard let primary = calendar.calendars.first(where: { $0.id == "primary" }) else { return check(false, "the main calendar") }
            Task {
                guard var settings = try? await calendar.settings(for: primary) else { return }
                settings.description = "Self-test description"
                settings.eventReminders = [30, 1_440]
                settings.allDayReminders = [AllDayReminder(daysBefore: 1, minuteOfDay: 17 * 60)]
                settings.emailNotices = [.dailyAgenda]
                try? await calendar.saveSettings(settings, for: primary)
            }
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            wait("the calendar’s settings saved") {
                read { await service?.keptSettings("primary")?.description } == "Self-test description"
                    && calendar.calendars.first { $0.id == "primary" }?.defaultReminders == [30, 1_440]
            }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            let kept = read { await service?.keptSettings("primary") } ?? nil
            check(kept?.eventReminders == [30, 1_440] && kept?.emailNotices == [.dailyAgenda], "a calendar’s settings go to its provider")
            check(calendar.newDraft()?.reminders.map(\.minutes) == [30, 1_440], "new events start with its notifications")
            check(calendar.newDraft(allDay: true)?.reminders.map(\.minutes) == [7 * 60], "and new all-day events with theirs (a day before at 5 PM)")
            // Exporting it: a weekly event, with its second time deleted, goes once, as it is.
            guard var draft = calendar.newDraft() else { return check(false, "a new event can be started") }
            draft.title = "Self-test export"
            draft.repeatRule = RepeatRule(frequency: .weekly, weekdays: [calendar.calendar.component(.weekday, from: draft.start)], end: .after(3))
            Task {
                do { try await calendar.save(draft) } catch { check(false, "saving a repeating event to export", "\(error)") }
            }
            wait("the weekly event to export") { calendar.events.filter { $0.title == "Self-test export" }.count == 3 }
        }
        step {
            let calendar = session.calendar
            let times = calendar.events.filter { $0.title == "Self-test export" }.sorted { $0.start < $1.start }
            if let second = times[safe: 1] { calendar.delete(second, scope: .thisEvent) }
            wait("its second time deleted") { calendar.events.filter { $0.title == "Self-test export" }.count == 2 }
        }
        step {
            let calendar = session.calendar
            guard let primary = calendar.calendars.first(where: { $0.id == "primary" }) else { return check(false, "the main calendar") }
            Task { exportedCalendar = try? await calendar.exportDocument(for: primary) }
            wait("the exported calendar") { exportedCalendar != nil }
        }
        step {
            let calendar = session.calendar
            let text = exportedCalendar ?? ""
            check(text.hasPrefix("BEGIN:VCALENDAR") && text.components(separatedBy: "SUMMARY:Design review").count == 2,
                  "exporting a calendar writes its events")
            check(text.components(separatedBy: "SUMMARY:Self-test export").count == 2 && text.contains("EXDATE") && text.contains("UNTIL="),
                  "a repeating event goes once, without the time deleted")
            if let one = calendar.events.first(where: { $0.title == "Self-test export" }) { calendar.delete(one, scope: .allEvents) }
            wait("the exported event deleted") { !calendar.events.contains { $0.title == "Self-test export" } }
        }
        // Answering invitations for the account: ones that overlap an event it's going to, and ones during out of office.
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            let zoe = SampleData.person("Zoe Anderson")
            let me = session.account.address
            let day = calendar.calendar.date(byAdding: .day, value: 2, to: calendar.calendar.startOfDay(for: AppClock.now())) ?? AppClock.now()
            autoAnswerDay = day
            let busy = CalendarEvent(id: "selftest-busy", calendarID: "primary", title: "Self-test busy", start: at(day, 10), end: at(day, 11))
            let waiting = invitationEvent("selftest-waiting", "Self-test waiting", from: at(day, 10, 15), to: at(day, 10, 45), organizer: zoe, guest: me)
            _ = read { await service?.arrive(busy); await service?.arrive(waiting) }
            calendar.setConflictReply(response: .declined)
            calendar.setConflictReply(message: "Self-test: busy then")
            wait("the invitations already waiting noted") { calendar.autoAnswersSeen()[CalendarViewModel.autoAnswerKey(waiting)] != nil }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            guard let day = autoAnswerDay else { return check(false, "the day for automatic answers") }
            let zoe = SampleData.person("Zoe Anderson")
            let me = session.account.address
            let clash = invitationEvent("selftest-clash", "Self-test clash", from: at(day, 10, 30), to: at(day, 11, 30), organizer: zoe, guest: me)
            let free = invitationEvent("selftest-free", "Self-test free", from: at(day, 14), to: at(day, 15), organizer: zoe, guest: me)
            // A weekly meeting whose first time overlaps too.
            var weekly = invitationEvent("selftest-weekly", "Self-test weekly sync", from: at(day, 10, 30), to: at(day, 11), organizer: zoe, guest: me)
            weekly.recurrence = ["RRULE:FREQ=WEEKLY"]
            let series = weekly
            _ = read { await service?.arrive(clash); await service?.arrive(free); await service?.arrive(series) }
            Task { await calendar.answerInvitationsAutomatically() }
            wait("the invitation that overlaps answered") { read { await service?.event("selftest-clash")?.myResponse } == .declined }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            check(read { await service?.comment(for: "selftest-clash") } == "Self-test: busy then",
                  "an invitation that overlaps an event you’re going to is declined for you, with your message")
            check(read { await service?.event("selftest-free")?.myResponse } == .needsAction, "one that doesn’t is left for you")
            check(read { await service?.event("selftest-waiting")?.myResponse } == .needsAction, "and so are the ones that were waiting already")
            guard let day = autoAnswerDay else { return }
            let nextWeek = calendar.calendar.date(byAdding: .day, value: 7, to: day) ?? day
            let first = "selftest-weekly@\(Int(at(day, 10, 30).timeIntervalSince1970))"
            let second = "selftest-weekly@\(Int(at(nextWeek, 10, 30).timeIntervalSince1970))"
            check(read { await service?.answer(forTime: first) } == .declined && (read { await service?.answer(forTime: second) } ?? nil) == nil,
                  "a repeating invitation is answered just for the time that overlaps")
            // Answering every time of it by hand.
            let services = session.services.calendar as? CalendarWithTasks
            let times = (read { try? await services?.loadEvents(in: ["primary"], from: nextWeek, to: nextWeek.addingTimeInterval(86_400)) } ?? nil) ?? nil
            guard let later = times?.first(where: { $0.seriesID == "selftest-weekly" }) else { return check(false, "the weekly meeting's next time") }
            calendar.respond(to: later, with: .accepted, scope: .allEvents)
            wait("every time of it answered") { read { await service?.event("selftest-weekly")?.myResponse } == .accepted }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            guard let day = autoAnswerDay else { return }
            let first = "selftest-weekly@\(Int(at(day, 10, 30).timeIntervalSince1970))"
            check((read { await service?.answer(forTime: first) } ?? nil) == nil, "answering all of a repeating meeting answers every time of it")
            calendar.setConflictReply(response: nil)
            // Out of office on a calendar that doesn't decline meetings itself: PMail declines the ones already planned.
            guard var away = calendar.newDraft(type: .outOfOffice) else { return check(false, "out of office can be started") }
            let planned = invitationEvent("selftest-planned", "Self-test planned", from: at(day, 16), to: at(day, 17),
                                          organizer: SampleData.person("Zoe Anderson"), guest: session.account.address, answer: .accepted)
            _ = read { await service?.arrive(planned) }
            away.title = "Self-test vacation"
            away.calendarID = "family"
            (away.start, away.end, away.isAllDay) = (day, calendar.calendar.date(byAdding: .day, value: 1, to: day) ?? day, true)
            (away.declinesInvitations, away.declinesExisting, away.declineMessage) = (true, true, "Self-test: away")
            check(calendar.canDecline(away) && !calendar.providerDeclines(away), "PMail declines meetings for out of office on other calendars")
            Task {
                do { try await calendar.save(away) } catch { check(false, "saving out of office that declines meetings", "\(error)") }
            }
            wait("the meeting already planned declined") { read { await service?.event("selftest-planned")?.myResponse } == .declined }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            check(read { await service?.comment(for: "selftest-planned") } == "Self-test: away",
                  "out of office declines the meetings already planned, with its message")
            guard let day = autoAnswerDay else { return }
            let during = invitationEvent("selftest-during", "Self-test during", from: at(day, 12), to: at(day, 13),
                                         organizer: SampleData.person("Zoe Anderson"), guest: session.account.address)
            _ = read { await service?.arrive(during) }
            Task { await calendar.answerInvitationsAutomatically() }
            wait("the new invitation declined") { read { await service?.event("selftest-during")?.myResponse } == .declined }
        }
        step {
            let calendar = session.calendar
            let service = (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService
            check(read { await service?.comment(for: "selftest-during") } == "Self-test: away", "and new invitations for that time")
            let vacation = read { await service?.allEvents.first { $0.title == "Self-test vacation" } } ?? nil
            if let vacation { calendar.delete(vacation, scope: .allEvents) }
            _ = read { await service?.remove(["selftest-busy", "selftest-waiting", "selftest-clash", "selftest-free", "selftest-planned", "selftest-during",
                                               "selftest-weekly"]) }
            let titles: Set = ["Self-test busy", "Self-test waiting", "Self-test clash", "Self-test free", "Self-test planned", "Self-test during",
                               "Self-test vacation", "Self-test weekly sync"]
            wait("the automatic answers' events gone") {
                read { await service?.allEvents.contains { titles.contains($0.title) } } == false
            }
        }
        step {
            let calendar = session.calendar
            let created = calendar.events.first { $0.title == "Self-test sync" }
            check(created?.conference?.kind == .meet && created?.conference?.joinURL.host == "meet.google.com", "a new event gets its Meet meeting",
                  created?.conference?.joinURL.absoluteString ?? "none")
            check(created?.attendees.count == 2 && created?.attendees.first?.isOrganizer == true, "with its guest and its organizer")
            calendar.mode = .month
            check(calendar.visibleInterval.duration >= 28 * 86_400, "the month view shows the whole month")
            calendar.step(1)
            check(calendar.title == "December 2026", "the next month", calendar.title)
            calendar.goToday()
            calendar.mode = .week
            if let created { calendar.delete(created, scope: .thisEvent) }
            wait("the event to go") { !calendar.events.contains { $0.title == "Self-test sync" } }
        }

        // Kinds of events, and tasks
        var keptFocus: CalendarEvent?
        step {
            let calendar = session.calendar
            check(calendar.taskLists.map(\.name) == ["My Tasks", "Waffles"] && calendar.myCalendars.count == 3,
                  "the task lists show apart from the calendars", "\(calendar.taskLists.map(\.name))")
            check(calendar.defaultTaskList?.id == "tasks:my-tasks", "new tasks go in the first list")
            let shown = calendar.shownEvents()
            let focus = shown.first { $0.title == "Focus time" }
            check(focus?.type == .focusTime && focus?.isTypeLocal == false && focus?.declinesInvitations == true, "focus time comes from the calendar")
            check(shown.first { $0.title == "Out of office" }?.type == .outOfOffice, "and out of office")
            let tasks = shown.filter(\.isTask)
            check(tasks.contains { $0.title == "Renew passport" && $0.isAllDay && $0.type == .task }
                  && tasks.contains { $0.title == "Send slides to Priya" && $0.isCompleted }, "this week's tasks show on their days", "\(tasks.map(\.title))")
            if let new = calendar.newDraft() {
                check(calendar.types(for: new) == [.event, .task, .outOfOffice, .focusTime], "something new can be any kind")
            }
            if let meeting = shown.first(where: { $0.title == "Design review" }) {
                check(calendar.types(for: calendar.draft(for: meeting)) == [.event], "a meeting stays a meeting")
            }
            guard var draft = calendar.newDraft(type: .task) else { return check(false, "a new task can be started") }
            check(draft.calendarID == "tasks:my-tasks" && draft.isAllDay && draft.guests.isEmpty, "a new task is all day, in the default list")
            draft.title = "Self-test task"
            draft.notes = "Made by the self-test"
            Task {
                do { try await calendar.save(draft) } catch { check(false, "saving a task", "\(error)") }
            }
            wait("the new task") { calendar.events.contains { $0.title == "Self-test task" } }
        }
        step {
            let calendar = session.calendar
            guard let task = calendar.events.first(where: { $0.title == "Self-test task" }) else { return check(false, "making a task") }
            check(task.isTask && task.type == .task && task.notes == "Made by the self-test", "making a task saves it in the task list")
            calendar.setCompleted(task, true)
            check(calendar.event(task.id)?.isCompleted == true, "ticking a task off shows at once")
            let tasks = (session.services.calendar as? CalendarWithTasks)?.tasks as? SampleTaskService
            wait("the task list to hear it's done") { read { await tasks?.allTasks.first { $0.id == task.id }?.isCompleted } == true }
        }
        step {
            let calendar = session.calendar
            if let task = calendar.events.first(where: { $0.title == "Self-test task" }) { calendar.delete(task, scope: .thisEvent) }
            // Out of office on the main calendar, which holds it itself.
            guard var away = calendar.newDraft(type: .outOfOffice) else { return check(false, "out of office can be started") }
            check(away.isAllDay && away.title == "Out of office" && away.calendarID == "primary", "out of office starts as the whole day, on the main calendar")
            check(calendar.canDecline(away), "where meetings can be declined")
            away.title = "Self-test away"
            away.declinesInvitations = true
            away.declineMessage = "Back Monday"
            // Focus time on a calendar that can't hold it.
            guard var focus = calendar.newDraft(type: .focusTime) else { return check(false, "focus time can be started") }
            check(!focus.isAllDay && focus.end.timeIntervalSince(focus.start) == 7_200, "focus time starts as two hours")
            // In the morning, so it's in the week showing whatever the time of day (late at night, the next half hour is tomorrow).
            let morning = calendar.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: calendar.today()) ?? focus.start
            (focus.start, focus.end) = (morning, morning.addingTimeInterval(7_200))
            focus.calendarID = "family"
            check(calendar.canDecline(focus) && !calendar.providerDeclines(focus), "other calendars decline meetings through PMail")
            focus.title = "Self-test focus"
            Task {
                do {
                    try await calendar.save(away)
                    try await calendar.save(focus)
                } catch { check(false, "saving out of office and focus time", "\(error)") }
            }
            wait("out of office and focus time") {
                calendar.events.contains { $0.title == "Self-test focus" } && !calendar.events.contains { $0.title == "Self-test task" }
            }
        }
        step {
            let calendar = session.calendar
            check(!calendar.events.contains { $0.title == "Self-test task" }, "deleting a task")
            let away = calendar.events.first { $0.title == "Self-test away" }
            check(away?.type == .outOfOffice && away?.isTypeLocal == false && away?.declinesInvitations == true && away?.declineMessage == "Back Monday",
                  "out of office is saved as out of office, declining meetings")
            guard let focus = calendar.events.first(where: { $0.title == "Self-test focus" }) else { return check(false, "saving focus time") }
            check(focus.type == .focusTime && focus.isTypeLocal, "focus time a calendar can't hold is kept as focus time on this Mac")
            let services = session.services.calendar as? CalendarWithTasks
            let saved = read { await (services?.calendars as? SampleCalendarService)?.allEvents.first { $0.id == focus.id } }
            check(saved??.type == .event, "and saved in the calendar as an event")
            let interval = calendar.visibleInterval
            let again = read { try? await services?.loadEvents(in: ["family"], from: interval.start, to: interval.end) }
            check(again??.first { $0.id == focus.id }?.type == .focusTime, "loading the calendar again still shows it as focus time",
                  "\(again.map { $0?.map { "\($0.id) \($0.title) \($0.type) \($0.start)" } ?? ["threw"] } ?? ["timed out"]); \(focus.id) \(focus.start) in \(interval)")
            let book = DebugLaunchOptions.sampleStorage.appendingPathComponent(SampleData.googleID.uuidString).appendingPathComponent(EventTypeBook.fileName)
            check(FileManager.default.fileExists(atPath: book.path), "kept in the account's folder")
            keptFocus = focus
            calendar.delete(focus, scope: .thisEvent)
            if let away { calendar.delete(away, scope: .thisEvent) }
            // The window drops them at once; the calendar (and the kinds kept here) a moment later.
            wait("out of office and focus time to go") {
                read { await (services?.calendars as? SampleCalendarService)?.allEvents.contains { $0.title.hasPrefix("Self-test") } } == false
            }
        }
        step {
            let services = session.services.calendar as? CalendarWithTasks
            let focus = keptFocus
            let kept = read { () async -> EventType? in
                guard let focus else { return .event }
                return await services?.types.type(for: focus)
            }
            check(focus != nil && kept == .some(nil), "deleting focus time forgets it here", "\(String(describing: kept))")
        }

        // Repeating, notifications, visibility, guest permissions and busy times
        let busy = ResultBox<[String: FreeBusy]>()
        step {
            let calendar = session.calendar
            check(calendar.features == .google, "a Google calendar keeps five notifications, visibility and guest permissions")
            guard var draft = calendar.newDraft() else { return check(false, "a new event can be started") }
            let weekday = calendar.calendar.component(.weekday, from: draft.start)
            check(RepeatRule.presets(for: draft.start, calendar: calendar.calendar)[1].weekdays == [weekday], "it can repeat weekly on its own weekday")
            draft.title = "Self-test weekly"
            draft.repeatRule = RepeatRule(frequency: .weekly, weekdays: [weekday], end: .after(3))
            draft.reminders = [Reminder(minutes: 10), Reminder(amount: 1, unit: .days)]
            draft.visibility = .private
            draft.guestsCanModify = true
            draft.guests = [SampleData.person("Alex Kim")]
            Task {
                do { try await calendar.save(draft) } catch { check(false, "saving a repeating event", "\(error)") }
            }
            wait("the weekly event's three times") { calendar.events.filter { $0.title == "Self-test weekly" }.count == 3 }
        }
        step {
            let calendar = session.calendar
            let times = calendar.events.filter { $0.title == "Self-test weekly" }.sorted { $0.start < $1.start }
            check(times.count == 3 && Set(times.compactMap(\.seriesID)).count == 1, "a repeating event shows each time, as one series", "\(times.count)")
            check(times.count == 3 && times[1].start.timeIntervalSince(times[0].start) >= 6 * 86_400, "a week apart")
            let first = times.first
            check(first?.recurrence.last?.hasSuffix(";COUNT=3") == true && first?.recurrence.last?.hasPrefix("RRULE:FREQ=WEEKLY;BYDAY=") == true,
                  "with its rule", first?.recurrence.joined() ?? "")
            check(first?.reminderMinutes == [10, 1_440], "two notifications", "\(first?.reminderMinutes ?? [])")
            check(first?.visibility == .private && first?.guestsCanModify == true && first?.guestsCanSeeOtherGuests == true,
                  "private, with guests allowed to change it")
            guard let second = times[safe: 1] else { return }
            var draft = calendar.draft(for: second)
            check(draft.repeatRule == RepeatRule(frequency: .weekly, weekdays: [calendar.calendar.component(.weekday, from: second.start)], end: .after(3)),
                  "the editor reads its rule")
            check(draft.reminders == [Reminder(minutes: 10), Reminder(amount: 1, unit: .days)], "and its notifications")
            draft.repeatRule = RepeatRule(frequency: .daily, end: .after(2))
            check(draft.changesRepeat, "choosing another rule changes it")
            Task {
                do { try await calendar.save(draft) } catch { check(false, "changing how an event repeats", "\(error)") }
            }
            wait("the daily times") {
                let daily = calendar.events.filter { $0.title == "Self-test weekly" }.sorted { $0.start < $1.start }
                return daily.count == 2 && daily[1].start.timeIntervalSince(daily[0].start) < 2 * 86_400
            }
        }
        step {
            let calendar = session.calendar
            check(calendar.events.filter { $0.title == "Self-test weekly" }.count == 2, "a new rule is for the whole series")
            if let one = calendar.events.first(where: { $0.title == "Self-test weekly" }) { calendar.delete(one, scope: .allEvents) }
            let interval = DateInterval(start: calendar.calendar.date(byAdding: .day, value: 7, to: calendar.grid.startOfWeek(calendar.today())) ?? calendar.today(),
                                        duration: 7 * 86_400)
            let guests = [SampleData.person("Alex Kim"), SampleData.person("Zoe Anderson")]
            Task { busy.value = await calendar.busyTimes(for: guests, in: interval) }
            wait("busy times") {
                busy.value != nil && !calendar.events.contains { $0.title == "Self-test weekly" }
            }
        }
        step {
            let calendar = session.calendar
            check(!calendar.events.contains { $0.title == "Self-test weekly" }, "deleting every time of a repeating event")
            let found = busy.value ?? [:]
            let alex = found["alex.kim@example.com"]?.busy ?? []
            check(!alex.isEmpty && found["alex.kim@example.com"]?.problem == nil, "a guest's busy times are looked up", "\(alex.count)")
            check(found["zoe.anderson@example.org"]?.problem == "Their calendar isn’t shared with you.", "or why they can't be")
            let monday = calendar.calendar.date(byAdding: .day, value: 8, to: calendar.grid.startOfWeek(calendar.today())) ?? calendar.today()
            let suggestions = calendar.suggestedTimes(lasting: 3_600, from: monday, busy: alex)
            check(suggestions.count == 8 && suggestions.allSatisfy { slot in !alex.contains { $0.start < slot.end && $0.end > slot.start } },
                  "suggested times miss every busy time", "\(suggestions.count)")
            check(suggestions.allSatisfy { slot in
                let hour = calendar.calendar.component(.hour, from: slot.start)
                let weekday = calendar.calendar.component(.weekday, from: slot.start)
                return hour >= 9 && slot.end <= (calendar.calendar.date(bySettingHour: 17, minute: 0, second: 0, of: slot.start) ?? slot.end)
                    && weekday != 1 && weekday != 7
            }, "on weekdays from 9 to 5")
            check(suggestions.first.map { calendar.calendar.component(.hour, from: $0.start) } == 9, "starting with the first free hour")
        }

        // Formatted descriptions
        step {
            let calendar = session.calendar
            let review = calendar.events.first { $0.title == "Design review" }
            let shown = RichNotes.attributed(fromHTML: review?.notesHTML ?? "")
            check(shown.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(shown[$0.range].characters) == "Agenda" },
                  "a formatted description shows its bold")
            check(shown.runs.contains { $0.link?.host == "docs.example.com" } && String(shown.characters).contains("• Onboarding flows"),
                  "with its link and its list")
            guard var draft = calendar.newDraft() else { return }
            draft.title = "Self-test notes"
            let text = NSMutableAttributedString(string: "Agenda", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            text.append(NSAttributedString(string: "\nBring snacks", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            draft.notes = RichTextHTML.plainText(from: text)
            draft.notesHTML = EventDescription.html(from: text)
            Task {
                do { try await calendar.save(draft) } catch { check(false, "saving a formatted description", "\(error)") }
            }
            wait("the formatted event") { calendar.events.contains { $0.title == "Self-test notes" } }
        }
        step {
            let calendar = session.calendar
            let saved = calendar.events.first { $0.title == "Self-test notes" }
            check(saved?.notesHTML == "<b>Agenda</b><br>Bring snacks" && saved?.notes == "Agenda\nBring snacks",
                  "a formatted description is saved as simple HTML, with its plain text", saved?.notesHTML ?? "none")
            check(calendar.draft(for: saved ?? CalendarEvent(calendarID: "", start: .now, end: .now)).notesHTML == "<b>Agenda</b><br>Bring snacks",
                  "and comes back to the editor")
            if let saved { calendar.delete(saved, scope: .thisEvent) }
        }

        // MARK: Saving, moving and deleting an event happen at once, with Undo for as long as sending waits
        var calendarService: SampleCalendarService? { (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService }
        var movedFrom: Date?
        step {
            let calendar = session.calendar
            guard var draft = calendar.newDraft() else { return check(false, "an event can be started") }
            draft.title = "Self-test undo"
            app.sheet = nil
            calendar.undoDelay = 30
            calendar.saveWithUndo(draft)
            wait("the event saved at once") { calendar.events.contains { $0.title == "Self-test undo" } && app.toast?.text == "Event saved." }
        }
        step {
            let calendar = session.calendar
            let service = calendarService
            check(app.toast?.actionTitle == "Undo", "saving an event happens at once, saying so with Undo", app.toast?.text ?? "none")
            check(read { await service?.allEvents.contains { $0.title == "Self-test undo" } ?? false } == true, "it's on the calendar already")
            app.toast?.action?()
            wait("Undo to take it away") { !calendar.events.contains { $0.title == "Self-test undo" } && app.toast?.text == "Saving undone." }
        }
        step {
            let calendar = session.calendar
            let service = calendarService
            check(read { await service?.allEvents.contains { $0.title == "Self-test undo" } ?? true } == false, "Undo takes it off the calendar too")
            guard var draft = calendar.newDraft() else { return check(false, "an event can be started") }
            draft.title = "Self-test moved"
            Task { try? await calendar.save(draft) }
            wait("an event to move") { calendar.events.contains { $0.title == "Self-test moved" } }
        }
        step {
            let calendar = session.calendar
            guard let event = calendar.events.first(where: { $0.title == "Self-test moved" }) else { return check(false, "the event to move") }
            check(calendar.canMove(event), "an event of the account's own can be dragged")
            movedFrom = event.start
            let later = event.start.addingTimeInterval(90 * 60)
            calendar.drop(event, start: later, end: event.end.addingTimeInterval(90 * 60))
            check(calendar.events.first { $0.title == "Self-test moved" }?.start == later, "dropped somewhere else, it shows there at once")
            wait("the move saved") { app.toast?.text == "Event moved." }
        }
        step {
            let calendar = session.calendar
            let service = calendarService
            let saved = read { await service?.allEvents.first { $0.title == "Self-test moved" }?.start } ?? nil
            check(saved != nil && saved == calendar.events.first { $0.title == "Self-test moved" }?.start && app.toast?.actionTitle == "Undo",
                  "and it's saved at once, with Undo")
            app.toast?.action?()
            wait("Undo to put it back") { app.toast?.text == "Move undone." && calendar.events.first { $0.title == "Self-test moved" }?.start == movedFrom }
        }
        step {
            let calendar = session.calendar
            let service = calendarService
            let saved = read { await service?.allEvents.first { $0.title == "Self-test moved" }?.start } ?? nil
            check(saved != nil && saved == movedFrom, "Undo puts it back where it was, on the calendar too")
            if let event = calendar.events.first(where: { $0.title == "Self-test moved" }) { calendar.delete(event, scope: .thisEvent) }
            check(!calendar.events.contains { $0.title == "Self-test moved" }, "deleting takes it away at once")
            wait("the deletion with Undo") { app.toast?.text == "Event deleted." }
        }
        step {
            let service = calendarService
            check(read { await service?.allEvents.contains { $0.title == "Self-test moved" } ?? true } == false && app.toast?.actionTitle == "Undo",
                  "it's deleted from the calendar at once, with Undo")
            app.toast?.action?()
            wait("Undo to bring it back") { session.calendar.events.contains { $0.title == "Self-test moved" } && app.toast?.text == "Event restored." }
        }
        step {
            let calendar = session.calendar
            let service = calendarService
            check(read { await service?.allEvents.contains { $0.title == "Self-test moved" } ?? false } == true, "Undo puts it back on the calendar")
            calendar.undoDelay = 0.05
            if let event = calendar.events.first(where: { $0.title == "Self-test moved" }) { calendar.delete(event, scope: .thisEvent) }
            wait("it to go") { read { await service?.allEvents.contains { $0.title == "Self-test moved" } ?? false } == false }
        }

        // MARK: Calendars and contacts with each mail check, and changes made offline
        var sampleCalendar: SampleCalendarService? { (session.services.calendar as? CalendarWithTasks)?.calendars as? SampleCalendarService }
        var sampleContacts: SampleContactsService? { session.services.contacts as? SampleContactsService }
        step {
            // Made on another device: the next mail check brings them.
            let begin = AppClock.now().addingTimeInterval(3 * 3_600)
            let arrived = CalendarEvent(id: "arrived-elsewhere", calendarID: "primary", title: "Self-test from elsewhere", start: begin,
                                        end: begin.addingTimeInterval(1_800))
            let calendarService = sampleCalendar, contactsService = sampleContacts, session = session
            Task {
                await calendarService?.arrive(arrived)
                await contactsService?.arrive(Contact(id: "arrived-contact", givenName: "Elsewhere", familyName: "Pug"))
                await app.sync?.check(session)
            }
            wait("the mail check to bring them") {
                session.calendar.events.contains { $0.title == "Self-test from elsewhere" } && session.contacts.savedContacts.contains { $0.givenName == "Elsewhere" }
            }
        }
        step {
            check(session.calendar.events.contains { $0.title == "Self-test from elsewhere" }, "checking for mail brings an event made elsewhere")
            check(session.contacts.savedContacts.contains { $0.givenName == "Elsewhere" }, "and a contact")
            // Offline: the network goes, and none of the servers can be reached.
            app.sync?.pretendNetwork(online: false)
            let calendarService = sampleCalendar, contactsService = sampleContacts, mailService = sampleMail
            Task {
                await calendarService?.setFailsLikeOffline(true)
                await contactsService?.setFailsLikeOffline(true)
                await mailService?.setFailsLikeOffline(true)
            }
            wait(upTo: 0.3) { false }
        }
        step {
            let calendar = session.calendar, contacts = session.contacts
            guard var draft = calendar.newDraft() else { return check(false, "an event can be started offline") }
            draft.title = "Self-test offline"
            Task { _ = try? await calendar.save(draft) }
            Task { await contacts.save(Contact(id: "new-offline", givenName: "Offline", familyName: "Pug"), isNew: true) }
            if let elsewhere = calendar.events.first(where: { $0.title == "Self-test from elsewhere" }) { calendar.delete(elsewhere, scope: .thisEvent) }
            if let composer = app.compose(to: [SampleData.person("Sam Rivera")], subject: "Self-test offline draft", body: "Written on a plane.") {
                composer.closeKeepingDraft()
            }
            wait("the changes made offline") {
                calendar.events.contains { $0.title == "Self-test offline" } && contacts.savedContacts.contains { $0.givenName == "Offline" }
                    && mail.waitingDrafts.contains { $0.message?.subject == "Self-test offline draft" }
                    && calendar.waiting.contains { $0.event.title == "Self-test from elsewhere" }
            }
        }
        step {
            let calendar = session.calendar, contacts = session.contacts
            let made = calendar.events.first { $0.title == "Self-test offline" }
            check(made.map { LocalID.isLocal($0.id) && calendar.isWaiting($0) } == true, "an event made offline shows, waiting to be sent")
            check(contacts.savedContacts.first { $0.givenName == "Offline" }.map { LocalID.isLocal($0.id) && contacts.isWaiting($0) } == true,
                  "and so does a contact")
            check(!calendar.events.contains { $0.title == "Self-test from elsewhere" }, "an event deleted offline goes at once, its deletion waiting")
            let folder = DebugLaunchOptions.sampleStorage.appendingPathComponent(session.id.uuidString)
            check([AccountStorage.calendarChangesFile, AccountStorage.contactChangesFile, AccountStorage.waitingDraftsFile]
                .allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }, "all kept in the account's folder on this Mac")
            if let made {
                var renamed = calendar.draft(for: made)
                renamed.title = "Self-test offline, renamed"
                Task { _ = try? await calendar.save(renamed) }
            }
            mail.select(folderID: mail.folders.first { $0.role == .drafts }?.id)
            wait("Drafts, and the renamed event") {
                mail.conversations.first?.id.hasPrefix(WaitingDraft.summaryPrefix) == true && calendar.events.contains { $0.title == "Self-test offline, renamed" }
            }
        }
        step {
            let calendar = session.calendar
            check(mail.conversations.first?.subject == "Self-test offline draft", "a draft saved offline is at the top of Drafts",
                  mail.conversations.first?.subject ?? "none")
            check(calendar.waiting.count == 2 && calendar.waiting.contains { $0.event.title == "Self-test offline, renamed" },
                  "changing it again offline changes what waits", "\(calendar.waiting.count)")
            // Back online: everything waiting goes, beside the next mail check.
            let calendarService = sampleCalendar, contactsService = sampleContacts, mailService = sampleMail
            Task {
                await calendarService?.setFailsLikeOffline(false)
                await contactsService?.setFailsLikeOffline(false)
                await mailService?.setFailsLikeOffline(false)
                app.sync?.pretendNetwork(online: true)
            }
            wait("what waited to go", upTo: 8) {
                session.calendar.waiting.isEmpty && session.contacts.waiting.isEmpty && mail.waitingDrafts.isEmpty
                    && session.calendar.events.contains { $0.title == "Self-test offline, renamed" && !LocalID.isLocal($0.id) }
            }
        }
        step {
            let calendarService = sampleCalendar, contactsService = sampleContacts, mailService = sampleMail
            let onServer = read { await calendarService?.allEvents ?? [] } ?? []
            check(onServer.contains { $0.title == "Self-test offline, renamed" } && !onServer.contains { $0.title == "Self-test from elsewhere" },
                  "back online, the changes reach the calendar", "\(onServer.filter { $0.title.hasPrefix("Self-test") }.map(\.title))")
            let contactsOnServer = read { await contactsService?.allContacts ?? [] } ?? []
            check(contactsOnServer.contains { $0.givenName == "Offline" && !LocalID.isLocal($0.id) }, "the contacts")
            let draftsOnServer = read { await mailService?.drafts ?? [] } ?? []
            check(draftsOnServer.contains { $0.subject == "Self-test offline draft" }, "and Drafts")
            check(session.contacts.savedContacts.first { $0.givenName == "Offline" }.map { !LocalID.isLocal($0.id) } == true, "showing as the servers saved them")
            let folder = DebugLaunchOptions.sampleStorage.appendingPathComponent(session.id.uuidString)
            check(![AccountStorage.calendarChangesFile, AccountStorage.contactChangesFile, AccountStorage.waitingDraftsFile]
                .contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }, "with nothing left waiting")
            // Tidy up.
            if let event = session.calendar.events.first(where: { $0.title == "Self-test offline, renamed" }) { session.calendar.delete(event, scope: .thisEvent) }
            for name in ["Offline", "Elsewhere"] {
                if let contact = session.contacts.savedContacts.first(where: { $0.givenName == name }) { session.contacts.delete(contact) }
            }
            Task { for draft in draftsOnServer where draft.subject == "Self-test offline draft" { try? await mailService?.deleteDraft(draft) } }
            mail.select(folderID: mail.inbox?.id)
            app.show(.calendar)
            wait("the inbox, and the contacts tidied") {
                mail.selectedFolderID == mail.inbox?.id && !mail.isLoadingList
                    && !session.contacts.savedContacts.contains { $0.givenName == "Offline" || $0.givenName == "Elsewhere" }
            }
            check(!session.calendar.events.contains { $0.title == "Self-test sync" }, "deleting an event")
            // Microsoft: the same account switch changes mail, calendar and contacts together.
            app.switchAccount(to: SampleData.microsoftID)
            wait("the second account", upTo: 8) {
                app.current?.account.kind == .microsoft && app.current?.calendar.calendars.isEmpty == false && app.current?.mail.conversations.isEmpty == false
                    && app.current?.contacts.loaded == true
            }
        }
        step {
            check(session.account.kind == .microsoft, "switching accounts")
            check(app.module == .calendar, "keeps the part of the app showing")
            check(mail.inboxTabs.map(\.name) == ["Focused", "Other"], "the second account's inbox has its own tabs", "\(mail.inboxTabs.map(\.name))")
            check(session.calendar.defaultCalendar?.nativeConference == .teams, "its calendar makes Teams meetings")
            check(session.contacts.savedContacts.contains { $0.displayName == "Marcus Lee" }, "and its own contacts")
            guard var draft = session.calendar.newDraft() else { return }
            draft.title = "Self-test Teams call"
            draft.addsNativeConference = true
            draft.reminders = [Reminder(minutes: 10), Reminder(minutes: 60)]
            check(session.calendar.features.maximumReminders == 1 && session.calendar.features.visibilities == [.default, .private],
                  "a Microsoft calendar keeps one notification, and normal or private")
            let calendar = session.calendar
            Task { try? await calendar.save(draft) }
            wait("the Teams event") { calendar.events.contains { $0.title == "Self-test Teams call" } && calendar.events.contains(where: \.isTask) }
        }
        step {
            let created = session.calendar.events.first { $0.title == "Self-test Teams call" }
            check(created?.conference?.kind == .teams && created?.conference?.joinURL.host == "teams.microsoft.com", "a new event gets its Teams meeting",
                  created?.conference?.joinURL.absoluteString ?? "none")
            check(created?.reminderMinutes == [10], "with the one notification it keeps", "\(created?.reminderMinutes ?? [])")
            let calendar = session.calendar
            check(calendar.taskLists.map(\.name) == ["Tasks"] && calendar.shownEvents().contains { $0.title == "Submit expense report" && $0.isTask },
                  "a Microsoft account's To Do tasks show",
                  "\(calendar.taskLists.map(\.name)) \(calendar.shownEvents().filter(\.isTask).map(\.title)) \(calendar.visibleInterval) \(calendar.mode) \(calendar.tasksProblem ?? "")")
            calendar.step(1)
            wait("next week") { calendar.events.contains { $0.title == "Vacation" } }
        }
        step {
            let calendar = session.calendar
            check(calendar.events.first { $0.title == "Vacation" }?.type == .outOfOffice, "and its calendar's out of office")
            calendar.goToday()
            app.switchAccount(to: SampleData.iCloudID)
            wait("the third account", upTo: 8) { app.current?.account.kind == .icloud && app.current?.calendar.events.isEmpty == false }
        }
        step {
            check(session.calendar.defaultCalendar?.nativeConference == nil, "an iCloud calendar has no meetings of its own")
            check(session.calendar.features == .basic, "nor visibility, guest permissions or other people's busy times")
            check(session.calendar.shownEvents().contains { $0.conference?.kind == .faceTime }, "but shows FaceTime links on its events")
            guard var draft = session.calendar.newDraft() else { return }
            draft.title = "Self-test FaceTime"
            draft.faceTimeLink = "https://facetime.apple.com/join#v=1&p=selftest&k=key"
            let calendar = session.calendar
            Task { try? await calendar.save(draft) }
            wait("the FaceTime event") { calendar.events.contains { $0.title == "Self-test FaceTime" } }
        }
        step {
            let created = session.calendar.events.first { $0.title == "Self-test FaceTime" }
            check(created?.conference?.kind == .faceTime && created?.conference?.joinURL.host == "facetime.apple.com", "a pasted FaceTime link joins the event")
            check(mail.capabilities.usesLabels == false && mail.sortsInboxOnMac, "iCloud mail has folders, with its inbox sorted on the Mac")
            // Tasks kept on this Mac, and a kind the calendar can't hold.
            let calendar = session.calendar
            check(calendar.taskLists.map(\.id) == ["tasks:local"] && calendar.taskLists.first?.name == "Tasks", "an iCloud account's tasks are kept on this Mac")
            guard var task = calendar.newDraft(type: .task) else { return check(false, "an iCloud task can be started") }
            task.title = "Self-test Mac task"
            guard let yoga = calendar.shownEvents().first(where: { $0.title == "Yoga" }) else { return check(false, "the sample yoga class") }
            var focus = calendar.draft(for: yoga)
            check(calendar.types(for: focus) == [.event, .outOfOffice, .focusTime], "an event without guests can change kind")
            calendar.retype(&focus, as: .focusTime)
            check(focus.start == yoga.start && focus.end == yoga.end && focus.title == "Yoga", "keeping its time and title")
            Task {
                do {
                    try await calendar.save(task)
                    try await calendar.save(focus)
                } catch { check(false, "saving an iCloud task and focus time", "\(error)") }
            }
            wait("the iCloud task and focus time") {
                calendar.events.contains { $0.title == "Self-test Mac task" } && calendar.event(yoga.id)?.type == .focusTime
            }
        }
        step {
            let calendar = session.calendar
            let folder = DebugLaunchOptions.sampleStorage.appendingPathComponent(SampleData.iCloudID.uuidString)
            let saved = (try? String(contentsOf: folder.appendingPathComponent(LocalTaskService.fileName), encoding: .utf8)) ?? ""
            check(saved.contains("Self-test Mac task"), "an iCloud task is saved on this Mac")
            check(calendar.events.first { $0.title == "Yoga" && $0.type == .focusTime }?.isTypeLocal == true,
                  "an iCloud event changed to focus time is kept as focus time on this Mac")
            check(FileManager.default.fileExists(atPath: folder.appendingPathComponent(EventTypeBook.fileName).path), "in the account's folder")
            app.switchAccount(to: SampleData.googleID)
            app.show(.contacts)
            wait("the first account's contacts") { app.current?.account.kind == .google && app.current?.contacts.loaded == true }
        }

        // MARK: Places for an event's location (made-up ones: sample runs never ask Apple Maps)
        let places = PlaceSearch(finder: SamplePlaceFinder())
        step {
            check(PrivacySettings.shared.suggestsPlaces, "places are suggested for event locations unless Settings ▸ Privacy says not to")
            places.search("bakery")
            wait("places") { !places.suggestions.isEmpty }
        }
        step {
            check(places.suggestions.first?.text == "Bluebird Bakery, 412 SE Oak St, Portland, OR 97214", "typing a location suggests places with their addresses",
                  places.suggestions.first?.text ?? "none")
            places.search("b")
            check(places.suggestions.isEmpty, "but not for one letter")
            PrivacySettings.shared.suggestsPlaces = false
            check(PlaceSearch.makeFinder() == nil, "and none at all with the setting off")
            PrivacySettings.shared.suggestsPlaces = true
            check(PlaceSearch.makeFinder() is SamplePlaceFinder, "sample runs use made-up places")
        }

        // MARK: Contacts
        step {
            let contacts = session.contacts
            check(contacts.count(in: .contacts) == 20, "the contacts load", "\(contacts.count(in: .contacts))")
            check(contacts.count(in: .other) == 3, "and the other contacts")
            check(contacts.labels == ["Family", "Puppy School", "Work"], "labels come from the contacts", "\(contacts.labels)")
            check(contacts.contacts(in: .contacts, matching: "").first?.displayName == "Aisha Rahman", "contacts sort by name")
            check(contacts.contacts(in: .contacts, matching: "bakery").map(\.displayName) == ["Olivia Chen"], "search finds a contact by company")
            check(contacts.suggestions(for: "ale").first?.email == "alex.kim@example.com", "typing a name suggests addresses")
            let new = Contact(id: "new-selftest", givenName: "Biscuit", familyName: "Pug", emails: [LabeledValue(label: "home", value: "biscuit@example.com")])
            Task { await contacts.save(new, isNew: true) }
            wait("the new contact") { contacts.savedContacts.contains { $0.givenName == "Biscuit" } }
        }
        step {
            let contacts = session.contacts
            guard let biscuit = contacts.savedContacts.first(where: { $0.givenName == "Biscuit" }) else { return check(false, "creating a contact") }
            check(!biscuit.id.hasPrefix("new-"), "creating a contact gives it the server's ID")
            contacts.toggleStar(biscuit)
            check(contacts.contact(biscuit.id)?.isStarred == true, "starring a contact")
            contacts.delete(biscuit)
            check(contacts.contact(biscuit.id) == nil, "deleting a contact")
        }

        // MARK: People written to, added to contacts
        let taylor = MailAddress(name: "Taylor Brooks", email: "taylor.brooks@pawprint.example")
        let morgan = MailAddress(name: "Morgan Diaz", email: "morgan@elsewhere.example")
        let casey = MailAddress(name: "Park, Casey", email: "casey@elsewhere.example")
        func sendSelfTest(to people: [MailAddress], bcc: [MailAddress] = []) {
            guard let composer = app.compose(to: people, subject: "Self-test hello", body: "Hi!") else { return }
            composer.bcc = bcc
            composer.undoSendDelay = 0.1
            composer.send()
        }
        step {
            app.toast = nil
            sendSelfTest(to: [taylor, morgan, SampleData.person("Alex Kim")], bcc: [MailAddress(email: "no-reply@shop.example")])
            wait("the people written to", upTo: 6) {
                session.contacts.savedContacts.contains { $0.givenName == "Taylor" } && app.toast?.actionTitle == "Add…"
            }
        }
        step {
            let contacts = session.contacts
            let added = contacts.savedContacts.first { $0.givenName == "Taylor" }
            check(added?.jobTitle == "Product Designer" && added?.company == "Pawprint Studio" && added?.phones.first?.value == "(503) 555-0161",
                  "someone written to who's in the organization's directory is added, with their details")
            check(contacts.savedContacts.filter { $0.emails.contains { $0.value == "alex.kim@example.com" } }.count == 1, "someone already there isn't added again")
            check(!contacts.savedContacts.contains { $0.emails.contains { $0.value == "no-reply@shop.example" } }, "nor a no-reply address")
            check(!contacts.savedContacts.contains { $0.emails.contains { $0.value == morgan.email } }, "someone who can't be looked up isn't added by itself")
            check(app.toast?.text == "Added Taylor Brooks. Add Morgan Diaz to Contacts?", "but offered", app.toast?.text ?? "none")
            app.toast?.action?()
            if case let .addPeople(_, people)? = app.sheet {
                check(people.map(\.email) == [morgan.email], "Add… opens the contact editor for them")
            } else {
                check(false, "Add… opens the contact editor for them")
            }
            check(ContactsViewModel.newContact(for: morgan).givenName == "Morgan" && ContactsViewModel.newContact(for: casey).familyName == "Park",
                  "filled in with their name and address")
            app.sheet = nil
            app.toast = nil
            sendSelfTest(to: [casey])
            wait("Casey to be offered") { app.toast?.text == "Add Park, Casey to Contacts?" }
        }
        step {
            check(app.toast?.text == "Add Park, Casey to Contacts?", "someone new is offered", app.toast?.text ?? "none")
            app.toast = nil
            // Typed in To and not made an address with Return: sending still takes it.
            guard let composer = app.compose(to: [], subject: "Self-test hello", body: "Hi!") else { return }
            composer.typedTo = "\"Park, Casey\" <casey@elsewhere.example>"
            composer.undoSendDelay = 0.1
            composer.send()
            check(composer.to.map(\.email) == [casey.email] && composer.typedTo.isEmpty, "an address typed in To and not entered is sent to")
            wait("Casey to be offered again") { app.toast?.text == "Add Park, Casey to Contacts?" }
        }
        step {
            check(app.toast?.text == "Add Park, Casey to Contacts?", "and someone new is offered each time until they're added", app.toast?.text ?? "none")
            check(!session.contacts.savedContacts.contains { $0.emails.contains { $0.value == casey.email } }, "never added without asking")
            // Return keeps a whole address that's typed, rather than a suggestion it's part of.
            let jason = MailAddress(name: "Jason Lee", email: "jason@icloud.example")
            check(TypedAddresses.pick(jason, typed: "son@icloud.example") == nil, "a whole address typed is taken as typed, not a suggestion it's part of")
            check(TypedAddresses.pick(jason, typed: "jas") == jason && TypedAddresses.pick(jason, typed: "Jason@icloud.example") == jason,
                  "while part of a name, or the suggestion's own address, takes the suggestion")
            check(TypedAddresses.adding("son@icloud.example, Sam <sam@example.com>", to: [jason]).map(\.email)
                  == ["jason@icloud.example", "son@icloud.example", "sam@example.com"], "every address typed is added, once each")
            check(!TypedAddresses.isComplete("son") && !TypedAddresses.isComplete("son@icloud") && TypedAddresses.isComplete("son@icloud.example"),
                  "only whole addresses count")
            let parsed = RecipientParser.parse("\"Park, Casey\" <casey@elsewhere.example>, sam@example.com; <kim@example.com>")
            check(parsed.map(\.email) == ["casey@elsewhere.example", "sam@example.com", "kim@example.com"] && parsed.first?.name == "Park, Casey"
                  && parsed.last?.name == nil, "a comma inside a quoted name doesn't split the address", "\(parsed)")
            check(!RecipientParser.hasSeparator("\"Park,") && RecipientParser.hasSeparator("sam@example.com,"),
                  "and typing one there doesn't end it")
            if let added = session.contacts.savedContacts.first(where: { $0.givenName == "Taylor" }) { session.contacts.delete(added, quietly: true) }
            wait("Taylor tidied away") { !session.contacts.savedContacts.contains { $0.givenName == "Taylor" } }
        }
        let riley = MailAddress(name: "Riley Chen", email: "riley@elsewhere.example")
        step {
            // Guests invited to an event, the same way.
            guard var draft = session.calendar.newDraft() else { return check(false, "an event can be started") }
            draft.title = "Self-test invite"
            draft.guests = [taylor, riley, SampleData.person("Alex Kim")]
            app.toast = nil
            let calendar = session.calendar
            Task { _ = try? await calendar.save(draft) }
            wait("the guests", upTo: 6) { session.contacts.savedContacts.contains { $0.givenName == "Taylor" } && app.toast?.actionTitle == "Add…" }
        }
        step {
            let added = session.contacts.savedContacts.first { $0.givenName == "Taylor" }
            check(added?.jobTitle == "Product Designer" && added?.phones.first?.value == "(503) 555-0161",
                  "a guest invited to an event who's in the organization's directory is added, with their details")
            check(app.toast?.text == "Added Taylor Brooks. Add Riley Chen to Contacts?", "and someone new is offered", app.toast?.text ?? "none")
            check(session.contacts.savedContacts.filter { $0.emails.contains { $0.value == "alex.kim@example.com" } }.count == 1, "a guest already there isn't added again")
            app.toast = nil
            let calendar = session.calendar
            if let invite = calendar.events.first(where: { $0.title == "Self-test invite" }) {
                var draft = calendar.draft(for: invite)
                draft.title = "Self-test invite, renamed"
                Task { _ = try? await calendar.save(draft) }
            }
            wait(upTo: 1.5) { false }
        }
        step {
            check(app.toast?.actionTitle != "Add…", "changing the event doesn't ask about its guests again", app.toast?.text ?? "none")
            if let invite = session.calendar.events.first(where: { $0.title.hasPrefix("Self-test invite") }) { session.calendar.delete(invite, scope: .thisEvent) }
            if let added = session.contacts.savedContacts.first(where: { $0.givenName == "Taylor" }) { session.contacts.delete(added, quietly: true) }
            wait("the invite tidied away") {
                !session.contacts.savedContacts.contains { $0.givenName == "Taylor" } && !session.calendar.events.contains { $0.title.hasPrefix("Self-test invite") }
            }
        }

        // MARK: The real services, made for each kind of account (nothing connects)
        step {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMail Factory Check \(UUID().uuidString)")
            let factory = LiveServiceFactory(oauth: OAuthConfiguration(google: .google(clientID: "selftest.apps.googleusercontent.com"),
                                                                       microsoft: .microsoft(clientID: "selftest")), folder: folder)
            let secrets = MemorySecretStore()
            let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
            let google = Account(kind: .google, name: "G", email: "g@example.com")
            let microsoft = Account(kind: .microsoft, name: "M", email: "m@example.com")
            let presets = ServerPresets.iCloud(email: "i@icloud.com")
            let iCloud = Account(kind: .icloud, name: "I", email: "i@icloud.com", incoming: presets.incoming, outgoing: presets.outgoing,
                                 calendarServer: presets.calendar, contactsServer: presets.contacts, serverLoginName: presets.login)
            let guess = ServerPresets.guess(forEmail: "p@example.org", incoming: .pop3)
            let pop = Account(kind: .other, name: "P", email: "p@example.org", incoming: guess.incoming, outgoing: guess.outgoing)
            try? secrets.setSecret(.oauth(tokens), for: google.id)
            try? secrets.setSecret(.oauth(tokens), for: microsoft.id)
            try? secrets.setSecret(.password("x"), for: iCloud.id)
            try? secrets.setSecret(.password("x"), for: pop.id)
            let g = factory.services(for: google, secrets: secrets)
            let gCalendar = g.calendar as? CalendarWithTasks
            check(g.mail is GoogleMailService && gCalendar?.calendars is GoogleCalendarService && gCalendar?.tasks is GoogleTasksService
                  && g.contacts is GoogleContactsService, "a Google account uses Google's mail, calendar, tasks and contacts services")
            check(gCalendar?.types.file == factory.storage(for: google).appendingPathComponent(EventTypeBook.fileName),
                  "and keeps the kinds of events its calendars can't hold in its folder")
            let m = factory.services(for: microsoft, secrets: secrets)
            let mCalendar = m.calendar as? CalendarWithTasks
            check(m.mail is MicrosoftMailService && mCalendar?.calendars is MicrosoftCalendarService && mCalendar?.tasks is MicrosoftTasksService
                  && m.contacts is MicrosoftContactsService, "a Microsoft account uses Microsoft's")
            let i = factory.services(for: iCloud, secrets: secrets)
            let iCalendar = i.calendar as? CalendarWithTasks
            check(i.mail is IMAPMailService && iCalendar?.calendars is CalDAVCalendarService && i.contacts is CardDAVContactsService,
                  "an iCloud account uses IMAP, CalDAV and CardDAV")
            check(iCalendar?.tasks is LocalTaskService, "with its tasks kept on the Mac")
            let p = factory.services(for: pop, secrets: secrets)
            check(p.mail is POPMailService && (p.calendar as? CalendarWithTasks)?.calendars is LocalCalendarService && p.contacts is LocalContactsService,
                  "a POP account without servers keeps its calendar and contacts on the Mac")
            let unsigned = factory.services(for: Account(kind: .icloud, name: "", email: "x@icloud.com", incoming: presets.incoming), secrets: secrets)
            check(unsigned.mail is UnavailableService, "an account without its password can't connect")
            let unconfigured = LiveServiceFactory(oauth: OAuthConfiguration(), folder: folder).services(for: google, secrets: secrets)
            check(unconfigured.mail is UnavailableService, "and neither can a Google account in a copy without Google sign-in")
            try? FileManager.default.removeItem(at: folder)
        }

        // MARK: Keeping up to date
        var sentMark = 0
        var notifier: RecordingNotifier? { app.sync?.notifier as? RecordingNotifier }
        step {
            app.show(.mail)
            mail.select(folderID: mail.inbox?.id)
            wait("the inbox") { !mail.isLoadingList && !mail.conversations.isEmpty }
        }
        step {
            guard let sync = app.sync else { return check(false, "the background sync runs") }
            let session = session
            let cache = session.storage.cache
            // The background sync has been checking all along, and may have announced mail earlier steps delivered; this
            // starts over, as if the inbox had never been checked.
            notifier?.forgetNewMail()
            Task {
                await cache.save(syncState: nil)
                await sync.check(session)
            }
            wait("the first check") { (read({ await cache.syncState() }) ?? nil) != nil }
        }
        step {
            check(notifier?.newMail.isEmpty == true, "the first check for new mail announces nothing",
                  "\(notifier?.newMail.map { $0.messages.map(\.subject) } ?? [])")
            // Reading something, so the window isn't just showing the inbox (where a notification would only repeat it).
            if let first = mail.conversations.first { mail.open(first) }
            let service = sampleMail
            let alex = SampleData.person("Alex Kim")
            Task { await service?.deliver(from: alex, subject: "Self-test arrival", text: "Just arrived.", at: AppClock.now()) }
            let session = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { await app.sync?.check(session) } }
            wait("the new message to be noticed") { notifier?.newMail.isEmpty == false }
        }
        step {
            check(notifier?.newMail.first?.messages.first?.subject == "Self-test arrival", "new mail is announced")
            wait("the inbox to show it") { mail.conversations.contains { $0.subject == "Self-test arrival" } }
        }
        step {
            check(mail.conversations.first?.subject == "Self-test arrival", "and the inbox shows it at the top without being asked")
            check((app.sync?.unread(for: session.id) ?? 0) >= 1, "the unread count follows")
            guard let message = notifier?.newMail.first?.messages.first else { return }
            mail.closeConversation()
            app.openConversation(message, in: session.id)
            wait("the conversation") { mail.openMessages.first?.summary.subject == "Self-test arrival" }
        }
        step {
            check(mail.openConversation?.subject == "Self-test arrival", "clicking a notification opens its conversation",
                  "open: \(mail.openConversation?.subject ?? "nothing") \(mail.openMessages.map(\.summary.subject)); composers: \(app.composers.map(\.title)); folder: \(String(describing: mail.currentFolder?.role)); error: \(mail.conversationError ?? "none")")
            mail.closeConversation()
            guard let target = mail.conversations.first(where: { $0.subject == "Self-test arrival" }) else {
                return check(false, "the new conversation is listed")
            }
            mail.undoDelay = 0.2
            mail.snooze([target], until: AppClock.now().addingTimeInterval(1.5))
            check(!mail.conversations.contains { $0.id == target.id }, "snoozing takes a conversation out of the inbox")
            check(app.toast?.text.contains("snoozed until Today") == true, "and says until when", app.toast?.text ?? "")
            wait("the snooze to be kept and the archive to go") { mail.snoozeCount == 1 && actions().filter { $0 == "archive" }.count >= 2 }
        }
        step {
            check(mail.snoozeCount == 1, "Snoozed counts it")
            mail.select(folderID: Snooze.folderID)
            wait("Snoozed") { mail.conversations.count == 1 }
        }
        step {
            check(mail.conversations.first?.subject == "Self-test arrival", "Snoozed lists it")
            check(mail.conversations.first.map { mail.rowDate(for: $0).hasPrefix("Today") } == true, "with when it comes back")
            wait(upTo: 1.6) { false }
        }
        step {
            let session = session
            Task { await app.sync?.wakeSnoozes(session, at: AppClock.now()) }
            wait("the conversation to come back") { notifier?.snoozeReturns.isEmpty == false }
        }
        step {
            check(notifier?.snoozeReturns.count == 1, "a snoozed conversation comes back when its time comes, with a notification")
            check(actions().contains("moveToInbox"), "back into the inbox on the server")
            wait("Snoozed to empty") { mail.snoozeCount == 0 && mail.conversations.isEmpty }
        }
        step {
            check(mail.snoozeCount == 0 && mail.conversations.isEmpty, "and leaves Snoozed")
            mail.select(folderID: mail.inbox?.id)
            sentMark = sentCount()
            guard let composer = app.compose(to: [SampleData.person("Alex Kim")], subject: "Self-test later", body: "Sent later.") else { return }
            composer.schedule(at: AppClock.now().addingTimeInterval(1))
            check(!app.composers.contains { $0 === composer }, "scheduling a message closes it")
            if !app.composers.isEmpty {
                // Not this step's doing, but worth knowing where it came from.
                print("SELFTEST NOTE: other compose windows open: " + app.composers.map { model in
                    "\(model.title) [to \(model.to.map(\.email).joined(separator: ","))] [\(model.body.string.prefix(30))] [draft \(model.editingDraftID ?? "-")]"
                }.joined(separator: "; "))
            }
            wait("Scheduled to count it") { mail.scheduledCount == 1 || sentCount() > sentMark }
        }
        step {
            check(mail.folder(role: .scheduled) != nil || sentCount() > sentMark, "Scheduled shows in the sidebar while something waits there")
            mail.select(folderID: QueuedMessage.scheduledFolderID)
            wait("Scheduled") { mail.conversations.count == 1 || sentCount() > sentMark }
        }
        step {
            if sentCount() == sentMark {
                check(mail.conversations.first?.subject == "Self-test later", "Scheduled lists the message")
                if let first = mail.conversations.first { mail.open(first) }
                check(mail.openQueuedItem != nil && mail.openMessages.first?.textBody?.contains("Sent later.") == true, "and opens it as it will go")
                mail.closeConversation()
            }
            wait(upTo: 1.1) { false }
        }
        step {
            let session = session
            Task { await app.sync?.sendDue(session, at: AppClock.now()) }
            wait("the scheduled message to go") { sentCount() > sentMark }
        }
        step {
            if let service = sampleMail, let last = read({ await service.sentMessages.last }) ?? nil {
                check(last.subject == "Self-test later", "a scheduled message goes when its time comes", last.subject)
            }
            wait("Scheduled to empty") { mail.scheduledCount == 0 }
        }
        step {
            check(mail.scheduledCount == 0, "and leaves Scheduled")
            mail.select(folderID: mail.inbox?.id)
            wait("the inbox") { mail.currentFolder?.role == .inbox && !mail.isLoadingList && !mail.conversations.isEmpty }
        }
        step {
            guard let roadmap = mail.conversations.first(where: { $0.subject == "Q4 roadmap draft" }) else { return }
            mail.open(roadmap)
            wait("the roadmap conversation") { mail.openMessages.count == 3 }
        }
        step {
            mail.closeConversation()
            let service = sampleMail
            Task { await service?.setFailsLikeOffline(true) }
            wait(upTo: 0.3) { false }
        }
        step {
            guard let roadmap = mail.conversations.first(where: { $0.subject == "Q4 roadmap draft" }) else { return }
            mail.open(roadmap)
            wait("the offline copy") { mail.openMessages.count == 3 && mail.isOffline }
        }
        step {
            check(mail.openMessages.count == 3, "a conversation read before opens offline, from the copy on the Mac")
            check(mail.isOffline, "and the window says it’s offline")
            mail.closeConversation()
            sentMark = sentCount()
            guard let composer = app.compose(to: [SampleData.person("Sam Rivera")], subject: "Self-test outbox", body: "Waiting for the network.") else { return }
            composer.undoSendDelay = 0.1
            composer.send()
            wait("the Outbox") { mail.outboxCount == 1 }
        }
        step {
            check(mail.outboxCount == 1, "a message sent offline waits in the Outbox")
            check(app.toast?.text.contains("Outbox") == true, "and says so", app.toast?.text ?? "")
            let service = sampleMail
            let session = session
            Task {
                await service?.setFailsLikeOffline(false)
                await app.sync?.sendDue(session, at: AppClock.now().addingTimeInterval(1))
            }
            wait("the Outbox to send") { mail.outboxCount == 0 && sentCount() > sentMark }
        }
        step {
            check(mail.outboxCount == 0 && sentCount() > sentMark, "the Outbox sends once the server can be reached")
            mail.refresh()
            wait("back online") { !mail.isOffline }
        }
        step {
            check(!mail.isOffline, "and the offline note goes once the server answers")
            mail.select(folderID: mail.inbox?.id)
            let service = sampleMail
            let deals = MailAddress(name: "Great Deals", email: "deals@offers.example")
            let session = session
            // Delivered, then checked for, in that order, so the check has come and gone before the next step blocks anyone.
            Task {
                await service?.deliver(from: deals, subject: "Self-test offer", text: "Buy now!", at: AppClock.now().addingTimeInterval(60))
                await app.sync?.check(session)
            }
            wait("the offer to arrive") { mail.conversations.contains { $0.subject == "Self-test offer" } }
        }

        // MARK: Blocking senders
        var spamMark = 0
        var notifiedBefore = 0
        step {
            guard let offer = mail.conversations.first(where: { $0.subject == "Self-test offer" }) else {
                return check(false, "the offer is in the inbox")
            }
            mail.undoDelay = 0.2
            mail.reportSpam([offer])
            check(mail.spamReport?.addresses == ["deals@offers.example"], "Report spam offers to block the sender")
            check(mail.spamReport?.domains == ["offers.example"], "or everything from their domain")
            guard let report = mail.spamReport else { return }
            spamMark = actions().filter { $0 == "markSpam" }.count
            mail.finishSpamReport(report, block: .senders)
            check(!mail.conversations.contains { $0.id == offer.id }, "reporting takes the conversation out of the inbox")
            check(app.toast?.text == "Blocked deals@offers.example. Their mail goes to Spam from now on.", "and says who's blocked",
                  app.toast?.text ?? "")
            wait("the block to be kept") {
                mail.blockedSenders.map(\.id) == ["address:deals@offers.example"] && actions().filter { $0 == "markSpam" }.count > spamMark
            }
        }
        step {
            check(mail.blockedSenders.map(\.id) == ["address:deals@offers.example"], "the sender is blocked on this account")
            if let otherBook = app.accounts.session(for: SampleData.iCloudID)?.storage.blockedSenders {
                check((read { await otherBook.all() } ?? [BlockedSender.address("x@y.z")]).isEmpty, "and only this one: other accounts keep their own")
            }
            check(actions().filter { $0 == "markSpam" }.count > spamMark, "and the conversation went to Spam on the server")
            spamMark = actions().filter { $0 == "markSpam" }.count
            notifiedBefore = notifier?.newMail.count ?? 0
            let service = sampleMail
            let deals = MailAddress(name: "Great Deals", email: "deals@offers.example")
            let session = session
            Task {
                await service?.deliver(from: deals, subject: "Self-test offer again", text: "Last chance!", at: AppClock.now().addingTimeInterval(120))
                await app.sync?.check(session)
            }
            wait("the blocked mail to go to Spam") {
                guard let service else { return false }
                return (read { await service.labels(ofSubject: "Self-test offer again") } ?? []).contains("SPAM")
            }
        }
        step {
            let service = sampleMail
            let labels = service.flatMap { service in read { await service.labels(ofSubject: "Self-test offer again") } } ?? []
            check(labels.contains("SPAM") && !labels.contains("INBOX"), "new mail from a blocked sender goes straight to Spam", labels.joined(separator: " "))
            check((notifier?.newMail.count ?? 0) == notifiedBefore, "without a notification")
            mail.loadList()
            wait("the inbox to load again") { !mail.isLoadingList }
        }
        step {
            check(!mail.conversations.contains { $0.subject == "Self-test offer again" }, "and it isn't in the inbox")
            guard let rule = mail.blockedSenders.first else { return check(false, "the block is listed") }
            mail.unblock(rule)
            wait("the sender to be unblocked") { mail.blockedSenders.isEmpty }
        }
        step {
            check(mail.blockedSenders.isEmpty, "Settings can unblock a sender")
            guard let composer = app.compose(to: [SampleData.person("Alex Kim")], subject: "Self-test draft", body: "Half written.") else {
                return check(false, "a new message opens")
            }
            composer.closeKeepingDraft()
            mail.select(folderID: mail.folder(role: .drafts)?.id)
            wait("Drafts to list it") { mail.showsDrafts && mail.conversations.contains { $0.subject == "Self-test draft" } }
        }

        // MARK: Drafts
        step {
            guard let draft = mail.conversations.first(where: { $0.subject == "Self-test draft" }) else {
                return check(false, "Drafts lists the draft")
            }
            mail.open(draft)
            check(mail.openConversation == nil, "a draft doesn't open to be read like mail")
            wait("the draft's window") { app.composers.contains { $0.subject == "Self-test draft" } }
        }
        step {
            guard let editor = app.composers.first(where: { $0.subject == "Self-test draft" }),
                  let draft = mail.conversations.first(where: { $0.subject == "Self-test draft" }) else {
                return check(false, "the draft opens in a window to edit")
            }
            check(editor.to.map(\.email) == [SampleData.person("Alex Kim").email] && editor.body.string.contains("Half written."),
                  "it opens to edit, with its recipients and text")
            check(editor.editingDraftID == draft.latest?.id, "the window knows which draft it's editing")
            mail.open(draft)
            check(app.composers.filter { $0.subject == "Self-test draft" }.count == 1, "opening it again brings the same window forward")
            editor.closeKeepingDraft()
            mail.loadList()
            wait("Drafts to load again") { !mail.isLoadingList }
        }
        step {
            check(mail.conversations.filter { $0.subject == "Self-test draft" }.count == 1, "closing it unchanged leaves one draft")
            guard let draft = mail.conversations.first(where: { $0.subject == "Self-test draft" }) else { return }
            mail.open(draft)
            wait("the draft's window again") { app.composers.contains { $0.subject == "Self-test draft" } }
        }
        step {
            guard let editor = app.composers.first(where: { $0.subject == "Self-test draft" }) else { return check(false, "the draft reopens") }
            editor.setPlainBody("Fully written now.")
            editor.closeKeepingDraft()
            wait("the edited draft to replace the old one") {
                mail.conversations.filter { $0.subject == "Self-test draft" }.count == 1
                    && mail.conversations.first { $0.subject == "Self-test draft" }?.snippet.contains("Fully written") == true
            }
        }
        step {
            check(mail.conversations.first { $0.subject == "Self-test draft" }?.snippet.contains("Fully written") == true,
                  "editing a draft replaces it rather than adding another")
            guard let draft = mail.conversations.first(where: { $0.subject == "Self-test draft" }) else { return }
            mail.undoDelay = 0.2
            mail.discardDrafts([draft])
            check(!mail.conversations.contains { $0.id == draft.id }, "discarding a draft takes it out of Drafts at once")
            check(app.toast?.text == "Draft discarded." && app.toast?.actionTitle == "Undo", "with Undo", app.toast?.text ?? "")
            wait("the draft to be deleted") { !mail.isLoadingList && !mail.conversations.contains { $0.subject == "Self-test draft" } }
        }
        step {
            mail.loadList()
            wait("Drafts to load again") { !mail.isLoadingList }
        }
        step {
            check(!mail.conversations.contains { $0.subject == "Self-test draft" }, "and it's deleted from the server")
            mail.select(folderID: mail.inbox?.id)
            wait("the inbox") { mail.currentFolder?.role == .inbox && !mail.isLoadingList }
        }

        // MARK: Signatures
        step {
            check(session.account.signatureHTML?.contains("PuggleSoft") == true, "a Google account's signature comes from its server",
                  session.account.signatureHTML ?? "none")
            guard let composer = app.compose() else { return check(false, "a new message opens") }
            var links = 0
            composer.body.enumerateAttribute(.link, in: NSRange(location: 0, length: composer.body.length)) { value, _, _ in
                if value != nil { links += 1 }
            }
            check(composer.body.string.contains("Jamie Rivera") && links > 0, "and a new message starts with it, formatted, link and all")
            composer.discard()
            var account = session.account
            account.signatureHTML = "<i>Self-test signature</i>"
            account.signature = "Self-test signature"
            app.accounts.update(account)
            let service = sampleMail
            wait("the signature to reach the server") {
                guard let service else { return false }
                return (read { await service.savedSignature } ?? nil) == "<i>Self-test signature</i>"
            }
        }
        step {
            let service = sampleMail
            check(service.flatMap { service in read { await service.savedSignature } ?? nil } == "<i>Self-test signature</i>",
                  "a signature changed here is saved to the account's server")
            var account = session.account
            account.signatureHTML = #"<div><b>Jamie Rivera</b> · <a href="https://pugglesoft.example/">PuggleSoft</a></div>"#
            account.signature = "Jamie Rivera · PuggleSoft"
            app.accounts.update(account)
            wait("the signature back as it was") {
                guard let service else { return false }
                return (read { await service.savedSignature } ?? nil)?.contains("PuggleSoft") == true
            }
        }

        // MARK: Writing options
        step {
            guard let composer = app.compose(to: [SampleData.person("Alex Kim")], subject: "Self-test options", body: "Plain words.") else {
                return check(false, "a new message opens")
            }
            check(composer.outgoing().htmlBody != nil, "a new message goes out formatted")
            composer.setPlainText(true)
            check(composer.outgoing().htmlBody == nil && composer.outgoing().textBody.contains("Plain words."), "plain text mode sends the text alone")
            composer.setPlainText(false)
            guard let label = mail.labels.first?.folder else { return check(false, "the account has labels") }
            composer.labelIDs = [label.id]
            composer.undoSendDelay = 0.1
            composer.send()
            wait("the sent message to get its label") { actions().contains { $0.hasPrefix("addLabel") && $0.contains(label.id) } }
        }
        step {
            check(actions().contains { $0.hasPrefix("addLabel") }, "labels chosen while writing go on the sent message")
            mail.select(folderID: mail.folder(role: .trash)?.id)
            wait("the Trash") { mail.showsTrash && !mail.isLoadingList && !mail.conversations.isEmpty }
        }

        // MARK: The Trash
        step {
            check(!mail.allows(.archive) && !mail.canSnooze && !mail.allows(.star) && !mail.allows(.unstar)
                  && !mail.allows(.addLabel("Label_work")) && !mail.allows(.removeLabel("Label_work")),
                  "conversations in the Trash can't be archived, snoozed, starred or labeled")
            check(mail.allows(.moveToInbox) && mail.allows(.markRead) && mail.allows(.markUnread) && mail.allows(.deleteForever),
                  "they can be put back, marked read or unread, or deleted for good")
            let sent = mail.folder(role: .sent)?.id ?? "SENT"
            check(!mail.moveTargets.contains { [.sent, .drafts].contains($0.role) } && !mail.allows(.move(toFolderID: sent)),
                  "nothing is ever moved into Sent (or Drafts)")
            if let trashed = mail.conversations.first {
                mail.perform(trashed.isStarred ? .unstar : .star, on: [trashed])
                mail.perform(.addLabel("Label_work"), on: [trashed])
                let now = mail.conversations.first { $0.id == trashed.id }
                check(now?.isStarred == trashed.isStarred && now?.labelIDs == trashed.labelIDs, "asking anyway changes nothing")
            }
            // Labels and categories on an account with folders: the iCloud sample.
            app.switchAccount(to: SampleData.iCloudID)
            wait("the iCloud inbox") { session.id == SampleData.iCloudID && mail.foldersLoaded && !mail.isLoadingList && !mail.conversations.isEmpty }
        }

        // MARK: Labels beside folders
        step {
            check(mail.hasLabels && mail.capabilities.canEditLabels, "an account with folders can have labels too")
            check(mail.inboxTabs.map(\.name) == ["Primary", "Transactions", "Updates", "Promotions", "Social"],
                  "its inbox is sorted into five categories", mail.inboxTabs.map(\.name).joined(separator: ", "))
            guard let target = mail.conversations.first else { return }
            mail.saveLabel(MailViewModel.LabelEditing(label: nil, applyTo: [target]), name: "Self-test label", colorHex: "#1A73E8")
            wait("the new label") {
                // On the server too, before its list is asked for.
                guard let label = mail.labels.first(where: { $0.folder.name == "Self-test label" })?.folder else { return false }
                return mail.conversations.first { $0.id == target.id }?.labelIDs.isEmpty == false
                    && actions().contains { $0.hasPrefix("addLabel") && $0.contains(label.id) }
            }
        }
        step {
            guard let label = mail.labels.first(where: { $0.folder.name == "Self-test label" })?.folder,
                  let target = mail.conversations.first else { return check(false, "the label is made") }
            check(label.colorHex == "#1A73E8" && label.kind == .label, "a new label has its color")
            check(target.labelIDs.contains(label.id), "and goes on the conversation it was made for")
            check(!mail.moveTargets.contains { $0.id == label.id }, "labels aren't places to move mail to")
            mail.select(folderID: label.id)
            wait("the label's list") { mail.selectedFolderID == label.id && !mail.isLoadingList && mail.conversations.count == 1 }
        }
        step {
            guard let label = mail.labels.first(where: { $0.folder.name == "Self-test label" })?.folder else { return }
            check(mail.conversations.count == 1 && mail.listTitle == "Self-test label", "a label lists the conversations with it", mail.listTitle)
            mail.saveLabel(MailViewModel.LabelEditing(label: label, applyTo: []), name: "Renamed label", colorHex: "#188038")
            wait("the renamed label") { mail.labels.contains { $0.folder.name == "Renamed label" } }
        }
        step {
            guard let label = mail.labels.first(where: { $0.folder.name == "Renamed label" })?.folder,
                  let conversation = mail.conversations.first else { return check(false, "the label is renamed") }
            check(label.colorHex == "#188038", "a label can be renamed and recolored")
            mail.undoDelay = 0.2
            mail.toggleLabel(label.id, on: [conversation])
            check(mail.conversations.isEmpty, "taking the label off takes the conversation out of its list")
            wait("the label to come off") { actions().contains { $0.hasPrefix("removeLabel") } }
        }
        step {
            guard let label = mail.labels.first(where: { $0.folder.name == "Renamed label" })?.folder else { return }
            mail.deleteLabel(label)
            wait("the label to go") { !mail.labels.contains { $0.folder.name == "Renamed label" } && mail.currentFolder?.role == .inbox }
        }
        step {
            check(!mail.labels.contains { $0.folder.name == "Renamed label" }, "a label can be deleted, back to the inbox")
            wait("the inbox list") { !mail.isLoadingList && !mail.conversations.isEmpty }
        }

        // MARK: Inbox categories
        step {
            check(mail.selectedTabID == InboxCategory.primary.tabID, "the inbox opens on Primary")
            wait("the tabs' counts") { !mail.tabUnreadCounts.isEmpty }
        }
        step {
            let counts = mail.tabUnreadCounts
            check((counts[InboxCategory.primary.tabID] ?? 0) > 0 && counts.values.reduce(0, +) == mail.unreadInbox,
                  "each category shows its unread count, adding up to the inbox's", "\(counts) and \(mail.unreadInbox)")
            mail.setShowsCategories(false)
            check(mail.inboxTabs.isEmpty && mail.selectedTabID == nil, "turning categories off shows the inbox as one list")
            wait("the whole inbox") { !mail.isLoadingList }
        }
        step {
            check(mail.conversations.count == mail.folder(role: .inbox)?.totalCount, "with everything in it",
                  "\(mail.conversations.count) of \(mail.folder(role: .inbox)?.totalCount ?? -1)")
            mail.setShowsCategories(true)
            wait("Primary again") { mail.selectedTabID == InboxCategory.primary.tabID && !mail.isLoadingList }
        }
        step {
            guard let target = mail.conversations.first(where: { $0.subject == "Class schedule for December" }) else {
                return check(false, "mail from people is in Primary", mail.conversations.map(\.subject).joined(separator: ", "))
            }
            mail.moveToCategory([target], .promotions)
            check(!mail.conversations.contains { $0.id == target.id }, "moving a conversation to another category takes it out of this one")
            wait("the sender's category") { mail.senderCategories.values.contains(.promotions) && app.toast?.text.contains("Promotions") == true }
        }
        step {
            check(app.toast?.text.contains("goes to Promotions from now on") == true, "and says the sender's mail goes there", app.toast?.text ?? "")
            check(mail.senderCategories.values.contains(.promotions), "the sender is remembered, for Settings")
            if let otherSorter = app.accounts.session(for: SampleData.googleID)?.storage.sorter {
                check((read { await otherSorter.senderCategories() } ?? ["x": .social]).isEmpty, "on this account only")
            }
            mail.select(tabID: InboxCategory.promotions.tabID)
            wait("Promotions") { mail.selectedTabID == InboxCategory.promotions.tabID && !mail.isLoadingList }
        }
        step {
            check(mail.conversations.contains { $0.subject == "Class schedule for December" }, "and the conversation is in Promotions")
            guard let sender = mail.senderCategories.first(where: { $0.value == .promotions })?.key else { return }
            mail.setCategory(nil, forSender: sender)
            wait("the sender to be sorted automatically again") {
                mail.senderCategories.isEmpty && !mail.isLoadingList && !mail.conversations.contains { $0.subject == "Class schedule for December" }
            }
        }
        step {
            check(!mail.conversations.contains { $0.subject == "Class schedule for December" }, "sorting a sender automatically again takes it back out")
            mail.select(tabID: InboxCategory.primary.tabID)
            app.switchAccount(to: SampleData.googleID)
            wait("the Google inbox") { session.id == SampleData.googleID && !mail.isLoadingList }
        }

        // MARK: Privacy
        let privacy = PrivacySettings.shared
        let internet = SampleRemoteFetcher.shared
        let salePicture = URL(string: "https://images.example.com/sale.jpg")!
        var askedBefore = 0
        let torLoad = ResultBox<Bool>()
        step {
            mail.select(folderID: mail.inbox?.id)
            if let first = mail.inboxTabs.first?.id { mail.select(tabID: first) }
            wait("the inbox's first tab") { mail.selectedTabID == mail.inboxTabs.first?.id && !mail.isLoadingList }
        }
        step {
            check(privacy.blocksRemoteContent && !privacy.protectsMailActivity && !privacy.hidesIPAddress && privacy.ipRoute == .tor,
                  "remote content starts out blocked, with nothing loaded ahead and the IP address not hidden (Tor ready to choose)")
            let newsletter = MailMessage(summary: MessageSummary(id: "self-test-news", from: MailAddress(email: "news@shop.example")),
                                         htmlBody: "<p>Sale<img src=\"https://images.example.com/sale.jpg\"></p>")
            check(MessageHTML.hasRemoteContent(newsletter) && !mail.showsImages(for: newsletter), "a message's pictures wait to be asked for")
            privacy.trustedImageSenders.insert("news@shop.example")
            check(mail.showsImages(for: newsletter), "or show for a sender whose pictures always show")
            privacy.trustedImageSenders.remove("news@shop.example")
            privacy.blocksRemoteContent = false
            check(mail.showsImages(for: newsletter), "with nothing blocked, pictures show as a message opens")
            privacy.blocksRemoteContent = true
            privacy.protectsMailActivity = true
            check(mail.showsImages(for: newsletter), "and with mail activity protected, every message's do")
            let page = MessageHTML.document(for: newsletter, allowsRemote: true)
            check(page.contains("img-src cid: data: pmail-remote:;") && !page.contains("images.example.com"),
                  "through PMail's own loader: the page never reaches the internet itself")
            check(MessageHTML.document(for: newsletter).contains("x-dns-prefetch-control"), "or looks up its links ahead of a click")
            askedBefore = internet.requests.count
            let service = sampleMail
            let session = session
            Task {
                await service?.deliver(from: MailAddress(name: "Shop", email: "news@shop.example"), subject: "Self-test sale", text: "Sale",
                                       html: "<p>Sale</p><img src=\"https://images.example.com/sale.jpg\" width=\"1\" height=\"1\">",
                                       at: AppClock.now().addingTimeInterval(180))
                await app.sync?.check(session)
            }
            let cache = session.storage.remoteContent
            wait("the sale's picture to load ahead") { read { await cache.contains(salePicture) } == true }
        }
        step {
            let cache = session.storage.remoteContent
            check(read { await cache.contains(salePicture) } == true, "new mail's pictures load as it arrives, before it's opened")
            check(internet.requests.count - askedBefore == 1, "once", "\(internet.requests.count - askedBefore) requests")
            wait("the sale in the inbox") { mail.conversations.contains { $0.subject == "Self-test sale" } && !mail.isLoadingList }
        }
        step {
            guard let sale = mail.conversations.first(where: { $0.subject == "Self-test sale" }) else {
                return check(false, "the sale arrives", mail.conversations.prefix(5).map(\.subject).joined(separator: ", "))
            }
            MessageBodyView.remoteContentServed = []
            mail.open(sale)
            wait("the sale's page to show its picture", upTo: 10) { MessageBodyView.remoteContentServed.contains(salePicture) }
        }
        step {
            check(MessageBodyView.remoteContentServed.contains(salePicture), "opening it shows the picture, from PMail's copy",
                  MessageBodyView.remoteContentServed.map(\.absoluteString).joined(separator: " "))
            check(internet.requests.count - askedBefore == 1, "without asking the internet again", "\(internet.requests.count - askedBefore) requests")
            let before = internet.requests.count
            privacy.ipRoute = .proxy
            privacy.proxy = RemoteContentProxy(host: "")
            privacy.hidesIPAddress = true
            check(BuiltInTor.shared.state == .off, "a proxy of your own leaves the built-in Tor off")
            let other = URL(string: "https://images.example.com/other.jpg")!
            let refused = read { (try? await RemoteContentLoader.shared.data(from: other)) == nil }
            check(refused == true && internet.requests.count == before, "with the proxy on but not filled in, nothing loads at all")
            privacy.proxy = RemoteContentProxy()
            check(RemoteContentLoader.shared.isThroughProxy, "once it is, everything goes through it")
            let router = URL(string: "http://192.168.1.1/admin")!
            let local = read { (try? await RemoteContentLoader.shared.data(from: router)) == nil }
            check(local == true && internet.requests.count == before, "and nothing on the local network loads", "\(internet.requests.map(\.absoluteString))")
            // The built-in Tor (a stand-in in sample runs, which never reaches the Tor network): a request made while
            // it connects waits for it, then goes through it.
            privacy.ipRoute = .tor
            check(BuiltInTor.shared.state != .off && RemoteContentLoader.shared.isThroughProxy, "choosing Tor starts the one built into PMail",
                  "\(BuiltInTor.shared.state)")
            check(!BuiltInTor.shared.fetcher.isReady, "and holds requests while it connects")
            torLoad.value = nil
            let early = URL(string: "https://images.example.com/early.jpg")!
            let box = torLoad
            Task.detached { box.value = (try? await RemoteContentLoader.shared.data(from: early)) != nil }
            wait("Tor to connect") { BuiltInTor.shared.state == .connected && box.value != nil }
        }
        step {
            check(BuiltInTor.shared.state == .connected, "Tor connects", "\(BuiltInTor.shared.state)")
            check(torLoad.value == true && internet.requests.last?.absoluteString == "https://images.example.com/early.jpg",
                  "and the request that waited loads through it")
            privacy.hidesIPAddress = false
            check(BuiltInTor.shared.state == .off && !RemoteContentLoader.shared.isThroughProxy, "turning Hide IP Address off stops Tor")
            privacy.protectsMailActivity = false
            check(privacy.blocksRemoteContent && !privacy.protectsMailActivity, "the settings go back")
            mail.closeConversation()
            wait("the inbox list") { mail.openConversation == nil && !mail.isLoadingList }
        }

        // MARK: Junk mail
        let junk = JunkSettings.shared
        /// Delivers mail (to the account's bare address, as junk mostly is, unless `byName`), then checks for it, in that order.
        func deliver(_ mail: [(subject: String, from: String, text: String)], hints: SenderHints? = nil, byName: Bool = false, minutes: Double) {
            let service = sampleMail
            let session = session
            let to = byName ? session.account.address : MailAddress(email: session.account.email)
            Task {
                for (index, item) in mail.enumerated() {
                    await service?.deliver(from: MailAddress(name: "Sender", email: item.from), to: [to], subject: item.subject, text: item.text,
                                           hints: hints, at: AppClock.now().addingTimeInterval(minutes * 60 + Double(index)))
                }
                await app.sync?.check(session)
            }
        }
        func deliver(_ subject: String, from email: String, text: String, hints: SenderHints? = nil, byName: Bool = false, minutes: Double) {
            deliver([(subject, email, text)], hints: hints, byName: byName, minutes: minutes)
        }
        func serverLabels(_ subject: String) -> [String] {
            guard let service = sampleMail else { return [] }
            return read { await service.labels(ofSubject: subject) } ?? []
        }
        func serverSummary(_ subject: String) -> MessageSummary? {
            guard let service = sampleMail else { return nil }
            return read { await service.summary(ofSubject: subject) } ?? nil
        }
        let prize = "Click here to claim your free prize money before it expires"
        step {
            let policy = junk.policy
            check(policy.filtersJunk && policy.junkAction == .mark && policy.exemptsContacts && policy.exemptsPreviousRecipients && policy.exemptsFullName
                  && policy.trustsServerMarks && policy.filtersBlocked && policy.blockedAction == .moveToJunk,
                  "junk starts out filtered, marked and left in the inbox, with blocked senders' mail going to Junk")
            let recipients = session.storage.recipients
            check(read { await recipients.contains("alex.kim@example.com") } == true, "PMail remembers who the account has written to")
            // The sample spam folder is too little to learn from: some made-up junk and good mail first.
            let account = session.account.email
            let made = (0..<25).map { index in
                (MessageSummary(id: "st-junk-\(index)", from: MailAddress(name: "Lucky Winner", email: "prizes\(index % 3)@lucky-winner.example"),
                                subject: ["You WON a FREE prize!!", "Claim your prize money now", "URGENT: free prize waiting"][index % 3],
                                snippet: prize, messageIDHeader: "<st-junk-\(index)@example>"),
                 MessageSummary(id: "st-good-\(index)", from: MailAddress(name: "Priya Shah", email: "priya\(index % 3)@acme.example"),
                                to: [MailAddress(email: account)], subject: ["Notes from the planning meeting", "Lunch on Friday?", "Draft of the report"][index % 3],
                                snippet: "Here are the notes from the meeting, let me know what I missed", messageIDHeader: "<st-good-\(index)@example>"))
            }
            let filter = junk.filter
            let ready = read {
                await filter.learn(made.map(\.0), asJunk: true)
                await filter.learn(made.map(\.1), asJunk: false)
                return await filter.isReady
            }
            check(ready == true, "the junk filter learns from junk and good mail")
            deliver("You WON a FREE prize!!", from: "winner@lucky-winner.example", text: prize, minutes: 4)
            wait("the junk to arrive, marked") { mail.conversations.contains { $0.subject == "You WON a FREE prize!!" && mail.junkMark(for: $0) == .junk } }
        }
        step {
            guard let found = mail.conversations.first(where: { $0.subject == "You WON a FREE prize!!" }) else {
                return check(false, "the junk arrives in the inbox")
            }
            check(mail.junkMark(for: found) == .junk, "junk is marked as junk and left in the inbox")
            check(!(notifier?.newMail.contains { $0.messages.contains { $0.subject == "You WON a FREE prize!!" } } ?? true), "without a notification")
            mail.open(found)
            wait("the junk to open") { mail.openMessages.last?.summary.subject == "You WON a FREE prize!!" && !mail.junkMarks.isEmpty }
        }
        var goodBefore = 0
        step {
            guard let message = mail.openMessages.last else { return check(false, "the junk opens") }
            check(mail.junkMarks[message.id] == .junk, "its message says PMail thinks it's junk")
            check(!mail.showsImages(for: message), "and junk's pictures wait to be asked for")
            goodBefore = read { await junk.filter.learnedCounts().good } ?? 0
            mail.notJunk(message.summary)
            check(mail.junkMarks[message.id] == nil, "Not Junk takes the mark off")
            wait("the filter to learn it's good") { (read { await junk.filter.learnedCounts().good } ?? 0) > goodBefore }
        }
        step {
            check((read { await junk.filter.learnedCounts().good } ?? 0) > goodBefore, "and the junk filter learns from it")
            mail.closeConversation()
            junk.policy.junkAction = .moveToJunk
            let recipients = session.storage.recipients
            _ = read { await recipients.record(["friend@lucky-winner.example"]) }
            deliver([("Claim your prize money now", "friend@lucky-winner.example", prize), ("URGENT: free prize waiting", "stranger@lucky-winner.example", prize)],
                    minutes: 5)
            deliver("Your FREE prize, Jamie!!", from: "named@lucky-winner.example", text: prize, byName: true, minutes: 6)
            wait("the junk to go to the spam folder") {
                serverLabels("URGENT: free prize waiting").contains("SPAM") && !serverLabels("Your FREE prize, Jamie!!").isEmpty
            }
        }
        step {
            check(serverLabels("URGENT: free prize waiting").contains("SPAM"), "set to move junk, it goes straight to the spam folder")
            check(!serverLabels("Claim your prize money now").contains("SPAM"), "but junk-like mail from someone written to before is never junk",
                  serverLabels("Claim your prize money now").joined(separator: " "))
            check(!serverLabels("Your FREE prize, Jamie!!").contains("SPAM"), "nor mail addressed to the person by their full name")
            junk.policy.junkAction = .custom
            junk.policy.customRule = MailRule(description: "Invoices", conditions: [RuleCondition(.subject, .contains, "invoice")],
                                              actions: [RuleAction(.star), RuleAction(.markRead)])
            deliver("Your invoice 42", from: "billing@shop.example", text: "Your invoice is attached.", minutes: 7)
            wait("the rule to star the invoice and mark it read") {
                let invoice = serverSummary("Your invoice 42")
                return invoice?.isStarred == true && invoice?.isUnread == false
            }
        }
        step {
            let invoice = serverSummary("Your invoice 42")
            check(invoice?.isStarred == true && invoice?.isUnread == false, "the Advanced rule's actions are done to the mail it matches")
            junk.policy = JunkPolicy()
            deliver("Weekly digest", from: "digest@neutral.example", text: "This week's digest.", hints: SenderHints(serverMarkedJunk: true), minutes: 8)
            wait("the server's junk mark to count") { mail.conversations.contains { $0.subject == "Weekly digest" && mail.junkMark(for: $0) == .junk } }
        }
        step {
            // Mail taken out of junk stays out, even with the server's own junk mark on it, arriving in the inbox again as
            // new mail (as a moved message does on an IMAP server).
            junk.policy.junkAction = .moveToJunk
            deliver("Board meeting invitation", from: "board@neutral.example", text: "You're invited.", hints: SenderHints(serverMarkedJunk: true),
                    minutes: 8.3)
            wait("the server-marked mail moved to the spam folder") { serverLabels("Board meeting invitation").contains("SPAM") }
        }
        step {
            check(serverLabels("Board meeting invitation").contains("SPAM"), "mail the server marks as junk goes to the spam folder")
            guard let message = serverSummary("Board meeting invitation") else { return check(false, "the server-marked mail") }
            mail.perform(.notSpam, onMessage: message)
            let kept = session.storage.keptFromJunk
            wait("it's taken out of junk, for good") {
                !serverLabels("Board meeting invitation").contains("SPAM") && read({ await kept.kept(among: [message]) })?.isEmpty == false
            }
        }
        step {
            guard let message = serverSummary("Board meeting invitation"), let service = sampleMail else { return }
            let session = session
            // Before the mail the next steps deliver (from nine minutes on), so the checks still see theirs as new.
            let arrival = AppClock.now().addingTimeInterval(8.6 * 60)
            Task {
                let again = await service.deliver(from: MailAddress(name: "Sender", email: "board@neutral.example"), to: [MailAddress(email: session.account.email)],
                                                  subject: "Board meeting invitation", text: "You're invited.", hints: SenderHints(serverMarkedJunk: true),
                                                  at: arrival, messageID: message.messageIDHeader)
                await app.sync?.check(session)
                movedBackID = again
            }
            wait("the check to see it arrive again") { movedBackID != nil }
        }
        step {
            guard let id = movedBackID, let service = sampleMail else { return check(false, "the message arriving again") }
            let labels = read { await service.summary(id: id)?.labelIDs } ?? nil
            check(labels?.contains("INBOX") == true && labels?.contains("SPAM") == false,
                  "mail taken out of junk stays out, whatever the server's own mark on it says", "\(labels ?? [])")
            junk.policy.junkAction = .mark
        }
        step {
            check(mail.conversations.contains { $0.subject == "Weekly digest" && mail.junkMark(for: $0) == .junk },
                  "a server's junk mark in a message's headers is trusted")
            junk.policy.blockedAction = .mark
            let book = session.storage.blockedSenders
            _ = read { try? await book.add([.address("pest@blocked.example")]) }
            deliver("Still here", from: "pest@blocked.example", text: "Remember me?", minutes: 9)
            wait("blocked mail to arrive, marked") { mail.conversations.contains { $0.subject == "Still here" && mail.junkMark(for: $0) == .blocked } }
        }
        step {
            guard let blocked = mail.conversations.first(where: { $0.subject == "Still here" }) else { return check(false, "blocked mail arrives") }
            check(mail.junkMark(for: blocked) == .blocked && !serverLabels("Still here").contains("SPAM"),
                  "set to mark blocked mail, it's marked and left in the inbox")
            if let message = blocked.messages.first { mail.unblockSender(of: message) }
            wait("the sender to be unblocked") { mail.blockedSenders.isEmpty && mail.junkMark(for: blocked) == nil }
        }
        step {
            check(mail.blockedSenders.isEmpty, "Unblock on a blocked message unblocks its sender")
            junk.policy.blockedAction = .moveToTrash
            let book = session.storage.blockedSenders
            _ = read { try? await book.add([.address("pest@blocked.example")]) }
            deliver("Back again", from: "pest@blocked.example", text: "Me again.", minutes: 10)
            wait("blocked mail to go to the Trash") { serverLabels("Back again").contains("TRASH") }
        }
        step {
            check(serverLabels("Back again").contains("TRASH"), "set to trash blocked mail, it goes to the Trash")
            let book = session.storage.blockedSenders
            _ = read { try? await book.remove(id: BlockedSender.address("pest@blocked.example").id) }
            junk.policy = JunkPolicy()
            mail.loadList()
            wait("the inbox list") { !mail.isLoadingList }
        }

        // MARK: Accounts, windows and menus
        step {
            check(app.oauth.google == nil || ProcessInfo.processInfo.environment["PMAIL_GOOGLE_CLIENT_ID"] != nil, "sign-in setup comes from the environment")
            app.sheet = .addAccount(nil)
            check(app.sheet?.id == "add-any", "Add Account opens the sheet")
            app.sheet = nil
            app.show(.mail)
            check(validateEveryMenuItem(controller) >= 30, "every menu item can be checked on mail")
            app.show(.calendar)
            check(validateEveryMenuItem(controller) >= 30, "and on the calendar")
            app.show(.contacts)
            check(validateEveryMenuItem(controller) >= 30, "and on contacts")
            delegate.showAboutWindow(nil)
            check(NSImage(named: "AboutLogo") != nil, "the About window has the logo")
            check(AboutView.version.hasPrefix("Version "), "and the version", AboutView.version)
            check(AboutView.copyright.contains("GNU General Public License"), "and the license")
            NSApp.windows.first { $0.windowController is AboutWindowController }?.close()
            app.removeAccount(SampleData.iCloudID)
            check(app.accounts.accounts.count == 2 && app.accounts.session(for: SampleData.iCloudID) == nil, "removing an account")
            check(app.current?.account.kind == .google, "keeps the account showing")
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        step {
            app.show(.mail)
            check(validateEveryMenuItem(controller) >= 30, "nothing breaks in Dark Mode")
        }
        runSteps()
    }
}
#endif
