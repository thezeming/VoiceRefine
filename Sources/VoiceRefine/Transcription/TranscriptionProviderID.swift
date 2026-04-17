import Foundation

enum TranscriptionProviderID: String, CaseIterable, Identifiable, Hashable {
    case whisperKit
    case groq
    case openAIWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit:     "WhisperKit (local)"
        case .groq:           "Groq (cloud)"
        case .openAIWhisper:  "OpenAI Whisper (cloud)"
        }
    }

    var isLocal: Bool { self == .whisperKit }

    var requiresAPIKey: Bool { !isLocal }

    var apiKeyAccount: String? {
        requiresAPIKey ? "\(rawValue).apiKey" : nil
    }

    var availableModels: [String] {
        switch self {
        case .whisperKit:
            return [
                "openai_whisper-base.en",
                "openai_whisper-small.en",
                "openai_whisper-medium.en",
                "openai_whisper-large-v3-v20240930_turbo"
            ]
        case .groq:
            return ["whisper-large-v3", "whisper-large-v3-turbo"]
        case .openAIWhisper:
            return ["whisper-1"]
        }
    }

    var defaultModel: String { availableModels[0] }

    var modelPreferenceKey: String { "model.\(rawValue)" }
}
