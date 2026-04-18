# VoiceRefine

Local-first macOS menu-bar dictation. Hold **⌥ Space**, speak, release —
get cleaned-up text pasted into the frontmost app. Pipeline is
**audio → local Whisper transcription → local LLM refinement with context → paste**.

Everything runs on-device by default. No API keys, no cloud, no per-use
cost, no data leaving the machine. Cloud providers (Groq/OpenAI for
transcription, Anthropic/OpenAI/OpenAI-compatible for refinement) are
available as optional alternatives — keys go in the macOS Keychain when
used.

Think Superwhisper / Wispr Flow, but hackable, local-first, and free.

---

## Requirements

- **Apple Silicon Mac** (arm64). Intel not supported — WhisperKit targets
  the Neural Engine.
- **macOS 14** (Sonoma) or later.
- **Xcode Command Line Tools** with Swift 5.10+ (`xcode-select --install`).
  The full Xcode.app is **not** required.
- **Ollama** (optional, recommended) — default local refiner.
  `brew install ollama && ollama serve`, then the onboarding wizard can
  pull `llama3.2:3b` for you (~2 GB).

## Build & run

```bash
make build       # compile the Swift executable
make bundle      # assemble build/VoiceRefine.app
make run         # bundle + open (menu bar icon appears on the right)
make debug-run   # bundle + foreground launch with NSLog on stdout
make clean       # remove build artefacts
```

The build produces a non-sandboxed, ad-hoc signed `.app`. The first
launch shows a onboarding window walking through:

1. **Microphone access** — required for recording.
2. **Accessibility access** — required for synthesized ⌘V paste and for
   capturing the frontmost window's title / selected text. Flip
   **VoiceRefine** on under *System Settings → Privacy & Security →
   Accessibility*; the onboarding closes automatically when detected.
3. **Whisper model** — `openai_whisper-base.en` (~142 MB) downloads on
   first recording to
   `~/Library/Application Support/VoiceRefine/models/whisper/`.
4. **Ollama** — the onboarding shows install / running / model-pulled
   status with action buttons. If you skip Ollama, the refiner falls
   back to **No-Op** (Whisper output pasted unchanged).

Reopen the onboarding any time from the mic-icon menu → **Onboarding…**.

## Using it

- Hold **⌥ Space**, speak (0.3 s – 120 s), release. Menu bar icon is red
  while recording.
- Cleaned text pastes at the cursor after transcription + refinement.
- Your previous clipboard is restored ~0.5 s after paste.
- Change the hotkey, provider, model, system prompt, or glossary from
  **Settings…** (tabbed window).

### Tip: crowded menu bar

Menu-bar apps on notched MacBooks can hide behind the notch when you
have many running apps with icons. If you can't see VoiceRefine's mic
icon, quit one or two other menu-bar apps and it will reappear.

## Project layout

```
Package.swift                                    # SPM manifest — HotKey + WhisperKit deps
Makefile                                         # build + bundle + run targets
Resources/Info.plist                             # LSUIElement, mic usage description, etc.
Sources/VoiceRefine/
  App/                                           # main.swift, AppDelegate, NotificationDispatcher
  Audio/                                         # AudioRecorder, WAVEncoder
  Context/                                       # ContextGatherer (AXUIElement)
  Hotkey/                                        # HotkeyManager (wraps HotKey SPM pkg)
  MenuBar/                                       # NSStatusItem + main menu
  Onboarding/                                    # Accessibility + Onboarding windows, OllamaDetector
  Paste/                                         # PasteEngine (cmd+V synthesis)
  Pipeline/                                      # DictationPipeline orchestrator
  Refinement/                                    # Ollama / NoOp / OpenAI / Anthropic / OpenAI-compat
  Settings/                                      # Tabs + Keychain + Preferences
  Transcription/                                 # WhisperKit + Groq + OpenAI Whisper
PLAN.md                                          # design source of truth
CLAUDE.md                                        # invariants, decisions log, gotchas
```

## Troubleshooting

- **Paste does nothing.** Check *System Settings → Privacy & Security →
  Accessibility* — the app must be listed and enabled. Killing and
  relaunching helps on older macOS versions.
- **"Ollama installed, not running"** — run `ollama serve` in Terminal
  or open *Ollama.app*.
- **Slow first recording** — WhisperKit downloads the model on the
  first press (~142 MB). Subsequent recordings are fast.
- **Refinement is too aggressive / off-topic** — the default
  `llama3.2:3b` is small. Try `ollama pull qwen2.5:7b` (or another
  instruction-tuned 7B model) and select it in Settings → Refinement.
- **No network wanted** — once Whisper is downloaded and Ollama has its
  model, unplug wifi and the full pipeline still works. Verify with
  Little Snitch or `nettop`.

## License

MIT — see [LICENSE](LICENSE).
