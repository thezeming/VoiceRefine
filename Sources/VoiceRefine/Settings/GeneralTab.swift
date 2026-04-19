import SwiftUI

struct GeneralTab: View {
    @AppStorage(PrefKey.startAtLogin)        private var startAtLogin: Bool = false
    @AppStorage(PrefKey.playStartStopSound)  private var playStartStopSound: Bool = false
    @AppStorage(PrefKey.glossary)            private var glossary: String = ""
    @AppStorage(PrefKey.refinementSystemPrompt) private var systemPrompt: String = ""

    @AppStorage(PrefKey.contextCaptureBeforeCursor)   private var captureBeforeCursor: Bool = true
    @AppStorage(PrefKey.contextBeforeCursorCharLimit) private var beforeCursorLimit: Int = 1500

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Push-to-talk") {
                    Text("Double-tap ⇧ and hold")
                        .foregroundStyle(.secondary)
                    + Text(" — release to transcribe")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Behaviour") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                        } catch {
                            NSLog("VoiceRefine: LoginItem.setEnabled(\(newValue)) failed: \(error)")
                            NotificationDispatcher.postError(
                                title: "Could not update login item",
                                message: error.localizedDescription
                            )
                            // Roll the UI back to reality.
                            DispatchQueue.main.async {
                                startAtLogin = LoginItem.isEnabled
                            }
                        }
                    }
                Toggle("Play sound on record start/stop", isOn: $playStartStopSound)
            }

            Section {
                Toggle("Use text before cursor as context", isOn: $captureBeforeCursor)
                HStack {
                    Text("Characters to capture")
                    Spacer()
                    Stepper(
                        value: $beforeCursorLimit,
                        in: ContextLimits.beforeCursorMin...ContextLimits.beforeCursorMax,
                        step: ContextLimits.beforeCursorStep
                    ) {
                        Text("\(beforeCursorLimit)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!captureBeforeCursor)
            } header: {
                Text("Context")
            } footer: {
                Text("Reads the last N characters before your cursor via Accessibility so the refiner can disambiguate pronouns and project terms. Skipped for password fields and known password-manager apps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
            } header: {
                Text("Glossary")
            } footer: {
                Text("Freeform terms the refiner should prefer over Whisper guesses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Reset to default") {
                        systemPrompt = PrefDefaults.refinementSystemPrompt
                    }
                }
            } header: {
                Text("Refinement system prompt")
            } footer: {
                Text("Sent to the refinement provider on every transcript.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Reconcile with ServiceManagement in case the user changed
            // the login item directly in System Settings.
            let actual = LoginItem.isEnabled
            if startAtLogin != actual {
                startAtLogin = actual
            }
        }
    }
}
