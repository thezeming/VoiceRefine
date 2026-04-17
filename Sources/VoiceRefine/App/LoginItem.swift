import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the start-at-login
/// toggle. macOS 13+ replaced `SMLoginItemSetEnabled` with this API;
/// VoiceRefine is macOS 14+, so no fallback is needed.
///
/// Caveats:
/// - The first `register()` call may prompt the user; the OS decides.
/// - If the user disables the login item in *System Settings → General
///   → Login Items*, `status` reflects that independently of any local
///   preference. Callers should reconcile on launch / on tab appear.
/// - Registration requires the app bundle to live somewhere the system
///   can relaunch from. `build/VoiceRefine.app` and `/Applications`
///   work; arbitrary paths inside e.g. `~/Downloads/` may or may not.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
