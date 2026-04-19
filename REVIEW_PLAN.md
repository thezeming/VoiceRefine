# VoiceRefine — Revision Plan

**Source:** code review dated 2026-04-19.
**Goal:** land the review findings as independently-mergeable tasks so
multiple agents can work in parallel without stepping on each other.

Each `### TASK-X.Y` heading below is one agent assignment / one GitHub
issue / one PR. Tasks are **self-contained** — a fresh Claude Code
session with only this file + `CLAUDE.md` + `PLAN.md` can implement any
single task without reading the others.

> This plan deliberately departs from the strict phase-gated workflow
> in `CLAUDE.md` ("Work through phases 0 → 9 in sequence…"). The
> original phases built the app up from scratch; this plan polishes
> an already-complete app. Parallel execution is intended.

---

## ⚡ Quick start

Single-agent, sequential mode. One fresh Claude Code session runs one
task at a time; the human merges the PR between tasks. Simplest
possible loop.

**Each new session:** open Claude Code in this repo and do:

1. Identify what's already done:
   ```bash
   gh pr list --state merged --search "TASK" -L 30
   ```
2. Pick the lowest-numbered task whose **Blocked by** items are all
   in that merged list. (Start with `TASK-0.1` on the very first run.)
3. Implement it exactly per the worker prompt template in §"Agent
   prompt template (worker)": stay inside the task's **Files** block,
   respect the **Conventions** table, stop-and-ask on scope creep.
4. Commit (`<kind>(task-X.Y): <summary>`), push, open a PR whose
   description is the Acceptance checkboxes. Use `gh pr create`.
5. Stop. Do **not** start another task — wait for the human to merge
   and re-prompt you.

**The exact prompt to paste each time:**

```
Read CLAUDE.md, PLAN.md, and REVIEW_PLAN.md in full.
Then follow the steps in REVIEW_PLAN.md §"⚡ Quick start" — pick the
next eligible task, implement it, open a PR, and stop. One task only.
```

Between sessions the human does: review the PR, merge it (via
GitHub web or `gh pr merge`), then start a new Claude Code session
and re-paste the prompt.

---

## How to use this plan

1. Pick a task. Read **only** its Rationale / Files / Implementation /
   Acceptance blocks.
2. Confirm its **Blocked by** list is merged on `main`.
3. Branch: `git checkout -b task-X.Y-slug` (e.g. `task-1.1-notif-gate`).
4. Implement. Stay inside the task's **Files** list — resist scope creep.
5. Commit: `<kind>(task-X.Y): <summary>` with
   `<kind>` ∈ {`fix`, `feat`, `refactor`, `test`, `docs`, `chore`}.
   Push after each meaningful commit (CLAUDE.md workflow rule).
6. PR title: `TASK-X.Y — <summary>`. Paste the task's Acceptance
   checkboxes into the PR description.
7. Invariants in `CLAUDE.md` still apply — any task that would violate
   one needs explicit sign-off in the PR description.

### Agent prompt template (worker)

Copy this into a fresh Claude Code session:

> Read `CLAUDE.md`, `PLAN.md`, the **Coordination model** section of
> `REVIEW_PLAN.md`, and then the `TASK-X.Y` section. Implement only that
> task — do not widen scope, do not touch files outside its **Files**
> block. Follow the **Conventions** checklist under Coordination. If
> anything pushes you outside scope, STOP and report back to the
> orchestrator instead of proceeding. Commit per the task's template.
> Push the branch and open a PR whose description is the Acceptance
> checkboxes. Stop and wait for review.

Orchestrator-mode prompt is in Appendix C.

### Parallelism rules

- Two tasks can run **in parallel** if their **Files** lists are
  disjoint. Per-phase headers call out known file conflicts.
- If a task's Files list overlaps another in-progress task, the second
  one waits. Use `gh pr view` to check status before starting.
- Tasks in **Phase 6** are optional / exploratory — coordinate with the
  repo owner before starting.

### Converting tasks to GitHub issues

Each task block is shaped so `gh issue create` can be driven
mechanically. Minimum viable script:

```bash
# From the repo root, after the plan is on main:
awk '/^### TASK-/{flag=1; title=$0; next} /^### /{flag=0} flag' REVIEW_PLAN.md
```

Pipe each block into `gh issue create --title "$title" --body-file -`,
optionally tagged with `--label` derived from the task ID
(`phase-0` … `phase-6`) and the **kind** suffix.

---

## Coordination model

Pure independence between worker agents has real failure modes, even
when file lists don't overlap: style drift, semantic conflicts,
duplicated helpers, stale prerequisites, integration regressions, and
no one owning the plan itself. This section defines how workers stay
coherent without the overhead of a real build system.

### Roles

**Orchestrator (one at a time).** Can be you + one Claude Code session
in orchestrator mode, or a dedicated session that only uses
`Agent` / `Bash` / `Read` / `Edit` / `Write` — never implements tasks
directly. Responsibilities:

- Decide *which* task runs next and who runs it.
- Verify prerequisites are **merged to `main`** (not just in flight)
  before assigning.
- Watch open PRs for cross-task conflicts; trigger rebases.
- Run **phase checkpoints** when a phase's PRs all merge.
- Update this file as work lands (mark phases done, append follow-ups).
- Resolve convention questions workers raise.
- Answer the one question no worker can: "this task wants to bleed
  into files outside its scope — should I expand, split, or defer?"

**Workers (1…N, parallel).** Ephemeral Claude Code sessions each
assigned exactly one `TASK-X.Y`. Responsibilities:

- Implement inside the task's **Files** block. Nothing else.
- Follow the **Conventions** checklist below.
- If the task is impossible as written, STOP and report — don't
  silently widen scope or improvise.
- Open a PR. Do not merge.

**Reviewer.** The human. Merges PRs, approves invariant-waiving
changes, breaks orchestrator ties.

### Conventions (locked in advance so workers don't drift)

Any new code introduced by a Phase 1–4 task must follow these. Phase 5
is the sweep that retrofits older code; until 5 lands, leave existing
code alone even if it violates these — consistency-through-migration
comes later.

| Topic                     | Convention                                                                                                                                                                                                       |
|---------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Concurrency**           | UI-owning classes → `@MainActor`. Scheduled main-thread work → `Task { @MainActor in … }`. Cancellable delays → `DispatchWorkItem` (keep). Avoid raw `DispatchQueue.main.async` in new code.                   |
| **Locks**                 | `OSAllocatedUnfairLock<T>` for short critical sections. No new `DispatchQueue.sync` patterns, no `NSLock`.                                                                                                       |
| **Error types**           | Preserve underlying context. Pattern: `enum ProviderError { case wrapped(Error) }` with `.description` that includes `underlying.localizedDescription`. Don't collapse to string-less cases. (TASK-1.3 template.) |
| **Logging**               | `NSLog("VoiceRefine: …")` stays. Diagnostic file logs go through the helper established by TASK-3.2 once merged; before that, inline `FileHandle` writes are fine.                                              |
| **Tests**                 | Every new pure-logic module gets a sibling `*Tests.swift` in the test target: ≥ 1 happy-path, ≥ 1 edge case. No behavior-only tests ("method X was called"); test observable outcomes.                           |
| **Pref keys**             | New keys declared only in `Preferences.swift`. Every new key must have a default in `PrefDefaults.registerAll()`. Never access prefs by raw string outside that file.                                            |
| **File placement**        | Refinement → `Sources/VoiceRefine/Refinement/`. Transcription → `Sources/VoiceRefine/Transcription/`. UI tabs → `Settings/`. App chrome → `MenuBar/` or `App/`. Shared helpers → nearest common parent.         |
| **SPM deps**              | No new deps. TASK-6.5 and TASK-6.6 are the only exceptions and require explicit sign-off in the PR.                                                                                                              |
| **Comments**              | Per `CLAUDE.md`: "why" only when non-obvious. Never reference task IDs, PR numbers, or "added for X flow" — they rot.                                                                                            |
| **Commit messages**       | `<kind>(task-X.Y): <summary>`. One task per PR. Don't amend across review rounds — new commits.                                                                                                                  |
| **PLAN-level changes**    | Workers never modify `PLAN.md`'s design invariants. Workers never modify `CLAUDE.md`'s decisions log without the orchestrator's nod. `REVIEW_PLAN.md` is orchestrator-only to edit.                              |
| **Stop and ask**          | If a task requires code *outside* its Files list to work, stop. If an invariant (`CLAUDE.md` §"Hard invariants") would be violated, stop. If scope feels wrong, stop. Asking is cheap; fixing drift isn't.      |

### Merge ordering

- A task's **Blocked by** PRs must be **merged to `main`**, not merely
  open, before the dependent task starts. Workers verify with
  `gh pr list --state merged --search "TASK-X.Y"`.
- Within a phase, merge oldest PR first — smaller rebase burden on the
  ones still open.
- After each merge, orchestrator runs
  `git fetch && git log --oneline main -5` and tells currently-open
  workers "rebase and re-run your tests" only if the merged diff
  plausibly affects them. Default: don't rebase speculatively.
