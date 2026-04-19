import Foundation

/// Refines via Anthropic's Messages API. Uses `x-api-key` rather than the
/// OpenAI-style Bearer header, and wraps responses as an array of
/// content blocks — enough API divergence that it doesn't share the
/// OpenAI-compat client.
final class AnthropicProvider: RefinementProvider, APIKeyed, @unchecked Sendable {
    // @unchecked Sendable: holds only let URLSession; all methods are async.
    static let providerID = RefinementProviderID.anthropic
    static let apiKeyAccount = RefinementProviderID.anthropic.apiKeyAccount ?? ""
    static var missingAPIKeyError: any Error { ProviderError.missingAPIKey }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let maxTokens = 2048

    enum ProviderError: CloudProviderError {
        case missingAPIKey
        case unreachable
        case httpStatus(Int, String?)
        case malformedResponse

        var description: String {
            switch self {
            case .missingAPIKey:              "No Anthropic API key. Add one in Settings → Refinement."
            case .unreachable:                "Could not reach api.anthropic.com."
            case .httpStatus(let c, let b):   "Anthropic returned HTTP \(c). \(b ?? "")"
            case .malformedResponse:          "Anthropic returned an unexpected response shape."
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String {
        let apiKey = try Self.requireAPIKey()

        let model = UserDefaults.standard.string(forKey: RefinementProviderID.anthropic.modelPreferenceKey)
            ?? RefinementProviderID.anthropic.defaultModel
            ?? "claude-sonnet-4-6"

        let userMessage = RefinementMessageBuilder.userMessage(transcript: transcript, context: context)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "temperature": 0.1,
            "stop_sequences": RefinementStopSequences.anthropic,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion,    forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }

        struct MessagesResponse: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
        }

        do {
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            let text = decoded.content
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined()
            return RefinementOutputSanitizer.sanitize(text)
        } catch {
            throw ProviderError.malformedResponse
        }
    }
}
