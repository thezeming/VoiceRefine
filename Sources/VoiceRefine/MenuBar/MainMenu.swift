import AppKit

@MainActor
enum MainMenuBuilder {
    /// LSUIElement apps don't render a menu bar, but shortcuts like ⌘V are still
    /// dispatched through `NSApp.mainMenu`. Without this menu, `SecureField`
    /// and `TextField` ignore paste / copy / select-all keystrokes.
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeWindowMenu())
        return mainMenu
    }

    private static func makeAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(withTitle: "About VoiceRefine",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "Hide VoiceRefine",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")
        hide.target = NSApp

        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp

        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit VoiceRefine",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func makeEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
