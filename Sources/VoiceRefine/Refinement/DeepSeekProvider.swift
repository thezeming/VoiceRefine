import Foundation

/// Refines via DeepSeek's OpenAI-compatible chat endpoint. Hardcoded
/// base URL; otherwise indistinguishable from `OpenAIProvider` — both
/// route through `OpenAICompatClient`. Pulled in as a cost-effective
/// cloud alternative to Anthropic / OpenAI.
final class DeepSeekProvider: RefinementProvider, APIKeyed, @unchecked Sendable {
    // @unchecked Sendable: no stored mutable state; all methods are async.
    static let providerID = RefinementProviderID.deepseek
    static let apiKeyAccount = RefinementProviderID.deepseek.apiKeyAccount ?? ""
    static var missingAPIKeyError: any Error { ProviderError.missingAPIKey }

    enum ProviderError: CloudProviderError {
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
        let apiKey = try Self.requireAPIKey()

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
