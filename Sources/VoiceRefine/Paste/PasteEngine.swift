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
final class PasteEngine {
    private let restoreDelay: TimeInterval

    init(restoreDelay: TimeInterval = 0.5) {
        self.restoreDelay = restoreDelay
    }

    func paste(_ text: String) {
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
        Self.appendDiagnostic(diag)

        // Post key events on the main queue so CGEvent has the run loop.
        DispatchQueue.main.async {
            Self.synthesizeCommandV()
        }

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

    private static let diagnosticURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/VoiceRefine/paste.log")
    }()

    private static let diagnosticFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Appends one timestamped line to `~/Library/Logs/VoiceRefine/paste.log`.
    /// Persists regardless of launch mode (direct/open/login), unlike
    /// `NSLog`, which is only reachable via `log stream` and needs admin.
    private static func appendDiagnostic(_ line: String) {
        let url = diagnosticURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamped = diagnosticFormatter.string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
