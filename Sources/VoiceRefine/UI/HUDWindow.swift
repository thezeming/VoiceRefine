import AppKit

/// A small floating panel that appears at the bottom-centre of the main
/// screen during recording and transcription.  Its primary job is to echo
/// Apple SpeechAnalyzer streaming partials as a live caption — giving the
/// user immediate visual feedback that dictation is happening.
///
/// Lifecycle:
///   `show()` — display the "Recording…" state.
///   `updatePartial(_:)` — swap in live caption text (called on main thread).
///   `hide()` — dismiss and reset to default state.
///
/// All public methods must be called on the main thread. The window is gated
/// by `PrefKey.showRecordingIndicator`; when that pref is false, all three
/// methods are no-ops.
final class HUDWindowController {

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat  = 440
        static let windowHeight: CGFloat = 44
        static let bottomMargin: CGFloat = 80
        static let cornerRadius: CGFloat = 12
        static let horizontalPadding: CGFloat = 16
        static let fontSize: CGFloat = 14
    }

    // MARK: - State

    private var window: NSPanel?
    private var label: NSTextField?
    /// Whether `updatePartial` has been called at least once for the current
    /// recording session.  Used to decide whether to show the default
    /// "Recording…" text or live caption text.
    private var hasReceivedPartial = false

    // MARK: - Public API

    /// Show the HUD with the default "Recording…" label.
    func show() {
        guard UserDefaults.standard.bool(forKey: PrefKey.showRecordingIndicator) else { return }
        hasReceivedPartial = false
        makeWindowIfNeeded()
        setLabelText("Recording…", isPlaceholder: true)
        window?.orderFrontRegardless()
    }

    /// Update the live caption.  Called from the transcription task via
    /// `MainActor.run`.  No-ops if the pref gate is off or the window is not
    /// currently visible.
    func updatePartial(_ text: String) {
        guard UserDefaults.standard.bool(forKey: PrefKey.showRecordingIndicator) else { return }
        guard window?.isVisible == true else { return }
        hasReceivedPartial = true
        setLabelText(text, isPlaceholder: false)
    }

    /// Hide and reset the HUD.  Must be called on every recording session
    /// end (including cancellations) so the next `show()` starts clean.
    func hide() {
        window?.orderOut(nil)
        hasReceivedPartial = false
        setLabelText("Recording…", isPlaceholder: true)
    }

    // MARK: - Private helpers

    private func makeWindowIfNeeded() {
        if window != nil { return }

        // Position centred at the bottom of the main screen.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - Layout.windowWidth / 2,
            y: screenFrame.minY + Layout.bottomMargin
        )
        let frame = NSRect(origin: origin, size: CGSize(width: Layout.windowWidth, height: Layout.windowHeight))

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

        // Pill-shaped frosted glass background.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Layout.cornerRadius
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        // Single-line text field for the caption.
        let tf = NSTextField(frame: NSRect(
            x: Layout.horizontalPadding,
            y: 0,
            width: frame.width - Layout.horizontalPadding * 2,
            height: frame.height
        ))
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.textColor = .labelColor
        tf.font = .systemFont(ofSize: Layout.fontSize, weight: .medium)
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.cell?.truncatesLastVisibleLine = true
        blur.addSubview(tf)

        self.window = panel
        self.label = tf
    }

    private func setLabelText(_ text: String, isPlaceholder: Bool) {
        guard let label else { return }
        if isPlaceholder {
            label.textColor = .tertiaryLabelColor
            label.stringValue = text
        } else {
            label.textColor = .labelColor
            label.stringValue = text
        }
    }
}
