#if DEBUG
import AppKit
import PMailKit

/// Launch arguments for checking the app without clicking through it, all starting with `PM`:
/// `-PMSampleAccounts YES` uses the made-up sample accounts instead of the real ones, and
/// `-PMSnapshot <file name>` writes a PNG of the window to the app's temporary folder and quits.
/// The rest set up what the snapshot shows (see `setUp`).
enum DebugLaunchOptions {
    static var defaults: UserDefaults { .standard }

    /// Snapshots and the self-test always use the sample accounts, so automated runs never touch real accounts,
    /// the keychain or any server.
    static var usesSampleAccounts: Bool {
        defaults.bool(forKey: "PMSampleAccounts") || defaults.bool(forKey: "PMSelfTest") || defaults.string(forKey: "PMSnapshot") != nil
    }

    /// The day the sample accounts treat as today: `-PMToday 2026-11-21`, else the real today, at the real time of day.
    static func installSampleClock() {
        guard let text = defaults.string(forKey: "PMToday") else { return }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return }
        let shift = day.timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        AppClock.now = { Date().addingTimeInterval(shift) }
    }

    static var sampleAccounts: [Account] {
        installSampleClock()
        return defaults.bool(forKey: "PMNoAccounts") ? [] : SampleData.accounts
    }

    /// A fresh folder for the sample accounts' caches, Outboxes and snoozes, so the real ones are never touched.
    static let sampleStorage = FileManager.default.temporaryDirectory
        .appendingPathComponent("PMail Sample Accounts \(UUID().uuidString)", isDirectory: true)

    /// Settings for sample runs, emptied at launch so every run starts the same way.
    static let sampleDefaults: UserDefaults = {
        let name = "com.pugglesoft.PMail.sample"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    static func runIfRequested(_ delegate: AppDelegate) {
        guard let name = defaults.string(forKey: "PMSnapshot") else {
            if usesSampleAccounts { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { setUp(delegate) } }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { setUp(delegate) }
        let delay = defaults.double(forKey: "PMSnapshotDelay") > 0 ? defaults.double(forKey: "PMSnapshotDelay") : 2.4
        // A timer in the common modes fires while a menu is open, too.
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { snapshot(name, delegate: delegate) } }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `-PMAccount 2` picks an account; `-PMModule calendar` (or `contacts`) a part of the app; `-PMFolder sent`
    /// (a role, or a folder's name) and `-PMTab 2` the list; `-PMSearch words` searches; `-PMOpen 1` opens a
    /// conversation; `-PMCompose YES` (or `reply`, `formatted` or `cc`) opens a compose window; `-PMCalendarView month` (or `day`, `week`,
    /// `schedule`), `-PMEvent 3` (the details of the third event this week) and `-PMEventEditor new` (or a number);
    /// `-PMContact 2` and `-PMContactEditor YES`; `-PMAddAccount YES` (or `google`, `microsoft`, `icloud`, `other`);
    /// `-PMAccountMenu YES`, `-PMSettings YES`, `-PMShowAbout YES`, `-PMShortcuts YES`, `-PMCollapsed YES`;
    /// `-PMWindowWidth`/`-PMWindowHeight` size the window.
    static func setUp(_ delegate: AppDelegate) {
        let app = delegate.app!
        if let window = delegate.windowController?.window {
            let width = defaults.double(forKey: "PMWindowWidth"), height = defaults.double(forKey: "PMWindowHeight")
            if width > 0 || height > 0 {
                window.setContentSize(NSSize(width: width > 0 ? width : window.frame.width, height: height > 0 ? height : window.frame.height))
            }
        }
        if defaults.bool(forKey: "PMCollapsed") { app.isSidebarExpanded = false }
        let index = max(1, defaults.integer(forKey: "PMAccount")) - 1
        if let account = app.accounts.accounts[safe: index], account.id != app.accounts.currentID {
            app.switchAccount(to: account.id)
        }
        if let module = defaults.string(forKey: "PMModule").flatMap(AppModel.Module.init(rawValue:)) { app.show(module) }
        if let view = defaults.string(forKey: "PMCalendarView").flatMap(CalendarViewModel.Mode.init(rawValue:)) {
            app.show(.calendar)
            app.current?.calendar.mode = view
        }
        if let kind = defaults.string(forKey: "PMAddAccount") {
            app.sheet = .addAccount(AccountKind(rawValue: kind))
        }
        if defaults.bool(forKey: "PMSettings") { delegate.showSettings(nil) }
        // `-PMSettingsPane accounts` (or `general`, `mail`, `signing`) opens Settings on that pane.
        if let name = defaults.string(forKey: "PMSettingsPane")?.lowercased(),
           let pane = SettingsWindowController.Pane.allCases.first(where: { $0.title.lowercased().hasPrefix(name) }) {
            SettingsWindowController.show(app, pane: pane)
        }
        if defaults.bool(forKey: "PMShowAbout") { delegate.showAboutWindow(nil) }
        if defaults.bool(forKey: "PMShortcuts") { app.sheet = .shortcuts }
        if defaults.bool(forKey: "PMAccountMenu") { app.accountMenuRequest += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { setUpLists(app) }
    }

    /// The parts that wait for the sample account's mail, calendars and contacts to load.
    private static func setUpLists(_ app: AppModel) {
        guard let session = app.current else { return }
        let mail = session.mail
        if let folderName = defaults.string(forKey: "PMFolder") {
            let roleMatch = FolderRole.allCases.first { $0.rawValue.lowercased() == folderName.lowercased() }
            let folder = mail.folders.first { $0.role == roleMatch && roleMatch != nil } ?? mail.folders.first { $0.name.lowercased() == folderName.lowercased() }
            if folderName == "all" { mail.select(folderID: nil) } else if let folder { mail.select(folderID: folder.id) }
        }
        if let tab = mail.inboxTabs[safe: defaults.integer(forKey: "PMTab") - 1] { mail.select(tabID: tab.id) }
        // `-PMSampleWaiting YES`: snoozed conversations and a scheduled message, to look at Snoozed and Scheduled. The
        // folder named with -PMFolder is chosen once they're there.
        if defaults.bool(forKey: "PMSampleWaiting") {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: AppClock.now()))
                .flatMap { Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: $0) } ?? AppClock.now()
            let book = session.storage.snoozes
            let queue = session.storage.queue
            let service = session.services.mail
            let message = OutgoingMessage(from: session.account.address, to: [SampleData.person("Priya Shah")], subject: "Friday demo notes",
                                          textBody: "Hi Priya,\n\nNotes from the demo are below. Talk Monday!\n\nJamie")
            let request = ListRequest(folderID: mail.inbox?.id, tabID: mail.inboxTabs.first?.id)
            Task {
                let inbox = try? await service.listConversations(request)
                for conversation in inbox?.conversations.filter({ $0.subject.contains("Hiking") || $0.subject.contains("Turkey") }) ?? [] {
                    try? await book.add(Snooze(conversation: conversation, wakeAt: tomorrow))
                }
                try? await queue.save(QueuedMessage(message: message, sendAt: tomorrow.addingTimeInterval(3600 * 24 * 2), queuedAt: AppClock.now()))
                await mail.refreshLocalFolders()
                if let role = defaults.string(forKey: "PMFolder").flatMap(FolderRole.init(rawValue:)), let folder = mail.folder(role: role) {
                    mail.select(folderID: folder.id)
                    try? await Task.sleep(for: .milliseconds(300))
                    if let open = mail.conversations[safe: defaults.integer(forKey: "PMOpen") - 1] { mail.open(open) }
                }
            }
        }
        // `-PMJunkMark 2` marks the second conversation in the list as junk (`-PMBlockedMark 3` as from a blocked sender).
        for (option, mark) in [("PMJunkMark", JunkMarks.Mark.junk), ("PMBlockedMark", .blocked)] {
            guard let conversation = mail.conversations[safe: defaults.integer(forKey: option) - 1] else { continue }
            let marks = session.storage.junkMarks
            Task {
                await marks.mark(conversation.messages, as: mark)
                mail.refreshJunkMarks()
            }
        }
        // `-PMOffline YES`: the sample servers stop answering, as if the network were down.
        if defaults.bool(forKey: "PMOffline"), let service = session.services.mail as? SampleMailService {
            Task { await service.setFailsLikeOffline(true) }
        }
        if let search = defaults.string(forKey: "PMSearch") {
            app.searchText = search
            if app.module == .mail { mail.search(search) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let open = mail.conversations[safe: defaults.integer(forKey: "PMOpen") - 1] { mail.open(open) }
            if let compose = defaults.string(forKey: "PMCompose") {
                if compose == "reply" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let message = mail.openMessages.last { app.reply(to: message, kind: .reply, in: session) }
                    }
                } else {
                    let model = app.compose(to: [SampleData.person("Alex Kim")], subject: "Notes from today")
                    model?.setPlainBody("Hi Alex,\n\nHere are my notes from the design review. Waffles says hi!\n\nJamie")
                    // `-PMCompose formatted` shows the formatting bar too; `-PMCompose cc` the Cc and Bcc fields.
                    if compose == "formatted" { model?.showsFormatting = true }
                    if compose == "cc" {
                        model?.showsCc = true
                        model?.showsBcc = true
                    }
                }
            }
            let calendar = session.calendar
            let weekEvents = calendar.shownEvents().filter { calendar.visibleInterval.contains($0.start) && !$0.isAllDay }
                .sorted { $0.start < $1.start }
            if let event = weekEvents[safe: defaults.integer(forKey: "PMEvent") - 1] { calendar.selectedEventKey = event.key }
            // `-PMTask 2` shows the details of the week's second task.
            let weekTasks = calendar.shownEvents().filter { calendar.visibleInterval.contains($0.start) && $0.isTask }.sorted { $0.start < $1.start }
            if let task = weekTasks[safe: defaults.integer(forKey: "PMTask") - 1] { calendar.selectedEventKey = task.key }
            if let editor = defaults.string(forKey: "PMEventEditor") {
                if let number = Int(editor), let event = weekEvents[safe: number - 1] {
                    app.sheet = .eventEditor(calendar.draft(for: event))
                } else if let number = Int(editor.dropFirst(4)), editor.hasPrefix("task"), let task = weekTasks[safe: number - 1] {
                    // `-PMEventEditor task2` edits the week's second task.
                    app.sheet = .eventEditor(calendar.draft(for: task))
                } else if let type = EventType(rawValue: editor), type != .event, let draft = calendar.newDraft(type: type) {
                    // `-PMEventEditor task` (or outOfOffice, focusTime) starts one of those.
                    app.sheet = .eventEditor(draft)
                } else if var draft = calendar.newDraft() {
                    draft.title = "Planning lunch"
                    draft.guests = [SampleData.person("Alex Kim")]
                    app.sheet = .eventEditor(draft)
                }
            }
            let contacts = session.contacts
            if let contact = contacts.contacts(in: .contacts, matching: "")[safe: defaults.integer(forKey: "PMContact") - 1] {
                contacts.openContactID = contact.id
            }
            // `-PMAddPeople 1` (or 2) offers to add people written to: the bubble, then (with `-PMAddPeopleSheet YES`) the editor or list.
            let people = [MailAddress(name: "Morgan Diaz", email: "morgan@elsewhere.example"), MailAddress(name: "Casey Park", email: "casey@elsewhere.example")]
            let offered = Array(people.prefix(defaults.integer(forKey: "PMAddPeople")))
            if !offered.isEmpty {
                let id = session.id
                if defaults.bool(forKey: "PMAddPeopleSheet") {
                    app.sheet = .addPeople(id, offered)
                } else {
                    let question = offered.count == 1 ? "Add Morgan Diaz to Contacts?" : "Add \(offered.count) people to Contacts?"
                    app.show("Added Taylor Brooks. " + question, actionTitle: "Add…", duration: 60) { app.sheet = .addPeople(id, offered) }
                }
            }
            if defaults.bool(forKey: "PMContactEditor") {
                app.sheet = .contactEditor(contacts.contacts(in: .contacts, matching: "").first ?? Contact())
            }
        }
    }

    // MARK: Snapshots

    private static func snapshot(_ name: String, delegate: AppDelegate) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 1 }
        let main = delegate.windowController?.window
        let about = windows.first { $0.windowController is AboutWindowController }
        let settings = windows.first { $0.title == "Settings" || $0.identifier?.rawValue == "PMailSettings" }
        // A sheet over Settings (Junk Mail ▸ Advanced, say) is drawn on its own.
        guard let base = about ?? settings?.attachedSheet ?? settings ?? main else {
            print("PMSnapshot: no window")
            exit(1)
        }
        // The window, then every window of PMail's over it (sheets, popovers, menus), each drawn where it is.
        let others = base === main ? windows.filter { $0 !== base && $0.frame.intersects(base.frame) && $0 !== about && $0 !== settings } : []
        let scale = base.backingScaleFactor
        let size = NSSize(width: base.frame.width * scale, height: base.frame.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for window in [base] + others.sorted(by: { $0.level.rawValue < $1.level.rawValue }) {
            guard let image = windowImage(window) else { continue }
            let origin = NSPoint(x: (window.frame.minX - base.frame.minX) * scale, y: (window.frame.minY - base.frame.minY) * scale)
            image.draw(in: NSRect(x: origin.x, y: origin.y, width: window.frame.width * scale, height: window.frame.height * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? png?.write(to: url)
        print("PMSnapshot: \(url.path)")
        if defaults.bool(forKey: "PMSnapshotPrint"), let png { print("PMSnapshotData: " + png.base64EncodedString()) }
        fflush(stdout)
        exit(0)
    }

    /// One window as the window server draws it, whatever is in front of it (through `CGWindowListCreateImage`,
    /// looked up at run time: it's deprecated, but a debug build may still use it), else drawn by its views.
    static func windowImage(_ window: NSWindow) -> NSImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: Create.self)
            // Just this window (kCGWindowListOptionIncludingWindow), unframed, at full resolution.
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() {
                return NSImage(cgImage: image, size: window.frame.size)
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
#endif
