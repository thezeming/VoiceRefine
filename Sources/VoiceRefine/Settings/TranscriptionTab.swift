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
                    ForEach(TranscriptionProviderID.visibleCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
            }

            Section(provider == .appleSpeech ? "Locale" : "Model") {
                TranscriptionModelPicker(provider: provider)
                if provider == .whisperKit {
                    WhisperKitModelStatusRow()
                }
                if provider == .appleSpeech, #available(macOS 26, *) {
                    AppleSpeechLocaleRow()
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
        .onAppear(perform: migrateStalePref)
    }

    /// Pre-Tahoe safety net: the picker hides `.appleSpeech` via
    /// `visibleCases`, but a stored preference from a newer OS (or a manual
    /// `defaults write`) can still bind the Picker to a hidden tag, leaving
    /// the control blank. Migrate once to `.whisperKit` so the UI stays
    /// consistent with what `DictationPipeline.resolveTranscription` would
    /// already do at runtime.
    private func migrateStalePref() {
        guard provider == .appleSpeech else { return }
        if #available(macOS 26, *) { return }
        providerRaw = TranscriptionProviderID.whisperKit.rawValue
    }
}

/// Model / locale picker. For `.appleSpeech` on macOS 26+, the list is
/// loaded asynchronously from `SpeechTranscriber.supportedLocales` so it
/// reflects whatever Apple ships in the current OS update rather than the
/// hard-coded fallback list. Every other provider uses the static list
/// from `TranscriptionProviderID.availableModels` synchronously.
private struct TranscriptionModelPicker: View {
    let provider: TranscriptionProviderID

    @State private var selected: String = ""
    @State private var models: [String] = []

    var body: some View {
        Picker("Model", selection: $selected) {
            ForEach(models, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .onAppear { Task { await reload() } }
        .onChange(of: provider) { _, _ in Task { await reload() } }
        .onChange(of: selected) { _, new in
            guard !new.isEmpty else { return }
            UserDefaults.standard.set(new, forKey: provider.modelPreferenceKey)
        }
    }

    private func reload() async {
        // Start with the hard-coded fallback so the picker never flashes
        // empty. Runtime overrides win if available.
        var list = provider.availableModels

        if provider == .appleSpeech, #available(macOS 26, *) {
            let runtime = await AppleSpeechAssetManager.supportedLocales()
            if !runtime.isEmpty { list = runtime }
        }

        await MainActor.run {
            // Only re-assign if this task wasn't superseded by a provider
            // change while the runtime query was in flight.
            guard self.provider == provider else { return }
            models = list
            let stored = UserDefaults.standard.string(forKey: provider.modelPreferenceKey)
            if let stored, list.contains(stored) {
                selected = stored
            } else {
                selected = list.first ?? provider.defaultModel
            }
        }
    }
}

/// WhisperKit model status + explicit download button. Replaces the
/// placeholder "Not downloaded / disabled Download" row with live state.
/// Progress is coarse (spinner only); proper percentage comes in a later
/// polish pass when we hook WhisperKit's download delegate.
private struct WhisperKitModelStatusRow: View {
    @AppStorage(TranscriptionProviderID.whisperKit.modelPreferenceKey)
    private var model: String = TranscriptionProviderID.whisperKit.defaultModel

    @State private var isDownloaded: Bool = false
    @State private var isDownloading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Download status")
                    .foregroundStyle(.secondary)
                Spacer()
                statusLabel
                Button("Download", action: download)
                    .disabled(isDownloaded || isDownloading)
            }
            .font(.callout)

            if isDownloading {
                ProgressView().progressViewStyle(.linear)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model) { _, _ in refresh() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloading {
            Text("Downloading…").foregroundStyle(.orange)
        } else if isDownloaded {
            Text("Downloaded").foregroundStyle(.green)
        } else {
            Text("Not downloaded").foregroundStyle(.tertiary)
        }
    }

    private func refresh() {
        isDownloaded = WhisperKitProvider.isModelDownloaded(model)
        errorMessage = nil
    }

    private func download() {
        guard !isDownloading, !isDownloaded else { return }
        let target = model
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                try await WhisperKitProvider.prefetch(model: target)
                await MainActor.run {
                    guard target == model else { return }
                    isDownloading = false
                    isDownloaded = WhisperKitProvider.isModelDownloaded(target)
                }
            } catch {
                await MainActor.run {
                    guard target == model else { return }
                    isDownloading = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
