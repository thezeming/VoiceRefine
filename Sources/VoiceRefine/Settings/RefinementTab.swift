import SwiftUI

struct RefinementTab: View {
    @AppStorage(PrefKey.selectedRefinementProvider)
    private var providerRaw: String = RefinementProviderID.ollama.rawValue

    private var provider: RefinementProviderID {
        RefinementProviderID(rawValue: providerRaw) ?? .ollama
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(RefinementProviderID.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
            }

            if provider.requiresBaseURL || provider == .ollama {
                Section("Endpoint") {
                    RefinementBaseURLField(provider: provider)
                }
            }

            if !provider.availableModels.isEmpty {
                Section("Model") {
                    RefinementModelPicker(provider: provider)
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
                HStack {
                    Spacer()
                    Button("Test") {}
                        .disabled(true)
                }
            } footer: {
                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footerText: String {
        switch provider {
        case .ollama:
            return "Ollama detection + model pull land in Phase 4."
        case .noOp:
            return "No-Op simply forwards the raw transcript unchanged."
        default:
            return "Test button is wired in Phase 7."
        }
    }
}

private struct RefinementModelPicker: View {
    let provider: RefinementProviderID
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
        selected = UserDefaults.standard.string(forKey: provider.modelPreferenceKey) ?? provider.defaultModel ?? ""
    }
}

private struct RefinementBaseURLField: View {
    let provider: RefinementProviderID
    @State private var url: String = ""

    var body: some View {
        TextField("Base URL", text: $url, prompt: Text("https://…"))
            .textFieldStyle(.roundedBorder)
            .onAppear(perform: load)
            .onChange(of: provider) { _, _ in load() }
            .onChange(of: url) { _, new in
                UserDefaults.standard.set(new, forKey: provider.baseURLPreferenceKey)
            }
    }

    private func load() {
        url = UserDefaults.standard.string(forKey: provider.baseURLPreferenceKey) ?? ""
    }
}
