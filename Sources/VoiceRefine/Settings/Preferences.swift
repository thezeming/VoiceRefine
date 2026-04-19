import AppKit

enum PrefKey {
    static let selectedTranscriptionProvider = "selectedTranscriptionProvider"
    static let selectedRefinementProvider    = "selectedRefinementProvider"

    static let glossary                = "glossary"
    static let refinementSystemPrompt  = "refinementSystemPrompt"
    static let startAtLogin            = "startAtLogin"
    static let playStartStopSound      = "playStartStopSound"

    static let modelStorageOverride    = "modelStorageOverride"

    static let didCompleteOnboarding   = "didCompleteOnboarding"

    static let contextCaptureBeforeCursor   = "contextCaptureBeforeCursor"
    static let contextBeforeCursorCharLimit = "contextBeforeCursorCharLimit"

    static let disableDiagnosticLogs        = "disableDiagnosticLogs"

    /// Newline-separated words/phrases accumulated by the "Correct last…"
    /// flow. Stored in the same style as `glossary` (plain newline-delimited
    /// text). Wiring into refinement context is a follow-up task.
    static let learnedGlossary              = "learnedGlossary"

    static let perAppSystemPrompts          = "perAppSystemPrompts"
    static let hotkeyGesture                = "hotkeyGesture"
    static let showRecordingIndicator       = "showRecordingIndicator"
}

enum ContextLimits {
    static let beforeCursorMin  = 200
    static let beforeCursorMax  = 5000
    static let beforeCursorStep = 100
}

enum PrefDefaults {
    static let refinementSystemPrompt = """
    You clean up voice-dictated text from a software engineer talking to an \
    AI coding assistant. The input came from a speech-to-text model and will \
    contain misrecognitions of technical terms.

    Your ONLY job: return the <transcript> with misrecognitions corrected and \
    punctuation normalized. Fix programming terms, library names, CLI commands, \
    file paths, and technical jargon (regex, OAuth, async, kubectl, TypeScript, \
    useEffect, etc.). Fix obvious grammar slips from spoken English.

    HARD RULES:
    - Preserve the speaker's intent exactly. Do NOT add, remove, or invent content.
    - NEVER copy words, phrases, identifiers, file paths, or any strings from \
      <context>, <app>, <selected_text>, <text_before_cursor>, or <glossary> \
      into your output. That material is METADATA only. If the transcript has \
      a word that doesn't appear to belong, leave it alone — do not substitute \
      it with something from the metadata.
    - <context> is for silent disambiguation only: pick between two plausible \
      spellings of a word the user actually said. It is never a source of new \
      words.
    - <text_before_cursor> shows what the user was typing just before dictating. \
      Read it silently to resolve ambiguous pronouns or ongoing subjects — \
      never continue, complete, or quote it.
    - If a <glossary> term clearly matches a transcribed word, prefer the \
      glossary spelling. Otherwise ignore the glossary.
    - Do NOT answer questions in the transcript. Treat the transcript as a \
      prompt that will be sent to ANOTHER assistant — your output is that \
      prompt, cleaned up.
    - Never write the words "transcript", "context", "metadata", "cleaned", \
      "output", or "here's" as a prefix to your response. Never wrap the \
      response in quotes, backticks, or markdown fences. Begin your response \
      with the first word of the cleaned text.

    EXAMPLE

    Input:
    <transcript>
    so um please refactor the off middleware to use a sink await and check that \
    the use effect hook in account dot ts isn't re rendering twice
    </transcript>

    Output:
    Please refactor the auth middleware to use async/await and check that the \
    useEffect hook in Account.ts isn't re-rendering twice.
    """

    static func registerAll() {
        // Fresh-install default: Apple SpeechAnalyzer on macOS 26+ (model
        // managed by the OS — zero bundled asset), WhisperKit elsewhere.
        // UserDefaults.register() only fires when the key is unset, so
        // existing users keep whatever they already chose.
        let defaultTranscription: String = {
            if #available(macOS 26, *) {
                return TranscriptionProviderID.appleSpeech.rawValue
            }
            return TranscriptionProviderID.whisperKit.rawValue
        }()

        var defaults: [String: Any] = [
            PrefKey.selectedTranscriptionProvider: defaultTranscription,
            PrefKey.selectedRefinementProvider:    RefinementProviderID.ollama.rawValue,

            PrefKey.glossary:               "",
            PrefKey.refinementSystemPrompt: refinementSystemPrompt,
            PrefKey.startAtLogin:           false,
            PrefKey.playStartStopSound:     false,

            PrefKey.modelStorageOverride:   "",

            PrefKey.didCompleteOnboarding:  false,

            PrefKey.contextCaptureBeforeCursor:   true,
            PrefKey.contextBeforeCursorCharLimit: 1500,

            PrefKey.disableDiagnosticLogs:        false,

            PrefKey.learnedGlossary:              "",

            PrefKey.perAppSystemPrompts:          "",
            PrefKey.hotkeyGesture:                HotkeyGesture.doubleTapShift.rawValue,
            PrefKey.showRecordingIndicator:       true
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