- Never squash-merge review iterations into the initial commit — keep
  the history readable.
- Hook failure → new commit, never `--amend` (per `CLAUDE.md`
  workflow rule).

### Phase checkpoints (integration gates)

After the last PR in a phase merges, the orchestrator runs:

```bash
# 1. Unit tests.
swift test 2>&1 | tail -20                            # must be green

# 2. Build + bundle.
make clean && make bundle                             # must succeed

# 3. Smoke test.
make run                                              # icon appears
#    dictate: "refactor the OAuth middleware to use async await"
#    expect: cleaned text pastes; no console errors

# 4. Per-phase extra checks (see per-phase notes).

# 5. Plan update.
#    - Mark the phase complete in the Dependency graph.
#    - Append any follow-ups discovered during the phase as new TASK-X
#      entries under a new "Phase F" (follow-ups) section.
#    - Note any deferred/de-scoped items with a rationale line.

git commit -m "docs(plan): complete phase-N; add follow-ups TASK-F.1..."
git push
```

**Phase 0 extra check:** `swift test` must pass. This is the canary —
if any later phase breaks it, the breakage is real.

**Phase 2 extra check:** WhisperKit download + Apple Speech locale
install both run from a clean `~/Library/Application Support/VoiceRefine/`.

**Phase 3 extra check:** toggle each privacy switch, dictate, verify
`~/Library/Logs/VoiceRefine/context.log` reflects the setting.

**Phase 4 extra check:** start a dictation, press hotkey again
mid-transcription, verify the first task unwinds within ~100 ms
(Activity Monitor CPU drop is the cheap indicator).

**Phase 5 extra check:** `swift build -Xswiftc -strict-concurrency=complete`
emits no *errors*. Warnings listed in the PR.

### Conflict-resolution protocol

If two in-flight workers discover they need overlapping changes (either
pre-emptively, via file inspection, or at merge time):

1. Both workers **stop** immediately. No "I'll just rebase it."
2. Orchestrator reviews both diffs. Picks one of:
   a. **Merge A, rebase B.** Cheapest when B is small and B's diff
      doesn't conflict with A's semantics.
   b. **Re-scope.** Pull shared changes out into a new preliminary
      task (`TASK-X.Y-pre`) that merges first; A and B then rebase.
   c. **Serialize.** Pause one, finish the other, resume. Use when
      the semantics actually conflict, not just the text.
3. Decision is recorded as a comment on both PRs, not in this file
   (it's ephemeral).
4. If the conflict reveals a plan mistake (bad dependency, wrong
   scope), orchestrator updates `REVIEW_PLAN.md` and calls it out in
   the commit message.

### State tracking

Use GitHub, not a file:

- **Issues** mirror tasks one-to-one. Labels: `phase-0` … `phase-6`,
  plus `kind:fix` / `feat` / `refactor` / etc.
- **PRs** reference issues (`Closes #N`). PR title matches task title.
- **Projects** (GitHub Projects V2, optional) give a kanban view:
  `Backlog` → `Ready` → `In Progress` → `In Review` → `Merged`.
- The plan file is the *spec*; GitHub is the *state*. Workers read the
  plan; orchestrator reads both.

### Failure handling

- Worker session dies or produces broken work: orchestrator closes the
  PR with a comment, reopens the issue with status `blocked`, spawns a
  fresh worker with full context. Don't try to rescue a confused
  session.
- A task is found unimplementable as written: orchestrator re-scopes
  the task (edits `REVIEW_PLAN.md`) and reassigns. Don't let the
  worker silently do something different.
- A checkpoint fails: STOP assigning new tasks until it's green.
  Fixing the checkpoint failure is the next task; it takes priority
  over the remaining phase backlog.

---

## Dependency graph

```
Phase 0 (foundation, sequential)
  TASK-0.1 (XCTest scaffold) ─┐
  TASK-0.2 (swift-tools 6.0)  ┴─► enables stricter-concurrency work

Phase 1 (trivial, fully parallel — start immediately)
  1.1  1.2  1.3  1.4  1.5  1.6  1.7

Phase 2 (TranscriptionTab — sequential within phase)
  2.1 ──► 2.2 ──► 2.3 ──► 2.4

Phase 3 (privacy — parallel with Phase 2)
  3.1  3.2  3.3

Phase 4 (pipeline robustness — after Phase 2 drains)
  4.1  4.2  4.3

Phase 5 (sweeping refactors — after 4; needs stable tests from 0.1)
  5.1 ──► 5.2 ──► 5.3

Phase 6 (optional features — any time after Phase 1)
  6.1  6.2  6.3  6.4  6.5  6.6
```

### Phase parallelism matrix

| Can run in parallel with → | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---------------------------|---|---|---|---|---|---|---|
| **Phase 0**               | — | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **Phase 1**               | ✗ | ✓ | ✓ | ✓ | — | — | ✓ |
| **Phase 2**               | ✗ | ✓ | sequential | ✓ | — | — | partial* |
| **Phase 3**               | ✗ | ✓ | ✓ | ✓ | — | — | partial* |
| **Phase 4**               | ✗ | — | — | — | ✓ | — | partial* |
| **Phase 5**               | ✗ | — | — | — | — | sequential | — |
| **Phase 6**               | ✗ | ✓ | partial* | partial* | partial* | — | ✓ |

`*partial` = check file-level overlap per task before scheduling.

---

## Phase 0 — Foundation

Must merge before anything else. Both tasks are small and uncontentious.

### TASK-0.1 — Scaffold XCTest target with four initial suites

- **Blocked by:** `none`
- **Parallel with:** `TASK-0.2`
- **Files:**
  - `Package.swift`
  - `Tests/VoiceRefineTests/RefinementOutputSanitizerTests.swift` (new)
  - `Tests/VoiceRefineTests/ContextLeakDetectorTests.swift` (new)
  - `Tests/VoiceRefineTests/WAVEncoderTests.swift` (new)
  - `Tests/VoiceRefineTests/HotkeyGestureTests.swift` (new)
- **Out of scope:** any implementation changes

**Rationale.** The codebase currently has no tests. Four subsystems
have subtle, pure-logic behavior that will silently regress without
coverage: `RefinementOutputSanitizer` (regex-heavy),
`ContextLeakDetector` (heuristic threshold), `WAVEncoder` (byte-exact
format), and `HotkeyManager`'s 5-state machine.

**Implementation.**
1. Add a `testTarget` to `Package.swift` named `VoiceRefineTests`,
   depending on the `VoiceRefine` executable target. SPM allows this
   via `@testable import VoiceRefine`; no changes to `internal`
   access needed.
2. `RefinementOutputSanitizerTests`: table-driven cases covering each
   cleanup stage (code fences, stray tags, leading preamble, wrapping
   quotes) plus composed cases. Target ≥ 15 cases.
3. `ContextLeakDetectorTests`: assert clean output, short output
   (below `minOutputChars`), 80-char overlap in `textBeforeCursor`,
   80-char overlap in `selectedText`, 79-char overlap (below
   threshold). Target ≥ 6 cases.
4. `WAVEncoderTests`: encode a 16 kHz Int16 buffer, parse it with
   `AVAudioFile`, assert frame count and sample rate match.
5. `HotkeyGestureTests`: extract the gesture state machine into a
   pure function `HotkeyGesture.advance(state, event) → (state, action?)`
   inside `HotkeyManager.swift` (minimal refactor — keep the existing
   NSEvent driver as a thin wrapper around it). Assert first-tap
   timing, gap timing, hold-confirm, non-Shift abort.

**Acceptance.**
- [ ] `swift test` exits 0 with ≥ 30 cases passing.
- [ ] Test target builds on arm64 macOS 14 and 26.
- [ ] No changes to non-test behavior (CI-equivalent smoke test still
      produces identical binary).

**Manual test.** `swift test 2>&1 | tail -20` shows all green.

**Commit:** `test(task-0.1): scaffold XCTest target with 4 initial suites`

---

### TASK-0.2 — Bump `swift-tools-version` to 6.0

- **Blocked by:** `none`
- **Parallel with:** `TASK-0.1`
- **Files:** `Package.swift`
- **Out of scope:** enabling any strict-concurrency *errors* (this task
  only bumps the tools version; TASK-5.3 does the sweep)

**Rationale.** Current `// swift-tools-version: 5.10`. Code already
uses `nonisolated(unsafe)` and `@Sendable`. Tools 6.0 unlocks stricter
concurrency checking as warnings; needed for TASK-5.3.

**Implementation.**
1. Change header to `// swift-tools-version: 6.0`.
2. Leave `swiftSettings` absent for now. Verify `make build` still
   succeeds on CLT 26.
3. If any new warnings appear, enumerate them in the PR description.
   Do **not** fix them here — that's TASK-5.3.

**Acceptance.**
- [ ] `make build` succeeds on CLT 26 with no errors.
- [ ] `make bundle && make run` shows the menu-bar icon as before.
- [ ] New warnings (if any) listed in PR description.

**Manual test.** `make build && make bundle && make run`. Record,
dictate, verify end-to-end pipeline.

**Commit:** `chore(task-0.2): bump swift-tools-version to 6.0`

---

## Phase 1 — Isolated bug fixes (fully parallel)

Each task below touches exactly one file. Assign to different agents
simultaneously; no coordination needed. None is blocked by any other.

### TASK-1.1 — Fix `NotificationDispatcher` duplicate-call gate

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/App/NotificationDispatcher.swift`

**Rationale.** `requestAuthorization()` has a `guard` inside a
`queue.sync { … }` closure — `return` exits the closure, not the
function, so every call re-requests auth. The stored `authorized`
flag is never read. Harmless today (only one caller) but a trap.

**Implementation.** Hoist the "should we proceed" decision out of the
closure:
```swift
let shouldRequest: Bool = queue.sync {
    guard !didRequestAuth else { return false }
    didRequestAuth = true
    return true
}
guard shouldRequest else { return }
UNUserNotificationCenter.current().requestAuthorization(...)
```
Delete the `authorized` variable (unused) and its write in the
completion handler.

**Acceptance.**
- [ ] Two calls to `requestAuthorization()` result in one call to
      `UNUserNotificationCenter.current().requestAuthorization(…)`.
      (Add to the XCTest target as `NotificationDispatcherTests`
      using a local injected mock; optional — can be verified by
      `log stream` trace.)
- [ ] Existing auth prompt on first launch still fires.
- [ ] `nonisolated(unsafe)` declarations reduced to one.

**Manual test.** Delete the app's TCC entry for notifications, relaunch,
verify prompt still appears exactly once.

**Commit:** `fix(task-1.1): guard NotificationDispatcher auth request correctly`

---

### TASK-1.2 — Remove dead "Clear transcription history" button

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Settings/AdvancedTab.swift`

**Rationale.** The button is permanently `.disabled(true)` with no
tooltip. Showing a permanently-disabled control is UX debt. History
itself arrives in TASK-4.3; delete the stub now so no one wonders
what it does.

**Implementation.** Delete the `Button("Clear transcription history")`
line and its modifiers. Leave the surrounding `Section("Maintenance")`
intact.

**Acceptance.**
- [ ] Button gone.
- [ ] Other "Maintenance" items (Reveal logs, Clear Keychain) still
      function.
- [ ] No new SwiftUI warnings.

**Manual test.** Open Settings → Advanced; "Clear transcription
history" row is absent.

**Commit:** `chore(task-1.2): remove dead clear-history button`

---

### TASK-1.3 — Preserve decoder error in `OpenAICompatClient`

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Refinement/OpenAICompatClient.swift`

**Rationale.** Both `catch` branches after `JSONDecoder().decode(...)`
throw `ClientError.malformedResponse` with no underlying message. The
first branch (`catch is ClientError`) is also dead — `JSONDecoder`
never throws `ClientError`. Users of self-hosted endpoints get
"Unexpected response shape." with no clue which field was missing.

**Implementation.**
1. Change the error case to
   `case malformedResponse(String)` with a description that includes
   the underlying message.
2. Replace both catches with:
   ```swift
   } catch {
       throw ClientError.malformedResponse(String(describing: error))
   }
   ```
3. Update the description:
   ```swift
   case .malformedResponse(let why): return "Unexpected response shape: \(why)"
   ```
4. `OpenAICompatibleProvider` / `OpenAIProvider` / `DeepSeekProvider`
   forward via `ProviderError.clientError(e)`; their `.description`
   already includes `e.description`. No changes needed there.

**Acceptance.**
- [ ] Feeding a 200-with-`{"unexpected": true}` body surfaces a
      user-visible message naming the missing field (e.g.
      "Unexpected response shape: keyNotFound(CodingKeys(stringValue:
      \"choices\", intValue: nil) …").
- [ ] Happy path unchanged.
- [ ] Add an `OpenAICompatClientTests` case (optional).

**Manual test.** Point the OpenAI-compatible provider base URL at
`http://httpbin.org` (returns 200 with JSON that doesn't match), run
the Test button in Settings → Refinement. Error message now names the
decoder failure.

