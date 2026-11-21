import AppKit
import PMailKit

/// Builds the menu bar: PMail, File, Edit, View, Message, Account, Window and Help. Commands travel the responder
/// chain to the main window.
enum MenuBuilder {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                     tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        main.addItem(appItem)
        for (title, items) in [("File", fileItems()), ("Edit", editItems()), ("View", viewItems()), ("Message", messageItems())] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        let accountItem = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "Account")
        accountMenu.delegate = DynamicMenus.shared
        DynamicMenus.shared.fillAccounts(accountMenu)
        accountItem.submenu = accountMenu
        main.addItem(accountItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = makeWindowMenu()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Keyboard Shortcuts", #selector(MainWindowController.pmShowShortcuts(_:)), "/", symbol: "keyboard"))
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }

    static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: "PMail")
        menu.addItem(item("About PMail", #selector(AppDelegate.showAboutWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide PMail", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PMail", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("PMail", #selector(AppDelegate.showMainWindow(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func fileItems() -> [NSMenuItem] {
        typealias W = MainWindowController
        return [
            item("New Message", #selector(W.pmNewMessage(_:)), "n", symbol: "square.and.pencil"),
            item("New Event", #selector(W.pmNewEvent(_:)), "n", [.command, .option], symbol: "calendar.badge.plus"),
            item("New Contact", #selector(W.pmNewContact(_:)), symbol: "person.crop.circle.badge.plus"),
            .separator(),
            item("Add Account…", #selector(W.pmAddAccount(_:)), symbol: "person.badge.plus"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find", #selector(MainWindowController.pmFind(_:)), "f"),
            .separator(),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        typealias W = MainWindowController
        var items: [NSMenuItem] = AppModel.Module.allCases.enumerated().map { index, module in
            item(module.title, #selector(W.pmShowModule(_:)), "\(index + 1)", tag: index, symbol: module.symbol)
        }
        items.append(item("Hide Sidebar", #selector(W.pmToggleSidebar(_:)), "s", [.command, .control]))
        items.append(.separator())
        for (index, mode) in CalendarViewModel.Mode.allCases.enumerated() {
            items.append(item(mode.title, #selector(W.pmCalendarMode(_:)), "\(index + 1)", [.command, .option], tag: index))
        }
        items.append(item("Today", #selector(W.pmGoToday(_:)), "t"))
        items.append(.separator())
        items.append(item("Refresh", #selector(W.pmRefresh(_:)), "n", [.command, .shift], symbol: "arrow.clockwise"))
        return items
    }

    private static func messageItems() -> [NSMenuItem] {
        typealias W = MainWindowController
        let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu(title: "Move To")
        moveMenu.delegate = DynamicMenus.shared
        move.submenu = moveMenu
        move.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let delete = item("Move to Trash", #selector(W.pmTrash(_:)), "\u{8}", symbol: "trash")
        return [
            item("Reply", #selector(W.pmReply(_:)), "r", symbol: "arrowshape.turn.up.left"),
            item("Reply All", #selector(W.pmReplyAll(_:)), "r", [.command, .shift], symbol: "arrowshape.turn.up.left.2"),
            item("Forward", #selector(W.pmForward(_:)), "f", [.command, .shift], symbol: "arrowshape.turn.up.right"),
            .separator(),
            item("Archive", #selector(W.pmArchive(_:)), "a", [.command, .control], symbol: "archivebox"),
            delete,
            item("Mark as Spam", #selector(W.pmSpam(_:)), "j", [.command, .shift], symbol: "exclamationmark.octagon"),
            move,
            .separator(),
            item("Mark as Unread", #selector(W.pmToggleRead(_:)), "u", [.command, .shift], symbol: "envelope.badge"),
            item("Add Star", #selector(W.pmToggleStar(_:)), "l", [.command, .shift], symbol: "star"),
            .separator(),
            item("Send", #selector(W.pmSendMessage(_:)), "d", [.command, .shift], symbol: "paperplane"),
        ]
    }
}

/// Menus filled in as they open: the accounts, and the folders messages can move to.
final class DynamicMenus: NSObject, NSMenuDelegate {
    static let shared = DynamicMenus()

    private var app: AppModel? { (NSApp.delegate as? AppDelegate)?.app }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Account": fillAccounts(menu)
        case "Move To": fillMoveTargets(menu)
        default: break
        }
    }

    func fillAccounts(_ menu: NSMenu) {
        menu.removeAllItems()
        typealias W = MainWindowController
        for (index, account) in (app?.accounts.accounts ?? []).enumerated() {
            let key = index < 9 ? "\(index + 1)" : ""
            let item = MenuBuilder.item("\(account.name.isEmpty ? account.email : account.name) — \(account.email)",
                                        #selector(W.pmSwitchAccount(_:)), key, [.command, .control])
            item.representedObject = account.id
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(MenuBuilder.item("Add Account…", #selector(W.pmAddAccount(_:)), symbol: "person.badge.plus"))
        menu.addItem(MenuBuilder.item("Account Settings…", #selector(W.pmAccountSettings(_:)), symbol: "gearshape"))
        menu.addItem(MenuBuilder.item("Remove Account…", #selector(W.pmRemoveAccount(_:)), symbol: "person.badge.minus"))
    }

    func fillMoveTargets(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let mail = app?.current?.mail else { return }
        for folder in mail.moveTargets {
            let item = MenuBuilder.item(mail.displayName(for: folder), #selector(MainWindowController.pmMoveTo(_:)), symbol: mail.symbol(for: folder))
            item.representedObject = folder.id
            menu.addItem(item)
        }
        if menu.numberOfItems == 0 {
            let none = NSMenuItem(title: "No Folders", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }
}
