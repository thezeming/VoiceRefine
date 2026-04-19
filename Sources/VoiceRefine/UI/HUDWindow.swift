import AppKit

/// A small floating panel that appears at the bottom-centre of the main
/// screen during recording. Shows just a mic icon — no text caption — so
/// the user can confirm the mic is live without the HUD becoming reading
/// material that competes with the actual app they're dictating into.
///
/// `updatePartial(_:)` is kept as a no-op so the streaming-partials code
/// path in `AppleSpeechProvider` doesn't need to change. If a future v2
/// brings back the live caption it can re-enable display here.
@MainActor
final class HUDWindowController {

    private enum Layout {
        static let windowSide: CGFloat   = 36
        static let bottomMargin: CGFloat = 80
        static let cornerRadius: CGFloat = 9
        static let glyphPointSize: CGFloat = 16
    }

    private var window: NSPanel?

    func show() {
        guard UserDefaults.standard.bool(forKey: PrefKey.showRecordingIndicator) else { return }
        makeWindowIfNeeded()
        window?.orderFrontRegardless()
    }

    /// Kept as a no-op: HUD intentionally doesn't surface streaming text.
    /// Argument is ignored. Streaming pipeline still runs internally.
    func updatePartial(_ text: String) {
        _ = text
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindowIfNeeded() {
        if window != nil { return }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - Layout.windowSide / 2,
            y: screenFrame.minY + Layout.bottomMargin
        )
        let frame = NSRect(origin: origin, size: CGSize(width: Layout.windowSide, height: Layout.windowSide))

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Layout.cornerRadius
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        let config = NSImage.SymbolConfiguration(pointSize: Layout.glyphPointSize, weight: .semibold)
        let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = micImage
        imageView.contentTintColor = .systemRed
        imageView.imageScaling = .scaleProportionallyUpOrDown
        blur.addSubview(imageView)

        self.window = panel
    }
}
