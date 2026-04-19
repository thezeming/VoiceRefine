import AppKit

/// Global ⌘R chord for "Retry last refinement".
///
/// Caveat: ⌘R is widely used (browser reload, IDE run/refactor, Slack
/// reactions, Finder…). Because the local monitor returns the event
/// (we never swallow keystrokes), the host app still receives ⌘R AND we
/// also fire retry. Whenever the user presses ⌘R in *any* app, retry
/// will run if there's a previous transcription in history. Switch to a
/// less-conflicting chord (e.g. ⌃⌘R) here if that becomes a problem.
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
        // Exact-match: ⌘ only — no shift, control, option, capslock, function.
        // Picky on purpose so a stray ⌘⇧R (e.g. browser hard-reload) doesn't fire.
        guard flags == .command else { return }
        onTrigger()
    }
}
