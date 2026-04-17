import SwiftUI
import Combine

struct APIKeyField: View {
    let label: String
    let account: String

    @State private var text: String = ""
    @State private var didLoad: Bool = false

    var body: some View {
        SecureField(label, text: $text, prompt: Text("sk-…"))
            .textFieldStyle(.roundedBorder)
            .onAppear(perform: reload)
            .onChange(of: account) { _, _ in
                didLoad = false
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceRefineKeychainDidChange)) { _ in
                reload()
            }
            .onChange(of: text) { _, newValue in
                guard didLoad else { return }
                do {
                    if newValue.isEmpty {
                        try KeychainStore.shared.delete(account: account)
                    } else {
                        try KeychainStore.shared.set(newValue, account: account)
                    }
                } catch {
                    NSLog("VoiceRefine: keychain write failed for \(account): \(error)")
                }
            }
    }

    private func reload() {
        let stored = KeychainStore.shared.get(account: account) ?? ""
        didLoad = false
        text = stored
        didLoad = true
    }
}
