import Foundation
import Speech

/// Local transcription via Apple's `SpeechAnalyzer` + `SpeechTranscriber`
/// (introduced in macOS 26 / iOS 26). The model is managed by the OS — no
/// bundled asset, no per-variant download under Application Support.
///
/// Phase 9.1 is scaffolding only: the class exists, conforms to
/// `TranscriptionProvider`, and is wired into the picker/factory so the
/// availability-gating plumbing can be exercised end-to-end. The actual
/// `SpeechAnalyzer` pipeline lands in Phase 9.2.
@available(macOS 26, *)
final class AppleSpeechProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.appleSpeech

    enum ProviderError: Error, CustomStringConvertible {
        case notImplementedYet
        case emptyAudio
        case unsupportedLocale(String)
        case assetNotInstalled(String)
        case bufferConversionFailed
        case analyzerFailed(Error)

        var description: String {
            switch self {
            case .notImplementedYet:
                return "Apple SpeechAnalyzer provider is not yet wired up (Phase 9.2)."
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
        throw ProviderError.notImplementedYet
    }
}
