import Foundation

enum RefinementProviderID: String, CaseIterable, Identifiable, Hashable {
    case ollama
    case noOp
    case openAICompatible
    case anthropic
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama:            "Ollama (local)"
        case .noOp:              "No-Op (pass-through)"
        case .openAICompatible:  "OpenAI-compatible (custom URL)"
        case .anthropic:         "Anthropic (cloud)"
        case .openAI:            "OpenAI (cloud)"
        }
    }

    var isLocal: Bool {
        switch self {
        case .ollama, .noOp: true
        default:             false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openAI, .openAICompatible: true
        default: false
        }
    }

    var requiresBaseURL: Bool {
        self == .openAICompatible
    }

    var apiKeyAccount: String? {
        requiresAPIKey ? "\(rawValue).apiKey" : nil
    }

    var availableModels: [String] {
        switch self {
        case .ollama:
            return ["llama3.2:3b", "qwen2.5:7b", "mistral:7b"]
        case .noOp:
            return []
        case .openAICompatible:
            return []
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-opus-4-7"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        }
    }

    var defaultModel: String? {
        availableModels.first
    }

    var modelPreferenceKey: String { "model.\(rawValue)" }
    var baseURLPreferenceKey: String { "baseURL.\(rawValue)" }
}
