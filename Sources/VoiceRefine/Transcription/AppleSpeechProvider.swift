import AVFoundation
import Foundation
import Speech

/// Local transcription via Apple's `SpeechAnalyzer` + `SpeechTranscriber`
/// (introduced in macOS 26 / iOS 26). The model is managed by the OS — no
/// bundled asset, no per-variant download under Application Support.
///
/// Runs fully offline once the locale asset is installed (see
/// `AppleSpeechAssetManager.isInstalled`). Audio format: we convert
/// `AudioRecorder`'s 16 kHz mono Int16 PCM into a Float32 non-interleaved
/// `AVAudioPCMBuffer` — the standard shape Apple's ML audio frameworks
/// consume.
@available(macOS 26, *)
final class AppleSpeechProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.appleSpeech

    enum ProviderError: Error, CustomStringConvertible {
        case emptyAudio
        case unsupportedLocale(String)
        case assetNotInstalled(String)
        case bufferConversionFailed
        case analyzerFailed(Error)

        var description: String {
            switch self {
            case .emptyAudio:
                return "Audio buffer is empty."
            case .unsupportedLocale(let id):
                return "Locale '\(id)' is not supported by SpeechTranscriber on this machine."
            case .assetNotInstalled(let id):
                return "Locale '\(id)' asset is not installed. Download it from Settings › Transcription."
            case .bufferConversionFailed:
                return "Could not convert recorded PCM into an AVAudioPCMBuffer for SpeechAnalyzer."
            case .analyzerFailed(let err):
                return "SpeechAnalyzer failed: \(err.localizedDescription)"
            }
        }
    }

    func transcribe(audio: Data, model: String) async throws -> String {
        guard !audio.isEmpty else { throw ProviderError.emptyAudio }

        let locale = Locale(identifier: model)

        // Fail fast with a clear, user-actionable message when the locale
        // asset hasn't been installed yet. Otherwise the raw AssetInventory
        // error bubbles up through the notification dispatcher as a
        // multi-line exception, which is opaque.
        if !(await AppleSpeechAssetManager.isInstalled(localeID: model)) {
            throw ProviderError.assetNotInstalled(model)
        }

        let buffer = try Self.makePCMBuffer(fromInt16LE16kMono: audio)

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain `transcriber.results` on a background Task so we can keep
        // pushing audio on the current Task. `finalizeAndFinishThroughEndOfInput`
        // closes the results stream once the analyzer has nothing left, so
        // this task terminates naturally without an explicit stop signal.
        let collectTask = Task { () -> String in
            var out = ""
            for try await result in transcriber.results where result.isFinal {
                out += String(result.text.characters)
            }
            return out
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        do {
            try await analyzer.start(inputSequence: stream)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collectTask.cancel()
            throw ProviderError.analyzerFailed(error)
        }

        let text = (try? await collectTask.value) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio conversion

    /// Builds a Float32 mono non-interleaved `AVAudioPCMBuffer` at 16 kHz
    /// from the little-endian Int16 PCM bytes `AudioRecorder` produces.
    /// Division by 32768 matches the `int16PCMToFloat` helper in
    /// `WhisperKitProvider` so both local backends see identical sample
    /// values.
    private static func makePCMBuffer(fromInt16LE16kMono data: Data) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0 else { throw ProviderError.emptyAudio }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ProviderError.bufferConversionFailed }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ProviderError.bufferConversionFailed
        }
        buffer.frameLength = frames

        guard let channel = buffer.floatChannelData?[0] else {
            throw ProviderError.bufferConversionFailed
        }

        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) {
                channel[i] = Float(src[i]) / 32768.0
            }
        }
        return buffer
    }
}
