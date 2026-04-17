import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var dictationPipeline: DictationPipeline?
    private var pasteEngine: PasteEngine?
    private var accessibilityWindow: AccessibilityPermissionWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenuBuilder.build()

        let settingsController = SettingsWindowController()
        self.settingsWindowController = settingsController

        let menuBar = MenuBarController(
            onShowSettings: { [weak settingsController] in
                settingsController?.present()
            }
        )
        self.menuBarController = menuBar

        let paste = PasteEngine()
        self.pasteEngine = paste

        let pipeline = DictationPipeline()
        pipeline.onStateChange = { [weak menuBar] state in
            menuBar?.apply(state)
        }
        pipeline.onTranscript = { [weak paste] text in
            paste?.paste(text)
        }
        pipeline.start()
        self.dictationPipeline = pipeline

        if !AccessibilityPermission.isTrusted {
            showAccessibilityOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationPipeline?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
