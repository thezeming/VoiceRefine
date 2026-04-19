# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**VoiceRefine** — a native macOS menu-bar app (Swift/SwiftUI + AppKit) that runs a push-to-talk pipeline: audio → local Whisper transcription → local LLM refinement → paste into frontmost app. Runs fully on-device by default; cloud providers are optional.

**`PLAN.md` at the repo root is the design source of truth.** Read it before any implementation work. This file captures only the things a future session would otherwise have to rediscover: workflow, invariants, and gotchas.

## Current status

**All nine phases complete.** Full pipeline works end to end: push-to-talk → on-device transcription (WhisperKit on macOS 14/15, Apple `SpeechAnalyzer` by default on macOS 26+) → Ollama refinement with context + glossary → paste. Cloud providers (Anthropic / OpenAI / OpenAI-compatible / Groq / OpenAI-Whisper) wired as alternatives. First-run onboarding covers microphone, Accessibility, transcription-provider-specific model/locale download, and Ollama status. Error notifications via UNUserNotificationCenter. Any future work is deep polish / features beyond PLAN.

## Workflow — read this before writing code

- **Phases are ordered and gated.** Work through `PLAN.md` phases 0 → 9 in sequence. At the end of each phase, commit and hand the user a concrete manual test, then **stop and wait** for confirmation before starting the next phase.
- **Commit message format:** `feat(phase-N): short description` (e.g. `feat(phase-3): whisperkit transcription`). One commit per phase minimum.
- **Push to GitHub (`git push`) after every meaningful commit.** End of a phase, fix, feature, docs sweep — anything worth reading. Don't let local work pile up unpushed; the remote is the authoritative backup. Tiny WIP / formatting-only commits can batch, but default to pushing.
- Don't ask about naming, code style, or minor design. Pick something sensible and note the decision in this file under "Decisions made along the way".
- If you discover the plan is wrong as you implement, say so and propose an alternative — don't silently deviate.

## Hard invariants (do not violate)

These are project-wide rules, not phase-specific. Breaking any of them is a regression.

1. **Apple Silicon only.** arm64 target, min macOS 14.0 (Sonoma). WhisperKit targets the Neural Engine and won't work on Intel.
2. **Non-sandboxed app.** The Accessibility API is required for synthesized paste and reading selected text. Do not add the App Sandbox entitlement.
3. **`LSUIElement = YES`.** Menu-bar only, no dock icon, no main window on launch.
4. **Default config = zero outbound network calls** once Whisper and Ollama models are pulled. This is a testable invariant — verify with Little Snitch or equivalent.
5. **SPM dependencies are capped at one:** `WhisperKit` (argmaxinc). Adding any further package needs explicit user sign-off.
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

