import Foundation

/// Any OpenAI-compatible endpoint the user points at: LM Studio,
/// Together, Fireworks, Groq's chat API, a homelab vLLM, etc. Reads
/// base URL from `baseURLPreferenceKey` and an optional API key from
/// Keychain. Missing key is fine — some self-hosted endpoints don't
/// require auth.
final class OpenAICompatibleProvider: RefinementProvider, @unchecked Sendable {
    // @unchecked Sendable: no stored mutable state; all methods are async.
    static let providerID = RefinementProviderID.openAICompatible

    enum ProviderError: CloudProviderError {
        case missingBaseURL
        case invalidBaseURL(String)
        case missingModel
        case clientError(OpenAICompatClient.ClientError)

        var description: String {
            switch self {
            case .missingBaseURL:         "No OpenAI-compatible base URL configured."
            case .invalidBaseURL(let s):  "Invalid base URL: \(s)"
            case .missingModel:           "No model specified for the OpenAI-compatible provider."
            case .clientError(let e):     e.description
            }
        }
    }

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String {
        let defaults = UserDefaults.standard
        let baseURLString = (defaults.string(forKey: RefinementProviderID.openAICompatible.baseURLPreferenceKey) ?? "")
            .trimmingCharacters(in: CharacterSet.whitespaces)
        guard !baseURLString.isEmpty else { throw ProviderError.missingBaseURL }
        guard let url = URL(string: baseURLString) else { throw ProviderError.invalidBaseURL(baseURLString) }

        let model = (defaults.string(forKey: RefinementProviderID.openAICompatible.modelPreferenceKey) ?? "")
            .trimmingCharacters(in: CharacterSet.whitespaces)
        guard !model.isEmpty else { throw ProviderError.missingModel }

        let apiKey = KeychainStore.shared.get(account: RefinementProviderID.openAICompatible.apiKeyAccount ?? "")
        let userMessage = RefinementMessageBuilder.userMessage(transcript: transcript, context: context)

        do {
            return try await OpenAICompatClient.chat(.init(
                baseURL: url,
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
