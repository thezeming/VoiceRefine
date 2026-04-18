import Foundation

/// Refines via a local Ollama daemon. Uses the OpenAI-compatible endpoint
/// (`/v1/chat/completions`) — Ollama accepts the same request shape as
/// OpenAI with a dummy `Authorization` header, so one HTTP code path
/// serves Ollama, LM Studio, Together, and any other OpenAI-compat server.
final class OllamaProvider: RefinementProvider {
    static let providerID = RefinementProviderID.ollama

    enum ProviderError: Error, CustomStringConvertible {
        case invalidBaseURL(String)
        case unreachable(String)
        case httpStatus(Int, String?)
        case malformedResponse

        var description: String {
            switch self {
            case .invalidBaseURL(let s):      "Invalid Ollama base URL: \(s)"
            case .unreachable(let s):         "Could not reach Ollama at \(s). Is it running? (ollama serve)"
            case .httpStatus(let code, let body): "Ollama returned HTTP \(code). \(body ?? "")"
            case .malformedResponse:          "Ollama returned an unexpected response shape."
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
        let defaults = UserDefaults.standard
        let baseURLString = defaults.string(forKey: RefinementProviderID.ollama.baseURLPreferenceKey) ?? "http://localhost:11434"
        let model = defaults.string(forKey: RefinementProviderID.ollama.modelPreferenceKey)
            ?? RefinementProviderID.ollama.defaultModel
            ?? "qwen2.5:7b"

        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?
                .appendingPathComponent("v1/chat/completions") else {
            throw ProviderError.invalidBaseURL(baseURLString)
        }

        let userMessage = RefinementMessageBuilder.userMessage(transcript: transcript, context: context)

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0.1,
            "stop": RefinementStopSequences.openAICompatible,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMessage]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer ollama",    forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.unreachable(baseURLString)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let first = decoded.choices.first else {
                throw ProviderError.malformedResponse
            }
            return RefinementOutputSanitizer.sanitize(first.message.content)
        } catch {
            throw ProviderError.malformedResponse
        }
    }
}
