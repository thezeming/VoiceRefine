import SwiftUI
import AppKit

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

            if provider == .ollama {
                Section("Ollama status") {
                    OllamaStatusBlock()
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
                ProviderTestRow(kind: .refinement(provider))
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
            return "Detection checks localhost:11434. Install with `brew install ollama` or from ollama.com."
        case .noOp:
            return "No-Op simply forwards the raw transcript unchanged."
        default:
            return "Test button is wired in Phase 7."
        }
    }
}

private struct OllamaStatusBlock: View {
    @State private var state: OllamaState = .notInstalled
    @State private var installedModels: [String] = []
    @State private var isChecking: Bool = false
    @State private var isPulling: Bool = false
    @State private var pullFraction: Double = 0
    @State private var pullMessage: String = ""

    @AppStorage(RefinementProviderID.ollama.modelPreferenceKey)
    private var selectedModel: String = RefinementProviderID.ollama.defaultModel ?? "llama3.2:3b"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.callout)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(isChecking)
            }

            switch state {
            case .notInstalled:
                HStack {
                    Text("Install with `brew install ollama` or from the website.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download…") {
                        if let url = URL(string: "https://ollama.com/download") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            case .installedButNotRunning:
                Text("Start it with `ollama serve` in Terminal, or open Ollama.app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .running:
                runningBlock
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var runningBlock: some View {
        HStack {
            Text("Current model:")
                .foregroundStyle(.secondary)
            Text(selectedModel)
                .fontWeight(.medium)
                .monospaced()
            Spacer()
            if installedModels.contains(selectedModel) {
                Label("pulled", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button(isPulling ? "Pulling…" : "Pull") { pull() }
                    .disabled(isPulling)
            }
        }

        if !installedModels.isEmpty {
            Text("Installed: \(installedModels.joined(separator: ", "))")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }

        if isPulling || !pullMessage.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if pullFraction > 0 {
                    ProgressView(value: pullFraction)
                } else if isPulling {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(pullMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch state {
        case .notInstalled:           return .red
        case .installedButNotRunning: return .orange
        case .running:                return .green
        }
    }

    private var statusText: String {
        switch state {
        case .notInstalled:           return "Not installed"
        case .installedButNotRunning: return "Installed, not running"
        case .running:                return "Running at \(currentBaseURL())"
        }
    }

    private func currentBaseURL() -> String {
        UserDefaults.standard.string(forKey: RefinementProviderID.ollama.baseURLPreferenceKey)
            ?? "http://localhost:11434"
    }

    private func refresh() async {
        isChecking = true
        defer { isChecking = false }
        state = await OllamaDetector.shared.check()
        if state == .running {
            installedModels = await OllamaDetector.shared.listInstalledModels()
        } else {
            installedModels = []
        }
    }

    private func pull() {
        guard !isPulling else { return }
        isPulling = true
        pullFraction = 0
        pullMessage = "Starting pull…"
        Task {
            do {
                try await OllamaDetector.shared.pullModel(name: selectedModel) { fraction, message in
                    if fraction >= 0 { pullFraction = fraction }
                    pullMessage = message
                }
                pullMessage = "Pulled \(selectedModel)."
                pullFraction = 1
                await refresh()
            } catch {
                pullMessage = "Pull failed: \(error.localizedDescription)"
            }
            isPulling = false
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
