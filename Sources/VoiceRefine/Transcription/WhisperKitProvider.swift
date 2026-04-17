import Foundation
import WhisperKit

/// Local transcription via WhisperKit. Models are fetched once into
/// `~/Library/Application Support/VoiceRefine/models/whisper/<variant>/`
/// and reused afterwards — satisfying PLAN's "no network after the initial
/// model download" invariant.
final class WhisperKitProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.whisperKit

    enum ProviderError: Error, CustomStringConvertible {
        case emptyAudio
        case modelLoadFailed(Error)
        case transcribeFailed(Error)

        var description: String {
            switch self {
            case .emptyAudio:                    "Audio buffer is empty."
            case .modelLoadFailed(let err):      "WhisperKit could not load model: \(err.localizedDescription)"
            case .transcribeFailed(let err):     "WhisperKit transcription failed: \(err.localizedDescription)"
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    // MARK: - Paths

    static var downloadBaseURL: URL {
        let override = UserDefaults.standard.string(forKey: PrefKey.modelStorageOverride) ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("whisper", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VoiceRefine", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    static func isModelDownloaded(_ model: String) -> Bool {
        let folder = downloadBaseURL.appendingPathComponent(model, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return (contents?.count ?? 0) > 0
    }

    // MARK: - Transcription

    func transcribe(audio: Data, model: String) async throws -> String {
        guard !audio.isEmpty else { throw ProviderError.emptyAudio }

        try await ensureLoaded(model: model)

        let samples = Self.int16PCMToFloat(audio)
        guard !samples.isEmpty else { throw ProviderError.emptyAudio }

        guard let whisperKit else { return "" }
        do {
            let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: samples)
            let joined = results.map(\.text).joined(separator: " ")
            return joined.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            throw ProviderError.transcribeFailed(error)
        }
    }

    // MARK: - Model loading

    private func ensureLoaded(model: String) async throws {
        if let wk = whisperKit, loadedModel == model, wk.modelState == .loaded {
            return
        }
        let base = Self.downloadBaseURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let config = WhisperKitConfig(
            model: model,
            downloadBase: base,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )

        do {
            NSLog("VoiceRefine: loading Whisper model '\(model)' from \(base.path)")
            let wk = try await WhisperKit(config)
            self.whisperKit = wk
            self.loadedModel = model
            NSLog("VoiceRefine: Whisper model '\(model)' ready")
        } catch {
            throw ProviderError.modelLoadFailed(error)
        }
    }

    // MARK: - Audio format helpers

    /// Converts little-endian 16-bit signed PCM into Float samples in [-1, 1],
    /// which is what WhisperKit's `audioArray` parameter expects.
    static func int16PCMToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(samples[i]) / 32768.0
            }
            return floats
        }
    }
}
