import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onShowSettings: () -> Void

    init(onShowSettings: @escaping () -> Void) {
        self.onShowSettings = onShowSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button,
           let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceRefine") {
            image.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VoiceRefine",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showSettings() {
        onShowSettings()
    }
}
