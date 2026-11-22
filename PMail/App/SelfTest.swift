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
            check(calendar.calendars.count == 4, "the account's calendars load", "\(calendar.calendars.count)")
            check(calendar.defaultCalendar?.nativeConference == .meet, "its main calendar makes Meet meetings")
            check(calendar.visibleDays.count == 7, "the week shows seven days")
            let standups = calendar.shownEvents().filter { $0.title == "Team standup" }
            check(standups.count == 5 && standups.allSatisfy { $0.conference?.kind == .meet }, "this week's standups have their meeting links", "\(standups.count)")
            check(calendar.title == "November 2026", "the week's title", calendar.title)
            calendar.toggle(calendar.calendars.first { $0.id == "family" }!)
            check(!calendar.shownEvents().contains { $0.calendarID == "family" }, "turning a calendar off hides its events")
            calendar.toggle(calendar.calendars.first { $0.id == "family" }!)
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
        step {
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
            let calendar = session.calendar
            Task { try? await calendar.save(draft) }
            wait("the Teams event") { calendar.events.contains { $0.title == "Self-test Teams call" } }
        }
        step {
            let created = session.calendar.events.first { $0.title == "Self-test Teams call" }
            check(created?.conference?.kind == .teams && created?.conference?.joinURL.host == "teams.microsoft.com", "a new event gets its Teams meeting",
                  created?.conference?.joinURL.absoluteString ?? "none")
            app.switchAccount(to: SampleData.iCloudID)
            wait("the third account", upTo: 8) { app.current?.account.kind == .icloud && app.current?.calendar.events.isEmpty == false }
        }
        step {
            check(session.calendar.defaultCalendar?.nativeConference == nil, "an iCloud calendar has no meetings of its own")
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
            app.switchAccount(to: SampleData.googleID)
            app.show(.contacts)
            wait("the first account's contacts") { app.current?.account.kind == .google && app.current?.contacts.loaded == true }
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
            check(g.mail is GoogleMailService && g.calendar is GoogleCalendarService && g.contacts is GoogleContactsService,
                  "a Google account uses Google's mail, calendar and contacts services")
            let m = factory.services(for: microsoft, secrets: secrets)
            check(m.mail is MicrosoftMailService && m.calendar is MicrosoftCalendarService && m.contacts is MicrosoftContactsService,
                  "a Microsoft account uses Microsoft's")
            let i = factory.services(for: iCloud, secrets: secrets)
            check(i.mail is IMAPMailService && i.calendar is CalDAVCalendarService && i.contacts is CardDAVContactsService,
                  "an iCloud account uses IMAP, CalDAV and CardDAV")
            let p = factory.services(for: pop, secrets: secrets)
            check(p.mail is POPMailService && p.calendar is LocalCalendarService && p.contacts is LocalContactsService,
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
            Task { await sync.check(session) }
            let cache = session.storage.cache
            wait("the first check") { (read({ await cache.syncState() }) ?? nil) != nil }
        }
        step {
            check(notifier?.newMail.isEmpty == true, "the first check for new mail announces nothing")
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
