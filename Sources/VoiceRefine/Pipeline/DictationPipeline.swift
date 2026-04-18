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
final class DictationPipeline {
    static let minDuration: TimeInterval = 0.3
    static let maxDuration: TimeInterval = 120.0

    private let recorder = AudioRecorder()
    // Transcription backends
    private let whisperKitProvider     = WhisperKitProvider()
    private let openAIWhisperProvider  = OpenAIWhisperProvider()
    private let groqWhisperProvider    = GroqWhisperProvider()
    // Refinement backends
    private let ollamaProvider              = OllamaProvider()
    private let noOpProvider                = NoOpProvider()
    private let openAICompatibleProvider    = OpenAICompatibleProvider()
    private let anthropicProvider           = AnthropicProvider()
    private let openAIProvider              = OpenAIProvider()
    private let deepSeekProvider            = DeepSeekProvider()

    private let contextGatherer   = ContextGatherer.shared
    private var pendingContext: RefinementContext = .empty
    private var hotkeyManager: HotkeyManager?
    private var maxDurationCutoff: DispatchWorkItem?
    private var currentTranscriptionTask: Task<Void, Never>?

    private(set) var state: DictationState = .idle

    var onStateChange: ((DictationState) -> Void)?
    /// Fires with the final (refined) transcript once the full pipeline
    /// completes. Phase 5 hooks the paste engine here.
    var onTranscript: ((String) -> Void)?

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
        pendingContext = contextGatherer.gather()
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
            Self.appendContextDiagnostic(line)
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

        let duration = recorder.duration
        let audio = recorder.stop()

        // Play stop chirp *after* the mic tap is removed so it isn't
        // tacked onto the recorded buffer.
        SoundEffect.stop.play()

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
        pendingContext = .empty

        currentTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let startedTranscribe = Date()
                let raw = try await transcriptionProvider.transcribe(audio: audio, model: transcriptionModel)
                let transcribeElapsed = Date().timeIntervalSince(startedTranscribe)
                if Task.isCancelled { return }
                NSLog("VoiceRefine: raw transcript (\(String(format: "%.2fs", transcribeElapsed)) on \(transcriptionProviderID.rawValue)/\(transcriptionModel)) — \(raw)")

                let refined = await self.refine(raw: raw, context: context)
                if Task.isCancelled { return }
                NSLog("VoiceRefine: refined transcript — \(refined)")

                await MainActor.run {
                    self.onTranscript?(refined)
                    if self.state == .processing {
                        self.transition(to: .idle)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                NSLog("VoiceRefine: transcription error — \(error)")
                await MainActor.run { self.flashError("Transcription failed.") }
            }
        }
    }

    // MARK: - Refinement

    /// Runs the configured refinement provider on a raw transcript. Falls
    /// back to the raw text if the provider errors — we never want to lose
    /// the user's dictation just because the remote API is down.
    private func refine(raw: String, context: RefinementContext) async -> String {
        let (providerID, provider) = resolveRefinement()

        let systemPrompt = UserDefaults.standard.string(forKey: PrefKey.refinementSystemPrompt)
            ?? PrefDefaults.refinementSystemPrompt

        do {
            let started = Date()
            let out = try await provider.refine(transcript: raw, systemPrompt: systemPrompt, context: context)
            let elapsed = Date().timeIntervalSince(started)
            NSLog("VoiceRefine: refined via \(providerID.rawValue) in \(String(format: "%.2fs", elapsed))")
            return out.isEmpty ? raw : out
        } catch {
            NSLog("VoiceRefine: refinement via \(providerID.rawValue) failed (\(error)); falling back to raw")
            NotificationDispatcher.postError(
                title: "\(providerID.displayName) refinement unavailable",
                message: "Pasted raw transcript instead. \(String(describing: error))"
            )
            return raw
        }
    }

    // MARK: - Provider resolution

    private func resolveTranscription() -> (TranscriptionProviderID, any TranscriptionProvider, String) {
        let id = TranscriptionProviderID(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedTranscriptionProvider) ?? ""
        ) ?? .whisperKit

        let model = UserDefaults.standard.string(forKey: id.modelPreferenceKey) ?? id.defaultModel

        let provider: any TranscriptionProvider
        switch id {
        case .whisperKit:    provider = whisperKitProvider
        case .openAIWhisper: provider = openAIWhisperProvider
        case .groq:          provider = groqWhisperProvider
        }
        return (id, provider, model)
    }

    private func resolveRefinement() -> (RefinementProviderID, any RefinementProvider) {
        let id = RefinementProviderID(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedRefinementProvider) ?? ""
        ) ?? .ollama

        let provider: any RefinementProvider
        switch id {
        case .ollama:           provider = ollamaProvider
        case .noOp:             provider = noOpProvider
        case .openAICompatible: provider = openAICompatibleProvider
        case .anthropic:        provider = anthropicProvider
        case .openAI:           provider = openAIProvider
        case .deepseek:         provider = deepSeekProvider
        }
        return (id, provider)
    }

    private func flashError(_ message: String) {
        transition(to: .error(message))
        NotificationDispatcher.postError(title: "VoiceRefine error", message: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if case .error = self.state {
                self.transition(to: .idle)
            }
        }
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
        if Thread.isMainThread {
            onStateChange?(newState)
        } else {
            DispatchQueue.main.async { [weak self, newState] in
                self?.onStateChange?(newState)
            }
        }
    }

    // MARK: - Diagnostics

    private static let diagnosticURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/VoiceRefine/context.log")
    }()

    private static let diagnosticFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Appends one timestamped context-summary line to
    /// `~/Library/Logs/VoiceRefine/context.log`. Counts only — never the
    /// content itself. Parallel to `PasteEngine`'s paste.log so diagnostics
    /// remain visible without admin `log stream`.
    private static func appendContextDiagnostic(_ line: String) {
        let url = diagnosticURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamped = diagnosticFormatter.string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
