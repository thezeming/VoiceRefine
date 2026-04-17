import Foundation

/// Shared multipart-upload helper for OpenAI-family Whisper endpoints.
/// Used by both `OpenAIWhisperProvider` and `GroqWhisperProvider`
/// — Groq mirrors OpenAI's `/openai/v1/audio/transcriptions` shape.
enum CloudWhisperHTTP {
    enum HTTPError: Error, CustomStringConvertible {
        case unreachable(String)
        case httpStatus(Int, String?)
        case malformedResponse

        var description: String {
            switch self {
            case .unreachable(let s):       "Could not reach \(s)."
            case .httpStatus(let c, let b): "HTTP \(c). \(b ?? "")"
            case .malformedResponse:        "Unexpected response shape."
            }
        }
    }

    struct Request {
        let url: URL
        let apiKey: String
        let model: String
        let wavData: Data
        var timeout: TimeInterval = 60
        var language: String? = nil
    }

    static func transcribe(_ request: Request, session: URLSession = .shared) async throws -> String {
        let boundary = "----VoiceRefineBoundary\(UUID().uuidString)"

        var body = Data()
        func appendField(name: String, value: String) {
            body.appendASCII("--\(boundary)\r\n")
            body.appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendASCII("\(value)\r\n")
        }
        appendField(name: "model", value: request.model)
        if let lang = request.language, !lang.isEmpty {
            appendField(name: "language", value: lang)
        }
        appendField(name: "response_format", value: "text")

        body.appendASCII("--\(boundary)\r\n")
        body.appendASCII("Content-Disposition: form-data; name=\"file\"; filename=\"voicerefine.wav\"\r\n")
        body.appendASCII("Content-Type: audio/wav\r\n\r\n")
        body.append(request.wavData)
        body.appendASCII("\r\n")
        body.appendASCII("--\(boundary)--\r\n")

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)",                   forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = request.timeout

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw HTTPError.unreachable(request.url.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }

        // `response_format: text` → plain text body, not JSON.
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
