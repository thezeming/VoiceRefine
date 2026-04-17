# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**VoiceRefine** — a native macOS menu-bar app (Swift/SwiftUI + AppKit) that runs a push-to-talk pipeline: audio → local Whisper transcription → local LLM refinement → paste into frontmost app. Runs fully on-device by default; cloud providers are optional. Project directory name `Hush` is the build workspace; the product/bundle is `VoiceRefine`.

**`PLAN.md` at the repo root is the design source of truth.** Read it before any implementation work. This file captures only the things a future session would otherwise have to rediscover: workflow, invariants, and gotchas.

## Current status

**Phase 0 complete.** Build system is SPM + Makefile (not Xcode project — see Decisions log). Scaffold runs as a menu-bar-only app with placeholder mic icon, empty Settings window, and Quit. Apple Silicon verified (`arm64`). Phase 1 (Keychain + settings skeleton) is next.

## Workflow — read this before writing code

- **Phases are ordered and gated.** Work through `PLAN.md` phases 0 → 8 in sequence. At the end of each phase, commit and hand the user a concrete manual test, then **stop and wait** for confirmation before starting the next phase.
- **Commit message format:** `feat(phase-N): short description` (e.g. `feat(phase-3): whisperkit transcription`). One commit per phase minimum.
- Don't ask about naming, code style, or minor design. Pick something sensible and note the decision in this file under "Decisions made along the way".
- If you discover the plan is wrong as you implement, say so and propose an alternative — don't silently deviate.

## Hard invariants (do not violate)

These are project-wide rules, not phase-specific. Breaking any of them is a regression.

1. **Apple Silicon only.** arm64 target, min macOS 14.0 (Sonoma). WhisperKit targets the Neural Engine and won't work on Intel.
2. **Non-sandboxed app.** The Accessibility API is required for synthesized paste and reading selected text. Do not add the App Sandbox entitlement.
3. **`LSUIElement = YES`.** Menu-bar only, no dock icon, no main window on launch.
4. **Default config = zero outbound network calls** once Whisper and Ollama models are pulled. This is a testable invariant — verify with Little Snitch or equivalent.
5. **SPM dependencies are capped at two:** `HotKey` (soffes) and `WhisperKit` (argmaxinc). Adding any third package needs explicit user sign-off.
6. **No analytics, no telemetry, no crash-reporting service.**
7. **Never log API keys.** Redact before logging any request.
8. **No force unwraps** outside always-loaded cases.
9. **All async work is cancellable.** A new hotkey press cancels in-flight transcription/refinement.
10. **Pasteboard must be restored** after paste, even if paste synthesis throws.
11. **Hotkey must release cleanly.** On any pipeline failure, the menu-bar icon returns to idle.
12. **Errors are user-visible** via `UNUserNotificationCenter` — never swallow silently.

## Build & run

SPM + Makefile. No `xcodebuild`, no `VoiceRefine.xcodeproj` (see Decisions log for why).

```bash
make build       # swift build -c release --arch arm64
make bundle      # build + assemble build/VoiceRefine.app (Info.plist, PkgInfo, *.bundle resources, ad-hoc codesign)
make run         # bundle + open the app (menu bar icon appears)
make debug-run   # bundle + launch in foreground with stdout visible (good for print-debugging)
make clean       # rm -rf build
make distclean   # rm -rf build .build
```

PLAN.md doesn't specify a test framework; default to XCTest if/when tests are added. Most verification in this project is manual and lives in each phase's "✅ Test" block.

### Bundle assembly notes

- `swift build --show-bin-path` gives the correct output dir; Makefile reads this at bundle time.
- SPM generates `*_*.bundle` directories for packages with resources (swift-crypto, swift-transformers). These are **flat directories, not real macOS bundles** (no inner Info.plist), so `codesign --deep` chokes on them. Copy them to `Contents/Resources/` and sign the app without `--deep`.
- Ad-hoc signing (`codesign --force --sign -`) is enough for local dev; Gatekeeper accepts it on launch.

## Architecture pointers

