import AppKit
import AVFoundation
import Combine
import SwiftUI

/// First-launch checklist:
///   - microphone permission,
///   - accessibility permission,
///   - Whisper model downloaded,
///   - Ollama installed + running + model pulled (skippable).
///
/// The window is a single SwiftUI view driven by an `@Observable` model
/// so polling just mutates the model and SwiftUI re-renders. Closes
/// automatically only when the user presses Done — some rows (Ollama)
/// are legitimately skippable, so we don't auto-dismiss.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let host = NSHostingController(rootView: OnboardingView(onFinish: onFinish))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Welcome to VoiceRefine"
        window.setContentSize(NSSize(width: 560, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onFinish()
    }
}

// MARK: - View

private struct OnboardingView: View {
    let onFinish: () -> Void

    @AppStorage(PrefKey.selectedTranscriptionProvider)
    private var transcriptionProviderRaw: String = TranscriptionProviderID.whisperKit.rawValue

    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted: Bool = AccessibilityPermission.isTrusted
    @State private var whisperModel: String = UserDefaults.standard.string(forKey: TranscriptionProviderID.whisperKit.modelPreferenceKey)
        ?? TranscriptionProviderID.whisperKit.defaultModel
    @State private var whisperDownloaded: Bool = false
    @State private var isDownloadingWhisper: Bool = false
    @State private var whisperDownloadProgress: Double = 0
    @State private var whisperDownloadMessage: String = ""

    @State private var appleSpeechLocaleID: String = UserDefaults.standard.string(forKey: TranscriptionProviderID.appleSpeech.modelPreferenceKey)
        ?? TranscriptionProviderID.appleSpeech.defaultModel
    @State private var appleSpeechLocaleInstalled: Bool = false
    @State private var isInstallingAppleSpeechLocale: Bool = false
    @State private var appleSpeechInstallProgress: Double = 0
    @State private var appleSpeechInstallMessage: String = ""

    @State private var ollamaState: OllamaState = .notInstalled
    @State private var ollamaInstalledModels: [String] = []
    @State private var selectedOllamaModel: String = UserDefaults.standard.string(forKey: RefinementProviderID.ollama.modelPreferenceKey)
        ?? RefinementProviderID.ollama.defaultModel ?? "qwen2.5:7b"
    @State private var ollamaPullProgress: Double = 0
    @State private var isPullingOllama: Bool = false
    @State private var pullMessage: String = ""

    private var transcriptionProvider: TranscriptionProviderID {
        TranscriptionProviderID(rawValue: transcriptionProviderRaw) ?? .whisperKit
    }

    private var transcriptionReady: Bool {
        switch transcriptionProvider {
        case .appleSpeech:   return appleSpeechLocaleInstalled
        case .whisperKit:    return whisperDownloaded
        // Cloud transcribers aren't fetched ahead of time — they're ready
        // as long as a key is set, but onboarding doesn't collect keys.
        case .groq, .openAIWhisper: return true
        }
    }

    private var allGood: Bool {
        micStatus == .authorized
            && axGranted
            && transcriptionReady
            && ollamaState == .running
            && ollamaInstalledModels.contains(selectedOllamaModel)
    }

