import AppKit
import HotKey

/// Registers a global hot key for push-to-talk. Reads the current binding
/// from UserDefaults (`PrefKey.hotkeyKeyCode`, `PrefKey.hotkeyModifierFlags`).
/// Both `keyDown` and `keyUp` fire because macOS Carbon hot-key events
/// include release; that's what makes push-to-talk work.
final class HotkeyManager {
    private var hotKey: HotKey?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        reload()
    }

    /// Re-reads the binding from preferences and re-registers the hot key.
    func reload() {
        hotKey = nil

        let defaults = UserDefaults.standard
        let keyCode = defaults.integer(forKey: PrefKey.hotkeyKeyCode)
        let rawModifiers = UInt(defaults.integer(forKey: PrefKey.hotkeyModifierFlags))
        let modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)

        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            NSLog("VoiceRefine: hotkey key code \(keyCode) is not representable as HotKey.Key")
            return
        }

        hotKey = HotKey(
            key: key,
            modifiers: modifiers,
            keyDownHandler: { [weak self] in self?.onPress() },
            keyUpHandler:   { [weak self] in self?.onRelease() }
        )
    }

    /// Free the registration, e.g. during app teardown.
    func unregister() {
        hotKey = nil
    }
}
