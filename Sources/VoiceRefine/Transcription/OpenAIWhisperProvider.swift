import Foundation

<<<<<<< HEAD
final class OpenAIWhisperProvider: TranscriptionProvider, APIKeyed {
=======
final class OpenAIWhisperProvider: TranscriptionProvider, @unchecked Sendable {
    // @unchecked Sendable: holds only let URLSession; all methods are async.
>>>>>>> 253aabd (refactor(swift6): migrate to swift-tools-version 6.0 with strict concurrency)
    static let providerID = TranscriptionProviderID.openAIWhisper
    static let apiKeyAccount = TranscriptionProviderID.openAIWhisper.apiKeyAccount ?? ""
    static var missingAPIKeyError: any Error { ProviderError.missingAPIKey }

    enum ProviderError: CloudProviderError {
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
        let apiKey = try Self.requireAPIKey()

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
