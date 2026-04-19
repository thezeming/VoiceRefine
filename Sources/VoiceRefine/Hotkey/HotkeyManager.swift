import AppKit

/// Push-to-talk gesture: double-tap the Shift key, then hold it.
/// `onPress` fires once the second Shift-press has been held long
/// enough to distinguish it from an ordinary shift-for-capitalization
/// tap; `onRelease` fires when that hold ends. Modeled after
/// Claude Code's voice-dictation gesture.
///
/// Shift is a high-traffic modifier (every capital letter), so the
/// second press must be held ≥ `holdConfirmDuration` to activate —
/// otherwise rapid Shift+letter typing would false-trigger recording.
final class HotkeyManager {
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private enum State {
        case idle
        case firstDown(at: Date)
        case firstUp(at: Date)
        case secondDownPending
        case holding
    }

    private var state: State = .idle
    private var previousFlags: NSEvent.ModifierFlags = []
    private var holdConfirmWorkItem: DispatchWorkItem?

    /// Max duration of the first Shift press for it to count as a tap.
    private let maxTapDuration: TimeInterval = 0.35
    /// Max gap between the first tap's release and the second press.
    private let maxGapDuration: TimeInterval = 0.40
    /// How long the second Shift press must be held before recording starts.
    private let holdConfirmDuration: TimeInterval = 0.25

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        reload()
    }

    deinit {
        unregister()
    }

    /// (Re)installs the flagsChanged monitors. The gesture is fixed —
    /// preferences are not read.
    func reload() {
        unregister()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelHoldConfirm()
        if case .holding = state {
            onRelease()
        }
        state = .idle
        previousFlags = []
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let added = flags.subtracting(previousFlags)
        let removed = previousFlags.subtracting(flags)
        defer { previousFlags = flags }

        // Any non-Shift modifier change aborts the gesture. If we were
        // already holding, deliver a clean release so the pipeline unwinds.
        let nonShiftChanged = !added.subtracting(.shift).isEmpty
            || !removed.subtracting(.shift).isEmpty
        if nonShiftChanged {
            abortGesture()
            return
        }

        // Only pure-Shift (or no modifiers) counts; any chord cancels.
        guard flags == .shift || flags.isEmpty else {
            abortGesture()
            return
        }

        let shiftDown = added.contains(.shift)
        let shiftUp = removed.contains(.shift)
        let now = Date()

        switch state {
        case .idle:
            if shiftDown {
                state = .firstDown(at: now)
            }
        case .firstDown(let downAt):
            if shiftUp {
                if now.timeIntervalSince(downAt) <= maxTapDuration {
                    state = .firstUp(at: now)
                } else {
                    state = .idle
                }
            }
        case .firstUp(let upAt):
            if shiftDown {
                if now.timeIntervalSince(upAt) <= maxGapDuration {
                    state = .secondDownPending
                    scheduleHoldConfirm()
                } else {
                    state = .firstDown(at: now)
                }
            }
        case .secondDownPending:
            if shiftUp {
                // Released before the hold threshold — treat as a third
                // rapid tap (e.g. mid-typing). Cancel, reset.
                cancelHoldConfirm()
                state = .idle
            }
        case .holding:
            if shiftUp {
                state = .idle
                onRelease()
            }
        }
    }

    private func abortGesture() {
        cancelHoldConfirm()
        if case .holding = state {
            state = .idle
            onRelease()
        } else {
            state = .idle
        }
    }

    private func scheduleHoldConfirm() {
        cancelHoldConfirm()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .secondDownPending = self.state {
                self.state = .holding
                self.onPress()
            }
        }
        holdConfirmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdConfirmDuration, execute: workItem)
    }

    private func cancelHoldConfirm() {
        holdConfirmWorkItem?.cancel()
        holdConfirmWorkItem = nil
    }
}
