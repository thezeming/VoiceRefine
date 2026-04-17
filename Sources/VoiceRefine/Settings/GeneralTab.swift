import SwiftUI

struct GeneralTab: View {
    @AppStorage(PrefKey.startAtLogin)        private var startAtLogin: Bool = false
    @AppStorage(PrefKey.playStartStopSound)  private var playStartStopSound: Bool = false
    @AppStorage(PrefKey.glossary)            private var glossary: String = ""
    @AppStorage(PrefKey.refinementSystemPrompt) private var systemPrompt: String = ""

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Push-to-talk") {
                    Text("⌥ Space")
                        .foregroundStyle(.secondary)
                    + Text(" — recorder in Phase 2")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Behaviour") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .disabled(true) // wired in Phase 8
                Toggle("Play sound on record start/stop", isOn: $playStartStopSound)
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
    }
}
