import Foundation

enum OllamaState: Equatable {
    case notInstalled
    case installedButNotRunning
    case running
}

/// Detects whether Ollama is installed + reachable, lists pulled models,
/// and can pull a model. Uses the native `/api/...` endpoints (not the
/// OpenAI-compat `/v1/...`) because only the native API exposes tags /
/// pull.
final class OllamaDetector: @unchecked Sendable {
    // @unchecked Sendable: holds only a let URLSession; all methods are
    // async and stateless between calls — no mutable instance state.
    static let shared = OllamaDetector()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - State

    func check() async -> OllamaState {
        if await isRunning() {
            return .running
        }
        return installedBinaryPath() != nil ? .installedButNotRunning : .notInstalled
    }

    func isRunning(timeout: TimeInterval = 0.5) async -> Bool {
        guard let url = tagsURL() else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    /// Searches a small set of canonical install paths. Intentionally avoids
    /// shelling out to `which` — that would require spawning `/bin/sh` and
    /// reading $PATH from a login shell, which is flaky.
    func installedBinaryPath() -> String? {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Also check the desktop app's bundled binary:
        let appBinary = "/Applications/Ollama.app/Contents/Resources/ollama"
        if FileManager.default.isExecutableFile(atPath: appBinary) {
            return appBinary
        }
        return nil
    }

    // MARK: - Models

    func listInstalledModels() async -> [String] {
        guard let url = tagsURL() else { return [] }
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map(\.name).sorted()
        } catch {
            return []
        }
    }

    /// Pulls a model. The handler reports coarse progress (percent 0…1 and
    /// a human-readable status line). Streaming NDJSON is consumed
    /// incrementally so the caller can update a progress bar as bytes
    /// arrive. The `progress` closure is always invoked on the main
    /// actor so SwiftUI `@State` mutations inside it are sound.
    func pullModel(
        name: String,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws {
        guard let url = baseURL()?.appendingPathComponent("api/pull") else {
            throw OllamaProvider.ProviderError.invalidBaseURL(currentBaseURLString())
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        request.timeoutInterval = 600

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaProvider.ProviderError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, nil)
        }

        struct PullChunk: Decodable {
            let status: String
            let total: Int?
            let completed: Int?
            let error: String?
        }

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8) else { continue }
            let chunk = try? JSONDecoder().decode(PullChunk.self, from: data)
            guard let chunk else { continue }
            if let err = chunk.error {
                throw NSError(domain: "Ollama.pull", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
            }
            let pct: Double
            if let total = chunk.total, let completed = chunk.completed, total > 0 {
                pct = Double(completed) / Double(total)
            } else {
                pct = -1 // indeterminate
            }
            await MainActor.run { progress(pct, chunk.status) }
        }
    }

    // MARK: - URL helpers

    private func currentBaseURLString() -> String {
        UserDefaults.standard.string(forKey: RefinementProviderID.ollama.baseURLPreferenceKey)
            ?? "http://localhost:11434"
    }

    private func baseURL() -> URL? {
        URL(string: currentBaseURLString().trimmingCharacters(in: .whitespaces))
    }

    private func tagsURL() -> URL? {
        baseURL()?.appendingPathComponent("api/tags")
    }
}
