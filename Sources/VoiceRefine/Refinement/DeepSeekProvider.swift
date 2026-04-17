import Foundation

/// Refines via DeepSeek's OpenAI-compatible chat endpoint. Hardcoded
/// base URL; otherwise indistinguishable from `OpenAIProvider` — both
/// route through `OpenAICompatClient`. Pulled in as a cost-effective
/// cloud alternative to Anthropic / OpenAI.
final class DeepSeekProvider: RefinementProvider {
    static let providerID = RefinementProviderID.deepseek

    enum ProviderError: Error, CustomStringConvertible {
        case missingAPIKey
        case clientError(OpenAICompatClient.ClientError)

        var description: String {
            switch self {
            case .missingAPIKey:      "No DeepSeek API key. Add one in Settings → Refinement."
            case .clientError(let e): e.description
            }
        }
    }

    private static let baseURL = URL(string: "https://api.deepseek.com")!

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String {
        guard let apiKey = KeychainStore.shared.get(account: RefinementProviderID.deepseek.apiKeyAccount ?? ""),
              !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        let model = UserDefaults.standard.string(forKey: RefinementProviderID.deepseek.modelPreferenceKey)
            ?? RefinementProviderID.deepseek.defaultModel
            ?? "deepseek-chat"

        let userMessage = RefinementMessageBuilder.userMessage(transcript: transcript, context: context)

        do {
            return try await OpenAICompatClient.chat(.init(
                baseURL: Self.baseURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                userMessage: userMessage
            ))
        } catch let error as OpenAICompatClient.ClientError {
            throw ProviderError.clientError(error)
        }
    }
}