Two-stage pipeline with **swappable providers** at each stage. Each stage is a protocol (`TranscriptionProvider`, `RefinementProvider`) — new providers implement the protocol and are chosen at runtime from settings. See `PLAN.md` §Providers for signatures.

Stage defaults: `WhisperKitProvider` (transcription) + `OllamaProvider` (refinement). Both local. `NoOpProvider` is a zero-dep fallback if the user skips Ollama.

`DictationPipeline` in `VoiceRefine/Pipeline/` orchestrates hotkey → record → transcribe → gather context → refine → paste. Context (frontmost app, window title, selected text, user glossary) is passed to the refinement provider as XML-tagged blocks — exact format in `PLAN.md` §v1.1.

## Stage-specific gotchas

**Ollama (refinement, default)**
- Inference: use the OpenAI-compatible endpoint `http://localhost:11434/v1/chat/completions` with a dummy API key.
- Only use Ollama's native API (`/api/...`) for `GET /api/tags` (list installed models) and `POST /api/pull` (pull a model with progress).
- "Running?" probe: `GET /api/tags` with 500 ms timeout — success = running, connection refused = not running.
- "Installed but not running": shell out `which ollama`; if present but endpoint silent, suggest `ollama serve`.
- **Do not auto-start Ollama.** It is a user-managed daemon.

**WhisperKit (transcription, default)**
- Models download on first use to `~/Library/Application Support/VoiceRefine/models/whisper/`.
- Default model: `openai_whisper-base.en` (~142 MB). Show a progress bar on first download.

**Paste engine**
- Save current `NSPasteboard.general` → write refined text → synthesize ⌘V via two `CGEvent` calls (keyDown + keyUp with `.maskCommand`) → wait 500 ms → restore original pasteboard.
- On startup check `AXIsProcessTrusted()`. If false, deep-link to System Settings with:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

**Audio**
- 16 kHz mono PCM via `AVAudioEngine`. In-memory `Data` buffer. Min 0.3 s, max 120 s.

## Storage

- **Keychain** (cloud providers only): `service = <bundle id>`, `account = "<provider-id>.<key-name>"`.
- **UserDefaults**: selected providers/models, hotkey, sound toggle, start-at-login, system prompt, glossary, history.
- **Whisper models**: `~/Library/Application Support/VoiceRefine/models/whisper/`.
- **Logs**: `~/Library/Logs/VoiceRefine/`.
- **Audio scratch (Phase 2 only)**: `~/Library/Caches/VoiceRefine/last.wav`.

## Defaults worth remembering

- Hotkey: `⌥ Space`
- Whisper model: `openai_whisper-base.en`
- Ollama model: `llama3.2:3b`
- Anthropic model (if user picks cloud): `claude-sonnet-4-6`
- OpenAI model (if user picks cloud): `gpt-4o-mini`
- Refinement system prompt: baked-in but user-editable — verbatim text in `PLAN.md` §"Default refinement system prompt". Keep short; local 3B models follow short prompts better.

## Decisions made along the way

- **2026-04-17 — SPM + Makefile build instead of Xcode project** — Xcode.app is not installed on this machine (only Command Line Tools). Verified WhisperKit 0.18.0 and HotKey 0.2.1 build cleanly with `swift build` + CLT; no build-time CoreML compilation is needed (WhisperKit downloads `.mlmodelc` at runtime). `swift build` + hand-assembled `.app` bundle via Makefile covers everything `xcodebuild` would have. If the user later installs Xcode, `Package.swift` opens directly there — no conversion needed.
- **2026-04-17 — SwiftUI `MenuBarExtra` instead of a hand-rolled `NSStatusItem`** — Cleaner for Phase 0. macOS 14+ (`.menuBarExtraStyle(.menu)`) supports all we need. If we hit limits on dynamic icon state or AppKit integration in later phases, swap to an AppKit `MenuBarController` behind the same `MenuBarContent` namespace.
- **2026-04-17 — `NSApp.setActivationPolicy(.accessory)` in AppDelegate in addition to `LSUIElement=YES`** — Belt and braces; ensures no dock icon even if Info.plist is ever stripped or overridden, and keeps windows foregroundable when opened from the menu.
