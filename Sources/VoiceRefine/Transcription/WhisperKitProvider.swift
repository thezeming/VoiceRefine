import Foundation
import WhisperKit

/// Local transcription via WhisperKit. Models are fetched once into
/// `~/Library/Application Support/VoiceRefine/models/whisper/<variant>/`
/// and reused afterwards — satisfying PLAN's "no network after the initial
/// model download" invariant.
final class WhisperKitProvider: TranscriptionProvider {
    static let providerID = TranscriptionProviderID.whisperKit

    enum ProviderError: Error, CustomStringConvertible {
        case emptyAudio
        case modelLoadFailed(Error)
        case transcribeFailed(Error)
        case tokenizerFetchFailed(repo: String, file: String, underlying: Error)

        var description: String {
            switch self {
            case .emptyAudio:                    "Audio buffer is empty."
            case .modelLoadFailed(let err):      "WhisperKit could not load model: \(err.localizedDescription)"
            case .transcribeFailed(let err):     "WhisperKit transcription failed: \(err.localizedDescription)"
            case .tokenizerFetchFailed(let repo, let file, let err):
                "Could not fetch tokenizer file '\(file)' from huggingface.co/\(repo): \(err.localizedDescription). Check your internet connection or proxy settings."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    // MARK: - Paths

    static var downloadBaseURL: URL {
        let override = UserDefaults.standard.string(forKey: PrefKey.modelStorageOverride) ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("whisper", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VoiceRefine", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    static func isModelDownloaded(_ model: String) -> Bool {
        let folder = downloadBaseURL.appendingPathComponent(model, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return (contents?.count ?? 0) > 0
    }

    /// Rough on-disk size (bytes) of each WhisperKit model we ship in the
    /// picker, used for progress estimation during `prefetch`. Not
    /// authoritative — HF Hub may change checkpoint layout — but close
    /// enough for a visual download bar. Unknown model → sensible default.
    static let approximateModelSizeBytes: [String: Int64] = [
        "openai_whisper-base.en":                    142 * 1_048_576,
        "openai_whisper-small.en":                   466 * 1_048_576,
        "openai_whisper-medium.en":                 1460 * 1_048_576,
        "openai_whisper-large-v3-v20240930_turbo":  1550 * 1_048_576
    ]

    /// Eagerly fetches + loads `model` so the first real dictation isn't
    /// delayed by a ~150 MB download and a CoreML compile. Used by the
    /// Transcription tab's "Download" button; safe to call when the model
    /// is already present (cheap re-load).
    ///
    /// `progress` is called with a value in `0.0…1.0` estimated from the
    /// on-disk footprint of the model folder relative to
    /// `approximateModelSizeBytes`. Sampled every ~500 ms on a detached
    /// poller — WhisperKit's own constructor does not expose a progress
    /// stream we can hook, so this is the best observable proxy.
    static func prefetch(
        model: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let provider = WhisperKitProvider()
        let pollTask: Task<Void, Never>?
        if let progress {
            let expected = approximateModelSizeBytes[model] ?? 150 * 1_048_576
            pollTask = Task.detached {
                while !Task.isCancelled {
                    let bytes = folderSizeBytes(for: model)
                    let frac = min(0.99, Double(bytes) / Double(expected))
                    progress(frac)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        } else {
            pollTask = nil
        }
        defer {
            pollTask?.cancel()
            progress?(1.0)
        }
        try await provider.ensureLoaded(model: model)
    }

    /// Recursive byte-size of the model directory, or 0 if missing.
    private static func folderSizeBytes(for model: String) -> Int64 {
        let folder = downloadBaseURL.appendingPathComponent(model, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Transcription

    func transcribe(audio: Data, model: String) async throws -> String {
        guard !audio.isEmpty else { throw ProviderError.emptyAudio }

        try await ensureLoaded(model: model)

        let samples = Self.int16PCMToFloat(audio)
        guard !samples.isEmpty else { throw ProviderError.emptyAudio }

        guard let whisperKit else { return "" }
        do {
            let started = Date()
            NSLog("VoiceRefine: WhisperKit transcribe start (\(samples.count) samples on '\(model)')")
            let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: samples)
            NSLog("VoiceRefine: WhisperKit transcribe done in \(String(format: "%.2fs", Date().timeIntervalSince(started)))")
            let joined = results.map(\.text).joined(separator: " ")
            return joined.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            throw ProviderError.transcribeFailed(error)
        }
    }

    // MARK: - Model loading

    private func ensureLoaded(model: String) async throws {
        if let wk = whisperKit, loadedModel == model, wk.modelState == .loaded {
            return
        }
        let base = Self.downloadBaseURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Pre-fetch tokenizer files with explicit timeouts. WhisperKit's
        // internal tokenizer fetch (via swift-transformers' AutoTokenizer) has
        // no per-request timeout — a network blip or HF rate-limit can hang
        // model load forever with no UI feedback. Doing the fetch ourselves
        // means a clear typed error instead of an infinite spinner.
        try await Self.prefetchTokenizer(forModel: model, into: base)

        let config = WhisperKitConfig(
            model: model,
            downloadBase: base,
            verbose: false,
            logLevel: .info,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )

        do {
            let started = Date()
            NSLog("VoiceRefine: loading Whisper model '\(model)' from \(base.path)")
            let wk = try await WhisperKit(config)
            self.whisperKit = wk
            self.loadedModel = model
            NSLog("VoiceRefine: Whisper model '\(model)' ready in \(String(format: "%.2fs", Date().timeIntervalSince(started)))")
        } catch let err as ProviderError {
            throw err
        } catch {
            throw ProviderError.modelLoadFailed(error)
        }
    }

    // MARK: - Tokenizer prefetch

    private static let tokenizerFetchTimeoutSeconds: Double = 30 // per file

    /// Maps a WhisperKit model identifier to its Hugging Face tokenizer repo
    /// (always `openai/whisper-...`). Mirrors `WhisperKit.ModelUtilities
    /// .tokenizerNameForVariant` — kept here so we can resolve the repo
    /// without first loading the model. Note: large-v3-turbo shares the
    /// large-v3 vocabulary, so it maps to `whisper-large-v3`.
    static func tokenizerRepo(for model: String) -> String {
        let stripped = model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .lowercased()
        // Drop optional date-stamped suffixes like `_v20240930_turbo` —
        // WhisperKit treats turbo as the v3 variant for tokenizer purposes.
        let base: String
        if stripped.contains("large-v3") {
            base = "large-v3"
        } else if stripped.contains("large-v2") {
            base = "large-v2"
        } else if stripped.hasPrefix("large") {
            base = "large"
        } else {
            base = stripped
        }
        return "openai/whisper-\(base)"
    }

    /// Files swift-transformers / HF Hub looks for in a tokenizer repo.
    /// `tokenizer.json` and `tokenizer_config.json` are required; the rest
    /// are nice-to-have and we tolerate per-file 404s.
    private static let tokenizerFiles: [(name: String, required: Bool)] = [
        ("tokenizer.json",          true),
        ("tokenizer_config.json",   true),
        ("config.json",             true),
        ("generation_config.json",  false),
        ("special_tokens_map.json", false),
        ("added_tokens.json",       false),
        ("normalizer.json",         false),
        ("preprocessor_config.json", false),
        ("vocab.json",              false),
        ("merges.txt",              false),
    ]

    private static func prefetchTokenizer(forModel model: String, into base: URL) async throws {
        let repo = tokenizerRepo(for: model)
        let folder = base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
        let marker = folder.appendingPathComponent("tokenizer.json")
        if FileManager.default.fileExists(atPath: marker.path) { return }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = tokenizerFetchTimeoutSeconds
            cfg.timeoutIntervalForResource = tokenizerFetchTimeoutSeconds * 2
            cfg.waitsForConnectivity = false
            return cfg
        }())

        NSLog("VoiceRefine: prefetching tokenizer for '\(model)' (HF repo: \(repo))")
        for entry in tokenizerFiles {
            let dest = folder.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(entry.name)")!
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    if entry.required {
                        throw ProviderError.tokenizerFetchFailed(repo: repo, file: entry.name, underlying: URLError(.badServerResponse))
                    }
                    continue
                }
                if http.statusCode == 404 {
                    if entry.required {
                        throw ProviderError.tokenizerFetchFailed(repo: repo, file: entry.name, underlying: URLError(.fileDoesNotExist))
                    }
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    if entry.required {
                        throw ProviderError.tokenizerFetchFailed(repo: repo, file: entry.name, underlying: URLError(.badServerResponse))
                    }
                    continue
                }
                try data.write(to: dest, options: .atomic)
            } catch let err as ProviderError {
                throw err
            } catch {
                if entry.required {
                    throw ProviderError.tokenizerFetchFailed(repo: repo, file: entry.name, underlying: error)
                }
                // Optional file — log and continue.
                NSLog("VoiceRefine: tokenizer prefetch skipped optional file \(entry.name) (\(error.localizedDescription))")
            }
        }
        NSLog("VoiceRefine: tokenizer cache ready at \(folder.path)")
    }

    // MARK: - Audio format helpers

    /// Converts little-endian 16-bit signed PCM into Float samples in [-1, 1],
    /// which is what WhisperKit's `audioArray` parameter expects.
    static func int16PCMToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(samples[i]) / 32768.0
            }
            return floats
        }
    }
}
