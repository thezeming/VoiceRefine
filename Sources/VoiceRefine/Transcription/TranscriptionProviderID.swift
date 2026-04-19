import Foundation

enum TranscriptionProviderID: String, CaseIterable, Identifiable, Hashable {
    case whisperKit
    case appleSpeech
    case groq
    case openAIWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit:     "WhisperKit (local)"
        case .appleSpeech:    "Apple SpeechAnalyzer (local)"
        case .groq:           "Groq (cloud)"
        case .openAIWhisper:  "OpenAI Whisper (cloud)"
        }
    }

    var isLocal: Bool {
        switch self {
        case .whisperKit, .appleSpeech: return true
        case .groq, .openAIWhisper:     return false
        }
    }

    var requiresAPIKey: Bool { !isLocal }

    var apiKeyAccount: String? {
        requiresAPIKey ? "\(rawValue).apiKey" : nil
    }

    /// For `appleSpeech` the "model" identifier is actually a BCP-47/POSIX
    /// locale identifier (e.g. `en_US`). The list here is the hard-coded
    /// fallback used for first paint — the Transcription tab overwrites it
    /// at runtime with whatever `SpeechTranscriber.supportedLocales` reports
    /// on this machine. Keep the first entry as `en_US` so `defaultModel`
    /// stays sensible.
    var availableModels: [String] {
        switch self {
        case .whisperKit:
            return [
                "openai_whisper-base.en",
                "openai_whisper-small.en",
                "openai_whisper-medium.en",
                "openai_whisper-large-v3-v20240930_turbo"
            ]
        case .appleSpeech:
            return [
                "en_US", "en_GB", "en_AU", "en_CA",
                "de_DE", "fr_FR", "es_ES",
                "ja_JP", "ko_KR", "zh_CN",
                "ar_SA"
            ]
        case .groq:
            return ["whisper-large-v3", "whisper-large-v3-turbo"]
        case .openAIWhisper:
            return ["whisper-1"]
        }
    }

    var defaultModel: String { availableModels[0] }

    var modelPreferenceKey: String { "model.\(rawValue)" }

    /// Cases that should appear in user-facing pickers on this OS. `appleSpeech`
    /// requires macOS 26 (Tahoe) — hidden entirely on older OSes rather than
    /// shown disabled, so users can't select a provider they can never use.
    /// `allCases` stays unfiltered so preference persistence keeps working
    /// across OS upgrades.
    static var visibleCases: [TranscriptionProviderID] {
        if #available(macOS 26, *) {
            return Self.allCases
        }
        return Self.allCases.filter { $0 != .appleSpeech }
    }
}
