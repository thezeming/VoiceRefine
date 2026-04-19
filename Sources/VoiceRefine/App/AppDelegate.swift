import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var correctionWindowController: CorrectionWindowController?
    private var dictationPipeline: DictationPipeline?
    private var pasteEngine: PasteEngine?
    private var accessibilityWindow: AccessibilityPermissionWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var hudController: HUDWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenuBuilder.build()

        let settingsController = SettingsWindowController()
        self.settingsWindowController = settingsController

        let correctionController = CorrectionWindowController()
        self.correctionWindowController = correctionController

        let menuBar = MenuBarController(
            onShowSettings: { [weak settingsController] in
                settingsController?.present()
            },
            onShowOnboarding: { [weak self] in
                self?.showOnboarding(force: true)
            },
            onShowCorrection: { [weak correctionController] in
                correctionController?.present()
            }
        )
        self.menuBarController = menuBar

        let paste = PasteEngine()
        self.pasteEngine = paste

        let hud = HUDWindowController()
        self.hudController = hud

        let pipeline = DictationPipeline()
        menuBar.setPipeline(pipeline)
        pipeline.onStateChange = { [weak menuBar, weak hud] state in
            menuBar?.apply(state)
            switch state {
            case .recording:
                hud?.show()
            case .idle, .error:
                hud?.hide()
            case .processing:
                // Keep the HUD visible during processing so the final
                // partial (if any) stays readable while refinement runs.
                break
            }
        }
        pipeline.onPartialTranscript = { [weak hud] text in
            hud?.updatePartial(text)
        }
        pipeline.onTranscript = { [weak paste] text in
            paste?.paste(text)
        }
        pipeline.start()
        self.dictationPipeline = pipeline

        NotificationDispatcher.requestAuthorization()

        // Keep the start-at-login pref honest: if the user disabled the
        // login item via System Settings, the @AppStorage-backed toggle
        // would otherwise show a stale true.
        let loginActual = LoginItem.isEnabled
        if UserDefaults.standard.bool(forKey: PrefKey.startAtLogin) != loginActual {
            UserDefaults.standard.set(loginActual, forKey: PrefKey.startAtLogin)
        }

        if !UserDefaults.standard.bool(forKey: PrefKey.didCompleteOnboarding) {
            showOnboarding(force: false)
        } else if !AccessibilityPermission.isTrusted {
            showAccessibilityOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationPipeline?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showOnboarding(force: Bool) {
        if onboardingWindow != nil { return }
        let controller = OnboardingWindowController { [weak self] in
            UserDefaults.standard.set(true, forKey: PrefKey.didCompleteOnboarding)
            self?.onboardingWindow?.window?.orderOut(nil)
            self?.onboardingWindow = nil
        }
        self.onboardingWindow = controller
        controller.present()
    }

    private func showAccessibilityOnboarding() {
        let controller = AccessibilityPermissionWindowController { [weak self] in
            NSLog("VoiceRefine: Accessibility permission granted.")
            self?.accessibilityWindow = nil
        }
        self.accessibilityWindow = controller
        controller.present()
    }
}
