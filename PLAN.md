# VoiceRefine — Project Plan (Local-First)

A native macOS menu-bar app: hold a hotkey, speak, and get cleaned-up text pasted into whatever app is frontmost. Pipeline is **audio → local Whisper transcription → local LLM refinement with context → paste**.

Everything runs on-device by default. No API keys, no cloud, no per-use cost, no data leaving the machine. Cloud providers are supported as optional alternatives but are not required.

Think Superwhisper / Wispr Flow, but hackable, local-first, and free.

---

## Goals

- Proper native macOS menu-bar app (not a script, not Electron).
- Push-to-talk with a configurable global hotkey.
- **Fully local by default.** Zero network calls in the default configuration.
- Two-stage pipeline with **swappable providers** at both stages.
- Cloud providers (Anthropic / OpenAI / OpenAI-compatible) remain available as alternatives; keys stored in Keychain when used.
- Refinement LLM gets **context** (frontmost app, selected text, user glossary) so it can fix misrecognitions intelligently.
- Minimal dependencies. Readable Swift code I can modify later.

## Non-goals for v1

- Windows/Linux.
- Streaming / real-time transcription (push-to-talk is fine).
- App Store distribution / notarization.
- Multi-user / cloud sync.
- Bundling Ollama itself in the app — user installs it separately.

---

## Tech stack