**Commit:** `fix(task-1.3): preserve decoder error in OpenAICompatClient`

---

### TASK-1.4 — `KeychainStore.deleteAll` posts one notification, not N

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Settings/KeychainStore.swift`

**Rationale.** `deleteAll(withPrefix:)` calls `delete(account:)` per
match; each call posts `.voiceRefineKeychainDidChange`. `APIKeyField`
subscribers reload N times.

**Implementation.**
1. Add a private `deleteWithoutNotifying(account:)` containing the
   current delete body but without the `post(name:)` call.
2. `delete(account:)` calls `deleteWithoutNotifying` then posts.
3. `deleteAll(withPrefix:)` loops `deleteWithoutNotifying`, posts
   once at the end (both success and empty-match branches).

**Acceptance.**
- [ ] Clicking "Clear all Keychain entries" in Advanced with N stored
      keys posts exactly one notification (observable via
      `log stream --predicate 'eventMessage CONTAINS "KeychainDidChange"'`
      or a `NotificationCenter` observer added to the tests).
- [ ] `APIKeyField` reload behavior unchanged (single re-read).

**Manual test.** Stash 3 dummy keys, open Settings → Advanced, click
"Clear all Keychain entries". Check Keychain Access — all gone in one
UI step.

**Commit:** `fix(task-1.4): KeychainStore.deleteAll posts one notification`

---

### TASK-1.5 — Error state persists until next recording

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Pipeline/DictationPipeline.swift`

**Rationale.** `flashError(_:)` calls
`DispatchQueue.main.asyncAfter(deadline: .now() + 1.5)` to revert to
`.idle`. On a notch-crowded menu bar the yellow triangle can vanish
before the user looks. Better: keep the error icon until the next
recording press.

**Implementation.**
1. Delete the `asyncAfter` call and the surrounding
   `if case .error = self.state { … }` block in `flashError`.
2. In `beginRecording`, before the `if state == .recording { return }`
   guard, add:
   ```swift
   if case .error = state { transition(to: .idle) }
   ```
3. Keep the `NotificationDispatcher.postError` call — the notification
   is still the primary surface.

**Acceptance.**
- [ ] An error (e.g. missing cloud API key) leaves the menu bar icon
      on the yellow triangle indefinitely.
- [ ] Next hotkey press clears it and starts a fresh recording.
- [ ] No lingering dispatch-work-items on the main queue from
      `flashError`.

**Manual test.** Switch refinement to OpenAI with an empty key, dictate,
observe yellow triangle. Wait 5 minutes — still yellow. Dictate again —
goes green / red / back to idle normally.

**Commit:** `fix(task-1.5): keep error state until next recording`

---

