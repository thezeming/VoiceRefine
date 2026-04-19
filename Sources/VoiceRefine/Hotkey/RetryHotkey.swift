import AppKit

/// Global ⌃⌘R chord for "Retry last refinement". Independent of the
/// push-to-talk gesture so it never interferes with normal dictation.
///
/// Why not configurable: a single fixed chord keeps the implementation
/// trivial — the moment we make it user-configurable we'll need a UI like
/// the gesture picker. ⌃⌘R is rarely used by other apps (most apps use
/// just ⌘R for "reload") and only fires when held with both ⌃ and ⌘ at
/// the same time, so accidental triggers during normal typing are
/// effectively impossible.
@MainActor
final class RetryHotkey {
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
            // the focused responder. We never want to swallow ⌃⌘R for any
            // other app — only piggy-back on the chord.
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rKeyCode else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.control, .command]
        // Exact-match: ⌃⌘ only — no shift, option, capslock, function.
        guard flags == required else { return }
        onTrigger()
    }
}
