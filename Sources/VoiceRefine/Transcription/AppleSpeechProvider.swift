@preconcurrency import AVFoundation
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
final class AppleSpeechProvider: TranscriptionProvider, @unchecked Sendable {
    // @unchecked Sendable: stateless — no instance stored properties; all
    // work is done inside the async transcribe() method.
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
        // when `finalizeAndFinishThroughEndOfInput` closes the stream, or
        // early if the outer pipeline cancels us (new hotkey press while
        // this one is still transcribing — PLAN invariant #9).
        //
        // Each final covers a freshly-committed audio segment (often a
        // single utterance delimited by a natural pause), so the loop
        // joins them with a single space rather than bare concatenation
        // — otherwise two pause-separated clauses come back glued as
        // "clause oneclause two".
        let collectTask = Task { () -> String in
            var out = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    try Task.checkCancellation()
                    let segment = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !segment.isEmpty else { continue }
                    if out.isEmpty {
                        out = segment
                    } else {
                        out += " " + segment
                    }
                }
            } catch is CancellationError {
                return out
            }
            return out
        }

        do {
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collectTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw ProviderError.analyzerFailed(error)
        }

        // Check once more after the analyzer finishes — a cancel can land
        // between analyzeSequence returning and here.
        if Task.isCancelled {
            collectTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }

        let text = (try? await collectTask.value) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming transcription

    /// Real streaming implementation for Apple SpeechAnalyzer. Emits both
    /// partial and final results via `onPartial` so the caller can show a
    /// live caption in the HUD. Returns the last accumulated final string.
    ///
    /// Cancellation is cooperative: `try Task.checkCancellation()` inside the
    /// result loop, and `await analyzer.cancelAndFinishNow()` on outer-task
    /// cancellation (mirrors the existing `transcribe` implementation).
    @available(macOS 26, *)
    func transcribeStreaming(
        audio: Data,
        model: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard !audio.isEmpty else { throw ProviderError.emptyAudio }

        let locale = Locale(identifier: model)

        if !(await AppleSpeechAssetManager.isInstalled(localeID: model)) {
            throw ProviderError.assetNotInstalled(model)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        let compatFormats = await transcriber.availableCompatibleAudioFormats
        guard let targetFormat = compatFormats.first else {
            throw ProviderError.noCompatibleAudioFormat
        }

        let buffer = try Self.convertInt16LE16kMono(data: audio, to: targetFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain results on a child Task, accumulating every final into
        // `committed` and showing `committed + current partial` through
        // `onPartial` so the HUD tracks the full transcript as it grows.
        //
        // SpeechTranscriber emits ONE final per committed utterance, not
        // one for the whole recording. Whenever the user pauses between
        // clauses (a natural rhythm during longer dictations) each
        // clause lands as its own final. The earlier implementation
        // did `lastFinal = text`, which kept only the last utterance
        // and silently dropped everything before it — long sentences
        // came back as just their tail. We now append each final with
        // a single-space separator; the existing trim at the return
        // site strips the leading/trailing whitespace from the join.
        let collectTask = Task { () -> String in
            var committed = ""
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    // Collapse internal whitespace so multi-line partials
                    // don't wreck the single-line HUD layout.
                    let text = String(result.text.characters)
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    guard !text.isEmpty else { continue }

                    if result.isFinal {
                        if committed.isEmpty {
                            committed = text
                        } else {
                            committed += " " + text
                        }
                        onPartial(committed)
                    } else {
                        // Partial: show whatever has been committed so
                        // far plus the current evolving hypothesis.
                        let display = committed.isEmpty
                            ? text
                            : committed + " " + text
                        onPartial(display)
                    }
                }
            } catch is CancellationError {
                return committed
            }
            return committed
        }

        do {
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collectTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw ProviderError.analyzerFailed(error)
        }

        if Task.isCancelled {
            collectTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
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

        // AVAudioConverterInputBlock is @Sendable in Swift 6. Use a
        // reference-type box so the single-use bool can be mutated safely
        // across the closure boundary (the block is called synchronously).
        final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
        var error: NSError?
        let provided = Box(false)
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if provided.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided.value = true
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
