import AppKit
import AVFoundation
import Foundation

enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

/// Orchestrates the dictation pipeline. In Phase 2 that means just hotkey
/// → microphone → WAV-to-disk; transcription and refinement plug in
/// during Phase 3 and Phase 4.
///
/// `@MainActor` because every piece of state it touches (hotkey callbacks,
/// state machine, `onStateChange` / `onTranscript` closures, and the
/// DispatchWorkItem timers) already lived on the main thread. Swift 6 makes
/// that explicit. Transcription and refinement await off-main inside the
/// structured Task; the `await MainActor.run` hops at the end of that Task
/// are now just `self.<property>` assignments (already on main).
@MainActor
final class DictationPipeline {
    static let minDuration: TimeInterval = 0.3
    static let maxDuration: TimeInterval = 120.0

    private let recorder = AudioRecorder()
    /// Factories decouple the pipeline from concrete provider constructors
    /// so tests can swap in stubs. Providers are lazily instantiated and
    /// memoized inside the factory — WhisperKit's init stays one-shot.
    private let transcriptionFactory: TranscriptionFactory
    private let refinementFactory: RefinementFactory

    private var pendingContext: RefinementContext = .empty
    /// Bundle ID of the frontmost app captured at `beginRecording()`. Stored
    /// separately from `pendingContext` because `RefinementContext` carries
    /// only the localized app name (for LLM use), not the bundle id —
    /// needed for re-activation (retry / correct-last) AND per-app
    /// system-prompt overrides in `refine(raw:context:bundleID:)`.
    private var pendingBundleID: String? = nil
    private var hotkeyManager: HotkeyManager?
    private var maxDurationCutoff: DispatchWorkItem?
    private var currentTranscriptionTask: Task<Void, Never>?
    /// True while a retry-only refinement run is in progress. Prevents the
    /// hotkey path and retry path from colliding.
    private var isRetrying: Bool = false

    private var refinementFailureCounts: [RefinementProviderID: Int] = [:]
    /// When non-nil, `resolveRefinement` returns the NoOp provider instead of
    /// the user-selected one. Set automatically after 2 consecutive failures
    /// for the same provider; cleared by `resetRefinementOverride()`.
    private var refinementOverride: RefinementProviderID? = nil

    private(set) var state: DictationState = .idle
    /// Tracks the last time a partial-transcript was forwarded to
    /// `onPartialTranscript`. Only accessed on the main thread.
    private var partialLastEmit: Date = .distantPast

    var onTranscript: (@MainActor (String) -> Void)?
    /// Fires with live partial transcripts during Apple Speech streaming.
    /// Always called on the main thread. Throttled to ~5 Hz (200 ms minimum
    /// between emissions). WhisperKit and cloud providers never fire this.
    var onPartialTranscript: (@MainActor (String) -> Void)?

    // MARK: - Init

    init(transcriptionFactory: TranscriptionFactory, refinementFactory: RefinementFactory) {
        self.transcriptionFactory = transcriptionFactory
        self.refinementFactory = refinementFactory
    }

    convenience init() {
        self.init(
            transcriptionFactory: DefaultTranscriptionFactory(),
            refinementFactory: DefaultRefinementFactory()
        )
    }

    // MARK: - Lifecycle

    func start() {
        hotkeyManager = HotkeyManager(
            onPress:   { [weak self] in self?.beginRecording() },
            onRelease: { [weak self] in self?.endRecording() }
        )
    }

    func stop() {
        hotkeyManager?.unregister()
        hotkeyManager = nil
        currentTranscriptionTask?.cancel()
        currentTranscriptionTask = nil
        _ = recorder.stop()
        transition(to: .idle)
    }

    // MARK: - Paths

