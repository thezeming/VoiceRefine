import Foundation

// MARK: - Factory protocols

/// Abstracts construction of transcription providers so DictationPipeline
/// can be unit-tested without hitting real model APIs.
protocol TranscriptionFactory {
    /// Return (or lazily create) the provider for `id`. Implementations
    /// should memoize so WhisperKit's expensive model-load init is paid
    /// at most once.
    func provider(for id: TranscriptionProviderID) -> any TranscriptionProvider
}

/// Abstracts construction of refinement providers for the same reason.
protocol RefinementFactory {
    func provider(for id: RefinementProviderID) -> any RefinementProvider
}

// MARK: - Default (production) implementations

/// Lazily instantiates concrete transcription providers on first request
/// and memoizes them. WhisperKit's init is lightweight but its first
/// `transcribe()` call loads the CoreML model; memoization avoids re-paying
/// even the init cost on every dictation.
final class DefaultTranscriptionFactory: TranscriptionFactory {

    private var whisperKit: WhisperKitProvider?
    private var openAIWhisper: OpenAIWhisperProvider?
    private var groq: GroqWhisperProvider?

    // AppleSpeechProvider exists only on macOS 26+. We store it as a
    // protocol-existential so the containing class itself doesn't need
    // to be @available.
    private var _appleSpeech: (any TranscriptionProvider)?

    func provider(for id: TranscriptionProviderID) -> any TranscriptionProvider {
        switch id {
        case .whisperKit:
            if whisperKit == nil { whisperKit = WhisperKitProvider() }
            return whisperKit!

        case .appleSpeech:
            if let existing = _appleSpeech { return existing }
            if #available(macOS 26, *) {
                let p = AppleSpeechProvider()
                _appleSpeech = p
                return p
            }
            // Stale pref on pre-Tahoe: fall back to WhisperKit.
            if whisperKit == nil { whisperKit = WhisperKitProvider() }
            return whisperKit!

        case .openAIWhisper:
            if openAIWhisper == nil { openAIWhisper = OpenAIWhisperProvider() }
            return openAIWhisper!

        case .groq:
            if groq == nil { groq = GroqWhisperProvider() }
            return groq!
        }
    }
}

/// Lazily instantiates concrete refinement providers on first request
/// and memoizes them.
final class DefaultRefinementFactory: RefinementFactory {

    private var ollama: OllamaProvider?
    private var noOp: NoOpProvider?
    private var openAICompatible: OpenAICompatibleProvider?
    private var anthropic: AnthropicProvider?
    private var openAI: OpenAIProvider?
    private var deepSeek: DeepSeekProvider?

    func provider(for id: RefinementProviderID) -> any RefinementProvider {
        switch id {
        case .ollama:
            if ollama == nil { ollama = OllamaProvider() }
            return ollama!

        case .noOp:
            if noOp == nil { noOp = NoOpProvider() }
            return noOp!

        case .openAICompatible:
            if openAICompatible == nil { openAICompatible = OpenAICompatibleProvider() }
            return openAICompatible!

        case .anthropic:
            if anthropic == nil { anthropic = AnthropicProvider() }
            return anthropic!

        case .openAI:
            if openAI == nil { openAI = OpenAIProvider() }
            return openAI!

        case .deepseek:
            if deepSeek == nil { deepSeek = DeepSeekProvider() }
            return deepSeek!
        }
    }
}