### TASK-1.6 — Extend stop sequences to cover METADATA sub-tags

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Refinement/RefinementOutputSanitizer.swift`

**Rationale.** `RefinementStopSequences.openAICompatible` stops on
`</transcript>` + `<context>` + `</context>` + `<glossary>` +
`</glossary>`. It does **not** cover `<text_before_cursor>`,
`</text_before_cursor>`, `<selected_text>`, `</selected_text>`,
`<app>`, `</app>`. Long-form metadata leakage (the failure mode
documented in CLAUDE.md) can slip past the API truncation.
`ContextLeakDetector` backstops it, but defense in depth is cheap.

**Implementation.** Expand both `openAICompatible` and `anthropic`
lists to include the six additional sub-tags. Keep them short of 6
items apiece on the OpenAI side (OpenAI's `stop` field accepts up to
4 — check the current count; if we exceed, drop the least-leak-prone
tags first: `<app>`/`</app>`). Anthropic allows up to 4 stop sequences
as well — prefer `</text_before_cursor>` and `</selected_text>` over
the opens (the output usually echoes the full block, not just a tag
open).

**Acceptance.**
- [ ] List size ≤ 4 per provider.
- [ ] An intentional refinement output containing
      `…random blather </text_before_cursor>` truncates before the
      tag when using OpenAI / Ollama.
- [ ] No existing sanitizer tests break (extend
      `RefinementOutputSanitizerTests` if TASK-0.1 has landed).

**Manual test.** Edit `Preferences.swift` temporarily to add a system
prompt that asks the model to echo `</selected_text>` in its reply.
Dictate — response is truncated at the tag.

**Commit:** `fix(task-1.6): extend stop sequences to metadata sub-tags`

---

### TASK-1.7 — Auto-migrate stale `.appleSpeech` pref on pre-26 OS

- **Blocked by:** `none`
- **Parallel with:** everything in Phase 1
- **Files:** `Sources/VoiceRefine/Settings/Preferences.swift`
  **(add `migrateStalePrefs()` helper called from `PrefDefaults.registerAll`)**

**Rationale.** A user who configured `.appleSpeech` on a macOS 26
machine, then downgraded (or restored-from-backup on macOS 14/15),
has `selectedTranscriptionProvider = appleSpeech` stored.
`DictationPipeline.resolveTranscription` falls back to WhisperKit at
runtime (safe), but `TranscriptionTab`'s Picker uses `visibleCases`
which excludes `.appleSpeech` on pre-26 — the selection is **blank**
until the user picks one. Confusing UX.

**Implementation.**
1. Add `PrefDefaults.migrateStalePrefs()` that, on pre-macOS-26,
   reads `selectedTranscriptionProvider` and — if it equals
   `.appleSpeech.rawValue` — overwrites it with `.whisperKit.rawValue`.
2. Call it from `registerAll()` *after* `UserDefaults.register` so the
   migration writes a real stored value (not just a default).
3. Log the migration via `NSLog("VoiceRefine: migrated stale
   appleSpeech pref → whisperKit on pre-26 OS")`.

**Acceptance.**
- [ ] Seed UserDefaults with `selectedTranscriptionProvider=appleSpeech`
      via `defaults write com.voicerefine.VoiceRefine
      selectedTranscriptionProvider appleSpeech`, launch on macOS 14/15
      — on first launch the pref is rewritten to `whisperKit`.
- [ ] On macOS 26 the same pref is left untouched.
- [ ] New users' flows unchanged.

**Manual test.** `defaults write com.voicerefine.VoiceRefine
selectedTranscriptionProvider appleSpeech && open build/VoiceRefine.app`,
then `defaults read com.voicerefine.VoiceRefine
selectedTranscriptionProvider` → should read `whisperKit` on pre-26.

**Commit:** `fix(task-1.7): migrate stale appleSpeech pref on pre-26 OS`

---

## Phase 2 — Transcription UX (sequential within phase)

All four tasks touch `TranscriptionTab.swift`. Must merge in order.
Parallel **across** phases with Phase 3.

### TASK-2.1 — Runtime Apple Speech locale loader

- **Blocked by:** `none` (but `TASK-1.7` is recommended first so the
  picker has a valid starting selection on all OSes)
- **Parallel with:** anything not in Phase 2
- **Files:**
  - `Sources/VoiceRefine/Settings/TranscriptionTab.swift`
  - (no changes needed to `AppleSpeechAssetManager.swift` —
    `supportedLocales()` already exists, just unused)

**Rationale.** `TranscriptionProviderID.availableModels` for
`.appleSpeech` is an 11-entry hardcoded list. A comment there
promises "the Transcription tab overwrites it at runtime" — it
doesn't. Users may see unsupported locales and miss supported ones.

**Implementation.**
1. In `TranscriptionModelPicker`, hold an `@State private var
   runtimeOptions: [String]?` initialized to `nil`.
2. `load()` becomes async: if `provider == .appleSpeech` and
   `#available(macOS 26, *)`, `await
   AppleSpeechAssetManager.supportedLocales()` and assign to
   `runtimeOptions`.
3. Picker `ForEach` uses `runtimeOptions ?? provider.availableModels`.
4. If the currently-selected locale isn't in the runtime list, fall
   back to the runtime list's first entry (and write back to
   UserDefaults so the pipeline and next-launch agree).
5. Guard the runtime call so it's skipped on non-`appleSpeech`
   providers (no perf cost for WhisperKit / cloud users).

**Acceptance.**
- [ ] On macOS 26, picker shows the list returned by
      `SpeechTranscriber.supportedLocales`, not the static fallback.
- [ ] On macOS 14/15, picker shows the static fallback (unchanged).
- [ ] If the static list contains a locale the runtime doesn't, it is
      **not** shown.
- [ ] Switching providers (WhisperKit ↔ Apple Speech) loads the right
      list each time.

**Manual test.** On macOS 26, Settings → Transcription → pick Apple
Speech. Picker should match `await SpeechTranscriber.supportedLocales`
as logged by a one-off `NSLog` you add while testing (remove before
commit).

**Commit:** `fix(task-2.1): load Apple Speech locales from runtime`

---

### TASK-2.2 — WhisperKit download button + progress in Transcription tab

- **Blocked by:** `TASK-2.1`
- **Parallel with:** anything not in Phase 2
- **Files:**
  - `Sources/VoiceRefine/Settings/TranscriptionTab.swift`
  - `Sources/VoiceRefine/Transcription/WhisperKitProvider.swift`
    (add `prefetch(model:progress:)`)

**Rationale.** The "Download status" row is hardcoded `"Not
downloaded"` with a disabled `Button("Download") {}`. Misleading —
users who believe the model hasn't downloaded click a dead button.

**Implementation.**
1. In `WhisperKitProvider`, add
   ```swift
   func prefetch(
       model: String,
       progress: @escaping @MainActor (Double, String) -> Void
   ) async throws
   ```
   that replicates `ensureLoaded`'s path but with `load: false` in the
   `WhisperKitConfig` so it only downloads. Report progress via
   WhisperKit's existing download progress hook (check the library
   API — may need an observation on the download session, or
   WhisperKit's `ModelVariantDownloader` publisher).
2. In the tab, replace the hardcoded block with
   `WhisperKitModelRow(model: selected)` — a new private view that
   owns state:
   - `@State var downloaded: Bool`
   - `@State var isDownloading: Bool`
   - `@State var fraction: Double`
   - status badge "Downloaded" / "Not downloaded" / "Downloading N%"
   - `[Download]` button when `!downloaded && !isDownloading`
   - `ProgressView(value: fraction)` when downloading
3. `onAppear` + `onChange(of: model)` call
   `WhisperKitProvider.isModelDownloaded(model)` to set state.

**Acceptance.**
- [ ] Row says "Downloaded" when the model folder contains files.
- [ ] "Download" button starts a visible progress bar, caps at 100%,
      then flips to "Downloaded".
- [ ] Download is cancellable by closing the Settings window (the
      task cancels; partial files are left, retry resumes).
- [ ] Picking a different model resets the status correctly.

**Manual test.** `rm -rf ~/Library/Application\ Support/VoiceRefine/
models/whisper/openai_whisper-small.en && make run`, open Settings →
Transcription, pick `small.en`, hit Download, watch progress.

**Commit:** `feat(task-2.2): WhisperKit model download UI + progress`

---

### TASK-2.3 — Onboarding WhisperKit progress integration

- **Blocked by:** `TASK-2.2`
- **Parallel with:** anything not in Phase 2
- **Files:** `Sources/VoiceRefine/Onboarding/OnboardingWindow.swift`

**Rationale.** Onboarding currently says "first recording will fetch
it (~142 MB)" — users dictate once, wait 60 s, assume the app
froze. The `AppleSpeechLocaleRow` parallel has a Download button.
WhisperKit should too.

**Implementation.**
1. In the `whisperKit` branch of `transcriptionChecklistSection`,
   replace the static `.todo`/`.ok` row with a version that has a
   Download button when `!whisperDownloaded`.
2. Wire the button to `WhisperKitProvider().prefetch(model:progress:)`
   from TASK-2.2; reuse the KVO-ish progress pattern the Apple Speech
   download already uses (see lines 238–271).
3. Show the progress bar + status line in the same style as the
   Apple Speech section.

**Acceptance.**
- [ ] Onboarding shows a Download button on the WhisperKit row when
      the model isn't downloaded.
- [ ] Progress bar advances during download, completion flips the
      row to `.ok`.
- [ ] Mic / AX rows still work unchanged.

**Manual test.** Delete the whisper model folder, wipe
`didCompleteOnboarding`, relaunch → Onboarding opens → hit Download,
verify progress.

**Commit:** `feat(task-2.3): onboarding WhisperKit download progress`

---

### TASK-2.4 — Provider Test gates on model readiness

- **Blocked by:** `TASK-2.2` (reuses `isModelDownloaded`)
- **Parallel with:** anything not in Phase 2
- **Files:** `Sources/VoiceRefine/Settings/ProviderTestRunner.swift`

**Rationale.** `testTranscription` sends 1 s of silence; if the
WhisperKit model isn't pulled, this triggers a ~142 MB download
with no progress UI and the button stuck on "Testing…" for minutes.
Same trap for Apple Speech if the locale asset isn't installed.

**Implementation.**
1. In `testTranscription(_ id:)`:
   - For `.whisperKit`: check `WhisperKitProvider.isModelDownloaded(model)`.
     If false, return
     `ProviderTestOutcome(isError: true, latency: 0,
     message: "Model not downloaded — use the Download button first.")`.
   - For `.appleSpeech` with `#available(macOS 26, *)`: await
     `AppleSpeechAssetManager.isInstalled(localeID: model)`. If false,
     return the equivalent message.
2. Cloud providers unchanged.

**Acceptance.**
- [ ] Test button with an un-downloaded model returns instantly with
      a clear message.
- [ ] Test button with a downloaded model still runs the 1 s
      silence probe and reports latency.

**Manual test.** Wipe the model folder, click Test — instant
"not downloaded" message. Download the model, click Test —
"OK · model ready · reply: (empty — expected for silence)".

**Commit:** `fix(task-2.4): Test button gates on model readiness`

---

## Phase 3 — Privacy & security

Runs in parallel with Phase 2; each task touches a disjoint set of
files from the others.

### TASK-3.1 — Default `contextCaptureBeforeCursor` off for cloud refiners

