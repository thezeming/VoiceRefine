import Foundation

/// Constructs provider instances on demand. Pipeline and Settings share
/// this factory so the Test buttons in Settings run against the exact
/// class the pipeline would select at dictation time.
enum RefinementProviderFactory {
    static func make(_ id: RefinementProviderID) -> any RefinementProvider {
        switch id {
        case .ollama:           return OllamaProvider()
        case .noOp:             return NoOpProvider()
        case .openAICompatible: return OpenAICompatibleProvider()
        case .anthropic:        return AnthropicProvider()
        case .openAI:           return OpenAIProvider()
        case .deepseek:         return DeepSeekProvider()
        }
    }
}

enum TranscriptionProviderFactory {
    static func make(_ id: TranscriptionProviderID) -> any TranscriptionProvider {
        switch id {
        case .whisperKit:     return WhisperKitProvider()
        case .groq:           return GroqWhisperProvider()
        case .openAIWhisper:  return OpenAIWhisperProvider()
        }
    }
}

/// Shared model for the Test button state in both tabs.
struct ProviderTestOutcome: Equatable {
    var isError: Bool
    var latency: TimeInterval
    var message: String
}

enum ProviderTestRunner {
    /// Sends a short canned transcript + default system prompt through the
    /// refinement provider. Returns latency and the first few words of the
    /// reply (full reply might be long).
    static func testRefinement(_ id: RefinementProviderID) async -> ProviderTestOutcome {
        let start = Date()
        do {
            let provider = RefinementProviderFactory.make(id)
            let systemPrompt = UserDefaults.standard.string(forKey: PrefKey.refinementSystemPrompt)
                ?? PrefDefaults.refinementSystemPrompt
            let text = try await provider.refine(
                transcript: "Refactor the off middleware to use async await.",
                systemPrompt: systemPrompt,
                context: .empty
            )
            let latency = Date().timeIntervalSince(start)
            let preview = text.split(separator: "\n").first.map(String.init) ?? text
            let shortened = preview.count > 140 ? String(preview.prefix(140)) + "…" : preview
            return ProviderTestOutcome(isError: false, latency: latency, message: shortened)
        } catch {
            return ProviderTestOutcome(
                isError: true,
                latency: Date().timeIntervalSince(start),
                message: "\(error)"
            )
        }
    }

    /// Sends one second of silence as 16 kHz mono Int16 PCM to the selected
    /// transcription provider. WhisperKit should produce an empty (or
    /// near-empty) result quickly once loaded; cloud providers should
    /// return a 2xx response.
    static func testTranscription(_ id: TranscriptionProviderID) async -> ProviderTestOutcome {
        let start = Date()
        let silencePCM = Data(count: 16_000 * MemoryLayout<Int16>.size) // 1 s of zeros
        let model = UserDefaults.standard.string(forKey: id.modelPreferenceKey) ?? id.defaultModel
        do {
            let provider = TranscriptionProviderFactory.make(id)
            let text = try await provider.transcribe(audio: silencePCM, model: model)
            let latency = Date().timeIntervalSince(start)
            let reply = text.isEmpty ? "(empty — expected for silence)" : text
            return ProviderTestOutcome(isError: false, latency: latency, message: "OK · model ready · reply: \(reply)")
        } catch {
            return ProviderTestOutcome(
                isError: true,
                latency: Date().timeIntervalSince(start),
                message: "\(error)"
            )
        }
    }
}
