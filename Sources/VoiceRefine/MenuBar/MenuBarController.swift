import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onShowSettings: () -> Void
    private let onShowOnboarding: () -> Void
    /// Weak ref so menu actions can read pipeline state (e.g. for the
    /// "Re-enable refinement" toggle) without a retain cycle — AppDelegate
    /// owns both this controller and the pipeline.
    private weak var pipeline: DictationPipeline?

    // MARK: - Processing pulse

    // nonisolated(unsafe): touched only on main (start/stop/advance run on
    // MainActor; deinit is nonisolated but releases occur via the @MainActor
    // AppDelegate setting menuBarController = nil on quit).
    nonisolated(unsafe) private var pulseTimer: Timer?
    private var pulsePhase: Int = 0
    private static let pulseSymbols = ["waveform", "waveform.path", "waveform.path.badge.plus"]

    deinit {
        pulseTimer?.invalidate()
    }

    // Menu item tag constants
    private enum Tag {
        static let reEnableRefinement = 100
    }

    init(onShowSettings: @escaping () -> Void,
         onShowOnboarding: @escaping () -> Void,
         pipeline: DictationPipeline? = nil) {
        self.onShowSettings = onShowSettings
        self.onShowOnboarding = onShowOnboarding
        self.pipeline = pipeline
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureMenu()
        apply(.idle)
    }

    /// Late-binder for the pipeline — AppDelegate constructs the menu bar
    /// before the pipeline (so the pipeline can forward state transitions
    /// into the menu bar). Call this once the pipeline is built.
    func setPipeline(_ pipeline: DictationPipeline) {
        self.pipeline = pipeline
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
            // Timer fires on RunLoop.main → safe to assume MainActor isolation.
            MainActor.assumeIsolated { self?.advancePulse() }
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
        menu.delegate = self

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

        let reEnableItem = NSMenuItem(
            title: "Re-enable refinement",
            action: #selector(reEnableRefinement),
            keyEquivalent: ""
        )
        reEnableItem.target = self
        reEnableItem.tag = Tag.reEnableRefinement
        reEnableItem.isEnabled = false   // starts disabled; menuWillOpen toggles it
        menu.addItem(reEnableItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VoiceRefine",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        // Update enabled state lazily — no KVO or notification plumbing.
        if let item = menu.item(withTag: Tag.reEnableRefinement) {
            item.isEnabled = pipeline?.hasRefinementOverride ?? false
        }
    }

    // MARK: - Actions

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func showOnboarding() {
        onShowOnboarding()
    }

    @objc private func reEnableRefinement() {
        Task { @MainActor in
            pipeline?.resetRefinementOverride()
        }
    }
}
