import AppKit

// MARK: - Gesture enum

/// The set of hotkey gestures the user can choose from. Stored as a String
/// in `PrefKey.hotkeyGesture` so it round-trips through UserDefaults.
enum HotkeyGesture: String, CaseIterable {
    /// Double-tap Shift and hold (the original / default gesture).
    case doubleTapShift   = "doubleTapShift"
    /// Double-tap Option and hold (same timing as Shift variant).
    case doubleTapOption  = "doubleTapOption"
    /// Hold Control + Option + Command simultaneously — no tap timing.
    case holdControlOptionCommand = "holdControlOptionCommand"
    /// Hold the Fn key — simple press/release.
    case fnKey            = "fnKey"

    var displayName: String {
        switch self {
        case .doubleTapShift:          return "Double-tap \u{21E7} Shift and hold"
        case .doubleTapOption:         return "Double-tap \u{2325} Option and hold"
        case .holdControlOptionCommand: return "Hold \u{2303} Control + \u{2325} Option + \u{2318} Command"
        case .fnKey:                   return "Hold Fn"
        }
    }
}

// MARK: - HotkeyManager

/// Manages push-to-talk gesture recognition. The active gesture is read from
/// `PrefKey.hotkeyGesture` at init time. Changes take effect after an app
/// restart (simpler than hot-swapping monitors mid-session).
///
/// `onPress` fires when the gesture is fully confirmed as deliberate.
/// `onRelease` fires when the user ends the hold. The contract with
/// `DictationPipeline` is unchanged regardless of gesture variant.
final class HotkeyManager {
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private let gesture: HotkeyGesture

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // MARK: Double-tap state machine (shared by doubleTapShift + doubleTapOption)
    private enum DoubleTapState {
        case idle
        case firstDown(at: Date)
        case firstUp(at: Date)
        case secondDownPending
        case holding
    }

    private var doubleTapState: DoubleTapState = .idle
    private var previousFlags: NSEvent.ModifierFlags = []
    private var holdConfirmWorkItem: DispatchWorkItem?

    /// Max duration of the first modifier press for it to count as a tap.
    private let maxTapDuration: TimeInterval = 0.35
    /// Max gap between the first tap's release and the second press.
    private let maxGapDuration: TimeInterval = 0.40
    /// How long the second press must be held before recording starts.
    /// Mandatory for Shift (every capital letter) and Option (accented chars).
    private let holdConfirmDuration: TimeInterval = 0.25

    // MARK: holdControlOptionCommand / fnKey state (simple boolean)
    private var holdActive = false

    // MARK: - Lifecycle

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease

        let raw = UserDefaults.standard.string(forKey: PrefKey.hotkeyGesture) ?? ""
        gesture = HotkeyGesture(rawValue: raw) ?? .doubleTapShift

