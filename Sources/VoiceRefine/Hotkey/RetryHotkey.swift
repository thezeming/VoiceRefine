import AppKit

/// Global ⌥R chord for "Retry last refinement".
///
/// Caveat: ⌥R is a *typing* chord on most layouts — US types `®`, other
/// locales type their own glyph. Because the global monitor can't
/// suppress events (only the local monitor can, and only when our menu-
/// bar app is frontmost — which it rarely is), the host app types the
/// character first AND we then fire retry, which backspaces the
/// previous paste. The typed glyph ends up off by one. Switch to a
/// non-typing chord (e.g. ⌥⌘R) here if that becomes a problem.
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
        // Exact-match: ⌥ only — no shift, control, command, capslock, function.
        // Picky on purpose so chords like ⌥⌘R don't fire by accident.
        guard flags == .option else { return }
        onTrigger()
    }
}
