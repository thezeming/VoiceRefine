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
    private let whisperKitProvider = WhisperKitProvider()
    private var hotkeyManager: HotkeyManager?
    private var maxDurationCutoff: DispatchWorkItem?
    private var currentTranscriptionTask: Task<Void, Never>?

    private(set) var state: DictationState = .idle

    var onStateChange: ((DictationState) -> Void)?
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

        let model = UserDefaults.standard.string(forKey: TranscriptionProviderID.whisperKit.modelPreferenceKey)
            ?? TranscriptionProviderID.whisperKit.defaultModel

        currentTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                let text = try await self.whisperKitProvider.transcribe(audio: audio, model: model)
                let elapsed = Date().timeIntervalSince(started)

                if Task.isCancelled { return }

                NSLog("VoiceRefine: transcript (\(String(format: "%.2fs", elapsed)) on \(model)) — \(text)")
                await MainActor.run {
                    self.onTranscript?(text)
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

    private func flashError(_ message: String) {
        transition(to: .error(message))
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
}
