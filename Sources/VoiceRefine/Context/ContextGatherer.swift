import AppKit
import ApplicationServices

/// Snapshots the environment the user is dictating into:
///   - frontmost app's localized name,
///   - focused window title,
///   - selected text (if any),
///   - user-editable glossary from preferences.
///
/// All three AX reads need Accessibility permission; if it's missing, the
/// calls just return nil (no crash, no error). The gatherer never blocks
/// longer than a single synchronous AX round-trip.
final class ContextGatherer {
    static let shared = ContextGatherer()

    /// Gathers a `RefinementContext` suitable for passing into the refine
    /// call. Reads the glossary from `UserDefaults` on the calling thread.
    func gather() -> RefinementContext {
        let raw = gatherAX()
        let glossaryText = (UserDefaults.standard.string(forKey: PrefKey.glossary) ?? "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return RefinementContext(
            frontmostApp: raw.appName,
            windowTitle:  raw.windowTitle,
            selectedText: raw.selectedText,
            glossary:     glossaryText.isEmpty ? nil : glossaryText
        )
    }

    // MARK: - AX plumbing

    private struct RawContext {
        let appName: String?
        let windowTitle: String?
        let selectedText: String?
    }

    private func gatherAX() -> RawContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName
        guard let pid = frontmost?.processIdentifier else {
            return RawContext(appName: appName, windowTitle: nil, selectedText: nil)
        }

        // If the frontmost app is VoiceRefine itself (Settings / onboarding
        // window has focus), skip the AX probe — the context is noise.
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return RawContext(appName: appName, windowTitle: nil, selectedText: nil)
        }

        let axApp = AXUIElementCreateApplication(pid)
        let title = focusedWindowTitle(for: axApp)
        let selection = selectedText(for: axApp)
        return RawContext(appName: appName, windowTitle: title, selectedText: selection)
    }

    private func focusedWindowTitle(for axApp: AXUIElement) -> String? {
        guard let windowRef = copyAttribute(axApp, kAXFocusedWindowAttribute as CFString) else { return nil }
        guard CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        guard let titleRef = copyAttribute(window, kAXTitleAttribute as CFString),
              let title = titleRef as? String,
              !title.isEmpty else { return nil }
        return title
    }

    private func selectedText(for axApp: AXUIElement) -> String? {
        guard let elementRef = copyAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else { return nil }
        guard CFGetTypeID(elementRef) == AXUIElementGetTypeID() else { return nil }
        let element = elementRef as! AXUIElement
        guard let textRef = copyAttribute(element, kAXSelectedTextAttribute as CFString),
              let text = textRef as? String,
              !text.isEmpty else { return nil }
        return text
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success else { return nil }
        return ref
    }
}
