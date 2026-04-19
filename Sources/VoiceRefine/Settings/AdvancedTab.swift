import SwiftUI
import AppKit

struct AdvancedTab: View {
    @AppStorage(PrefKey.modelStorageOverride) private var modelStorageOverride: String = ""
    @AppStorage(PrefKey.disableDiagnosticLogs) private var disableDiagnosticLogs: Bool = false

    @State private var showingClearKeychainConfirm: Bool = false
    @State private var showingClearHistoryConfirm: Bool = false
    /// Tracks whether history is empty so the button label can reflect the
    /// current count. Refreshed .onAppear and after clearing.
    @State private var historyCount: Int = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Model storage", text: $modelStorageOverride, prompt: Text("Default location"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseStorageFolder() }
                }
            } header: {
                Text("Model storage override")
            } footer: {
                Text("Leave blank to use ~/Library/Application Support/VoiceRefine/models/.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Disable diagnostic logs", isOn: $disableDiagnosticLogs)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("When off, ~/Library/Logs/VoiceRefine/paste.log and context.log record per-dictation counts (never the dictated text). Logs rotate at 256 KB. Disable to turn logging off entirely.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Button("Reveal logs folder in Finder") {
                    revealLogsFolder()
                }
                Button("Clear all Keychain entries", role: .destructive) {
                    showingClearKeychainConfirm = true
                }
                .confirmationDialog(
                    "Remove every VoiceRefine API key from the Keychain?",
                    isPresented: $showingClearKeychainConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Keychain Entries", role: .destructive) {
                        clearKeychainEntries()
                    }
                    Button("Cancel", role: .cancel) {}
                }

                let historyLabel = historyCount == 0
                    ? "Clear transcription history"
                    : "Clear transcription history (\(historyCount))"
                Button(historyLabel, role: .destructive) {
                    showingClearHistoryConfirm = true
                }
                .disabled(historyCount == 0)
                .confirmationDialog(
                    "Delete all \(historyCount) transcription history entries?",
                    isPresented: $showingClearHistoryConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear History", role: .destructive) {
                        clearTranscriptionHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { historyCount = TranscriptionHistory.shared.entries.count }
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            modelStorageOverride = url.path
        }
    }

    private func revealLogsFolder() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/VoiceRefine", isDirectory: true)
        guard let logs else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }

    private func clearKeychainEntries() {
        let providerPrefixes = TranscriptionProviderID.allCases.map { "\($0.rawValue)." }
            + RefinementProviderID.allCases.map { "\($0.rawValue)." }
        for prefix in providerPrefixes {
            try? KeychainStore.shared.deleteAll(withPrefix: prefix)
        }
    }

    private func clearTranscriptionHistory() {
        Task { @MainActor in
            TranscriptionHistory.shared.clear()
            historyCount = 0
        }
    }
}