**macOS 26 SDK required to build.** Phase 9 added `AppleSpeechProvider`, which references `@available(macOS 26, *)` symbols from the `Speech` framework (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`). Runtime target stays macOS 14 via `@available` gating — pre-Tahoe users keep working — but Command Line Tools ≥ 26 (or equivalent Xcode) is needed to compile. `xcrun --show-sdk-version` should report `26.x`.

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

**WhisperKit (transcription, default on macOS 14/15)**
- Models download on first use to `~/Library/Application Support/VoiceRefine/models/whisper/`.
- Default model: `openai_whisper-base.en` (~142 MB). Show a progress bar on first download.

**Apple SpeechAnalyzer (transcription, default on macOS 26+)**
- Gated `@available(macOS 26, *)`. Pre-Tahoe the case is hidden from pickers via `TranscriptionProviderID.visibleCases`; the raw enum case stays in `allCases` so stored prefs survive OS downgrades, and `DictationPipeline.resolveTranscription` falls back to WhisperKit if a stale pref selects it on an older OS.
- "Model" in the `modelPreferenceKey` scheme doubles as a locale id (`en_US`, `en_GB`, …). Populate the picker from `SpeechTranscriber.supportedLocales` at runtime with a hard-coded fallback for first paint.
- Asset install: **use `AssetInventory.status(forModules:) == .installed`** as the install check (not the nil-return heuristic on `assetInstallationRequest`). Before `downloadAndInstall()`, best-effort `AssetInventory.reserve(locale:)` so the OS doesn't reap the asset under storage pressure. Progress is KVO-observable via `AssetInstallationRequest.progress.fractionCompleted`.
- **Audio format must be queried per-locale, never hard-coded.** `SpeechTranscriber.availableCompatibleAudioFormats` (async) returns what the transcriber wants. Feeding anything else crashes inside `Speech.framework` with `EXC_BREAKPOINT` (a framework `__builtin_trap`, not a catchable Swift error). Route `AudioRecorder`'s Int16 16 kHz mono PCM through `AVAudioConverter` into the first entry of that list.
- Push-to-talk driver: `analyzer.analyzeSequence(stream) + finalizeAndFinishThroughEndOfInput()`. Don't use `start(inputSequence:)` from the same Task that feeds the stream — it blocks and deadlocks.
- `Info.plist` requires `NSSpeechRecognitionUsageDescription`. No explicit `requestAuthorization` call exists or is needed — the old SFSpeechRecognizer permission flow doesn't apply.

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
- **Apple Speech locale assets** (macOS 26+): OS-managed by `AssetInventory`, no per-app path. `SpeechTranscriber.installedLocales` reports what's present.
- **Logs**: `~/Library/Logs/VoiceRefine/`.
- **Audio scratch (Phase 2 only)**: `~/Library/Caches/VoiceRefine/last.wav`.

## Defaults worth remembering

- Hotkey: double-tap ⇧ and hold (release to transcribe). Fixed gesture — not user-configurable. Option was tried first but clashed with Claude Desktop's default voice hotkey.
- Whisper model: `openai_whisper-base.en`
- Apple Speech locale: `en_US` (only active when selected as transcriber)
- Selected transcription provider: OS-conditional in `PrefDefaults.registerAll()` — `.appleSpeech` on macOS 26+, `.whisperKit` on macOS 14/15. `UserDefaults.register` only seeds unset keys, so users who explicitly picked a provider keep it across OS upgrades.
- Ollama model: `llama3.2:3b`
- Anthropic model (if user picks cloud): `claude-sonnet-4-6`
- OpenAI model (if user picks cloud): `gpt-4o-mini`
- Refinement system prompt: baked-in but user-editable — verbatim text in `PLAN.md` §"Default refinement system prompt". Keep short; local 3B models follow short prompts better.

## Decisions made along the way

- **2026-04-17 — SPM + Makefile build instead of Xcode project** — Xcode.app is not installed on this machine (only Command Line Tools). Verified WhisperKit 0.18.0 and HotKey 0.2.1 build cleanly with `swift build` + CLT; no build-time CoreML compilation is needed (WhisperKit downloads `.mlmodelc` at runtime). `swift build` + hand-assembled `.app` bundle via Makefile covers everything `xcodebuild` would have. If the user later installs Xcode, `Package.swift` opens directly there — no conversion needed.
- **2026-04-17 — AppKit `NSStatusItem` + `MenuBarController`, not SwiftUI `MenuBarExtra`** — First attempt used `MenuBarExtra`. On macOS 26 (Tahoe) the item registered (ApplicationType=UIElement in launch services) but the glyph never appeared in the menu bar. Re-launch, SF Symbol checks, and activation-policy tweaks all failed. Switched to `NSStatusBar.system.statusItem(withLength: variableLength)` with an AppKit `NSMenu` — immediately visible. `SettingsWindowController` hosts the SwiftUI `SettingsView` via `NSHostingController`, so the Settings tabs remain in SwiftUI.
- **2026-04-17 — AppKit entry point (`main.swift`) instead of `@main struct VoiceRefineApp: App`** — Consequence of the NSStatusItem pivot. `App` requires a non-empty `Scene`; without `MenuBarExtra` there's nothing appropriate. Clean `NSApplication.shared.run()` in `main.swift` avoids phantom scenes.
- **2026-04-17 — `NSApp.setActivationPolicy(.accessory)` in AppDelegate in addition to `LSUIElement=YES`** — Belt and braces; ensures no dock icon even if Info.plist is ever stripped or overridden, and keeps windows foregroundable when opened from the menu.
- **2026-04-17 — Menu bar overflow confirmed on user's Mac** — With many running apps, a single new mic SF Symbol is easy to miss behind the notch. Not a code issue; flag when shipping new menu-bar UI so user knows to look / make room.
- **2026-04-17 — `LSUIElement=YES` apps still need `NSApp.mainMenu`** — Without a main menu, `SecureField` / `TextField` don't receive `⌘V`, `⌘C`, `⌘X`, `⌘A`. The menu bar itself is still suppressed by `LSUIElement`; only the shortcut routing matters. `MenuBarBuilder.build()` constructs a minimal App/Edit/Window menu wired to `NSText.cut/copy/paste/selectAll(_:)` and `NSApplication.terminate(_:)`. Assign via `NSApp.mainMenu = MainMenuBuilder.build()` in `applicationDidFinishLaunching`.
- **2026-04-17 — `KeychainStore` posts `.voiceRefineKeychainDidChange` on delete** — SwiftUI `APIKeyField` caches its value in `@State` and only reads from Keychain `.onAppear`. Without a change notification, the field stays populated even after "Clear all Keychain entries". The notification is only posted on delete / deleteAll (not set) to avoid feedback loops during live typing.
- **2026-04-17 — Custom tab bar instead of SwiftUI `TabView` for Settings** — On macOS 26 (Tahoe) the native selection pill is taller than the tab-bar row, so its bottom edge visibly clips into the content area below. `.padding(.top)` on tab content doesn't fix it (the pill is drawn by the tab bar, not the content). Rebuilt with a row of `SettingsTabButton`s (SwiftUI) that draw their own rounded backgrounds — exact sizing, no clipping. If Apple fixes TabView later, we can revert.
- **2026-04-18 — Stable self-signed code-signing identity ("VoiceRefine Dev"), not ad-hoc** — Ad-hoc (`codesign --sign -`) derives the code signature from binary bytes, so every source change produces a new cdhash. TCC designates Accessibility/Microphone grants by DR, which for ad-hoc includes the cdhash — so every rebuild silently invalidated the Accessibility grant. Symptom: System Settings still showed VoiceRefine checked, but `AXIsProcessTrusted()` returned false and synthesized ⌘V events were dropped. Worse, direct-launching the binary from a terminal (`make debug-run`) **inherited the terminal's Accessibility grant** via TCC's responsible-process delegation — so testing via debug-run gave a false "works for me" while the login-item / `open`-launched app was silently broken. Fix: `make setup-signing` creates a self-signed cert "VoiceRefine Dev" in the user's login keychain, trusted for code-signing only. Makefile signs with it by default. The DR becomes `identifier "com.voicerefine.VoiceRefine" and certificate leaf = H"<cert-sha1>"` — stable across rebuilds, so TCC grants persist indefinitely. One-time setup; idempotent. Don't regress to `--sign -`.
- **2026-04-18 — `PasteEngine` appends a timestamped line to `~/Library/Logs/VoiceRefine/paste.log`** — Per-paste log of `AXIsProcessTrusted` + `text.count`. Kept because `NSLog` is only readable via `log stream` which needs admin, so a login-launched app's silent paste failures are otherwise invisible. If this log shows `AXIsProcessTrusted=false` on a missed paste, it's the signing-identity regression above — not a code bug.
- **2026-04-18 — `textBeforeCursor` capture via AX for refinement context** — New optional channel alongside `selected_text`. Reads up to N chars (default 1500, user-configurable 200–5000) immediately preceding the caret from the focused UI element, passed to the refiner as `<text_before_cursor>` inside `<context>`. Gotchas: (a) `CFRange` from `kAXSelectedTextRangeAttribute` is in UTF-16 units, not Swift graphemes — all range math goes through `NSString.length` / `CFIndex`, never `String.count`; mixing them silently breaks on emoji/combining chars. (b) Parametric read via `kAXStringForRangeParameterizedAttribute` is preferred (cheap on large docs) but many Electron/web apps don't implement it — fallback reads full `kAXValueAttribute` and NSString-slices the prefix. (c) Secure-field check: both role AND subrole can be `"AXSecureTextField"` depending on the app; check both. (d) Bundle-ID blocklist covers common password managers (1Password, Bitwarden, KeePassXC, Dashlane, LastPass, Proton Pass, Apple Passwords, Enpass). (e) Result is left-snapped to the nearest whitespace within the first ~100 chars so the LLM doesn't see a torn "ing the…" opener. Anti-leakage: system prompt explicitly names the tag in its "never copy" list; placement inside the METADATA block (after `<transcript>`) matches the existing `<selected_text>` treatment. Known degradation: Terminal.app and most Electron apps expose little or nothing here; returns nil → no context, no error.
- **2026-04-18 — Refinement output regularization (sanitizer + stop sequences + leak guard)** — Three layered defenses against small-local-model failure modes, after a real-world incident where `qwen2.5:7b` dictating into Claude Code's terminal returned the entire visible conversation wrapped in `<transcript>`/`</transcript>` tags (the model treated `<text_before_cursor>` as the source). Layers: (1) `RefinementOutputSanitizer` runs on every provider's reply — strips markdown fences, stray envelope tags (`<transcript>`, `<context>`, `<glossary>`, etc.) anywhere, leading preambles ("Here's the cleaned text:" / "Sure!" / "Cleaned transcript:"), and matched wrapping quotes/backticks. (2) `RefinementStopSequences` (shared across Ollama/OpenAI-compat/Anthropic) sends `</transcript>`, `<context>`, `</context>`, `<glossary>`, `</glossary>` so an envelope-echo response truncates server-side. Bare `<` is too aggressive — users dictate "less than". (3) `ContextLeakDetector` runs in `DictationPipeline.refine` AFTER sanitization and is the critical safety net — sanitizer paradoxically makes leaked output look more legitimate by removing the wrapping tags, so a separate length-based guard is required. Heuristic: any 80-char contiguous run shared between output and `text_before_cursor` / `selected_text` triggers a leak. On leak, fall back to raw whisper transcript and post a `UNUserNotificationCenter` warning naming the leaked field. Threshold rationale: 80 chars is well above coincidental English overlap (≈25–30 chars max for unrelated speech) but small enough to catch partial leaks where the model paraphrases the start then copies a paragraph. Also lowered temperature from 0.3 → 0.1 across all providers and added a one-shot example to `PrefDefaults.refinementSystemPrompt` (single before/after demonstration outweighs paragraphs of additional rules for small local models). Default Ollama model bumped from `llama3.2:3b` → `qwen2.5:7b` for the same reason — 7B follows the contract far more reliably even with all three defenses in place.
- **2026-04-19 — Apple `SpeechAnalyzer` as optional local transcriber, `@available(macOS 26, *)`** — Added `AppleSpeechProvider` (new in macOS 26's `Speech` framework) alongside WhisperKit — both local, neither is a replacement for the other. WhisperKit stays the only option on macOS 14/15 and remains available everywhere; Apple Speech becomes the fresh-install default on macOS 26+ only. Rationale: Apple's new API is ~2× faster than WhisperKit's Whisper-large-v3-turbo and needs no per-app model download, at the cost of higher WER (~8% vs ~1% for Whisper large on top-end benchmarks — closer to `whisper-base.en`). Architecture: (a) `Package.swift` platform floor stays `.macOS(.v14)` — we gate at call sites via `@available` / `if #available` rather than bumping the whole runtime target. (b) `TranscriptionProviderID.visibleCases` filters `.appleSpeech` out of user-facing pickers pre-Tahoe; `allCases` stays unfiltered so stored prefs survive OS downgrades, and `DictationPipeline.resolveTranscription` falls back to WhisperKit if a stale pref selects it on an older OS. (c) `PrefDefaults.registerAll()` picks the default provider based on `#available(macOS 26, *)` — flips to `.appleSpeech` on Tahoe+, stays `.whisperKit` on Sonoma/Sequoia. `UserDefaults.register` only seeds unset keys, so this is invisible to existing users. (d) The existing `modelPreferenceKey` doubles as a locale id (`en_US`, `en_GB`, …) for this provider — no new pref key needed. Build: requires the macOS 26 SDK (Command Line Tools 26+) to compile; runtime target unchanged.
- **2026-04-19 — Apple Speech audio format must be queried per-locale, never hard-coded** — First live test trap-crashed (`EXC_BREAKPOINT`, `SIGTRAP`) 8 frames deep inside `Speech.framework` with no symbols. Cause: fed a hand-built Float32 16 kHz mono `AVAudioPCMBuffer` when the transcriber wanted a different shape on this machine. The crash is a framework `__builtin_trap` / precondition, not a catchable Swift error — no amount of try/catch helps. Fix: query `transcriber.availableCompatibleAudioFormats` (async, per-locale, may vary across Apple updates) and `AVAudioConverter` the recorder's Int16 16 kHz mono bytes into the first reported entry. Same-format feeds skip the converter. Future gotcha: if this crashes again after an OS update, first diagnostic is to log the returned format list and the actual feed format — the compatible shape is not documented as stable.
- **2026-04-19 — Apple Speech asset install via `AssetInventory.status` + `reserve` + KVO progress; one-shot driver uses `analyzeSequence` not `start`** — The canonical "is the locale installed?" check is `AssetInventory.status(forModules: [transcriber]) == .installed`. I started with a nil-return heuristic on `assetInstallationRequest(supporting:)` which happens to work but is fragile — a nil request can also be transient. Before `downloadAndInstall()`, call `AssetInventory.reserve(locale:)` best-effort so the OS doesn't reap the asset under storage pressure later (failure is non-fatal — e.g. user is over the reserved-locales cap). Progress is KVO-observable via `AssetInstallationRequest.progress.fractionCompleted`. Push-to-talk driver: use `analyzer.analyzeSequence(stream) + finalizeAndFinishThroughEndOfInput()` (one-shot shape) rather than `start(inputSequence:)` — `start` seems to block on the input stream and deadlocks when called from the same Task that feeds it. AsyncStream's default unbounded buffer lets us `yield → finish → analyze` in that order from a single Task without coordination. `Info.plist` needs `NSSpeechRecognitionUsageDescription`; no explicit `requestAuthorization` call exists or is required on the new API — the old SFSpeechRecognizer permission flow doesn't carry over.
- **2026-04-19 — Push-to-talk gesture: double-tap-and-hold Shift, replacing ⌥+Space chord; HotKey dependency dropped** — Modeled after Claude Code's voice-dictation gesture. First implemented on Option then switched to Shift because Option clashed with Claude Desktop's default voice hotkey. `HotkeyManager` uses two `NSEvent` flagsChanged monitors (global + local) and a 5-state machine (`idle → firstDown → firstUp → secondDownPending → holding`). Thresholds: first tap ≤350 ms, gap before re-press ≤400 ms, **second press must be held ≥250 ms before `onPress` fires**. The hold-confirm threshold is essential for Shift specifically — Shift is pressed on every capital letter during normal typing, so a second Shift within 400 ms is a routine event and would false-trigger recording without the hold gate. A release during `secondDownPending` cancels silently (no onPress fired, so no onRelease needed). Any non-Shift modifier change mid-gesture aborts and, if already `.holding`, fires a clean `onRelease()` so the pipeline unwinds. Pure-Shift only — `flags == .shift || flags.isEmpty` — chord combos (⇧⌘, ⇧⌥, …) cancel. `onPress`/`onRelease` callback contract to `DictationPipeline` is unchanged. Consequences: (a) `HotKey` SPM package removed (invariant #5 now "capped at one: WhisperKit"). (b) `PrefKey.hotkeyKeyCode` / `hotkeyModifierFlags` deleted — the gesture is fixed, not user-configurable. (c) Global flagsChanged monitoring requires Accessibility, which the app already needs for paste synthesis, so no new permission prompt. (d) `NSEvent` monitors and the `DispatchQueue.main.asyncAfter` hold-confirm all fire on the main thread — same implicit contract the pipeline already relied on under HotKey. If switching to another modifier (e.g. Control), keep the hold-confirm step unless that modifier is also typing-dead — Command and Control both appear in shortcuts rapidly enough that dropping it would regress. If a future user asks to customize the hotkey, this decision is the thing to reopen.
