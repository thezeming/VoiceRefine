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
    private var hotkeyManager: HotkeyManager?
    private var maxDurationCutoff: DispatchWorkItem?

    private(set) var state: DictationState = .idle

    var onStateChange: ((DictationState) -> Void)?

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
        guard state == .idle else { return }
        do {
            try recorder.start()
            transition(to: .recording)
            scheduleMaxDurationCutoff()
        } catch {
            NSLog("VoiceRefine: start recording failed: \(error)")
            transition(to: .error("Could not start recording."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.transition(to: .idle)
            }
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        cancelMaxDurationCutoff()

        let duration = recorder.duration
        let bytes = recorder.byteCount
        _ = recorder.stop()

        if duration < Self.minDuration {
            NSLog("VoiceRefine: discarded \(String(format: "%.3fs", duration)) recording (below \(Self.minDuration)s floor)")
            transition(to: .idle)
            return
        }

        do {
            let url = Self.lastWavURL
            try recorder.writeWAV(to: url)
            NSLog("VoiceRefine: recording saved — \(bytes) bytes, \(String(format: "%.2fs", duration)), wrote \(url.path)")
        } catch {
            NSLog("VoiceRefine: failed to write WAV: \(error)")
            transition(to: .error("Could not save recording."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.transition(to: .idle)
            }
            return
        }

        transition(to: .idle)
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