    private var canProceedLocally: Bool {
        // "Done enough to dictate" — mic + AX at minimum.
        micStatus == .authorized && axGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(spacing: 10) {
                ChecklistRow(
                    title: "Microphone access",
                    status: micStatus == .authorized ? .ok("granted") : .todo("needed for recording"),
                    actionTitle: micStatus == .authorized ? nil : (micStatus == .denied ? "Open System Settings" : "Grant"),
                    action: { requestMicrophone() }
                )

                ChecklistRow(
                    title: "Accessibility access",
                    status: axGranted ? .ok("granted") : .todo("needed for paste + selected-text context"),
                    actionTitle: axGranted ? nil : "Open System Settings",
                    action: { AccessibilityPermission.openSystemSettings() }
                )

                transcriptionChecklistSection

                ChecklistRow(
                    title: ollamaRowTitle,
                    status: ollamaRowStatus,
                    actionTitle: ollamaRowAction,
                    action: { ollamaRowTapped() }
                )

                if isPullingOllama || !pullMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if ollamaPullProgress > 0 {
                            ProgressView(value: ollamaPullProgress)
                        } else if isPullingOllama {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(pullMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)
                }
            }

            Spacer()

            HStack {
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if !canProceedLocally {
                    Button("Skip for now") { onFinish() }
                }
                Button(allGood ? "Done" : (canProceedLocally ? "Finish (use No-Op)" : "Done"),
                       action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProceedLocally && !allGood)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520, alignment: .topLeading)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User pulled focus back (likely returning from System Settings
            // / Ollama.app) — re-run everything immediately rather than
            // waiting for the next 3 s tick.
            Task { await refresh() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.badge.sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to VoiceRefine")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Hold ⌥ Space, speak, release — get cleaned-up text pasted in place. Everything runs on-device by default.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLine: String {
        if allGood { return "All set — refinement pipeline will run locally." }
        if canProceedLocally { return "Core features ready; Ollama optional." }
        return "Complete mic + accessibility to start dictating."
    }

    // MARK: - Transcription row (provider-aware)

    @ViewBuilder
    private var transcriptionChecklistSection: some View {
        switch transcriptionProvider {
        case .appleSpeech:
            ChecklistRow(
                title: "Apple Speech locale: \(appleSpeechLocaleID)",
                status: appleSpeechLocaleInstalled
                    ? .ok("installed — on-device, managed by macOS")
                    : .todo("on-device asset — download once, then offline"),
                actionTitle: appleSpeechLocaleInstalled
                    ? nil
                    : (isInstallingAppleSpeechLocale ? "Downloading…" : "Download"),
                action: { installAppleSpeechLocaleTapped() }
            )
            if isInstallingAppleSpeechLocale || (!appleSpeechInstallMessage.isEmpty && !appleSpeechLocaleInstalled) {
                VStack(alignment: .leading, spacing: 4) {
                    if appleSpeechInstallProgress > 0 {
                        ProgressView(value: appleSpeechInstallProgress)
                    } else if isInstallingAppleSpeechLocale {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(appleSpeechInstallMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
        case .whisperKit:
            ChecklistRow(
                title: "Whisper model: \(whisperModel)",
                status: whisperDownloaded
                    ? .ok("downloaded")
                    : .todo("~142 MB — download once, then offline"),
                actionTitle: whisperDownloaded
                    ? nil
                    : (isDownloadingWhisper ? "Downloading…" : "Download"),
                action: { downloadWhisperTapped() }
            )
            if isDownloadingWhisper {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: whisperDownloadProgress)
                    Text(whisperDownloadMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
        case .groq, .openAIWhisper:
            ChecklistRow(
                title: "Transcription: \(transcriptionProvider.displayName)",
                status: .skippable("add API key in Settings › Transcription"),
                actionTitle: nil,
                action: {}
            )
        }
    }

    private func downloadWhisperTapped() {
        guard !isDownloadingWhisper, !whisperDownloaded else { return }
        let target = whisperModel
        isDownloadingWhisper = true
        whisperDownloadProgress = 0
        whisperDownloadMessage = "Starting download…"
        Task {
            do {
                try await WhisperKitProvider.prefetch(model: target) { frac in
                    Task { @MainActor in
                        guard target == whisperModel else { return }
                        whisperDownloadProgress = frac
                        whisperDownloadMessage = String(
                            format: "Downloading %@… %d%%",
                            target,
                            Int((frac * 100).rounded())
                        )
                    }
                }
                await MainActor.run {
                    guard target == whisperModel else { return }
                    isDownloadingWhisper = false
                    whisperDownloadProgress = 1
                    whisperDownloaded = WhisperKitProvider.isModelDownloaded(target)
                    whisperDownloadMessage = "Installed \(target)."
                }
            } catch {
                await MainActor.run {
                    guard target == whisperModel else { return }
                    isDownloadingWhisper = false
                    whisperDownloadMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func installAppleSpeechLocaleTapped() {
        guard !isInstallingAppleSpeechLocale, !appleSpeechLocaleInstalled else { return }
        guard #available(macOS 26, *) else { return }

        let id = appleSpeechLocaleID
        isInstallingAppleSpeechLocale = true
        appleSpeechInstallProgress = 0
        appleSpeechInstallMessage = "Starting download…"

        Task {
            do {
                try await AppleSpeechAssetManager.installLocale(id) { frac, msg in
                    Task { @MainActor in
                        guard id == appleSpeechLocaleID else { return }
                        appleSpeechInstallProgress = frac
                        appleSpeechInstallMessage = msg
                    }
                }
                await MainActor.run {
                    guard id == appleSpeechLocaleID else { return }
                    isInstallingAppleSpeechLocale = false
                    appleSpeechLocaleInstalled = true
                    appleSpeechInstallProgress = 1
                    appleSpeechInstallMessage = "Installed \(id)."
                }
            } catch {
                await MainActor.run {
                    guard id == appleSpeechLocaleID else { return }
                    isInstallingAppleSpeechLocale = false
                    appleSpeechInstallMessage = "Install failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Ollama row helpers

    private var ollamaRowTitle: String {
        switch ollamaState {
        case .notInstalled:           return "Ollama refinement (optional)"
        case .installedButNotRunning: return "Ollama installed, not running"
        case .running:
            return "Ollama running · model: \(selectedOllamaModel)"
        }
    }

    private var ollamaRowStatus: ChecklistRowStatus {
        switch ollamaState {
        case .notInstalled:           return .skippable("install for smart refinement, or dictate with No-Op")
        case .installedButNotRunning: return .todo("start with `ollama serve` or open Ollama.app")
        case .running:
            if ollamaInstalledModels.contains(selectedOllamaModel) {
                return .ok("pulled — ready to refine")
            }
            return .todo("pull \(selectedOllamaModel) (~2 GB)")
        }
    }

    private var ollamaRowAction: String? {
        switch ollamaState {
        case .notInstalled:           return "Download Ollama"
        case .installedButNotRunning: return nil
        case .running:
            return ollamaInstalledModels.contains(selectedOllamaModel) ? nil : (isPullingOllama ? "Pulling…" : "Pull")
        }
    }

    private func ollamaRowTapped() {
        switch ollamaState {
        case .notInstalled:
            if let url = URL(string: "https://ollama.com/download") {
                NSWorkspace.shared.open(url)
            }
        case .installedButNotRunning:
            break
        case .running:
            if !ollamaInstalledModels.contains(selectedOllamaModel), !isPullingOllama {
                pullOllamaModel()
            }
        }
    }

    // MARK: - Actions

    private func requestMicrophone() {
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func pullOllamaModel() {
        isPullingOllama = true
        ollamaPullProgress = 0
        pullMessage = "Starting pull…"
        Task {
            do {
                try await OllamaDetector.shared.pullModel(name: selectedOllamaModel) { fraction, message in
                    if fraction >= 0 { ollamaPullProgress = fraction }
                    pullMessage = message
                }
                pullMessage = "Pulled \(selectedOllamaModel)."
                ollamaPullProgress = 1
                await refresh()
            } catch {
                pullMessage = "Pull failed: \(error.localizedDescription)"
            }
            isPullingOllama = false
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axGranted = AccessibilityPermission.isTrusted
        whisperDownloaded = WhisperKitProvider.isModelDownloaded(whisperModel)

        // Apple Speech: only ask the framework when the provider is active
        // AND we're on an OS that has the API. Doing it unconditionally
        // would either trap on pre-26 OSes (symbol missing) or waste an
        // async call for users who never touch the provider.
        if transcriptionProvider == .appleSpeech {
            if #available(macOS 26, *) {
                appleSpeechLocaleInstalled = await AppleSpeechAssetManager.isInstalled(localeID: appleSpeechLocaleID)
            }
        }

        // Skip Ollama probes once we've confirmed it's running AND the
        // selected model is already pulled — that's the terminal state
        // the onboarding cares about. `didBecomeActiveNotification`
        // still triggers a full refresh, so a user who stops Ollama
        // mid-session or pulls a new model externally catches up on
        // next focus. Saves ~40 HTTP calls / minute while onboarding is
        // open and the user is just reading.
        let ollamaSettled = ollamaState == .running
            && ollamaInstalledModels.contains(selectedOllamaModel)
        if !ollamaSettled {
            ollamaState = await OllamaDetector.shared.check()
            if ollamaState == .running {
                ollamaInstalledModels = await OllamaDetector.shared.listInstalledModels()
            } else {
                ollamaInstalledModels = []
            }
        }
    }
}

private enum ChecklistRowStatus {
    case ok(String)
    case todo(String)
    case skippable(String)
}

private struct ChecklistRow: View {
    let title: String
    let status: ChecklistRowStatus
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .ok:         Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .todo:       Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .skippable:  Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch status {
        case .ok(let s), .todo(let s), .skippable(let s): return s
        }
    }

    private var rowBackground: Color {
        switch status {
        case .ok:         return Color.green.opacity(0.06)
        case .todo:       return Color.orange.opacity(0.06)
        case .skippable:  return Color.secondary.opacity(0.06)
        }
    }
}
