import AppKit
import ApplicationServices
import CoreGraphics

/// Pastes refined text into the frontmost app by synthesizing ⌘V.
///
/// Per PLAN §"Paste mechanism":
/// 1. Save the current `NSPasteboard.general` contents (all items / all types).
/// 2. Write refined text.
/// 3. Synthesize ⌘V via two `CGEvent` posts (key down + key up, `.maskCommand`).
/// 4. Restore the original pasteboard after `restoreDelay` seconds.
///
/// Restore always fires — via defer-like scheduling — even when step 3
/// silently fails (missing Accessibility permission). Losing the user's
/// previous clipboard is worse than failing to paste.
///
/// `@MainActor`: NSPasteboard and CGEvent.post must run on the main thread;
/// the existing `DispatchQueue.main.async` wrappers made that implicit.
@MainActor
final class PasteEngine {
    private let restoreDelay: TimeInterval

    init(restoreDelay: TimeInterval = 0.5) {
        self.restoreDelay = restoreDelay
    }

    /// Paste `text` into the frontmost app. When `replacingPrevious` is true,
    /// send ⌘Z first to undo the previous paste, then ⌘V the new text — used
    /// by "Retry last" so the corrected version replaces the original instead
    /// of accumulating after it. Relies on the target app having the previous
    /// paste at the top of its undo stack; safe no-op for apps without undo.
    func paste(_ text: String, replacingPrevious: Bool = false) {
        if replacingPrevious {
            Self.synthesizeCommandZ()
            // Brief gap so the target app processes the undo before we
            // begin the new paste — otherwise CGEvent posts can race.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.pasteImpl(text)
            }
        } else {
            pasteImpl(text)
        }
    }

    private func pasteImpl(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Log AX trust state — if this is ever false on a paste that
        // didn't land, the TCC grant has decayed (usually: binary resigned
        // under a different identity; see `make setup-signing`).
        let diag = "paste — AXIsProcessTrusted=\(AXIsProcessTrusted()), text.count=\(text.count)"
        NSLog("VoiceRefine: \(diag)")
        Self.log.append(diag)

        // Already on @MainActor — synthesize immediately, then schedule
        // the pasteboard restore after the app has time to consume the paste.
        Self.synthesizeCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            Self.restore(pasteboard, from: snapshot)
        }
    }

    // MARK: - Pasteboard snapshot / restore

    private struct PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(of pb: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pb.pasteboardItems else {
            return PasteboardSnapshot(items: [])
        }
        let captured = items.map { item -> [NSPasteboard.PasteboardType: Data] in
            var bag: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    bag[type] = data
                }
            }
            return bag
        }
        return PasteboardSnapshot(items: captured)
    }

    private static func restore(_ pb: NSPasteboard, from snapshot: PasteboardSnapshot) {
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let pbItems: [NSPasteboardItem] = snapshot.items.map { bag in
            let item = NSPasteboardItem()
            for (type, data) in bag {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(pbItems)
    }

    // MARK: - ⌘V synthesis

    /// Virtual key codes from HIToolbox/Events.h. `kVK_ANSI_V = 0x09`.
    private static let vKeyCode: CGKeyCode = 0x09

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// `kVK_ANSI_Z = 0x06`. Used by `paste(_:replacingPrevious: true)` to
    /// undo the previous paste before writing the new one.
    private static let zKeyCode: CGKeyCode = 0x06

    private static func synthesizeCommandZ() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: zKeyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: zKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static let log = RotatingLogFile(
        url: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/VoiceRefine/paste.log")
    )
}
