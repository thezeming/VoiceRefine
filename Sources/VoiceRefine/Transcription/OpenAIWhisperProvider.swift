import Foundation

final class OpenAIWhisperProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.openAIWhisper

    enum ProviderError: Error, CustomStringConvertible {
        case missingAPIKey
        case httpError(CloudWhisperHTTP.HTTPError)

        var description: String {
            switch self {
            case .missingAPIKey:      "No OpenAI API key. Add one in Settings → Transcription."
            case .httpError(let e):   e.description
            }
        }
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribe(audio: Data, model: String) async throws -> String {
        guard let apiKey = KeychainStore.shared.get(account: TranscriptionProviderID.openAIWhisper.apiKeyAccount ?? ""),
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