    static var cacheDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VoiceRefine", isDirectory: true)
    }

    static var lastWavURL: URL {
        cacheDirectory.appendingPathComponent("last.wav")
    }

    // MARK: - Recording flow

    private func beginRecording() {
        // Per PLAN: a new hotkey press cancels any in-flight async work.
        currentTranscriptionTask?.cancel()
        currentTranscriptionTask = nil

        if state == .recording { return }

        // Snapshot context now — while the user's target app is still the
        // frontmost one. By release it usually still is, but capturing at
        // begin makes us robust against the user tabbing away mid-record.
        pendingBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        pendingContext = ContextGatherer.gather()
        if !pendingContext.isEmpty {
            let beforeDesc: String
            if let before = pendingContext.textBeforeCursor {
                beforeDesc = "\(before.count) chars"
            } else {
                beforeDesc = "none"
            }
            let selDesc = pendingContext.selectedText == nil ? "none" : "\(pendingContext.selectedText!.count) chars"
            let line = "context — app=\(pendingContext.frontmostApp ?? "-"), window=\(pendingContext.windowTitle ?? "-"), selection=\(selDesc), beforeCursor=\(beforeDesc), glossary=\(pendingContext.glossary == nil ? "none" : "\(pendingContext.glossary!.count) chars")"
            NSLog("VoiceRefine: \(line)")
            Self.contextLog.append(line)
        }

        // Play start chirp *before* the mic tap opens so it isn't
        // recorded into the buffer.
        SoundEffect.start.play()

        do {
            try recorder.start()
            transition(to: .recording)
            scheduleMaxDurationCutoff()
        } catch {
            NSLog("VoiceRefine: start recording failed: \(error)")
            flashError("Could not start recording.")
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        cancelMaxDurationCutoff()

        let audio = recorder.stop()

        // Play stop chirp *after* the mic tap is removed so it isn't
        // tacked onto the recorded buffer.
        SoundEffect.stop.play()

        // Derive duration from the VAD-trimmed byte count (Int16 = 2 bytes/sample,
        // 16 000 samples/s) so the gate reflects voiced content, not total wall time.
        let duration = Double(audio.count / 2) / 16_000.0

        if duration < Self.minDuration {
            NSLog("VoiceRefine: discarded \(String(format: "%.3fs", duration)) recording (below \(Self.minDuration)s floor)")
            transition(to: .idle)
            return
        }

        do {
            try recorder.writeWAV(to: Self.lastWavURL)
            NSLog("VoiceRefine: recording saved — \(audio.count) bytes, \(String(format: "%.2fs", duration)), wrote \(Self.lastWavURL.path)")
        } catch {
            NSLog("VoiceRefine: failed to write WAV: \(error)")
            // Non-fatal — continue to transcription.
        }

        transition(to: .processing)

        let (transcriptionProviderID, transcriptionProvider, transcriptionModel) = resolveTranscription()
        let context = pendingContext
        let bundleID = pendingBundleID
        pendingContext = .empty
        pendingBundleID = nil

        currentTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            // Throttle state lives on MainActor to avoid data races.
            // At most one partial emit per 200 ms (~5 Hz).
            await MainActor.run { self.partialLastEmit = Date.distantPast }
            do {
                let startedTranscribe = Date()
                let raw = try await transcriptionProvider.transcribeStreaming(
                    audio: audio,
                    model: transcriptionModel,
                    onPartial: { [weak self] partial in
                        guard let self else { return }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let now = Date()
                            guard now.timeIntervalSince(self.partialLastEmit) >= 0.2 else { return }
                            self.partialLastEmit = now
                            self.onPartialTranscript?(partial)
                        }
                    }
                )
                let transcribeElapsed = Date().timeIntervalSince(startedTranscribe)
                if Task.isCancelled { return }
                NSLog("VoiceRefine: raw transcript (\(String(format: "%.2fs", transcribeElapsed)) on \(transcriptionProviderID.rawValue)/\(transcriptionModel)) — \(raw)")

                let refined = await self.refine(raw: raw, context: context, bundleID: bundleID)
                if Task.isCancelled { return }
                NSLog("VoiceRefine: refined transcript — \(refined)")

                // Already on @MainActor — no hop needed.
                TranscriptionHistory.shared.record(
                    raw: raw,
                    refined: refined,
                    context: context,
                    frontmostAppBundleID: bundleID
                )
                self.onTranscript?(refined)
                if self.state == .processing {
                    self.transition(to: .idle)
                }
            } catch {
                if Task.isCancelled { return }
                NSLog("VoiceRefine: transcription error — \(error)")
                self.flashError("Transcription failed.")
            }
        }
    }

    // MARK: - Retry-last (refinement-only, no new recording)

    /// Re-runs refinement on the most-recent raw transcript and pastes. The
    /// caller should re-activate the target app first so the paste lands in
    /// the right window.
    ///
    /// No-ops when a recording or retry is already in flight — never
    /// double-dispatches. Must be called on the main actor.
    @MainActor
    func retryLastRefinement() {
        guard state == .idle, !isRetrying else {
            NSLog("VoiceRefine: retryLastRefinement ignored — busy (state=\(state), isRetrying=\(isRetrying))")
            return
        }
        guard let entry = TranscriptionHistory.shared.mostRecent() else {
            NSLog("VoiceRefine: retryLastRefinement ignored — history empty")
            return
        }

        isRetrying = true
        transition(to: .processing)

        let raw = entry.raw
        let context = entry.context ?? .empty
        let bundleID = entry.frontmostAppBundleID

        currentTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            let refined = await self.refine(raw: raw, context: context, bundleID: bundleID)
            if Task.isCancelled {
                await MainActor.run {
                    self.isRetrying = false
                    self.transition(to: .idle)
                }
                return
            }
            NSLog("VoiceRefine: retry refined transcript — \(refined)")
            await MainActor.run {
                TranscriptionHistory.shared.record(
                    raw: raw,
                    refined: refined,
                    context: context,
                    frontmostAppBundleID: bundleID
                )
                self.onTranscript?(refined)
                self.isRetrying = false
                if self.state == .processing {
                    self.transition(to: .idle)
                }
            }
        }
    }

    // MARK: - Refinement

    /// Runs the configured refinement provider on a raw transcript. Falls
    /// back to the raw text if the provider errors — we never want to lose
    /// the user's dictation just because the remote API is down.
    ///
    /// - Parameters:
    ///   - bundleID: Bundle ID of the frontmost app at recording time. Used to
    ///     look up a per-app system-prompt override from `PerAppPromptStore`.
    ///     When a match is found, it replaces the global system prompt only —
    ///     all other pipeline protections (sanitizer, leak guard, stop
    ///     sequences) are unaffected.
    ///
    /// After 2 consecutive errors for the same user-selected provider the
    /// pipeline auto-switches to NoOp for the rest of the session. The user
    /// can reset this via "Re-enable refinement" in the menu bar.
    private func refine(raw: String, context: RefinementContext, bundleID: String?) async -> String {
        // Capture the user-selected ID BEFORE resolveRefinement() so that
        // failure counters and notifications always name the real provider,
        // not NoOp (which resolveRefinement returns when the override is set).
        let selectedID = RefinementProviderID(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedRefinementProvider) ?? ""
        ) ?? .ollama

        let (providerID, provider) = resolveRefinement()

        // Resolve system prompt: per-app override wins if present, otherwise
        // fall back to the user's global prompt (or the compiled-in default).
        let systemPrompt: String
        if let bid = bundleID, !bid.isEmpty,
           let override = PerAppPromptStore.load()[bid], !override.isEmpty {
            NSLog("VoiceRefine: per-app prompt override for \(bid)")
            systemPrompt = override
        } else {
            systemPrompt = UserDefaults.standard.string(forKey: PrefKey.refinementSystemPrompt)
                ?? PrefDefaults.refinementSystemPrompt
        }

        do {
            let started = Date()
            let out = try await provider.refine(transcript: raw, systemPrompt: systemPrompt, context: context)
            let elapsed = Date().timeIntervalSince(started)
            NSLog("VoiceRefine: refined via \(providerID.rawValue) in \(String(format: "%.2fs", elapsed))")
            if out.isEmpty { return raw }

            let leak = ContextLeakDetector.evaluate(output: out, context: context)
            if leak.leaked {
                let sample = (leak.sample ?? "").prefix(60).replacingOccurrences(of: "\n", with: " ")
                NSLog("VoiceRefine: refinement leak detected (field=\(leak.matchedField ?? "?"), sample=\"\(sample)…\"); falling back to raw transcript")
                NotificationDispatcher.postError(
                    title: "Refinement leaked context",
                    message: "The model copied your \(leak.matchedField ?? "context") into its reply. Pasted raw transcript instead."
                )
                return raw
            }

            // Success — reset failure counter for the user-selected provider.
            await MainActor.run { refinementFailureCounts[selectedID] = 0 }
            return out
        } catch {
            NSLog("VoiceRefine: refinement via \(selectedID.rawValue) failed (\(error)); falling back to raw")

            let shouldPostSessionNotification: Bool = await MainActor.run {
                refinementFailureCounts[selectedID, default: 0] += 1
                let count = refinementFailureCounts[selectedID]!

                if count >= 2 && refinementOverride == nil {
                    // Auto-switch to NoOp for the rest of this session.
                    refinementOverride = .noOp
                    NSLog("VoiceRefine: 2 consecutive \(selectedID.rawValue) failures — switching to NoOp for this session")
                    return true  // caller posts the session-level notification only
                }
                return false
            }

            if shouldPostSessionNotification {
                // ONE session-level toast: explains the auto-switch.
                NotificationDispatcher.postError(
                    title: "Refinement disabled for this session",
                    message: "\(selectedID.displayName) failed twice — switched to raw-transcript mode. Choose \"Re-enable refinement\" from the menu once it's fixed."
                )
            } else {
                // Per-failure toast (only fires on the first failure).
                NotificationDispatcher.postError(
                    title: "\(selectedID.displayName) refinement unavailable",
                    message: "Pasted raw transcript instead. \(String(describing: error))"
                )
            }
            return raw
        }
    }

    // MARK: - Provider resolution

    private func resolveTranscription() -> (TranscriptionProviderID, any TranscriptionProvider, String) {
        let id = TranscriptionProviderID(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedTranscriptionProvider) ?? ""
        ) ?? .whisperKit
        let model = UserDefaults.standard.string(forKey: id.modelPreferenceKey) ?? id.defaultModel
        return (id, transcriptionFactory.provider(for: id), model)
    }

    private func resolveRefinement() -> (RefinementProviderID, any RefinementProvider) {
        let selectedID = RefinementProviderID(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedRefinementProvider) ?? ""
        ) ?? .ollama

        // When an override is active (after repeated failures), return NoOp
        // regardless of the user-selected provider.
        if refinementOverride != nil {
            return (.noOp, refinementFactory.provider(for: .noOp))
        }
        return (selectedID, refinementFactory.provider(for: selectedID))
    }

    // MARK: - Refinement override (auto-fallback after repeated failures)

    @MainActor
    func resetRefinementOverride() {
        refinementOverride = nil
        refinementFailureCounts.removeAll()
        NSLog("VoiceRefine: refinement override cleared — user-selected provider re-enabled")
    }

    @MainActor
    var hasRefinementOverride: Bool { refinementOverride != nil }

    private func flashError(_ message: String) {
        transition(to: .error(message))
        NotificationDispatcher.postError(title: "VoiceRefine error", message: message)
        // The error state persists until the next successful dictation —
        // `beginRecording()` transitions to `.recording`, which naturally
        // clears it. Auto-clearing after 1.5 s made transient failures
        // invisible on a crowded menu bar (hidden behind the notch).
    }

    private func scheduleMaxDurationCutoff() {
        cancelMaxDurationCutoff()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            NSLog("VoiceRefine: hit \(Self.maxDuration)s cap, auto-stopping recording")
            self.endRecording()
        }
        maxDurationCutoff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: work)
    }

    private func cancelMaxDurationCutoff() {
        maxDurationCutoff?.cancel()
        maxDurationCutoff = nil
    }

    // MARK: - State publishing

    private func transition(to newState: DictationState) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Diagnostics

    /// Per-dictation context summary (counts, not content). Parallel to
    /// `PasteEngine`'s paste.log so diagnostics remain visible without
    /// admin `log stream`.
    private static let contextLog = RotatingLogFile(
        url: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/VoiceRefine/context.log")
    )
}
