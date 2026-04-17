import SwiftUI

struct TranscriptionTab: View {
    @AppStorage(PrefKey.selectedTranscriptionProvider)
    private var providerRaw: String = TranscriptionProviderID.whisperKit.rawValue

    private var provider: TranscriptionProviderID {
        TranscriptionProviderID(rawValue: providerRaw) ?? .whisperKit
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(TranscriptionProviderID.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
            }

            Section("Model") {
                TranscriptionModelPicker(provider: provider)
                if provider == .whisperKit {
                    HStack {
                        Text("Download status")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Not downloaded")
                            .foregroundStyle(.tertiary)
                        Button("Download") {}
                            .disabled(true)
                    }
                    .font(.callout)
                }
            }

            if provider.requiresAPIKey, let account = provider.apiKeyAccount {
                Section {
                    APIKeyField(label: "API Key", account: account)
                } header: {
                    Text("\(provider.displayName) key")
                } footer: {
                    Text("Stored in Keychain under service \(Bundle.main.bundleIdentifier ?? "-").")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ProviderTestRow(kind: .transcription(provider))
            } footer: {
                Text("Sends 1 second of silence through the provider — reports latency and any error.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionModelPicker: View {
    let provider: TranscriptionProviderID

    @State private var selected: String = ""

    var body: some View {
        Picker("Model", selection: $selected) {
            ForEach(provider.availableModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .onAppear(perform: load)
        .onChange(of: provider) { _, _ in load() }
        .onChange(of: selected) { _, new in
            guard !new.isEmpty else { return }
            UserDefaults.standard.set(new, forKey: provider.modelPreferenceKey)
        }
    }

    private func load() {
        selected = UserDefaults.standard.string(forKey: provider.modelPreferenceKey) ?? provider.defaultModel
    }
}
