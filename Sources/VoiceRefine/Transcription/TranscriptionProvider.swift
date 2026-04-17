import Foundation

/// Any transcription backend — local WhisperKit, Groq, OpenAI — conforms to
/// this. The ID enum supplies all of PLAN's static metadata
/// (`displayName`, `isLocal`, `availableModels`, …); the protocol itself
/// only carries runtime behaviour.
///
/// `audio` is little-endian 16 kHz mono Int16 PCM — exactly what
/// `AudioRecorder` emits. Concrete providers convert to whatever shape their
/// SDK wants (Whisper wants `[Float]`, HTTP providers want WAV bytes).
protocol TranscriptionProvider: AnyObject {
    static var providerID: TranscriptionProviderID { get }
    func transcribe(audio: Data, model: String) async throws -> String
}

extension TranscriptionProvider {
    static var id: String              { providerID.rawValue }
    static var displayName: String     { providerID.displayName }
    static var isLocal: Bool           { providerID.isLocal }
    static var availableModels: [String] { providerID.availableModels }
    static var requiredKeys: [String] {
        providerID.apiKeyAccount.map { [$0] } ?? []
    }
}
