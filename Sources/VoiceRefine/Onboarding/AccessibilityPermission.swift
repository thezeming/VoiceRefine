import AppKit
@preconcurrency import ApplicationServices

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Runs the system prompt asking the user to add VoiceRefine to the
    /// Accessibility list. Returns current trust state. Mostly useful as a
    /// nudge — the user still has to flip the toggle in System Settings.
    ///
    /// `@MainActor` because `kAXTrustedCheckOptionPrompt` is a C global
    /// var — the compiler treats it as potentially-mutable shared state.
    @MainActor
    @discardableResult
    static func promptAndCheck() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
