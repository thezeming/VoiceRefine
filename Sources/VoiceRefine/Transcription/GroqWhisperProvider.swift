import Foundation

final class GroqWhisperProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.groq

    enum ProviderError: Error, CustomStringConvertible {
        case missingAPIKey
        case httpError(CloudWhisperHTTP.HTTPError)

        var description: String {
            switch self {
            case .missingAPIKey:      "No Groq API key. Add one in Settings → Transcription."
            case .httpError(let e):   e.description
            }
        }
    }

    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    func transcribe(audio: Data, model: String) async throws -> String {
        guard let apiKey = KeychainStore.shared.get(account: TranscriptionProviderID.groq.apiKeyAccount ?? ""),
              !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        let wav = WAVEncoder.encode(pcm: audio, sampleRate: 16_000, channels: 1, bitsPerSample: 16)

        do {
            return try await CloudWhisperHTTP.transcribe(.init(
                url: Self.endpoint,
                apiKey: apiKey,
                model: model,
                wavData: wav,
                language: "en"
            ))
        } catch let e as CloudWhisperHTTP.HTTPError {
            throw ProviderError.httpError(e)
        }
    }
}