- **Blocked by:** `none`
- **Parallel with:** Phase 2
- **Files:**
  - `Sources/VoiceRefine/Settings/Preferences.swift`
    (add `PrefKey.contextCaptureBeforeCursorCloud`, default `false`)
  - `Sources/VoiceRefine/Context/ContextGatherer.swift` (lookup change)
  - `Sources/VoiceRefine/Settings/GeneralTab.swift` (copy update)
  - `Sources/VoiceRefine/Settings/RefinementTab.swift` (inline warning
    shown when selected refiner is non-local)

**Rationale.** When the refiner is cloud (Anthropic / OpenAI /
DeepSeek / OpenAI-compat), every dictation sends up to 1500 chars
of surrounding text. Password manager blocklist covers explicit
secret fields but not the general "leaking my IDE / terminal"
surface.

**Implementation.**
1. New pref `contextCaptureBeforeCursorCloud` (default `false`).
2. In `ContextGatherer.gather()`, add:
   ```swift
   let providerID = RefinementProviderID(
       rawValue: defaults.string(forKey: PrefKey.selectedRefinementProvider) ?? ""
   ) ?? .ollama
   let allowForCurrentProvider = providerID.isLocal
       ? captureBefore
       : (captureBefore && defaults.bool(forKey: PrefKey.contextCaptureBeforeCursorCloud))
   ```
   and use `allowForCurrentProvider` as the gate for reading
   `textBeforeCursor`.
3. In `GeneralTab`, footer under the "Use text before cursor" toggle:
   "Local refiners (Ollama, No-Op) always receive this. Cloud refiners
   receive it only if the separate toggle on the Refinement tab is
   enabled."
4. In `RefinementTab`, when the current provider is non-local, show
   a yellow-tinted box:
   - `Toggle("Send text-before-cursor context to \(provider.displayName)",
     isOn: $captureBeforeCloud)`
   - Footer: "Off by default — cloud providers receive no surrounding
     text even with the General toggle on."

**Acceptance.**
- [ ] Switching between Ollama and OpenAI while the General toggle is
      on changes `context.textBeforeCursor` presence per the rule
      above (verify via the `context.log` diagnostic).
- [ ] Fresh install has the cloud toggle off.
- [ ] No regression for users who only ever use Ollama (they never see
      the new toggle).

**Manual test.** Enable General → "Use text before cursor"; switch
refiner to OpenAI; dictate in any app; check
`~/Library/Logs/VoiceRefine/context.log` — `beforeCursor=none`.
Toggle the Refinement-tab cloud override on; dictate again;
`beforeCursor=N chars`.

**Commit:** `feat(task-3.1): gate textBeforeCursor for cloud refiners`

---

### TASK-3.2 — Log rotation for `paste.log` and `context.log`

- **Blocked by:** `none`
- **Parallel with:** Phase 2, other Phase 3 tasks
- **Files:**
  - `Sources/VoiceRefine/Paste/PasteEngine.swift`
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift`
  - `Sources/VoiceRefine/Settings/AdvancedTab.swift` (add toggle)
  - `Sources/VoiceRefine/Settings/Preferences.swift` (add
    `PrefKey.diagnosticLogsEnabled`, default `true`)
  - Optionally: new helper
    `Sources/VoiceRefine/App/DiagnosticLog.swift`

**Rationale.** Both files append forever — a year of heavy dictation
is a character-count timeline of the user. Also, `AXIsProcessTrusted`
state is essentially a privileged-operations log.

**Implementation.**
1. Extract both `appendDiagnostic` helpers into a shared
   `DiagnosticLog.append(to: URL, line: String)` that:
   - Gates on `UserDefaults.standard.bool(forKey:
     PrefKey.diagnosticLogsEnabled)`; default is `true`.
   - Before writing, checks file size. If > 1 MB (configurable
     constant), renames existing `foo.log` → `foo.log.1`,
     overwriting any prior `.1`. Then appends to a fresh `foo.log`.
2. In `AdvancedTab`, add
   `Toggle("Diagnostic logs (paste + context)", isOn: $diagnosticLogsEnabled)`
   with a footer line explaining what's logged (counts only; never
   content) and where.
3. Keep the current NSLog-based log lines unchanged.

**Acceptance.**
- [ ] Seed a `paste.log` ≥ 1 MB, trigger a paste — previous log
      rotated to `paste.log.1`, new `paste.log` contains a single
      line.
- [ ] Toggle off → no new lines appended anywhere.
- [ ] Existing "Reveal logs folder" button still works.

**Manual test.** `yes "" | head -c 1200000 >
~/Library/Logs/VoiceRefine/paste.log; dictate; ls -la
~/Library/Logs/VoiceRefine/` — see `paste.log.1` with the old bytes
and a fresh `paste.log` with one line.

**Commit:** `feat(task-3.2): rotate diagnostic logs at 1 MB`

---

### TASK-3.3 — Per-app context-capture denylist

- **Blocked by:** `none`
- **Parallel with:** Phase 2, other Phase 3 tasks (no file conflict
  with 3.1: different toggle, different UI surface)
- **Files:**
  - `Sources/VoiceRefine/Context/ContextGatherer.swift`
  - `Sources/VoiceRefine/Settings/Preferences.swift` (new key
    `contextBundleIDDenylist`, default `""`)
  - `Sources/VoiceRefine/Settings/AdvancedTab.swift` (new Section)

**Rationale.** The hardcoded password-manager list covers one case.
Users want an escape hatch for their own sensitive apps
(Slack, Mail, 1Password-equivalents, private channels).

**Implementation.**
1. New pref `contextBundleIDDenylist` — newline-separated bundle IDs.
2. In `ContextGatherer.gather()`, when the frontmost bundle ID matches
   the denylist, return `RawContext(appName: …, windowTitle: nil,
   selectedText: nil, textBeforeCursor: nil)` — keep app name only
   (low risk) but skip every AX read. Log one line:
   `"context skipped (denylisted bundle=…)"`.
3. `AdvancedTab` gets a new Section with a `TextEditor` (monospace,
   4–6 lines tall) bound to the pref, plus a short footer listing the
   hardcoded password-manager IDs that are always skipped.

**Acceptance.**
- [ ] Adding `com.tinyspeck.slackmacgap` to the denylist means a
      dictation focused on Slack produces no AX reads
      (`context.log` shows the skip line).
- [ ] Removing it restores previous behavior on next dictation.
- [ ] Whitespace / blank lines in the editor are tolerated.

**Manual test.** Add `com.apple.Mail` to the denylist; dictate with
Mail focused; check `context.log`; paste target still works (app
name captured, rest skipped).

**Commit:** `feat(task-3.3): per-app context capture denylist`

---

## Phase 4 — Pipeline robustness

Starts after Phase 2 drains (shares no files but benefits from the
stable Transcription UI). Parallel with 3 if 2 is already merged.

### TASK-4.1 — Cancellation inside `AppleSpeechProvider`

- **Blocked by:** `TASK-0.1` (for the test case that verifies
  cancellation unwinds cleanly)
- **Parallel with:** `TASK-4.2`, `TASK-4.3`
- **Files:** `Sources/VoiceRefine/Transcription/AppleSpeechProvider.swift`

**Rationale.** Invariant #9 ("all async work is cancellable") is
partially violated. The `for try await result in transcriber.results`
loop doesn't check `Task.isCancelled`; a hotkey press during a long
transcription starts a new recording but leaves the previous
SpeechAnalyzer running.

**Implementation.**
1. Inside the `collectTask`:
   ```swift
   for try await result in transcriber.results where result.isFinal {
       try Task.checkCancellation()
       out += String(result.text.characters)
   }
   ```
2. Wrap the `analyzer.analyzeSequence` + `finalizeAndFinishThroughEndOfInput`
   block: before the outer `return`, add a `Task.isCancelled` check
   that `analyzer.cancelAndFinishNow()` and throws `CancellationError()`.
3. `DictationPipeline.currentTranscriptionTask?.cancel()` already
   fires on `beginRecording`; this task makes that cancel propagate
   into Apple Speech, not just the outer wrapper.

**Acceptance.**
- [ ] A dictation → while the analyzer is still running, press the
      hotkey again → the first analyzer's task raises
      `CancellationError` and unwinds within < 100 ms.
- [ ] Non-cancelled happy path unchanged.
- [ ] `AsyncStream` continuation is always `finish`ed (check with an
      artificial throw).

**Manual test.** Dictate 60 s (well into the max cap) while keeping an
eye on Activity Monitor → VoiceRefine CPU. Interrupt with a second
press. CPU drops immediately, not after the original analyzer would
have finished.

**Commit:** `fix(task-4.1): propagate cancellation into AppleSpeechProvider`

---

### TASK-4.2 — Inject factories into `DictationPipeline`

- **Blocked by:** `TASK-0.1`
- **Parallel with:** `TASK-4.1`, `TASK-4.3`
- **Files:**
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift`
  - `Sources/VoiceRefine/Settings/ProviderTestRunner.swift` (already
    has the factories — ensure pipeline reuses them)

**Rationale.** `DictationPipeline` eagerly instantiates every
provider at init. Ties the pipeline to concrete classes, blocks unit
testing.

