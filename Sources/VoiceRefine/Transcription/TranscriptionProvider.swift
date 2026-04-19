import Foundation

/// Any transcription backend — local WhisperKit, Groq, OpenAI — conforms to
/// this. The ID enum supplies all of PLAN's static metadata
/// (`displayName`, `isLocal`, `availableModels`, …); the protocol itself
/// only carries runtime behaviour.
///
/// `audio` is little-endian 16 kHz mono Int16 PCM — exactly what
/// `AudioRecorder` emits. Concrete providers convert to whatever shape their
/// SDK wants (Whisper wants `[Float]`, HTTP providers want WAV bytes).
///
/// `Sendable` conformance is required so `any TranscriptionProvider` values
/// can cross actor boundaries into the pipeline's Task without data-race
/// warnings. Concrete implementations either hold only `let` fields
/// (pure value semantics) or use locks internally.
protocol TranscriptionProvider: AnyObject, Sendable {
    static var providerID: TranscriptionProviderID { get }
    func transcribe(audio: Data, model: String) async throws -> String

    /// Streaming variant. Yields partial transcripts via `onPartial` as they
    /// become available; returns the final aggregated string.
    ///
    /// The default implementation wraps `transcribe(audio:model:)` and does
    /// **not** emit any partials — suitable for batch providers (WhisperKit,
    /// cloud APIs) that have no native streaming.
    func transcribeStreaming(
        audio: Data,
        model: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

extension TranscriptionProvider {
    static var id: String              { providerID.rawValue }
    static var displayName: String     { providerID.displayName }
    static var isLocal: Bool           { providerID.isLocal }
    static var availableModels: [String] { providerID.availableModels }
    static var requiredKeys: [String] {
        providerID.apiKeyAccount.map { [$0] } ?? []
    }

    // Default: batch — no partials emitted.
    func transcribeStreaming(
        audio: Data,
        model: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await transcribe(audio: audio, model: model)
    }
}
