import AppKit

enum PrefKey {
    static let selectedTranscriptionProvider = "selectedTranscriptionProvider"
    static let selectedRefinementProvider    = "selectedRefinementProvider"

    static let glossary                = "glossary"
    static let refinementSystemPrompt  = "refinementSystemPrompt"
    static let startAtLogin            = "startAtLogin"
    static let playStartStopSound      = "playStartStopSound"

    static let hotkeyKeyCode           = "hotkeyKeyCode"
    static let hotkeyModifierFlags     = "hotkeyModifierFlags"

    static let modelStorageOverride    = "modelStorageOverride"
}

enum PrefDefaults {
    static let refinementSystemPrompt = """
    You are cleaning up voice-dictated text from a software engineer who is \
    speaking to an AI coding assistant. The transcript came from a speech-to-text \
    model and will contain misrecognitions of technical terms.

    Your job: fix likely misrecognitions of programming terms, library names, \
    CLI commands, file paths, and common technical jargon (regex, OAuth, async, \
    kubectl, TypeScript, useEffect, etc.). Fix obvious grammar slips from spoken \
    English. Normalize numbers and punctuation.

    Hard rules:
    - Preserve the speaker's intent exactly. Do not add, remove, or reinterpret content.
    - Do NOT answer questions in the transcript. Treat the transcript as a prompt \
      that will be sent to ANOTHER assistant — your output is that prompt, cleaned up.
    - If a <glossary> is provided, prefer terms from it over guesses.
    - If <context> is provided, use frontmost app and selected text to disambiguate \
      ambiguous words.
    - Output ONLY the cleaned text. No preamble, no quotation marks, no markdown \
      fences, no "Here's the cleaned version:" prefix. Just the text.
    """

    static func registerAll() {
        var defaults: [String: Any] = [
            PrefKey.selectedTranscriptionProvider: TranscriptionProviderID.whisperKit.rawValue,
            PrefKey.selectedRefinementProvider:    RefinementProviderID.ollama.rawValue,

            PrefKey.glossary:               "",
            PrefKey.refinementSystemPrompt: refinementSystemPrompt,
            PrefKey.startAtLogin:           false,
            PrefKey.playStartStopSound:     false,

            // ⌥ Space: kVK_Space = 49, NSEvent.ModifierFlags.option.rawValue.
            PrefKey.hotkeyKeyCode:          49,
            PrefKey.hotkeyModifierFlags:    Int(NSEvent.ModifierFlags.option.rawValue),

            PrefKey.modelStorageOverride:   ""
        ]

        for provider in TranscriptionProviderID.allCases {
            defaults[provider.modelPreferenceKey] = provider.defaultModel
        }
        for provider in RefinementProviderID.allCases {
            if let model = provider.defaultModel {
                defaults[provider.modelPreferenceKey] = model
            }
            defaults[provider.baseURLPreferenceKey] = (provider == .ollama) ? "http://localhost:11434" : ""
        }

        UserDefaults.standard.register(defaults: defaults)
    }
}
