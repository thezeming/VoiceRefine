import AppKit

extension Notification.Name {
    /// Posted whenever the user picks a different hotkey gesture in
    /// Settings. `HotkeyManager` listens and live-reloads its monitors so
    /// no app restart is needed.
    static let voiceRefineHotkeyGestureChanged = Notification.Name("VoiceRefineHotkeyGestureChanged")
}

// MARK: - Gesture enum

/// The set of hotkey gestures the user can choose from. Stored as a String
/// in `PrefKey.hotkeyGesture` so it round-trips through UserDefaults.
///
/// Only two options by design — the broader set (double-tap-Option,
/// hold-⌃⌥⌘, hold-Fn) was tried first but added picker friction without
/// clear win. Stored prefs from those legacy values fall back to
/// `.doubleTapShift` via `init?(rawValue:)` returning nil.
enum HotkeyGesture: String, CaseIterable {
    /// Double-tap Shift and hold (the original / default gesture).
    case doubleTapShift = "doubleTapShift"
    /// Hold the Option key — simple press/release. No double-tap, no
    /// hold-confirm. Option alone doesn't type characters (Option+letter
    /// does, which cancels the gesture as a chord), so the hold-confirm
    /// threshold needed for Shift isn't required here.
    case holdOption     = "holdOption"

    var displayName: String {
        switch self {
        case .doubleTapShift: return "Double-tap \u{21E7} Shift and hold"
        case .holdOption:     return "Hold \u{2325} Option"
        }
    }
}

// MARK: - HotkeyManager

/// Manages push-to-talk gesture recognition. The active gesture is read
/// from `PrefKey.hotkeyGesture` at init time AND re-read whenever
/// `.voiceRefineHotkeyGestureChanged` fires (the Settings picker posts
/// this onChange), so the user doesn't need to restart the app.
///
/// `onPress` fires when the gesture is fully confirmed as deliberate.
/// `onRelease` fires when the user ends the hold. The contract with
/// `DictationPipeline` is unchanged regardless of gesture variant.
///
/// `@MainActor`: NSEvent monitors and DispatchQueue.main.asyncAfter
/// callbacks both execute on the main thread; `@MainActor` makes that
/// contract explicit so Swift 6 can verify state accesses are safe.
@MainActor
final class HotkeyManager {
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    private(set) var gesture: HotkeyGesture
    nonisolated(unsafe) private var prefObserver: NSObjectProtocol?

    // These three are accessed only on main (via @MainActor methods and
    // NSEvent callbacks). `nonisolated(unsafe)` lets deinit release them
    // without a hop — deinit runs after the last strong reference drops,
    // which in practice is always on main (DictationPipeline.stop() sets
    // hotkeyManager = nil on @MainActor).
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var holdConfirmWorkItem: DispatchWorkItem?

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

    init(onPress: @escaping @MainActor () -> Void, onRelease: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease

        // Resolve + migrate any legacy gesture (e.g. an older build's
        // .fnKey or .holdControlOptionCommand) to the current default
        // so the Settings picker doesn't end up displaying nothing.
        let raw = UserDefaults.standard.string(forKey: PrefKey.hotkeyGesture) ?? ""
        let resolved = HotkeyGesture(rawValue: raw) ?? .doubleTapShift
        gesture = resolved
        if raw != resolved.rawValue {
            UserDefaults.standard.set(resolved.rawValue, forKey: PrefKey.hotkeyGesture)
        }

        reload()

        // Live-reload when the user picks a different gesture in Settings.
        // Block API + main-queue avoids any selector / Sendable friction.
        prefObserver = NotificationCenter.default.addObserver(
            forName: .voiceRefineHotkeyGestureChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromPrefs() }
        }
    }

    // deinit cannot be @MainActor-isolated; unregister() is called from
    // DictationPipeline.stop() on main, so the deinit path just releases
    // the monitors directly (NSEvent.removeMonitor is thread-safe).
    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor  { NSEvent.removeMonitor(localMonitor)  }
        holdConfirmWorkItem?.cancel()
        if let prefObserver { NotificationCenter.default.removeObserver(prefObserver) }
    }

    /// Re-reads `PrefKey.hotkeyGesture` and reinstalls monitors if it
    /// changed. Mid-hold gestures get a clean `onRelease` first via
    /// `unregister()`.
    func reloadFromPrefs() {
        let raw = UserDefaults.standard.string(forKey: PrefKey.hotkeyGesture) ?? ""
        let next = HotkeyGesture(rawValue: raw) ?? .doubleTapShift
        guard next != gesture else { return }
        unregister()
        gesture = next
        doubleTapState = .idle
        holdActive = false
        previousFlags = []
        reload()
        NSLog("VoiceRefine: hotkey gesture changed → \(next.rawValue)")
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
        case .doubleTapShift:
            if case .holding = doubleTapState { onRelease() }
            doubleTapState = .idle
        case .holdOption:
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
        case .holdOption:
            handleHoldOption(event)
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

    // MARK: - Hold Option

    /// Fires `onPress` when Option goes true alone, `onRelease` when it
    /// goes false (or any other modifier appears, turning it into a
    /// chord like ⌥⌘). Pure boolean — no double-tap, no hold-confirm.
    private func handleHoldOption(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { previousFlags = flags }
        let optionOnly = flags == .option

        if !holdActive && optionOnly {
            holdActive = true
            onPress()
        } else if holdActive && !optionOnly {
            holdActive = false
            onRelease()
        }
    }
}