        reload()
    }

    deinit {
        unregister()
    }

    /// (Re)installs the flagsChanged monitors.
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
        if let localMonitor  { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor  = nil
        cancelHoldConfirm()

        // Deliver clean release if we were mid-hold.
        switch gesture {
        case .doubleTapShift, .doubleTapOption:
            if case .holding = doubleTapState { onRelease() }
            doubleTapState = .idle
        case .holdControlOptionCommand, .fnKey:
            if holdActive { onRelease() }
            holdActive = false
        }
        previousFlags = []
    }

    // MARK: - Event dispatch

    private func handle(_ event: NSEvent) {
        switch gesture {
        case .doubleTapShift:
            handleDoubleTap(event, modifier: .shift)
        case .doubleTapOption:
            handleDoubleTap(event, modifier: .option)
        case .holdControlOptionCommand:
            handleHoldControlOptionCommand(event)
        case .fnKey:
            handleFnKey(event)
        }
    }

    // MARK: - Double-tap handler (Shift or Option)

    private func handleDoubleTap(_ event: NSEvent, modifier: NSEvent.ModifierFlags) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let added   = flags.subtracting(previousFlags)
        let removed = previousFlags.subtracting(flags)
        defer { previousFlags = flags }

        // Any modifier change other than the target key aborts the gesture.
        // If we are already holding, deliver a clean release.
        let nonTargetChanged = !added.subtracting(modifier).isEmpty
            || !removed.subtracting(modifier).isEmpty
        if nonTargetChanged {
            abortDoubleTap()
            return
        }

        // Only pure-target (or empty) counts; chords (e.g. ⇧⌘) cancel.
        guard flags == modifier || flags.isEmpty else {
            abortDoubleTap()
            return
        }

        let keyDown = added.contains(modifier)
        let keyUp   = removed.contains(modifier)
        let now     = Date()

        switch doubleTapState {
        case .idle:
            if keyDown { doubleTapState = .firstDown(at: now) }

        case .firstDown(let downAt):
            if keyUp {
                if now.timeIntervalSince(downAt) <= maxTapDuration {
                    doubleTapState = .firstUp(at: now)
                } else {
                    doubleTapState = .idle
                }
            }

        case .firstUp(let upAt):
            if keyDown {
                if now.timeIntervalSince(upAt) <= maxGapDuration {
                    doubleTapState = .secondDownPending
                    scheduleHoldConfirm()
                } else {
                    // Too slow — treat this as a fresh first tap.
                    doubleTapState = .firstDown(at: now)
                }
            }

        case .secondDownPending:
            if keyUp {
                // Released before the hold threshold — ordinary double-tap
                // during typing. Cancel silently (no onRelease needed because
                // onPress was never fired).
                cancelHoldConfirm()
                doubleTapState = .idle
            }

        case .holding:
            if keyUp {
                doubleTapState = .idle
                onRelease()
            }
        }
    }

    private func abortDoubleTap() {
        cancelHoldConfirm()
        if case .holding = doubleTapState {
            doubleTapState = .idle
            onRelease()
        } else {
            doubleTapState = .idle
        }
    }

    private func scheduleHoldConfirm() {
        cancelHoldConfirm()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .secondDownPending = self.doubleTapState {
                self.doubleTapState = .holding
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

    // MARK: - Hold Control + Option + Command

    /// Fires `onPress` when ⌃⌥⌘ all go true simultaneously (first event
    /// where all three are set). Fires `onRelease` on the first event where
    /// any one of the three is released. Shift must not be present.
    private func handleHoldControlOptionCommand(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { previousFlags = flags }

        let required: NSEvent.ModifierFlags = [.control, .option, .command]
        let allHeld = flags.isSuperset(of: required) && !flags.contains(.shift)

        if !holdActive && allHeld {
            holdActive = true
            onPress()
        } else if holdActive && !allHeld {
            holdActive = false
            onRelease()
        }
    }

    // MARK: - Fn key hold

    /// Fires `onPress` on Fn-down, `onRelease` on Fn-up. Fn can co-appear
    /// with `.numericPad` on some keyboards; we only require `.function` to
    /// be present and allow no other device-independent flag (numericPad is
    /// not in deviceIndependentFlagsMask, so it doesn't interfere).
    private func handleFnKey(_ event: NSEvent) {
        // Use the raw flags to detect Fn, then mask to device-independent
        // bits to check no other meaningful modifier is active.
        let rawFlags = event.modifierFlags
        let fnDown   = rawFlags.contains(.function)
        // Device-independent flags excluding Fn (which is not in that mask).
        let diFlags  = rawFlags.intersection(.deviceIndependentFlagsMask)
        // Only allow empty device-independent flags when Fn is active
        // (i.e. Fn alone, not Fn+Shift, Fn+Command, etc.).
        let purelyFn = diFlags.isEmpty

        defer { previousFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask) }

        if !holdActive && fnDown && purelyFn {
            holdActive = true
            onPress()
        } else if holdActive && (!fnDown || !purelyFn) {
            holdActive = false
            onRelease()
        }
    }
}