**Implementation.**
1. Delete the per-provider `let whisperKitProvider = …` fields.
2. Add:
   ```swift
   init(
       transcriptionFactory: @escaping (TranscriptionProviderID) -> any TranscriptionProvider
           = TranscriptionProviderFactory.make,
       refinementFactory: @escaping (RefinementProviderID) -> any RefinementProvider
           = RefinementProviderFactory.make
   )
   ```
3. Cache the last-resolved providers to avoid reconstructing every
   press:
   ```swift
   private var cachedTranscription: (TranscriptionProviderID, any TranscriptionProvider)?
   ```
   Re-resolve only on ID change.
4. Add `DictationPipelineTests` with a mock refiner that returns a
   canned string — assert `onTranscript` fires with it.

**Acceptance.**
- [ ] Hot path allocates no new provider objects when provider ID
      hasn't changed.
- [ ] Test `DictationPipelineTests.testRefinePassesThroughContext`
      constructs a pipeline with a mock refiner and verifies the
      pipeline calls `refine` with the expected context.
- [ ] End-to-end manual dictation unchanged.

**Manual test.** Dictate normally. Monitor via `Instruments → Allocations`
that repeated dictations don't accumulate `OllamaProvider` instances.

**Commit:** `refactor(task-4.2): inject provider factories into pipeline`

---

### TASK-4.3 — Retry-last menu action + 20-entry in-memory history

- **Blocked by:** `TASK-4.2` (uses the cleaner pipeline API)
- **Parallel with:** `TASK-4.1`
- **Files:**
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift` (expose
    `lastEntry`, `history`)
  - `Sources/VoiceRefine/MenuBar/MenuBarController.swift` (new menu
    items)
  - `Sources/VoiceRefine/App/AppDelegate.swift` (wiring)

**Rationale.** PLAN §v1.2 calls for in-memory history + "Retry last".
The stub removed in TASK-1.2 referenced the history surface. Most
common failure mode is a transient refinement error; users want to
re-run without re-dictating.

**Implementation.**
1. Add to `DictationPipeline`:
   ```swift
   struct HistoryEntry {
       let timestamp: Date
       let raw: String
       let refined: String
       let context: RefinementContext
   }
   private(set) var history: [HistoryEntry] = []
   var lastEntry: HistoryEntry? { history.last }
   ```
   Push on successful refine (after leak check passes). Cap at 20 via
   `if history.count > 20 { history.removeFirst() }`.
2. Add `func retryLast() async` that re-runs refinement on the last
   entry's `raw` + `context`, then calls `onTranscript(refined)`. Skips
   silently if `history` is empty.
3. Add `func pasteLastRefined()` that calls `onTranscript` with
   `lastEntry?.refined` if present.
4. `MenuBarController`: above "Settings…", insert:
   - `"Retry last"` — enabled iff `lastEntry != nil`; calls `retryLast`.
   - `"Paste last refined"` — enabled iff `lastEntry != nil`; calls
     `pasteLastRefined`.
   - Separator.
5. Menu items need to be enabled/disabled dynamically. Use
   `NSMenuDelegate.menuWillOpen(_:)` to refresh state.

**Acceptance.**
- [ ] After one successful dictation, both menu items are enabled
      and do what they say.
- [ ] After pipeline error (refinement failure → raw pasted), history
      still records the raw entry and "Retry last" attempts refinement
      again.
- [ ] History is ephemeral (lost on app quit). No disk persistence
      yet — that's a future task.

**Manual test.** Stop Ollama (`pkill ollama`), dictate — raw is pasted,
notification shows refinement error. Restart Ollama. Click menu →
"Retry last" — cleaned version is pasted.

**Commit:** `feat(task-4.3): retry-last menu + in-memory history`

---

## Phase 5 — Refactor & hygiene

Sweeping changes. Run sequentially; needs stable tests from TASK-0.1.

### TASK-5.1 — Extract cloud-provider keychain boilerplate

- **Blocked by:** Phase 4 complete (avoids merge conflicts)
- **Parallel with:** nothing in Phase 5
- **Files:**
  - `Sources/VoiceRefine/Refinement/CloudProviderSupport.swift` (new)
  - `Sources/VoiceRefine/Refinement/OpenAIProvider.swift`
  - `Sources/VoiceRefine/Refinement/DeepSeekProvider.swift`
  - `Sources/VoiceRefine/Refinement/AnthropicProvider.swift`
  - `Sources/VoiceRefine/Refinement/OpenAICompatibleProvider.swift`
  - `Sources/VoiceRefine/Transcription/GroqWhisperProvider.swift`
  - `Sources/VoiceRefine/Transcription/OpenAIWhisperProvider.swift`

**Rationale.** Six providers each reimplement "fetch key from Keychain
by account; throw `missingAPIKey` if empty". Five define near-identical
`ProviderError` enums. Redundant and a change-amplifier when the
keychain lookup semantics evolve.

**Implementation.**
1. New `CloudProviderSupport.swift` containing:
   ```swift
   enum CloudProviderError: Error, CustomStringConvertible { … }
   func loadAPIKey(for id: some Identifiable) throws -> String
   ```
2. Each provider's `ProviderError` gains a `case cloud(CloudProviderError)`
   variant (keep existing cases for backwards-compat; deprecate over
   time).
3. Keychain lookup becomes a single call per provider.
4. Do **not** change public API shapes — `refine` / `transcribe`
   signatures untouched.

**Acceptance.**
- [ ] All six providers compile and pass their existing test-button
      flows (manual verify each).
- [ ] Diff in each provider file is a net reduction of 10–20 LOC.
- [ ] `CloudProviderSupport.swift` has its own small test file
      covering the `missingAPIKey` and "key present" branches.

**Manual test.** Settings → Refinement, run Test on each cloud
provider with and without a key.

**Commit:** `refactor(task-5.1): extract cloud-provider keychain helper`

---

### TASK-5.2 — Move `RefinementMessageBuilder` to its own file

- **Blocked by:** `TASK-5.1` (only to keep refactor-diffs readable)
- **Parallel with:** nothing in Phase 5
- **Files:**
  - `Sources/VoiceRefine/Refinement/RefinementProvider.swift`
    (remove the builder enum)
  - `Sources/VoiceRefine/Refinement/RefinementMessageBuilder.swift`
    (new)

**Rationale.** `RefinementMessageBuilder` is substantive prompt logic
(the METADATA-ordering rationale runs ~30 lines of comments) currently
tucked into the protocol file. Extracting makes it obvious where to
look when tuning prompts, and invites a sibling
`RefinementMessageBuilderTests.swift`.

**Implementation.** Lift-and-shift. No behavior change. Add a
`RefinementMessageBuilderTests` test file asserting the output for
three representative inputs (transcript only, transcript + context,
transcript + context + glossary).

**Acceptance.**
- [ ] `swift test` passes.
- [ ] `grep -n RefinementMessageBuilder
      Sources/VoiceRefine/Refinement/RefinementProvider.swift` returns
      zero matches.
- [ ] All provider call sites unchanged.

**Manual test.** End-to-end dictation. Diff the resulting HTTP body
against pre-refactor (via `mitmproxy` or a temporary NSLog of the
request body).

**Commit:** `refactor(task-5.2): RefinementMessageBuilder in its own file`

---

### TASK-5.3 — Concurrency discipline sweep

- **Blocked by:** `TASK-0.2`, Phase 4 complete, `TASK-5.2`
- **Parallel with:** nothing in Phase 5
- **Files:** broad — enumerate in the PR description. Expected:
  - `Sources/VoiceRefine/App/AppDelegate.swift`
  - `Sources/VoiceRefine/MenuBar/MenuBarController.swift`
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift`
  - `Sources/VoiceRefine/Hotkey/HotkeyManager.swift`
  - `Sources/VoiceRefine/Paste/PasteEngine.swift`
  - `Sources/VoiceRefine/Audio/AudioRecorder.swift`
  - `Package.swift` (optional: enable
    `.enableExperimentalFeature("StrictConcurrency")`)

**Rationale.** Current code mixes `DispatchQueue.main.async`,
`Task { @MainActor in }`, `await MainActor.run { }`, and
`if Thread.isMainThread`. Pick one idiom per role and migrate.

**Implementation.**
1. Annotate `AppDelegate`, `MenuBarController`, `SettingsWindowController`,
   `DictationPipeline`, `HotkeyManager` as `@MainActor` classes.
2. Replace `DispatchQueue.main.async { … }` inside `@MainActor`
   methods with direct calls (no dispatch needed).
3. Replace `DispatchQueue.main.asyncAfter(deadline: …)` with
   ```swift
   Task { @MainActor in
       try? await Task.sleep(for: .milliseconds(…))
       …
   }
   ```
   *except* where the existing DispatchWorkItem is cancellable
   (e.g. `scheduleMaxDurationCutoff`) — keep those.
4. `AudioRecorder`: replace `DispatchQueue.sync { … }` with
   `OSAllocatedUnfairLock<Data>` (iOS 16 / macOS 13+). Benchmark
   before/after; expect no regression for the user-perceived path.
