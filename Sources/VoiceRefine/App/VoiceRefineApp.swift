import SwiftUI

@main
struct VoiceRefineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "mic")
        }
        .menuBarExtraStyle(.menu)

        Window("VoiceRefine Settings", id: WindowID.settings) {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 380)
    }
}

enum WindowID {
    static let settings = "settings"
}
