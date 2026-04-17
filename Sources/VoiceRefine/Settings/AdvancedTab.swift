import SwiftUI
import AppKit

struct AdvancedTab: View {
    @AppStorage(PrefKey.modelStorageOverride) private var modelStorageOverride: String = ""

    @State private var showingClearKeychainConfirm: Bool = false

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

            Section("Maintenance") {
                Button("Reveal logs folder in Finder") {
                    revealLogsFolder()
                }
                Button("Clear transcription history") {}
                    .disabled(true)
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
            }
        }
        .formStyle(.grouped)
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
}
