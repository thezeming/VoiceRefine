import AppKit
import ApplicationServices

/// Snapshots the environment the user is dictating into:
///   - frontmost app's localized name,
///   - focused window title,
///   - selected text (if any),
///   - a bounded chunk of text immediately before the cursor (optional),
///   - user-editable glossary from preferences.
///
/// All AX reads need Accessibility permission; if it's missing, the calls
/// just return nil (no crash, no error). The gatherer never blocks longer
/// than a handful of synchronous AX round-trips.
final class ContextGatherer {
    static let shared = ContextGatherer()

    /// Bundle IDs whose text we refuse to probe even with permission —
    /// password managers expose plaintext secrets in focused fields and
    /// their "windows" are high-signal for credential leakage.
    /// Only gates `textBeforeCursor`; selected-text/app-name behaviour is
    /// unchanged.
    private let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.1password.1password8",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword7-helper",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.dashlane.5",
        "com.dashlanedesktop.app",
        "com.enpass.enpass-desktop",
        "com.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "me.proton.pass",
        "com.proton.pass.mac"
    ]

    /// Gathers a `RefinementContext` suitable for passing into the refine
    /// call. Reads the glossary and before-cursor prefs from `UserDefaults`
    /// on the calling thread.
    func gather() -> RefinementContext {
        let defaults = UserDefaults.standard
        let captureBefore = defaults.bool(forKey: PrefKey.contextCaptureBeforeCursor)
        let rawLimit = defaults.integer(forKey: PrefKey.contextBeforeCursorCharLimit)
        let limit = max(ContextLimits.beforeCursorMin,
                        min(ContextLimits.beforeCursorMax, rawLimit == 0 ? 1500 : rawLimit))

        let raw = gatherAX(captureBefore: captureBefore, beforeLimit: limit)
        let glossaryText = (defaults.string(forKey: PrefKey.glossary) ?? "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Redact credentials out of both user-text channels before they
        // cross into the refinement context. Applies to all providers —
        // local AND cloud — because today's local Ollama is tomorrow's
        // cloud refiner via a single settings toggle, and the captured
        // context is indistinguishable once it's off the device.
        let scrubbedSelection = raw.selectedText.map(SecretRedactor.redact)
        let scrubbedBefore    = raw.textBeforeCursor.map(SecretRedactor.redact)

        return RefinementContext(
            frontmostApp:     raw.appName,
            windowTitle:      raw.windowTitle,
            selectedText:     scrubbedSelection,
            textBeforeCursor: scrubbedBefore,
            glossary:         glossaryText.isEmpty ? nil : glossaryText
        )
    }

    // MARK: - AX plumbing

    private struct RawContext {
        let appName: String?
        let windowTitle: String?
        let selectedText: String?
        let textBeforeCursor: String?
    }

    private func gatherAX(captureBefore: Bool, beforeLimit: Int) -> RawContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName
        guard let pid = frontmost?.processIdentifier else {
            return RawContext(appName: appName, windowTitle: nil, selectedText: nil, textBeforeCursor: nil)
        }

        // If the frontmost app is VoiceRefine itself (Settings / onboarding
        // window has focus), skip the AX probe — the context is noise.
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return RawContext(appName: appName, windowTitle: nil, selectedText: nil, textBeforeCursor: nil)
        }

        let bundleID = frontmost?.bundleIdentifier ?? ""
        let isPasswordManager = passwordManagerBundleIDs.contains(bundleID)

        let axApp = AXUIElementCreateApplication(pid)
        let title = focusedWindowTitle(for: axApp)
        let element = focusedElement(for: axApp)
        let selection = element.flatMap { selectedText(for: $0) }

        let before: String?
        if captureBefore, !isPasswordManager, let element {
            before = textBeforeCursor(for: element, charBudget: beforeLimit)
        } else {
            before = nil
        }

        return RawContext(
            appName: appName,
            windowTitle: title,
            selectedText: selection,
            textBeforeCursor: before
        )
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

    private func focusedElement(for axApp: AXUIElement) -> AXUIElement? {
        guard let elementRef = copyAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else { return nil }
        guard CFGetTypeID(elementRef) == AXUIElementGetTypeID() else { return nil }
        return (elementRef as! AXUIElement)
    }

    private func selectedText(for element: AXUIElement) -> String? {
        guard let textRef = copyAttribute(element, kAXSelectedTextAttribute as CFString),
              let text = textRef as? String,
              !text.isEmpty else { return nil }
        return text
    }

    /// Reads up to `charBudget` graphemes of text ending at the caret. All
    /// range math is in UTF-16 units because that is what `CFRange` (and
    /// therefore `kAXSelectedTextRangeAttribute` /
    /// `kAXStringForRangeParameterizedAttribute`) expect — using Swift
    /// `String.count` here would produce off-by-N errors on any document
    /// containing emoji or combining characters.
    ///
    /// Returns nil if:
    ///   - the focused element is a secure text field (password box),
    ///   - there is no selection/caret attribute (non-text element),
    ///   - the cursor is at offset 0 (nothing before it),
    ///   - neither the parametric nor the full-value AX read returns text.
    private func textBeforeCursor(for element: AXUIElement, charBudget: Int) -> String? {
        // Secure-field guard: role OR subrole can be AXSecureTextField.
        if let roleRef = copyAttribute(element, kAXRoleAttribute as CFString),
           let role = roleRef as? String,
           role == "AXSecureTextField" {
            return nil
        }
        if let subroleRef = copyAttribute(element, kAXSubroleAttribute as CFString),
           let subrole = subroleRef as? String,
           subrole == "AXSecureTextField" {
            return nil
        }

        // Caret / selection range in UTF-16 units.
        guard let rangeRef = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString) else {
            return nil
        }
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let axRangeValue = rangeRef as! AXValue
        var selectionRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeValue, .cfRange, &selectionRange) else { return nil }

        let cursorUTF16 = selectionRange.location
        if cursorUTF16 <= 0 { return nil }

        // Budget is measured in Swift characters (graphemes) per user
        // setting, but AX reads in UTF-16 units. Treat the budget as an
        // over-approximation: read up to `charBudget` UTF-16 units, then
        // clip the resulting Swift string to `charBudget` graphemes. Worst
        // case we trim extra; never exceed the user's ceiling.
        let budgetUTF16 = min(cursorUTF16, charBudget)
        let start = cursorUTF16 - budgetUTF16
        let length = budgetUTF16

        // Parametric read first — avoids loading the entire document into
        // AX memory when the user is dictating into a huge editor pane.
        if let s = stringForRange(element: element, start: start, length: length) {
            return finaliseBeforeCursor(prefix: s, charBudget: charBudget)
        }

        // Fallback: read the whole value, NSString-slice the prefix.
        guard let valueRef = copyAttribute(element, kAXValueAttribute as CFString),
              let full = valueRef as? String, !full.isEmpty else {
            return nil
        }
        let nsFull = full as NSString
        let safeCursor = min(cursorUTF16, nsFull.length)
        guard safeCursor > 0 else { return nil }
        let safeStart = max(0, safeCursor - budgetUTF16)
        let range = NSRange(location: safeStart, length: safeCursor - safeStart)
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= nsFull.length else {
            return nil
        }
        let sliced = nsFull.substring(with: range)
        return finaliseBeforeCursor(prefix: sliced, charBudget: charBudget)
    }

    private func stringForRange(element: AXUIElement, start: CFIndex, length: CFIndex) -> String? {
        var range = CFRange(location: start, length: length)
        guard let axParam = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axParam,
            &out
        )
        guard err == .success, let s = out as? String, !s.isEmpty else {
            return nil
        }
        return s
    }

    /// Trims, caps to grapheme budget, and left-snaps to the nearest
    /// whitespace so we don't hand the LLM a half-word like "ing the…".
    private func finaliseBeforeCursor(prefix: String, charBudget: Int) -> String? {
        let trimmedInitial = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInitial.isEmpty { return nil }

        // Cap to grapheme budget from the right (tail is what matters).
        let capped: String = {
            if trimmedInitial.count <= charBudget { return trimmedInitial }
            let start = trimmedInitial.index(trimmedInitial.endIndex, offsetBy: -charBudget)
            return String(trimmedInitial[start...])
        }()

        // Only snap if we probably cut mid-word. Scan the first ~100
        // characters for whitespace/newline; if found, start after it.
        // If the prefix has no whitespace in its first 100 chars (rare —
        // one long identifier or path), accept a partial leading token.
        let scanLimit = min(capped.count, 100)
        let head = capped.prefix(scanLimit)
        if let wsIdx = head.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            let afterStart = capped.index(after: wsIdx)
            if afterStart < capped.endIndex {
                let tail = String(capped[afterStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    return tail
                }
            }
        }
        return capped
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success else { return nil }
        return ref
    }
}
