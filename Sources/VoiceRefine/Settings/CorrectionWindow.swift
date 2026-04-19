import AppKit
import SwiftUI

// MARK: - Window controller

/// Presents the "Correct last…" editor and wires Save / Cancel.
final class CorrectionWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let view = CorrectionView()
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Correct Last Dictation"
        window.setContentSize(NSSize(width: 560, height: 280))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Nothing extra needed — SwiftUI state resets on next open because
        // CorrectionView reads from LastRefinementStore on appear.
    }
}

// MARK: - SwiftUI view

private struct CorrectionView: View {
    @State private var editedText: String = ""
    @State private var originalRefined: String = ""
    @State private var targetBundleID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit the dictated text, then save to re-paste it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $editedText)
                .font(.body)
                .frame(minHeight: 140)
                .border(Color(NSColor.separatorColor), width: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { loadFromStore() }
    }

    // MARK: - Helpers

    private func loadFromStore() {
        // Must be called on MainActor; View body + onAppear are always on main.
        if let entry = LastRefinementStore.shared.last {
            editedText = entry.refined
            originalRefined = entry.refined
            targetBundleID = entry.frontmostAppBundleID
        }
    }

    private func save() {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Compute new tokens and append to learned glossary.
        appendLearnedGlossary(TokenDiff.additions(old: originalRefined, new: trimmed))

        // 2. Bring the target app forward and re-paste.
        activateTargetApp()
        PasteEngine().paste(trimmed)

        closeWindow()
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

    /// Brings the original frontmost app back to front so the re-paste
    /// lands in the right window, not in VoiceRefine's correction editor.
    private func activateTargetApp() {
        guard let bundleID = targetBundleID else { return }
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) {
            // `activate(options:)` is deprecated on macOS 14 (the flag is
            // a no-op there). Use the modern `activate()` — always brings
            // the target to front on macOS 14+.
            app.activate()
        }
        // Give the app a moment to come forward before CGEvent posts ⌘V.
        // This is a short synchronous pause on the main thread — acceptable
        // here because we are inside a button action and the user sees the
        // window close immediately after.
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
