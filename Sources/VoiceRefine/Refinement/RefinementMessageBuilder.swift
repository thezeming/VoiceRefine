import Foundation

/// Builds the user message fed to the refinement LLM.
///
/// Layout rationale — this used to put `<context>` first, which caused
/// small local models (qwen2.5:7b in particular) to plagiarize window
/// titles and selected code into the cleaned output. Two structural
/// changes prevent that:
///   1. `<transcript>` comes FIRST so the model's attention locks onto
///      it as the primary task before it ever sees context.
///   2. The window title is omitted entirely — in terminals/IDEs it is
///      a string of project/branch/file tokens the LLM cannot resist.
///      Frontmost app name + selected text carry the useful
///      disambiguation signal without the contamination risk.
enum RefinementMessageBuilder {
    static func userMessage(transcript: String, context: RefinementContext) -> String {
        var parts: [String] = []

        parts.append("<transcript>")
        parts.append(transcript)
        parts.append("</transcript>")

        let hasContext = !(context.frontmostApp ?? "").isEmpty
            || !(context.selectedText ?? "").isEmpty
            || !(context.textBeforeCursor ?? "").isEmpty
        if hasContext {
            parts.append("")
            parts.append("<!-- METADATA ONLY — never copy any text below into your output. -->")
            parts.append("<context>")
            if let app = context.frontmostApp, !app.isEmpty {
                parts.append("  <app>\(xmlEscape(app))</app>")
            }
            if let sel = context.selectedText, !sel.isEmpty {
                parts.append("  <selected_text>\(xmlEscape(sel))</selected_text>")
            }
            if let before = context.textBeforeCursor, !before.isEmpty {
                parts.append("  <text_before_cursor>\(xmlEscape(before))</text_before_cursor>")
            }
            parts.append("</context>")
        }

        if let glossary = context.glossary, !glossary.isEmpty {
            parts.append("<glossary>")
            parts.append(glossary)
            parts.append("</glossary>")
        }

        return parts.joined(separator: "\n")
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
