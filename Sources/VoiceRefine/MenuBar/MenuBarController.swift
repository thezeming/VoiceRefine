import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onShowSettings: () -> Void
    private let onShowOnboarding: () -> Void

    // MARK: - Processing pulse

    private var pulseTimer: Timer?
    private var pulsePhase: Int = 0
    private static let pulseSymbols = ["waveform", "waveform.path", "waveform.path.badge.plus"]

    deinit {
        pulseTimer?.invalidate()
    }

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
            stopPulse()
            setImage("mic",           button: button, template: true,  tint: nil)
        case .recording:
            stopPulse()
            setImage("mic.fill",      button: button, template: false, tint: .systemRed)
        case .processing:
            startPulse()
        case .error:
            stopPulse()
            setImage("exclamationmark.triangle.fill",
                                      button: button, template: false, tint: .systemYellow)
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulsePhase = 0
        advancePulse()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.advancePulse()
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func advancePulse() {
        guard let button = statusItem.button else { return }
        let symbol = MenuBarController.pulseSymbols[pulsePhase % MenuBarController.pulseSymbols.count]
        setImage(symbol, button: button, template: true, tint: nil)
        pulsePhase += 1
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
