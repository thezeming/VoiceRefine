import Foundation

/// Encodes and decodes the per-app system-prompt overrides stored under
/// `PrefKey.perAppSystemPrompts` as a JSON-encoded `[String: String]`.
/// Keys are bundle IDs (e.g. "com.apple.mail"), values are override prompts.
///
/// Decode failures (corruption, hand-editing) fall back to `[:]` with a
/// warning log rather than crashing — the stored key is simply reset on the
/// next save.
enum PerAppPromptStore {
    /// Returns the current override dictionary from UserDefaults.
    static func load() -> [String: String] {
        let raw = UserDefaults.standard.string(forKey: PrefKey.perAppSystemPrompts) ?? ""
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            return decoded
        } catch {
            NSLog("VoiceRefine: PerAppPromptStore decode failed (\(error)); resetting to empty")
            return [:]
        }
    }

    /// Persists the override dictionary to UserDefaults.
    static func save(_ overrides: [String: String]) {
        do {
            let data = try JSONEncoder().encode(overrides)
            let str = String(data: data, encoding: .utf8) ?? ""
            UserDefaults.standard.set(str, forKey: PrefKey.perAppSystemPrompts)
        } catch {
            NSLog("VoiceRefine: PerAppPromptStore encode failed (\(error))")
        }
    }
}