5. `NotificationDispatcher`: convert to an `actor` — eliminates the
   `nonisolated(unsafe)` bytes entirely.
6. Add `.enableExperimentalFeature("StrictConcurrency")` in
   `Package.swift`'s `swiftSettings`. Resolve warnings **or** (in
   scope of this task) explicitly `@preconcurrency` the noisy
   dependencies.

**Acceptance.**
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits no
      errors (warnings tolerated; list in PR).
- [ ] `@testable` tests still pass.
- [ ] End-to-end dictation still works; no new "Main thread
      checker" warnings in Console.

**Manual test.** Dictate repeatedly (20+ times) with Main Thread
Checker enabled (set `MTC_CrashOnCheckFailed=YES` in scheme env) — no
crashes.

**Commit:** `refactor(task-5.3): concurrency discipline sweep`

---

## Phase 6 — Optional / exploratory features

Not urgent. Each is a substantial workstream on its own. Coordinate
with the repo owner before starting — some violate invariants
(SPM-dependency cap) or add maintenance burden.

### TASK-6.1 — Hotkey customization escape hatch

- **Blocked by:** `none`
- **Parallel with:** anything post-Phase-1
- **Files:**
  - `Sources/VoiceRefine/Hotkey/HotkeyManager.swift`
  - `Sources/VoiceRefine/Hotkey/HotkeyGestures.swift` (new — pull the
    state machine out; add alternatives)
  - `Sources/VoiceRefine/Settings/GeneralTab.swift`
  - `Sources/VoiceRefine/Settings/Preferences.swift`

**Rationale.** CLAUDE.md: "If a future user asks to customize the
hotkey, this decision is the thing to reopen." Some users have
modified layouts (Dvorak) or Caps-as-Control setups that make
Shift-double-tap awkward. Claude Desktop collision may also resurface.

**Implementation.**
1. Introduce `HotkeyGesture` enum: `.doubleTapShiftHold` (current),
   `.doubleTapOptionHold`, `.chordControlOptionCommand` (hold while
   the chord is down), `.fnKey` (macOS-only special key).
2. `HotkeyManager` picks a driver per `HotkeyGesture`, defined behind
   a protocol:
   ```swift
   protocol HotkeyDriver {
       init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void)
       func unregister()
   }
   ```
3. Store pref key `hotkeyGesture` (string-enum). Default stays
   `.doubleTapShiftHold` for existing installs.
4. GeneralTab gets a Picker under "Hotkey" with the four options and
   a "More in docs →" link.
5. Keep the hold-confirm threshold configurable (existing
   `holdConfirmDuration` → new pref with a default).

**Acceptance.**
- [ ] Each of four gestures fires `onPress` / `onRelease` when
      performed; none of them false-fires during normal typing
      (verified manually by typing a long paragraph).
- [ ] Switching gestures in Settings takes effect without app
      restart.
- [ ] Existing users' default is preserved.

**Manual test.** Switch to `.chordControlOptionCommand`; hold
⌃⌥⌘ while dictating; release — pipeline runs.

**Commit:** `feat(task-6.1): customizable hotkey gesture`

---

### TASK-6.2 — Recording HUD overlay

- **Blocked by:** `none`
- **Parallel with:** anything post-Phase-1
- **Files:**
  - `Sources/VoiceRefine/MenuBar/RecordingHUDController.swift` (new)
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift` (tie
    to state changes)
  - `Sources/VoiceRefine/Settings/GeneralTab.swift` (toggle)
  - `Sources/VoiceRefine/Settings/Preferences.swift` (new
    `PrefKey.showRecordingHUD`, default `true`)

**Rationale.** Menu-bar icon can hide behind the notch; users miss the
recording state.

**Implementation.**
1. Borderless translucent `NSWindow` at `.screenSaver` level, 120×40
   px, centered near the top of the main screen.
2. SwiftUI content: animated `waveform` SF Symbol pulsing + "Recording".
3. Controller listens to pipeline state: show on `.recording`, hide
   with a 200 ms fade-out on `.idle`/`.error`.
4. Preference toggle in GeneralTab.

**Acceptance.**
- [ ] HUD appears within 100 ms of hotkey press; disappears within
      250 ms of release.
- [ ] HUD is click-through (doesn't steal focus or intercept clicks).
- [ ] Toggle off completely disables the HUD.

**Manual test.** Dictate with a full-screen app active — HUD visible
over it.

**Commit:** `feat(task-6.2): recording HUD overlay`

---

### TASK-6.3 — Per-app system-prompt overrides

- **Blocked by:** `TASK-4.2`
- **Parallel with:** anything post-Phase-1
- **Files:**
  - `Sources/VoiceRefine/Settings/PerAppPromptsView.swift` (new tab
    or sub-section)
  - `Sources/VoiceRefine/Settings/Preferences.swift` (JSON-encoded
    dict pref)
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift` (lookup)

**Rationale.** Heavy users want different refinement per target app
(code vs email vs chat).

**Implementation.**
1. Store `{bundleID: prompt}` as JSON-encoded `Data` in UserDefaults
   under `PrefKey.perAppPrompts`.
2. `DictationPipeline.refine`: before system prompt fallback, look up
   `context.frontmostApp`'s bundle ID in the dict. If present, use
   that prompt.
3. UI: list rows `{bundleID, app display name, truncated prompt, Edit}`;
   "Add…" button runs `NSOpenPanel` to pick an `.app` and reads its
   bundle ID.

**Acceptance.**
- [ ] Per-app prompt takes effect only for the named app; others use
      the default.
- [ ] Deleting an override restores the default for that app.
- [ ] Round-trip survives quit + relaunch.

**Manual test.** Add an override for TextEdit that says "always reply
in ALL CAPS" (obvious signature). Dictate into TextEdit → output is
uppercase. Dictate into Mail → normal output.

**Commit:** `feat(task-6.3): per-app system prompt overrides`

---

### TASK-6.4 — Streaming transcription with Apple Speech

- **Blocked by:** `TASK-4.1`, `TASK-6.2` (optional; streaming feels
  best with a HUD)
- **Parallel with:** `TASK-6.3`, `TASK-6.5`, `TASK-6.6`
- **Files:**
  - `Sources/VoiceRefine/Transcription/AppleSpeechProvider.swift`
    (add streaming mode)
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift` (consume
    partials if enabled)
  - `Sources/VoiceRefine/MenuBar/RecordingHUDController.swift` (if
    TASK-6.2 is merged: show partials)
  - `Sources/VoiceRefine/Settings/Preferences.swift` (toggle)

**Rationale.** Apple's `SpeechAnalyzer` exposes `isFinal == false`
partials. Showing a live transcript shrinks perceived latency on long
dictations.

**Implementation.**
1. Add `AppleSpeechProvider.transcribeStreaming(audioSource:) ->
   AsyncSequence<String>` that yields running partials; completion
   triggers refinement as today.
2. Pipeline reads from the sequence; routes partials to HUD / a
   callback.
3. Off by default behind a `GeneralTab` toggle.
4. Gated `@available(macOS 26, *)`; WhisperKit path unchanged.

**Acceptance.**
- [ ] Toggle on: HUD shows running transcript while recording.
- [ ] Toggle off: identical behavior to TASK-4.1's end state.
- [ ] Cancellation still unwinds cleanly.

**Manual test.** Dictate a long sentence; HUD fills in words as you
speak.

**Commit:** `feat(task-6.4): streaming Apple Speech transcription`

---

### TASK-6.5 — MLX local refinement provider

- **Blocked by:** explicit user sign-off (violates invariant #5
  — SPM dep count)
- **Parallel with:** other Phase 6 tasks (disjoint files)
- **Files:**
  - `Package.swift` (add `mlx-swift` dep)
  - `Sources/VoiceRefine/Refinement/MLXProvider.swift` (new)
  - `Sources/VoiceRefine/Refinement/RefinementProviderID.swift`
    (add `.mlx` case)
  - `Sources/VoiceRefine/Settings/RefinementTab.swift` (row)
  - `Sources/VoiceRefine/Pipeline/DictationPipeline.swift` (case)

**Rationale.** Fully-self-contained alternative to Ollama —
in-process inference of a small (≤ 4B) model via MLX. No daemon.
But: adds a major SPM dep and 200–600 MB runtime memory footprint
when loaded.

**Implementation.**
1. `mlx-swift` (+ possibly `mlx-swift-examples` for tokenization)
   as an SPM dependency. Document the size in README.
2. Ship no model — first use downloads a Hugging Face repo
   (Qwen-2.5-0.5B-instruct or similar 1-to-4B) to
   `~/Library/Application Support/VoiceRefine/models/mlx/<variant>/`.
3. Implement `MLXProvider.refine` that loads the model on first call
   (cached thereafter), runs chat template + sampler with the same
   system prompt / user message shape as other refiners.
4. RefinementTab row includes a model picker (`0.5B`, `1.5B`, `4B`) and
   a Download button.

**Acceptance.**
- [ ] `make build` succeeds with the new dep.
- [ ] End-to-end dictation → MLX refinement produces a cleaned
      output comparable to `qwen2.5:7b` via Ollama (qualitative).
- [ ] Zero outbound traffic after the initial model download
      (verify with Little Snitch).

**Manual test.** Quit Ollama, switch refiner to MLX, dictate — still
works.

**Commit:** `feat(task-6.5): MLX in-process refinement provider`

---

### TASK-6.6 — Distribution: notarization + Sparkle appcast

- **Blocked by:** explicit user sign-off (adds Sparkle as SPM dep,
  plus Developer ID and notarization infrastructure)
- **Parallel with:** other Phase 6 tasks
- **Files:**
  - `Makefile` (add `notarize`, `dmg`, `release` targets)
  - `scripts/notarize.sh` (new)
  - `scripts/make-dmg.sh` (new)
  - `Package.swift` (add Sparkle)
  - `Sources/VoiceRefine/App/AppDelegate.swift` (Sparkle driver)
  - `Resources/Info.plist` (`SUFeedURL`, `SUPublicEDKey`)

**Rationale.** Enable shipping to non-dev users. Also fixes the
decisions-log concern that ad-hoc rebuilds break TCC grants — a
proper Developer ID signature does not.

**Implementation.**
1. `Makefile.notarize` wraps `codesign --sign "Developer ID
   Application: …"`, `xcrun notarytool submit`, and `stapler staple`.
