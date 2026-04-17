import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onShowSettings: () -> Void
    private let onShowOnboarding: () -> Void

    init(onShowSettings: @escaping () -> Void,
         onShowOnboarding: @escaping () -> Void) {
        self.onShowSettings = onShowSettings
        self.onShowOnboarding = onShowOnboarding
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureMenu()
        apply(.idle)
    }

    // MARK: - State

    func apply(_ state: DictationState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            setImage("mic",           button: button, template: true,  tint: nil)
        case .recording:
            setImage("mic.fill",      button: button, template: false, tint: .systemRed)
        case .processing:
            setImage("waveform",      button: button, template: true,  tint: nil)
        case .error:
            setImage("exclamationmark.triangle.fill",
                                      button: button, template: false, tint: .systemYellow)
        }
    }

    private func setImage(_ symbolName: String,
                          button: NSStatusBarButton,
                          template: Bool,
                          tint: NSColor?) {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceRefine") else {
            return
        }
        image.isTemplate = template
        button.image = image
        button.contentTintColor = tint
    }

    // MARK: - Menu

    private func configureMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(
            title: "Onboarding…",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)

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

    @objc private func showOnboarding() {
        onShowOnboarding()
    }
}
