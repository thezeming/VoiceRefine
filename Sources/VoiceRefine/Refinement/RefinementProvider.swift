import Foundation

struct RefinementContext: Sendable {
    var frontmostApp: String?
    var windowTitle: String?
    var selectedText: String?
    var textBeforeCursor: String?
    var glossary: String?

    static let empty = RefinementContext()

    var isEmpty: Bool {
        (frontmostApp?.isEmpty ?? true)
            && (windowTitle?.isEmpty ?? true)
            && (selectedText?.isEmpty ?? true)
            && (textBeforeCursor?.isEmpty ?? true)
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