- **Language:** Swift 5.9+
- **UI:** SwiftUI for settings, AppKit for menu bar / hotkey / paste
- **Min macOS:** 14.0 (Sonoma)
- **Architecture:** Apple Silicon required (arm64). Intel Macs out of scope — WhisperKit targets the Neural Engine.
- **Audio:** `AVAudioEngine` + `AVAudioFile`
- **Transcription:** [`WhisperKit`](https://github.com/argmaxinc/WhisperKit) via SPM — runs Whisper locally on the Apple Neural Engine. On macOS 26+ Apple's built-in `SpeechAnalyzer` / `SpeechTranscriber` (from the `Speech` framework, no SPM dep) is also available as `AppleSpeechProvider`.
- **Local LLM:** [Ollama](https://ollama.com) running as a user-installed daemon on `localhost:11434`. We call its OpenAI-compatible endpoint.
- **Global hotkey:** [`HotKey`](https://github.com/soffes/HotKey) Swift package.
- **Secrets:** Keychain Services API (used only when the user opts into a cloud provider).
- **HTTP:** `URLSession` only.
- **Package manager:** Swift Package Manager.
- **Build:** Xcode project at repo root, also buildable via `xcodebuild`.
- **App must be non-sandboxed** — we need the Accessibility API for paste synthesis and reading selected text.

---

## Architecture

```
[Global Hotkey Listener]
         ↓ key held
[Audio Recorder]  →  in-memory 16 kHz mono PCM buffer
         ↓ key released
[Transcription Provider]  ──►  raw transcript
         ↓
[Context Gatherer]  ──►  { frontApp, windowTitle, selectedText, glossary }
         ↓
[Refinement Provider]  ──►  cleaned transcript
         ↓
[Paste Engine]  ──►  pasteboard + synthesized ⌘V
```

Each stage is a protocol. Providers implement the protocol and are chosen at runtime from settings.

---

## Providers

### `TranscriptionProvider` protocol

```swift
protocol TranscriptionProvider {
    static var id: String { get }
    static var displayName: String { get }
    static var isLocal: Bool { get }
    static var requiredKeys: [String] { get }
    static var availableModels: [String] { get }

    func transcribe(audio: Data, model: String) async throws -> String
}
```

**Implementations:**
- **`WhisperKitProvider`** (local; fresh-install default on macOS 14/15). Wraps the `WhisperKit` package. Models: `openai_whisper-base.en`, `openai_whisper-small.en`, `openai_whisper-medium.en`, `openai_whisper-large-v3-v20240930_turbo`. Models download on first use to `~/Library/Application Support/VoiceRefine/models/whisper/`.
- **`AppleSpeechProvider`** (local; fresh-install default on macOS 26+). Uses Apple's `SpeechAnalyzer` + `SpeechTranscriber` from the system `Speech` framework — no SPM dep, no per-app model storage (assets managed by `AssetInventory`). The "Model" field in Settings is a locale id (`en_US`, `en_GB`, …); the picker is populated from `SpeechTranscriber.supportedLocales` at runtime. Gated `@available(macOS 26, *)`; invisible to users on older OSes via `TranscriptionProviderID.visibleCases`.
- `GroqWhisperProvider` (optional, cloud).
- `OpenAIWhisperProvider` (optional, cloud).

### `RefinementProvider` protocol

```swift
protocol RefinementProvider {
    static var id: String { get }
    static var displayName: String { get }
    static var isLocal: Bool { get }
    static var requiredKeys: [String] { get }
    static var availableModels: [String] { get }

    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String
}

struct RefinementContext {
    let frontmostApp: String?
    let windowTitle: String?
    let selectedText: String?
    let glossary: String?
}
```

**Implementations for v1:**
- **`OllamaProvider`** (default, local). Talks to `http://localhost:11434/v1/chat/completions`. Auto-lists installed models via `GET /api/tags`. Default model: `qwen2.5:7b`. Other choices: `llama3.2:3b` (faster but more prone to leaking envelope tags), `mistral:7b`.
- `NoOpProvider` (local, zero-dep). Returns transcript unchanged. Useful if the user doesn't want Ollama.
- `OpenAICompatibleProvider` (cloud or self-hosted) — user-configurable base URL + key + model. Covers LM Studio, Together, Fireworks, etc.
- `AnthropicProvider` (cloud, optional). Default: `claude-sonnet-4-6`.
- `OpenAIProvider` (cloud, optional). Default: `gpt-4o-mini`.

---

## Features

### v1 (MVP)
1. Menu-bar-only app (`LSUIElement = YES`, no dock icon).
2. Menu bar icon with four states: **idle / recording / processing / error**.
3. Global push-to-talk hotkey. Default: `⌥ Space`. Remappable.
4. Audio capture while hotkey held; stop on release. Minimum 0.3s, maximum 120s.
5. Full pipeline: local transcription → local refinement → paste into frontmost app.
6. Settings window (SwiftUI), four tabs: **General**, **Transcription**, **Refinement**, **Advanced**.
7. API keys in Keychain (only used if user picks a cloud provider); prefs in `UserDefaults`.
8. Permissions flow: microphone + Accessibility.
9. **First-run onboarding**:
   - Microphone permission.
   - Accessibility permission (with deep link to System Settings).
   - Download default Whisper model (`base.en`, ~142 MB) with progress bar.
   - Detect Ollama. If not installed, show instructions (`brew install ollama` or ollama.com) and an option to skip (fall back to `NoOpProvider`).
   - If Ollama is installed but `qwen2.5:7b` isn't pulled, offer to pull it.
10. User-visible error notifications (`UNUserNotificationCenter`) on pipeline failures — never silent.

### v1.1 — Context gathering
- Capture frontmost app + window title via `NSWorkspace` and `AXUIElement`.
- Capture currently selected text via `kAXSelectedTextAttribute`.
- User-editable **glossary** (freeform text from settings).
- All passed to the refinement provider, XML-tagged:
  ```
  <context>
    <app>Terminal</app>
    <window>claude-code — ~/projects/foo</window>
    <selected_text>...</selected_text>
  </context>
  <glossary>
  ...user glossary...
  </glossary>
  <transcript>
  ...raw whisper output...
  </transcript>
  ```

### v1.2 — Polish
- Optional start/stop sound effect.
- In-memory transcription history (last 20), viewable from menu.
- "Retry last" menu item if the pipeline errored.
- App icon.

---

## Default refinement system prompt

Baked-in but user-editable. The authoritative copy lives in
`PrefDefaults.refinementSystemPrompt` (`Sources/VoiceRefine/Settings/Preferences.swift`).
Summary of the contract it imposes on the model:

- Return only the cleaned `<transcript>` — no preamble, no quotes, no fences.
- Treat `<context>`, `<selected_text>`, `<text_before_cursor>`, and
  `<glossary>` as METADATA: read silently for disambiguation, never copy
  words from them into the output.
- Do not answer questions in the transcript; the transcript is a prompt
  destined for a downstream assistant.
- Includes one before/after example. The example matters more than any
  amount of additional rule text for small local models — Qwen 2.5 7B
  follows a single demonstration far more reliably than longer
  instruction blocks.

A deterministic post-processor (`RefinementOutputSanitizer`) runs on every
provider's reply as a safety net for the failure modes the prompt cannot
fully suppress: leading preambles ("Here's the cleaned text:"), wrapping
quotes/backticks, markdown fences, and stray protocol tags. The model
also receives `stop` / `stop_sequences` covering `</transcript>`,
`<context>`, `</context>`, `<glossary>`, `</glossary>` so an
envelope-echo response is truncated server-side.

---

## Settings window — fields

**General tab**
- Hotkey recorder (SwiftUI custom control).
- Start at login toggle (`SMAppService.mainApp.register()`).
- Play sound on record start/stop.
- Glossary — multi-line text editor.
- Refinement system prompt — multi-line text editor with "Reset to default" button.

**Transcription tab**
- Provider picker (WhisperKit / Groq / OpenAI).
- Model picker. For WhisperKit, shows model size in MB and download status ("Downloaded" / "Not downloaded — click to download").
- "Download model" button with progress bar for WhisperKit models.
- API key field (visible only for cloud providers; reads/writes Keychain).
- "Test" button — runs a 1-second silent clip, reports status.

**Refinement tab**
- Provider picker (Ollama / NoOp / OpenAI-compatible / Anthropic / OpenAI).
- For Ollama: model picker populated by calling `GET http://localhost:11434/api/tags`. "Pull model" button for standard choices not yet pulled. Status indicator ("✓ Ollama running" / "✗ Ollama not running — start with `ollama serve`").
- For cloud providers: model picker + API key field.
- For OpenAI-compatible: base URL field.
- "Test" button — sends a canned prompt, shows response + latency.

**Advanced tab**
- Override model storage location.
- Clear transcription history.
- Reveal logs folder in Finder.
- Clear Keychain entries (per provider).

---

## Storage

- **Keychain** (`service = bundle id`, `account = "<provider-id>.<key-name>"`). Only used if cloud providers are configured.
- **UserDefaults** for selected providers, selected models, hotkey, sound toggle, start-at-login, system prompt, glossary, history.
- **Whisper models** → `~/Library/Application Support/VoiceRefine/models/whisper/` (managed by WhisperKit).
- **Logs** → `~/Library/Logs/VoiceRefine/`.

---

## Ollama integration notes

- Ollama exposes an OpenAI-compatible endpoint at `http://localhost:11434/v1`. Call it exactly like OpenAI; use a dummy API key.
- Ollama's own API is at `http://localhost:11434/api/...`. We use it for two things only: `GET /api/tags` (list installed models) and `POST /api/pull` (pull a model with progress).
- "Is Ollama running" check: `GET http://localhost:11434/api/tags` with a 500 ms timeout. Success → running. Connection refused → not running.
- "Installed but not running": shell out `which ollama`. If present but endpoint not responding, suggest `ollama serve`.
- "Not installed": `which ollama` returns non-zero. Show install instructions.
- **Do not auto-start Ollama.** It's a separate app managed by the user.

---

## Paste mechanism

1. Save current `NSPasteboard.general` contents.
2. Write refined text to pasteboard.
3. Synthesize `⌘V` via two `CGEvent` calls (key down + key up with `.maskCommand`).
4. After 500 ms, restore original pasteboard contents.

Requires **Accessibility permission**. On first launch, check `AXIsProcessTrusted()`; if false, show a window with a button that opens:
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

---

## Build phases

Work through these **in order**. At the end of each phase, commit to git and show me a concrete manual test. Don't start the next phase until I confirm.

### Phase 0 — Scaffold
- Xcode project `VoiceRefine.xcodeproj`, single app target, arm64 only.
- `LSUIElement = YES`. No dock icon, no main window on launch.
- Menu bar item with placeholder SF Symbol (`mic`) and a menu: "Settings…", "Quit".
- Empty SwiftUI settings window opened from the menu.
- Add `HotKey` and `WhisperKit` via SPM.
- Remove sandbox entitlement.
- `.gitignore`, README stub.

**✅ Test:** `xcodebuild` succeeds. App runs, appears in menu bar, no dock icon, Settings opens an empty window, Quit works.

### Phase 1 — Keychain + settings skeleton
- `KeychainStore` with `get/set/delete`.
- `Preferences` wrapper around `UserDefaults`.
- Settings window with four tabs, all fields wired to stores. Providers are stubs — one option per picker.

**✅ Test:** Enter a dummy key, quit, relaunch — key persists. Verify in Keychain Access.app.

### Phase 2 — Hotkey + audio capture
- `HotkeyManager` using `HotKey` package.
- `AudioRecorder` using `AVAudioEngine`. Records 16 kHz mono PCM into a `Data` buffer while hotkey held.
- Menu bar icon turns red while recording.
- On release, write buffer to `~/Library/Caches/VoiceRefine/last.wav` and log duration + bytes.

**✅ Test:** Hold hotkey 3 seconds while speaking. Play back the wav — should sound clear.

### Phase 3 — Local transcription (WhisperKit)
- `TranscriptionProvider` protocol.
- `WhisperKitProvider` implementation.
- Model download UI: on first use, show progress window while WhisperKit pulls `base.en`.
- Wire Phase 2 → Phase 3: on hotkey release, transcribe the buffer in-memory, log raw text.
- Menu bar icon shows "processing" state during transcription.

**✅ Test:** First run downloads the model. Subsequent runs: speak "refactor the OAuth middleware to use async await." Log shows raw Whisper output. No network traffic after the initial model download (verify with Little Snitch or equivalent).

### Phase 4 — Local refinement (Ollama)
- `RefinementProvider` protocol.
- `OllamaProvider` implementation talking to `http://localhost:11434/v1/chat/completions`.
- Onboarding checks for Ollama; if missing, shows install instructions.
- `OllamaProvider.listModels()` hits `/api/tags`.
- If `qwen2.5:7b` isn't pulled, settings shows a "Pull" button that POSTs to `/api/pull` and streams progress.
- Wire Phase 3 → Phase 4. Log raw + refined text. No context yet.

**✅ Test:** Deliberately mumble a technical term. Raw output is wrong; refined output is better. Still no external network traffic.

### Phase 5 — Paste engine
- `PasteEngine` with `paste(_:)` that saves/writes/synths/restores.
- Accessibility permission check on startup; if missing, show window with "Grant Accessibility" button linking to System Settings.
- Wire Phase 4 → Phase 5.

**✅ Test:** Focus a TextEdit window, hold hotkey, speak, release. Cleaned text appears at cursor. Previous clipboard is still there afterward.

### Phase 6 — Context + glossary
- `ContextGatherer` collects frontmost app, window title, selected text.
- Glossary from settings injected into refinement call.
- XML-tagged format as specified above.

**✅ Test:** Add a made-up project term to the glossary ("Zorblax API"). Say it aloud. Refined output contains "Zorblax API" even though Whisper will mishear it.

### Phase 7 — NoOp + cloud providers
- `NoOpProvider` (refinement).
- `OpenAICompatibleProvider` (refinement) — base URL + key + model.
- `AnthropicProvider`, `OpenAIProvider` (refinement).
- `GroqWhisperProvider`, `OpenAIWhisperProvider` (transcription).
- "Test" buttons in each tab.

**✅ Test:** Switch refinement to NoOp — raw transcript is pasted. Switch to Anthropic with a real key — still works. Switch back to Ollama.

### Phase 8 — Polish
- Error notifications via `UNUserNotificationCenter`.
- First-run onboarding window covering mic → accessibility → Whisper model download → Ollama check.
- App icon.
- README with setup steps: install the app, install Ollama (`brew install ollama && ollama serve`), pull `qwen2.5:7b`.

**✅ Test:** Delete models + Keychain entries + reset UserDefaults. Relaunch. Onboarding walks through all steps. Disconnect from wifi — app still works fully.

### Phase 9 — Apple `SpeechAnalyzer` provider (macOS 26+)

Adds Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber` (new in macOS 26) as a third **local** transcription option alongside WhisperKit. Not a replacement — both providers stay. All new code is gated `@available(macOS 26, *)` and falls through to WhisperKit on older OSes; `Package.swift` platform floor is unchanged. Build-time requires the macOS 26 SDK.

- **9.1 — Scaffolding + picker gate.** `TranscriptionProviderID.appleSpeech` case, `visibleCases` picker filter, empty `AppleSpeechProvider` that throws "not implemented yet", `AppleSpeechAssetManager` with real locale-listing + install-check. Factory + pipeline resolver handle the new case with a WhisperKit fallback.
- **9.2 — Real transcription path.** `SpeechAnalyzer(modules: [SpeechTranscriber(preset: .transcription)])` driven via `analyzeSequence(stream) + finalizeAndFinishThroughEndOfInput`. Audio format queried per-locale from `SpeechTranscriber.availableCompatibleAudioFormats` and converted via `AVAudioConverter` — hard-coding any format crashes `Speech.framework` with `EXC_BREAKPOINT` (see CLAUDE.md). `NSSpeechRecognitionUsageDescription` added to `Info.plist`.
- **9.3 — Locale-install UI.** New `AppleSpeechLocaleRow` (SwiftUI) in the Transcription tab: status badge (Installed / Downloading / Not installed / Unsupported), Download button, live progress bar via KVO on `AssetInstallationRequest.progress.fractionCompleted`. Status check switched from the nil-return heuristic to `AssetInventory.status(forModules:) == .installed`. Reserves the locale with `AssetInventory.reserve(locale:)` before download.
- **9.4 — Onboarding integration + fresh-install default flip.** `PrefDefaults.registerAll()` picks `.appleSpeech` as the fresh-install transcription default on macOS 26+ (`UserDefaults.register` only seeds unset keys so existing users' choices survive). Onboarding window replaces the fixed Whisper row with a provider-aware section — Apple Speech locale row (with a Download button + progress) when Apple Speech is selected, unchanged Whisper row otherwise.
- **9.5 — Docs.** This section, plus the `Apple SpeechAnalyzer` gotcha block and three decisions-log entries in `CLAUDE.md`.

**✅ Test (end-to-end):** On macOS 26+: wipe `selectedTranscriptionProvider` + `didCompleteOnboarding` from UserDefaults (`defaults delete com.voicerefine.VoiceRefine <key>`) and relaunch. Onboarding opens with an Apple Speech locale row. Install `en_US` (or your preferred locale) from the Download button. Dictate a short sentence — cleaned text pastes. Little Snitch / LuLu: zero outbound traffic once the asset is installed. Regression: WhisperKit remains selectable from the Transcription tab and unchanged on pre-Tahoe OSes.

---

## Implementation rules

- **Default configuration must make zero outbound network calls** once Whisper and Ollama models are downloaded. Testable invariant.
- **Never log API keys.** Redact before logging any request.
- **No force unwraps** outside IBOutlet-style always-loaded cases.
- **All async work is cancellable.** New hotkey press cancels in-flight transcription/refinement.
- **Hotkey must release cleanly** — on any failure, menu bar icon returns to idle.
- **Pasteboard must be restored** after paste, even if paste synthesis fails.
- **Dependencies:** `HotKey` and `WhisperKit` are the ONLY third-party SPM packages.
- **No analytics, no telemetry, no crash reporting service.**

---

## Suggested file structure

```
VoiceRefine/
├── VoiceRefine.xcodeproj/
├── VoiceRefine/
│   ├── App/
│   │   ├── VoiceRefineApp.swift        // @main
│   │   └── AppDelegate.swift
│   ├── MenuBar/
│   │   └── MenuBarController.swift
│   ├── Hotkey/
│   │   └── HotkeyManager.swift
│   ├── Audio/
│   │   └── AudioRecorder.swift
│   ├── Transcription/
│   │   ├── TranscriptionProvider.swift
│   │   ├── WhisperKitProvider.swift
│   │   ├── GroqWhisperProvider.swift
│   │   └── OpenAIWhisperProvider.swift
│   ├── Refinement/
│   │   ├── RefinementProvider.swift
│   │   ├── OllamaProvider.swift
│   │   ├── NoOpProvider.swift
│   │   ├── OpenAICompatibleProvider.swift
│   │   ├── AnthropicProvider.swift
│   │   └── OpenAIProvider.swift
│   ├── Context/
│   │   └── ContextGatherer.swift
│   ├── Paste/
│   │   └── PasteEngine.swift
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   ├── GeneralTab.swift
│   │   ├── TranscriptionTab.swift
│   │   ├── RefinementTab.swift
│   │   ├── AdvancedTab.swift
│   │   ├── HotkeyRecorder.swift
│   │   ├── KeychainStore.swift
│   │   └── Preferences.swift
│   ├── Onboarding/
│   │   ├── OnboardingWindow.swift
│   │   └── OllamaDetector.swift
│   ├── Pipeline/
│   │   └── DictationPipeline.swift
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Info.plist
│       └── VoiceRefine.entitlements
├── CLAUDE.md
├── PLAN.md                              // this file
└── README.md
```

---

## What I want you (Claude Code) to do

1. Read this plan top to bottom before writing any code.
2. Ask clarifying questions **only if they genuinely block you** — don't ask about naming, code style, or minor design decisions. Pick something sensible and note it in `CLAUDE.md`.
3. Create `CLAUDE.md` at the repo root and keep it updated with decisions, gotchas, and anything a future Claude session should know.
4. Work through the phases **in order**. At the end of each phase:
   - Commit to git with a clear message (`feat(phase-3): whisperkit transcription`).
   - Tell me what to test manually.
   - Stop and wait for confirmation before starting the next phase.
5. If something turns out to be wrong as you implement it, say so and propose an alternative. Don't silently deviate.
6. **Before starting**: check that my machine is Apple Silicon (`uname -m` should return `arm64`). If not, stop and tell me — WhisperKit won't work on Intel; we'd need to switch to `whisper.cpp` instead.

**Start with Phase 0.**
