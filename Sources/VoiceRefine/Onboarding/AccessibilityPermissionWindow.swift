import AppKit
import SwiftUI

@MainActor
final class AccessibilityPermissionWindowController: NSWindowController, NSWindowDelegate {
    private var pollTimer: Timer?
    private let onGranted: () -> Void

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        let host = NSHostingController(rootView: AccessibilityPermissionView(
            onOpenSettings: { AccessibilityPermission.openSystemSettings() }
        ))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Grant Accessibility Access"
        window.setContentSize(NSSize(width: 480, height: 340))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Timer.scheduledTimer fires on RunLoop.main — guaranteed main thread.
        // `MainActor.assumeIsolated` communicates that to Swift 6 so we can
        // call @MainActor-isolated methods from the @Sendable timer closure.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AccessibilityPermission.isTrusted {
                    self.stopPolling()
                    self.window?.orderOut(nil)
                    self.onGranted()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }
}

struct AccessibilityPermissionView: View {
    let onOpenSettings: () -> Void
    @State private var manualCheckTrusted: Bool = AccessibilityPermission.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility access required")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("VoiceRefine synthesizes ⌘V to paste cleaned-up dictation into the frontmost app. macOS requires Accessibility permission for any app that generates keystrokes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox("How to enable") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click **Open System Settings**.")
                    Text("2. In **Privacy & Security → Accessibility**, enable **VoiceRefine**.")
                    Text("3. Return to this window — it closes automatically once permission is granted.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer()

            HStack {
                if manualCheckTrusted {
                    Label("Permission granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label("Waiting for permission…", systemImage: "clock")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                Button("Open System Settings") { onOpenSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 340, alignment: .topLeading)
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            manualCheckTrusted = AccessibilityPermission.isTrusted
        }
    }
}