2. `make-dmg.sh` builds a read-only DMG with a symlink to
   `/Applications` (`create-dmg` tool or hand-rolled).
3. Sparkle config: appcast hosted on GitHub Pages via
   `docs/appcast.xml`; `SUFeedURL` points there; `SUPublicEDKey`
   generated with `generate_keys` (key pair stored in the repo
   owner's password manager — **not** in the repo).
4. Add a "Check for updates…" menu item.

**Acceptance.**
- [ ] `make release TAG=v0.2.0` produces a signed, notarized,
      stapled DMG that installs on a clean Mac without
      "app is damaged" warnings.
- [ ] Existing installs auto-detect the new appcast entry and prompt
      to update.
- [ ] Secrets (Developer ID P12, notarization creds) are not
      committed; scripts read them from env.

**Manual test.** Install the notarized DMG on a clean VM; grant
permissions; dictate; works.

**Commit:** `feat(task-6.6): notarization + Sparkle auto-update`

---

## Appendix A — Parallel execution scenarios

**Scenario 1: one agent.**
Do Phases in order: 0 → 1 → 2 → 3 → 4 → 5 → 6. Expected elapsed:
~3 full sessions for phases 0–5, plus per-feature sessions for phase 6.

**Scenario 2: two agents, shared repo.**
- Agent A takes Phase 0 sequentially, then Phase 2 (sequential), then 4.
- Agent B starts Phase 1 in parallel with A's Phase 0, then all of
  Phase 3, then joins A on Phase 4 (splitting 4.1/4.2/4.3).
- Merge conflicts expected only in Phase 5 — that's single-agent.

**Scenario 3: four agents, maximum concurrency.**
- Agent A: TASK-0.1 → Phase 2 chain (2.1 → 2.2 → 2.3 → 2.4).
- Agent B: TASK-0.2 → TASK-3.1 → TASK-4.2.
- Agent C: TASK-1.1 + TASK-1.3 + TASK-1.5 + TASK-3.2 → TASK-4.1.
- Agent D: TASK-1.2 + TASK-1.4 + TASK-1.6 + TASK-1.7 + TASK-3.3 →
  TASK-4.3.
- After all four converge, one agent takes Phase 5.
- Phase 6 is ambient — pick up any time.

---

## Appendix B — Orchestrator prompt template

Copy into a fresh Claude Code session to run as the orchestrator. The
orchestrator **never implements tasks directly** — it only assigns,
verifies, checkpoints, and updates the plan.

> You are the orchestrator for the VoiceRefine revision described in
> `REVIEW_PLAN.md`.
>
> **Hard rules.** You may use `Agent`, `Bash`, `Read`, `Edit`, `Write`,
> `Grep`, `Glob`. You MUST NOT implement tasks yourself — every
> implementation goes through a spawned `Agent` running the worker
> prompt template. You MUST NOT merge PRs — that's the reviewer's job.
>
> **On "start next" from the reviewer:**
> 1. `gh pr list --state merged --limit 30 --search "in:title TASK-"`
>    → list of merged task IDs.
> 2. `gh pr list --state open --limit 30 --search "in:title TASK-"`
>    → list of in-flight task IDs.
> 3. Scan `REVIEW_PLAN.md` for the lowest-numbered task whose
>    **Blocked by** list is fully in "merged" and whose **Files** list
>    doesn't overlap any "in-flight" task.
> 4. If found, spawn an `Agent` with the worker prompt template from
>    `REVIEW_PLAN.md` §"Agent prompt template (worker)", substituting
>    the chosen TASK-X.Y. Post a one-liner back summarising which task
>    you assigned and why.
> 5. If nothing is eligible, report the blockers.
>
> **On "checkpoint" from the reviewer:** run the commands in
> `REVIEW_PLAN.md` §"Phase checkpoints" for the most recently
> completed phase. If all pass, update `REVIEW_PLAN.md` to mark the
> phase done and commit (`docs(plan): complete phase-N`). If any
> fails, surface the failure and do NOT update the plan.
>
> **On "conflict" from a worker:** apply
> `REVIEW_PLAN.md` §"Conflict-resolution protocol". Record the
> decision as a comment on both PRs via `gh pr comment`.
>
> **On "convention question" from a worker:** check
> `REVIEW_PLAN.md` §"Conventions" first. If the table has an answer,
> point to it. If the table is silent, surface the question to the
> reviewer; don't invent a new convention yourself.
>
> **On "task impossible" from a worker:** close their PR with
> context, edit `REVIEW_PLAN.md` to reflect the new reality (re-scope
> or drop), commit (`docs(plan): re-scope TASK-X.Y — rationale`), then
> either re-assign or report back.
>
> Every response you give should end with one line of current state:
> `STATE: <N merged / M in-flight / K eligible>`. Keep your prose
> short — orchestration is a dispatch loop, not a design exercise.

---

## Appendix C — A concrete first day (four-agent scenario)

Illustrative, not prescriptive. Assumes reviewer is around to merge.

| t     | Orchestrator action                       | A (worker)       | B (worker)       | C (worker)       | D (worker)       |
|-------|-------------------------------------------|------------------|------------------|------------------|------------------|
| 0:00  | Assign TASK-0.1 (scaffold XCTest)         | TASK-0.1 start   | —                | —                | —                |
| 0:00  | Assign TASK-0.2 (tools bump)              |                  | TASK-0.2 start   | —                | —                |
| 0:20  | Reviewer merges 0.2                       |                  | ✅ merged         |                  |                  |
| 0:30  | Reviewer merges 0.1                       | ✅ merged         |                  |                  |                  |
| 0:35  | Assign 1.1 / 1.2 / 1.3 / 1.4              | TASK-1.1         | TASK-1.2         | TASK-1.3         | TASK-1.4         |
| 1:00  | All four merge                            | ✅                | ✅                | ✅                | ✅                |
| 1:05  | Assign 1.5 / 1.6 / 1.7 / 2.1              | TASK-1.5         | TASK-1.6         | TASK-1.7         | TASK-2.1         |
| 1:05  | Also: assign 3.1 / 3.2 (disjoint)         | (already busy)   | (already busy)   | — then 3.1       | — then 3.2       |
| 2:00  | Checkpoint: Phase 1 + 2.1 done            | Orchestrator runs `swift test && make run`. Green. Updates plan. Commits. |
| …     | Phase 2 sequential, Phase 3 parallel      | TASK-2.2         | TASK-3.3         |  TASK-3.1 cont'd | TASK-3.2 cont'd  |
| …     | Phase 4 begins once Phase 2 drains        | TASK-4.1         | TASK-4.2         | TASK-4.3         | (idle)           |
| …     | Phase 5 single-agent                      | TASK-5.1 → 5.2 → 5.3 (one worker, sequential) |

Reviewer is the bottleneck, not agents. If the reviewer merges 8 PRs/day
at 4-agent concurrency, Phase 1–4 ship in ~1 working day.

---

## Appendix D — Invariant compliance checklist

Every PR must affirm:

- [ ] Apple Silicon arm64, macOS 14+ floor unchanged (or
      `@available`-gated if bumping anything).
- [ ] App Sandbox entitlement not added.
- [ ] `LSUIElement = YES` preserved.
- [ ] Default config still zero outbound (unless the PR is a cloud
      provider — then note it).
- [ ] SPM dep cap respected (TASK-6.5 / TASK-6.6 are the only
      explicit exceptions, requiring user sign-off).
- [ ] No analytics / telemetry / crash-reporting added.
- [ ] No API keys logged; no force unwraps outside always-loaded
      cases.
- [ ] All async work cancellable; hotkey releases cleanly on error;
      pasteboard restored.
- [ ] Errors user-visible via `UNUserNotificationCenter` (or clear
      in-tab surface) — never silent.
