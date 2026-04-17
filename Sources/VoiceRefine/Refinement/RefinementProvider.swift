import Foundation

struct RefinementContext: Sendable {
    var frontmostApp: String?
    var windowTitle: String?
    var selectedText: String?
    var glossary: String?

    static let empty = RefinementContext()

    var isEmpty: Bool {
        (frontmostApp?.isEmpty ?? true)
            && (windowTitle?.isEmpty ?? true)
            && (selectedText?.isEmpty ?? true)
            && (glossary?.isEmpty ?? true)
    }
}

/// Second-stage provider: cleans up a raw Whisper transcript with optional
/// context (frontmost app, window title, selected text, glossary). Phase 4
/// wires Ollama and NoOp; cloud providers arrive in Phase 7.
protocol RefinementProvider: AnyObject {
    static var providerID: RefinementProviderID { get }
    func refine(
        transcript: String,
        systemPrompt: String,
        context: RefinementContext
    ) async throws -> String
}

extension RefinementProvider {
    static var id: String              { providerID.rawValue }
    static var displayName: String     { providerID.displayName }
    static var isLocal: Bool           { providerID.isLocal }
    static var availableModels: [String] { providerID.availableModels }
    static var requiredKeys: [String] {
        providerID.apiKeyAccount.map { [$0] } ?? []
    }
}

/// Builds the XML-wrapped user message per PLAN §v1.1.
enum RefinementMessageBuilder {
    static func userMessage(transcript: String, context: RefinementContext) -> String {
        var parts: [String] = []

        if !(context.frontmostApp ?? "").isEmpty
            || !(context.windowTitle ?? "").isEmpty
            || !(context.selectedText ?? "").isEmpty
        {
            parts.append("<context>")
            if let app = context.frontmostApp, !app.isEmpty {
                parts.append("  <app>\(xmlEscape(app))</app>")
            }
            if let title = context.windowTitle, !title.isEmpty {
                parts.append("  <window>\(xmlEscape(title))</window>")
            }
            if let sel = context.selectedText, !sel.isEmpty {
                parts.append("  <selected_text>\(xmlEscape(sel))</selected_text>")
            }
            parts.append("</context>")
        }

        if let glossary = context.glossary, !glossary.isEmpty {
            parts.append("<glossary>")
            parts.append(glossary)
            parts.append("</glossary>")
        }

        parts.append("<transcript>")
        parts.append(transcript)
        parts.append("</transcript>")

        return parts.joined(separator: "\n")
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
