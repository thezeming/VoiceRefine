import Foundation

/// Pass-through refiner. The transcript travels from Whisper to paste
/// unchanged. Useful when the user doesn't want Ollama or any cloud
/// provider (fully offline, lowest latency).
final class NoOpProvider: RefinementProvider {
    static let providerID = RefinementProviderID.noOp

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String {
        transcript
    }
}
