import Foundation

/// Refines via OpenAI's chat completion endpoint. Thin wrapper on
/// `OpenAICompatClient` with a hardcoded api.openai.com base URL.
final class OpenAIProvider: RefinementProvider {
    static let providerID = RefinementProviderID.openAI

    enum ProviderError: Error, CustomStringConvertible {
        case missingAPIKey
        case clientError(OpenAICompatClient.ClientError)

        var description: String {
            switch self {
            case .missingAPIKey:         "No OpenAI API key. Add one in Settings → Refinement."
            case .clientError(let e):    e.description
            }
        }
    }

    private static let baseURL = URL(string: "https://api.openai.com")!

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String {
        guard let apiKey = KeychainStore.shared.get(account: RefinementProviderID.openAI.apiKeyAccount ?? ""),
              !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        let model = UserDefaults.standard.string(forKey: RefinementProviderID.openAI.modelPreferenceKey)
            ?? RefinementProviderID.openAI.defaultModel
            ?? "gpt-4o-mini"

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
