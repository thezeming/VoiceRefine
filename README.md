# VoiceRefine

Local-first macOS menu-bar dictation. Hold a hotkey, speak, get cleaned-up text
pasted into the frontmost app. Pipeline is **audio → local Whisper transcription
→ local LLM refinement with context → paste**. Everything runs on-device by
default. Cloud providers are supported as optional alternatives.

See `PLAN.md` for the full design and phased build plan, and `CLAUDE.md` for
workflow / invariants / gotchas.

## Requirements

- Apple Silicon Mac (arm64). Intel Macs are not supported — WhisperKit targets
  the Neural Engine.
- macOS 14 (Sonoma) or later.
- Xcode Command Line Tools (Swift 5.10+). Full Xcode.app is **not** required.
  Install CLT with `xcode-select --install`.
- (Later phases) [Ollama](https://ollama.com) running locally as the default
  refinement provider: `brew install ollama && ollama serve`, then
  `ollama pull llama3.2:3b`.

## Build & run

```bash
make build      # compile the Swift executable
make bundle     # assemble build/VoiceRefine.app
make run        # bundle + open the app (menu bar icon appears)
make debug-run  # bundle + launch in foreground with stdout visible
make clean      # remove build artefacts
```

The build produces a non-sandboxed, ad-hoc signed `.app` bundle. The
Accessibility permission must be granted manually (from Phase 5 onwards) in
**System Settings → Privacy & Security → Accessibility**.

## Project layout

```
Package.swift             # SPM manifest — HotKey + WhisperKit deps
Makefile                  # build + bundle + run targets
Resources/Info.plist      # LSUIElement, NSMicrophoneUsageDescription, etc.
Sources/VoiceRefine/
  App/                    # @main + AppDelegate
  MenuBar/                # menu bar content
  Settings/               # SwiftUI settings window
  ... more added per phase
PLAN.md                   # design source of truth
CLAUDE.md                 # invariants + phase workflow for future sessions
```

## Status

Phase 0 (scaffold) complete. Phases 1–8 roll out per `PLAN.md`.
