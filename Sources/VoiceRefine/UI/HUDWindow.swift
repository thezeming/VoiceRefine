import AppKit
import SwiftUI

// MARK: - HUD SwiftUI content

private struct HUDView: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Text("Recording")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.75))
        )
    }
}

// MARK: - Non-activating panel subclass

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

final class HUDWindowController: NSObject {

    private var panel: HUDPanel?

    // MARK: Public interface

    func show() {
        guard UserDefaults.standard.bool(forKey: PrefKey.showRecordingIndicator) else { return }

        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }
        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Private helpers

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: HUDView())
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 80)
        p.contentView = hosting
        return p
    }

    private func positionPanel(_ panel: HUDPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = panel.frame.size

        let x = screenFrame.minX + (screenFrame.width - panelSize.width) / 2
        let y = screenFrame.minY + 120

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
