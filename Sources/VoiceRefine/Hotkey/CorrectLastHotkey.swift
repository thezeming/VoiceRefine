import AppKit

/// Global ⌥⌘R chord that opens the "Correct last…" window from any app —
/// equivalent to picking the menu item, just without having to mouse to
/// the menu bar.
///
/// ⌥⌘R is a "non-typing, non-action" chord on macOS — Option+Command
/// modifiers don't combine with R into any shipped system shortcut, and
/// Option alone doesn't type a glyph when Command is also held. Safer
/// than ⌘R (browser reload), ⌥R (types ®), or ⌃R (terminal reverse-i-
/// search).
@MainActor
final class CorrectLastHotkey {
    private let onTrigger: @MainActor () -> Void

    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?

    /// `kVK_ANSI_R = 0x0F`. From `<HIToolbox/Events.h>`.
    private static let rKeyCode: UInt16 = 0x0F

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
        register()
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor  { NSEvent.removeMonitor(localMonitor) }
    }

    private func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Returning the event lets the original keystroke continue to
            // the focused responder. We never want to swallow ⌥⌘R for any
            // other app — only piggy-back on the chord.
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rKeyCode else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.option, .command]
        // Exact-match: ⌥⌘ only — no shift, control, capslock, function.
        guard flags == required else { return }
        onTrigger()
    }
}
