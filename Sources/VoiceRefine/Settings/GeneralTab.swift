import SwiftUI

// MARK: - Per-app row model

/// One row in the per-app system-prompt override list.
private struct PerAppRow: Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var prompt: String
}

struct GeneralTab: View {
    @AppStorage(PrefKey.startAtLogin)           private var startAtLogin: Bool = false
    @AppStorage(PrefKey.playStartStopSound)     private var playStartStopSound: Bool = false
    @AppStorage(PrefKey.showRecordingIndicator) private var showRecordingIndicator: Bool = true
    @AppStorage(PrefKey.glossary)            private var glossary: String = ""
    @AppStorage(PrefKey.refinementSystemPrompt) private var systemPrompt: String = ""

    @AppStorage(PrefKey.contextCaptureBeforeCursor)   private var captureBeforeCursor: Bool = true
    @AppStorage(PrefKey.contextBeforeCursorCharLimit) private var beforeCursorLimit: Int = 1500

    @AppStorage(PrefKey.selectedRefinementProvider)
    private var refinementProviderRaw: String = RefinementProviderID.ollama.rawValue

    @AppStorage(PrefKey.hotkeyGesture)
    private var hotkeyGestureRaw: String = HotkeyGesture.doubleTapShift.rawValue

    private var selectedGesture: HotkeyGesture {
        HotkeyGesture(rawValue: hotkeyGestureRaw) ?? .doubleTapShift
    }

    /// Per-app override rows, loaded from UserDefaults on appear.
    @State private var perAppRows: [PerAppRow] = []
    /// Which row (if any) is showing its inline prompt editor.
    @State private var expandedRowID: UUID? = nil

    private var activeCloudRefinerName: String? {
        guard let id = RefinementProviderID(rawValue: refinementProviderRaw),
              !id.isLocal else { return nil }
        return id.displayName
    }

    var body: some View {
        Form {
            Section {
                Picker("Push-to-talk gesture", selection: $hotkeyGestureRaw) {
                    ForEach(HotkeyGesture.allCases, id: \.rawValue) { gesture in
                        Text(gesture.displayName).tag(gesture.rawValue)
                    }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Release the gesture to transcribe. Restart VoiceRefine for gesture changes to take effect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Toggle("Show recording indicator", isOn: $showRecordingIndicator)
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

                if captureBeforeCursor, let cloudName = activeCloudRefinerName {
                    Label {
                        Text("Sent to **\(cloudName)** on every dictation. VoiceRefine redacts common credential patterns (API keys, Bearer tokens, private keys, JWTs) before upload, but review the footer below for the full caveat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Context")
            } footer: {
                Text("Reads the last N characters before your cursor via Accessibility so the refiner can disambiguate pronouns and project terms. Skipped for password fields and known password-manager apps. Redaction is best-effort — if the captured text contains anything you would not send to a cloud LLM, disable this toggle or switch to a local refiner (Ollama / No-Op).")
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

            // MARK: Per-app system-prompt overrides
            Section {
                ForEach($perAppRows) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField("com.example.app", text: $row.bundleID)
                                .font(.body.monospaced())
                                .textFieldStyle(.plain)
                                .onChange(of: row.bundleID) { _, _ in savePerAppRows() }

                            Button {
                                if expandedRowID == row.id {
                                    expandedRowID = nil
                                } else {
                                    expandedRowID = row.id
                                }
                            } label: {
                                Text(expandedRowID == row.id ? "Hide" : "Edit prompt")
                                    .font(.footnote)
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                perAppRows.removeAll { $0.id == row.id }
                                if expandedRowID == row.id { expandedRowID = nil }
                                savePerAppRows()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }

                        if expandedRowID == row.id {
                            TextEditor(text: $row.prompt)
                                .font(.body.monospaced())
                                .frame(minHeight: 90)
                                .onChange(of: row.prompt) { _, _ in savePerAppRows() }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    let newRow = PerAppRow(id: UUID(), bundleID: "", prompt: "")
                    perAppRows.append(newRow)
                    expandedRowID = newRow.id
                    savePerAppRows()
                } label: {
                    Label("Add override", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Per-app system-prompt overrides")
            } footer: {
                Text("The frontmost app's bundle ID selects an override at dictation time. When a match exists it replaces the global system prompt below. Leave empty to use the global prompt for that app.")
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
                Text("Refinement system prompt (global)")
            } footer: {
                Text("Sent to the refinement provider on every transcript where no per-app override applies.")
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
            // Load per-app overrides from UserDefaults.
            loadPerAppRows()
        }
    }

    // MARK: - Per-app helpers

    private func loadPerAppRows() {
        let dict = PerAppPromptStore.load()
        // Stable sort by bundle ID so the list doesn't jump on every open.
        perAppRows = dict.keys.sorted().map { key in
            PerAppRow(id: UUID(), bundleID: key, prompt: dict[key] ?? "")
        }
    }

    private func savePerAppRows() {
        // Build dict; skip rows where bundle ID is empty (not yet typed).
        var dict: [String: String] = [:]
        for row in perAppRows where !row.bundleID.isEmpty {
            dict[row.bundleID] = row.prompt
        }
        PerAppPromptStore.save(dict)
    }
}
