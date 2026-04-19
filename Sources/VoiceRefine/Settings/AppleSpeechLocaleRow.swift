import SwiftUI

/// Status + install action for the currently selected Apple Speech locale.
/// Shown as a row inside `TranscriptionTab` whenever the Apple Speech
/// provider is the active selection; mirrors the WhisperKit "Download
/// model" row in shape but sourced from `AssetInventory` rather than the
/// filesystem.
@available(macOS 26, *)
struct AppleSpeechLocaleRow: View {
    @AppStorage(TranscriptionProviderID.appleSpeech.modelPreferenceKey)
    private var localeID: String = TranscriptionProviderID.appleSpeech.defaultModel

    @State private var status: AppleSpeechAssetManager.LocaleStatus = .supported
    @State private var isDownloading: Bool = false
    @State private var progress: Double = 0
    @State private var statusMessage: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Locale asset")
                    .foregroundStyle(.secondary)
                Spacer()
                statusBadge
                actionButton
            }
            .font(.callout)

            if isDownloading {
                ProgressView(value: progress)
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: localeID) { _, _ in
            errorMessage = nil
            refresh()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .installed:
            Text("Installed").foregroundStyle(.green)
        case .downloading:
            Text("Downloading…").foregroundStyle(.orange)
        case .supported:
            Text("Not installed").foregroundStyle(.tertiary)
        case .unsupported:
            Text("Unsupported").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .installed, .unsupported:
            EmptyView()
        case .supported, .downloading:
            Button(isDownloading ? "Downloading…" : "Download", action: download)
                .disabled(isDownloading)
        }
    }

    // MARK: - Actions

    private func refresh() {
        let id = localeID
        Task {
            let s = await AppleSpeechAssetManager.status(for: id)
            await MainActor.run {
                // Ignore stale responses if the user picked a different locale
                // while this status query was in flight.
                guard id == localeID else { return }
                status = s
            }
        }
    }

    private func download() {
        let id = localeID
        isDownloading = true
        progress = 0
        statusMessage = "Starting…"
        errorMessage = nil
        Task {
            do {
                try await AppleSpeechAssetManager.installLocale(id) { frac, msg in
                    Task { @MainActor in
                        progress = frac
                        statusMessage = msg
                    }
                }
                await MainActor.run {
                    isDownloading = false
                    progress = 1
                    statusMessage = "Installed \(id)."
                }
                refresh()
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = "Install failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
