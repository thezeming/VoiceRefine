import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("VoiceRefine")
                .font(.title2)
            Text("Settings")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tabs arrive in Phase 1.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}
