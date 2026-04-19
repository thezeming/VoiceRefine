import AVFoundation
import Foundation
import Speech

/// Local transcription via Apple's `SpeechAnalyzer` + `SpeechTranscriber`
/// (introduced in macOS 26 / iOS 26). The model is managed by the OS — no
/// bundled asset, no per-variant download under Application Support.
///
/// Runs fully offline once the locale asset is installed (see
/// `AppleSpeechAssetManager.isInstalled`). Input audio goes through
/// `AVAudioConverter` to whatever format `SpeechTranscriber` reports as
/// compatible on the current machine — hard-coding a format crashed deep
/// inside the Speech framework on first test.
@available(macOS 26, *)
final class AppleSpeechProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.appleSpeech

    enum ProviderError: Error, CustomStringConvertible {
        case emptyAudio
        case unsupportedLocale(String)
        case assetNotInstalled(String)
        case noCompatibleAudioFormat
        case bufferConversionFailed(String)
        case analyzerFailed(Error)

        var description: String {
            switch self {
            case .emptyAudio:
                return "Audio buffer is empty."
            case .unsupportedLocale(let id):
                return "Locale '\(id)' is not supported by SpeechTranscriber on this machine."
            case .assetNotInstalled(let id):
                return "Locale '\(id)' asset is not installed. Download it from Settings › Transcription."
            case .noCompatibleAudioFormat:
                return "SpeechTranscriber did not report any compatible audio formats."
            case .bufferConversionFailed(let why):
                return "Could not convert recorded PCM for SpeechAnalyzer: \(why)."
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

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // `availableCompatibleAudioFormats` is the authoritative source of
        // what the transcriber will accept. Feeding anything else crashes
        // inside Speech.framework with an EXC_BREAKPOINT (not a catchable
        // Swift error). First entry is the preferred format.
        let compatFormats = await transcriber.availableCompatibleAudioFormats
        guard let targetFormat = compatFormats.first else {
            throw ProviderError.noCompatibleAudioFormat
        }
        NSLog("VoiceRefine: Apple Speech compatible format — \(targetFormat)")

        let buffer = try Self.convertInt16LE16kMono(
            data: audio,
            to: targetFormat
        )

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Yield before we construct the analyzer. AsyncStream's default
        // buffering policy is unbounded, so the element is held until
        // `analyzeSequence` starts iterating.
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain `transcriber.results` on a background Task. The loop ends
        // when `finalizeAndFinishThroughEndOfInput` closes the stream.
        let collectTask = Task { () -> String in
            var out = ""
            for try await result in transcriber.results where result.isFinal {
                out += String(result.text.characters)
            }
            return out
        }

        do {
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collectTask.cancel()
            throw ProviderError.analyzerFailed(error)
        }

        let text = (try? await collectTask.value) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio conversion

    /// Converts `AudioRecorder`'s 16 kHz mono Int16 PCM bytes into an
    /// `AVAudioPCMBuffer` matching `targetFormat` (whatever the transcriber
    /// reports as compatible — typically Float32 at some framework-chosen
    /// rate). Uses `AVAudioConverter` because we can't assume the target
    /// sample rate, channel count, or Float32 vs Int.
    static func convertInt16LE16kMono(
        data: Data,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw ProviderError.bufferConversionFailed("could not build source AVAudioFormat")
        }

        let sourceFrames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard sourceFrames > 0 else { throw ProviderError.emptyAudio }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrames
        ) else {
            throw ProviderError.bufferConversionFailed("could not allocate source PCM buffer")
        }
        sourceBuffer.frameLength = sourceFrames
        data.withUnsafeBytes { raw in
            guard let dst = sourceBuffer.int16ChannelData?[0] else { return }
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(sourceFrames) { dst[i] = src[i] }
        }

        // Same source+target format → no conversion needed, skip
        // AVAudioConverter entirely.
        if targetFormat.isEqual(sourceFormat) {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ProviderError.bufferConversionFailed(
                "AVAudioConverter init failed for \(sourceFormat) → \(targetFormat)"
            )
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(ceil(Double(sourceFrames) * ratio)) + 1024

        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else {
            throw ProviderError.bufferConversionFailed("could not allocate target PCM buffer")
        }

        var error: NSError?
        var provided = false
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error {
            throw ProviderError.bufferConversionFailed("AVAudioConverter: \(error.localizedDescription)")
        }
        if status == .error {
            throw ProviderError.bufferConversionFailed("AVAudioConverter returned .error")
        }
        return targetBuffer
    }
}
