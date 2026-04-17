import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var dictationPipeline: DictationPipeline?

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

        let pipeline = DictationPipeline()
        pipeline.onStateChange = { [weak menuBar] state in
            menuBar?.apply(state)
        }
        pipeline.start()
        self.dictationPipeline = pipeline
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationPipeline?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
