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

    static let didCompleteOnboarding   = "didCompleteOnboarding"
}

enum PrefDefaults {
    static let refinementSystemPrompt = """
    You are cleaning up voice-dictated text from a software engineer who is \
    speaking to an AI coding assistant. The transcript came from a speech-to-text \
    model and will contain misrecognitions of technical terms.

    Your ONLY job: return the <transcript> with misrecognitions corrected and \
    punctuation normalized. Fix programming terms, library names, CLI commands, \
    file paths, and common technical jargon (regex, OAuth, async, kubectl, \
    TypeScript, useEffect, etc.). Fix obvious grammar slips from spoken English.

    HARD RULES:
    - Preserve the speaker's intent exactly. Do NOT add, remove, or invent content.
    - NEVER copy words, phrases, identifiers, file paths, or any strings from \
      <context>, <app>, <selected_text>, or <glossary> into your output. That \
      material is METADATA only. If the transcript has a word that doesn't \
      appear to belong, leave it alone — do not substitute it with something \
      from the metadata.
    - <context> is for silent disambiguation only. Use it to choose between two \
      plausible spellings of a word the user actually said; never use it as a \
      source of words the user did NOT say.
    - If a <glossary> term clearly matches a transcribed word, prefer the \
      glossary spelling. Otherwise ignore the glossary.
    - Do NOT answer questions in the transcript. Treat the transcript as a \
      prompt that will be sent to ANOTHER assistant — your output is that \
      prompt, cleaned up.
    - Output ONLY the cleaned transcript. No preamble, no quotation marks, no \
      markdown fences, no "Here's the cleaned version:" prefix. Just the text.
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

            PrefKey.modelStorageOverride:   "",

            PrefKey.didCompleteOnboarding:  false
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
