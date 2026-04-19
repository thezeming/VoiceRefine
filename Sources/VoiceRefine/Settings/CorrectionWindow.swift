import AppKit
import SwiftUI

// MARK: - Window controller

/// Presents the "Correct last…" editor and wires Save / Cancel.
///
/// The SwiftUI view is rebuilt on every `present()` (when the window isn't
/// already visible) so `@State` reflects the *current* `TranscriptionHistory`
/// entry. NSHostingController + a hidden NSWindow doesn't reliably re-fire
/// `.onAppear` when the window is brought back to front, so relying on it
/// gave an empty editor whenever the user pressed ⌥⌘R after dictation.
final class CorrectionWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        // Placeholder content — real CorrectionView is installed on first present().
        let placeholder = NSHostingController(rootView: Color.clear.frame(width: 560, height: 280))
        let window = NSWindow(contentViewController: placeholder)
        window.styleMask = [.titled, .closable]
        window.title = "Correct Last Dictation"
        window.setContentSize(NSSize(width: 560, height: 280))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            let entry = TranscriptionHistory.shared.mostRecent()
            NSLog("VoiceRefine: CorrectLast present — entry=\(entry == nil ? "nil" : "refined=\(entry!.refined.count)c, raw=\(entry!.raw.count)c, bundle=\(entry!.frontmostAppBundleID ?? "-")")")

            let view = CorrectionView(
                initialRefined: entry?.refined ?? "",
                initialRaw: entry?.raw ?? "",
                initialBundleID: entry?.frontmostAppBundleID,
                dismiss: { [weak self] in self?.window?.close() }
            )
            window.contentViewController = NSHostingController(rootView: view)
            // NSHostingController propagates the SwiftUI view's intrinsic
            // size to preferredContentSize, which shrinks the window to a
            // tiny "just fits the buttons" rectangle. Force the size back
            // to the design dimensions after every swap.
            window.setContentSize(NSSize(width: 560, height: 280))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Nothing to clean up — the next present() rebuilds contentViewController.
    }
}

// MARK: - SwiftUI view

private struct CorrectionView: View {
    @State private var editedText: String
    private let originalRefined: String
    private let rawTranscript: String
    private let targetBundleID: String?
    private let dismiss: () -> Void

    init(
        initialRefined: String,
        initialRaw: String,
        initialBundleID: String?,
        dismiss: @escaping () -> Void
    ) {
        _editedText = State(initialValue: initialRefined)
        self.originalRefined = initialRefined
        self.rawTranscript = initialRaw
        self.targetBundleID = initialBundleID
        self.dismiss = dismiss
    }

    private var hasRecent: Bool {
        !originalRefined.isEmpty || !rawTranscript.isEmpty
    }

    private var canSave: Bool {
        hasRecent && !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasRecent {
                Text("Edit the dictated text, then save to re-paste it into the original app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No recent dictation to correct. Dictate something first, then re-open this window with ⌥⌘R.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $editedText)
                .font(.body)
                .frame(minHeight: 140)
                .border(Color(NSColor.separatorColor), width: 1)
                .disabled(!hasRecent)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func save() {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        NSLog("VoiceRefine: CorrectLast save — orig=\(originalRefined.count)c, new=\(trimmed.count)c, bundle=\(targetBundleID ?? "nil")")

        // 1. Compute new tokens and append to learned glossary.
        let additions = TokenDiff.additions(old: originalRefined, new: trimmed)
        appendLearnedGlossary(additions)

        // 2. Persist the raw → original-refined → corrected triple (and
        //    the source WAV when available) for offline analysis.
        CorrectionLog.append(
            raw: rawTranscript,
            originalRefined: originalRefined,
            correctedRefined: trimmed,
            glossaryAdditions: additions,
            frontmostAppBundleID: targetBundleID,
            sourceWavURL: DictationPipeline.lastWavURL
        )

        // 3. Close the editor, return focus to the original target app,
        //    then defer the paste so the main runloop has time to process
        //    the activation event before backspaces + ⌘V fire. Two gotchas:
        //
        //    a. `app.activate()` (no params) bridges to the deprecated
        //       `activate(options:)`, which silently no-ops in many
        //       cross-app cases on macOS 14+. The macOS-14 API is
        //       `activate(from:options:)` and `from: .current` is what
        //       actually grants the activation.
        //    b. A blocking `Thread.sleep` here prevents WindowServer from
        //       processing the activation, so by the time keys fire,
        //       focus is still on our editor. `DispatchQueue.main.asyncAfter`
        //       yields the runloop instead.
        let bundleID = targetBundleID
        let toReplace = originalRefined.count
        let textToPaste = trimmed
        dismiss()

        if let bid = bundleID,
           let app = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == bid }) {
            let activated = app.activate(from: .current, options: [])
            NSLog("VoiceRefine: target activate(\(bid)) returned \(activated)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            NSLog("VoiceRefine: CorrectLast paste — frontmost=\(front), expected=\(bundleID ?? "-")")
            PasteEngine().paste(textToPaste, replacingPreviousLength: toReplace)
        }
    }

    /// Merges `newTokens` into the `learnedGlossary` pref, deduplicating
    /// against entries already stored there.
    private func appendLearnedGlossary(_ newTokens: [String]) {
        guard !newTokens.isEmpty else { return }

        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: PrefKey.learnedGlossary) ?? ""
        var existing = Set(
            raw.components(separatedBy: "\n")
               .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
               .filter { !$0.isEmpty }
        )

        let dedupedAdditions = newTokens.filter { !existing.contains($0) }
        guard !dedupedAdditions.isEmpty else { return }

        for token in dedupedAdditions { existing.insert(token) }
        // Keep the existing order, then append new entries.
        let existingOrdered = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let combined = existingOrdered + dedupedAdditions
        defaults.set(combined.joined(separator: "\n"), forKey: PrefKey.learnedGlossary)
    }

}
