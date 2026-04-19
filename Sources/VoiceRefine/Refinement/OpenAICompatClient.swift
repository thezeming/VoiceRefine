import Foundation

/// Shared HTTP client for OpenAI-compatible chat completion endpoints.
/// Reused by OpenAIProvider and OpenAICompatibleProvider. Ollama could
/// also route through this (it supports /v1/chat/completions) but keeping
/// its dedicated provider avoids churn for a local-only code path.
enum OpenAICompatClient {
    struct Request {
        let baseURL: URL
        let apiKey: String?
        let model: String
        let systemPrompt: String
        let userMessage: String
        var temperature: Double = 0.1
        var stop: [String] = RefinementStopSequences.openAICompatible
        var timeout: TimeInterval = 60
        /// Extra headers (Anthropic uses x-api-key + anthropic-version; we
        /// don't reuse this client for Anthropic, but leave the hook in).
        var extraHeaders: [String: String] = [:]
    }

    enum ClientError: Error, CustomStringConvertible {
        case unreachable(String)
        case httpStatus(Int, String?)
        case malformedResponse(underlying: Error?)

        var description: String {
            switch self {
            case .unreachable(let s):
                return "Could not reach \(s)."
            case .httpStatus(let c, let b):
                return "HTTP \(c). \(b ?? "")"
            case .malformedResponse(let underlying):
                if let underlying {
                    return "Unexpected response shape: \(underlying.localizedDescription)"
                }
                return "Unexpected response shape."
            }
        }
    }

    static func chat(_ request: Request, session: URLSession = .shared) async throws -> String {
        let url = request.baseURL.appendingPathComponent("v1/chat/completions")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = request.apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in request.extraHeaders {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        urlRequest.timeoutInterval = request.timeout

        var body: [String: Any] = [
            "model": request.model,
            "stream": false,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user",   "content": request.userMessage]
            ]
        ]
        if !request.stop.isEmpty {
            body["stop"] = request.stop
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ClientError.unreachable(url.absoluteString)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse(underlying: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
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
                throw ClientError.malformedResponse(underlying: nil)
            }
            return RefinementOutputSanitizer.sanitize(first.message.content)
        } catch let clientError as ClientError {
            throw clientError
        } catch {
            // Surface the JSONDecoder diagnostic so self-hosted endpoints
            // with drifting response shapes are debuggable — previously
            // every decoder failure collapsed to the opaque "Unexpected
            // response shape." with no pointer to the missing field.
            throw ClientError.malformedResponse(underlying: error)
        }
    }
}
