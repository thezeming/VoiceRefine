import Foundation

/// Stop sequences shared across providers. If the model starts echoing the
/// envelope tags from `RefinementMessageBuilder` (a common 3B-model failure
/// mode), the API truncates immediately rather than streaming garbage that
/// the sanitizer then has to clean up. Bare `<` is too aggressive — users
/// can dictate "less than" — so we only stop on the specific tag opens
/// and closes the model would have to be parroting the prompt to emit.
enum RefinementStopSequences {
    /// `stop` field accepted by OpenAI / Ollama / DeepSeek / OpenAI-compat.
    static let openAICompatible: [String] = [
        "</transcript>",
        "<context>",
        "</context>",
        "<glossary>",
        "</glossary>",
    ]
    /// Anthropic uses `stop_sequences`; same content, separate constant so
    /// future divergence is local.
    static let anthropic: [String] = openAICompatible
}

/// Post-processes refinement-LLM output before it reaches the pasteboard.
/// Small local models routinely emit one or more of: a leading preamble
/// ("Here's the cleaned text:"), wrapping quotes/backticks, markdown
/// fences, or stray protocol XML tags they were told to ignore. The
/// sanitizer is a deterministic safety net so the prompt doesn't have
/// to carry the full burden of suppressing these.
///
/// Order matters — fences first (they wrap everything else), then stray
/// tags anywhere, then leading preamble, then wrapping quotes that may
/// only become outermost after the preamble is gone.
enum RefinementOutputSanitizer {
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripCodeFences(s)
        s = stripStrayTags(s)
        s = stripLeadingPreamble(s)
        s = stripWrappingQuotes(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Code fences

    private static let leadingFence = try! NSRegularExpression(
        pattern: #"\A\s*```[a-zA-Z0-9_-]*[ \t]*\r?\n"#
    )
    private static let trailingFence = try! NSRegularExpression(
        pattern: #"\r?\n[ \t]*```\s*\z"#
    )

    private static func stripCodeFences(_ s: String) -> String {
        var out = s
        out = replaceFirst(out, regex: leadingFence, with: "")
        out = replaceFirst(out, regex: trailingFence, with: "")
        return out
    }

    // MARK: - Stray protocol tags

    /// Tag names that appear in `RefinementMessageBuilder`'s envelope. If
    /// the model echoes any of them — opening, closing, or self-closing —
    /// strip them wherever they appear. Inner content (which is the real
    /// cleaned text the model produced) is preserved.
    private static let strayTag = try! NSRegularExpression(
        pattern: #"</?(?:transcript|context|app|selected_text|text_before_cursor|glossary|metadata)\s*/?>"#,
        options: [.caseInsensitive]
    )

    private static func stripStrayTags(_ s: String) -> String {
        let ns = s as NSString
        return strayTag.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    // MARK: - Leading preamble

    /// Patterns we strip when they sit at the very start of the output.
    /// Each alternative is anchored to the start by the outer `\A`.
    /// Conservative on purpose: each branch ends with a colon (with
    /// optional trailing newline) or a bare-acknowledgement followed by
    /// a newline, so a real sentence like "Here's the patch I wrote"
    /// (no colon) is left alone.
    private static let preamble = try! NSRegularExpression(
        pattern: #"""
        \A(?:
              here(?:'s|\s+is|\s+are)?[^:\n]{0,80}:
            | sure[,!.\s][^:\n]{0,80}:
            | sure[,!.]?\s*\r?\n
            | ok(?:ay)?[,!.]?\s*\r?\n
            | (?:cleaned|refined|polished|corrected|fixed|edited)\s+(?:text|transcript|version|output|dictation)\s*:
            | (?:transcript|output|result|cleaned)\s*:
        )\s*\r?\n?
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private static func stripLeadingPreamble(_ s: String) -> String {
        replaceFirst(s, regex: preamble, with: "")
    }

    // MARK: - Wrapping quotes / backticks

    private static let wrappingPairs: [(Character, Character)] = [
        ("\"", "\""),
        ("'",  "'"),
        ("`",  "`"),
        ("\u{201C}", "\u{201D}"),  // “ ”
        ("\u{2018}", "\u{2019}"),  // ‘ ’
    ]

    private static func stripWrappingQuotes(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        for (open, close) in wrappingPairs where first == open && last == close {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Helpers

    private static func replaceFirst(_ s: String, regex: NSRegularExpression, with replacement: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: s, range: range) else { return s }
        return ns.replacingCharacters(in: m.range, with: replacement)
    }
}
