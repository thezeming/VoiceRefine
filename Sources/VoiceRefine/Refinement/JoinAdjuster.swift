import Foundation

/// Deterministic join between the text already present before the caret
/// and the refined dictation that is about to be pasted.
///
/// The refinement LLM produces a standalone, grammatically-complete chunk:
/// capitalized first word, terminal punctuation, no leading space. That
/// assumption is wrong when the user is dictating into the MIDDLE of a
/// sentence or immediately after a previous sentence. Without a join
/// pass, the paste engine emits things like
///
///     "…previous sentence.Hello world."     (missing space)
///     "I was writing Code that does X"       (wrong capitalization)
///
/// This type reads the raw trailing characters of `textBeforeCursor` —
/// which `ContextGatherer` now preserves instead of stripping — and
/// rewrites the first characters of the refined string so the paste
/// lands correctly.
///
/// The rules are intentionally small and local. The refinement system
/// prompt mirrors them so a compliant cloud model produces a clean
/// answer on its own; this post-processor is the authoritative fallback
/// for small local models (qwen2.5:7b and friends) that tend to ignore
/// prompt instructions about punctuation.
enum JoinAdjuster {

    /// Tokens that should never be lowercased when they appear as the
    /// first word of the refined output. Match is case-sensitive against
    /// the original token (before our lowercasing).
    private static let preservedFirstTokens: Set<String> = [
        "I", "I'm", "I've", "I'd", "I'll", "I's"
    ]

    /// Returns `refined` possibly prefixed with a space and/or with its
    /// first alphabetic character forced upper- or lowercase, depending
    /// on how `textBeforeCursor` ends. Pure and side-effect-free.
    static func adjust(refined: String, textBeforeCursor before: String?) -> String {
        guard !refined.isEmpty else { return refined }

        // No prior context (fresh document, or AX read failed) — treat as
        // a sentence start: capitalize the first word, no leading space.
        // This matches the system-prompt rule for the "<text_before_cursor>
        // is empty" case and corrects small local models that default to
        // lowercase when the block isn't sent at all.
        guard let before, !before.isEmpty else {
            return applyUppercaseFirstWord(refined)
        }

        // Split `before` into body + trailing whitespace run. The body's
        // last character tells us whether the caret is sitting after a
        // sentence break, a mid-sentence token, or a newline. The
        // presence/absence of trailing whitespace tells us whether the
        // refined chunk needs a leading space.
        let endsWithWhitespace = before.last.map { $0.isWhitespace || $0.isNewline } ?? false
        let body = endsWithWhitespace
            ? String(before.reversed().drop(while: { $0.isWhitespace || $0.isNewline }).reversed())
            : before
        guard let lastChar = body.last else {
            // before was nothing but whitespace — treat like a fresh
            // canvas. Capitalize, but keep the leading whitespace.
            return applyUppercaseFirstWord(refined)
        }

        // Fresh-line check: if the line containing the cursor has nothing
        // but whitespace, box-drawing, or shell-prompt chars, the caret is
        // at the start of a new prompt / paragraph. The body's last char
        // would be a stray ">" or "│" from the previous lines, which the
        // mid-sentence branch would wrongly lowercase against.
        //
        // This catches Terminal / Claude Code / iTerm prompts where AX
        // hands us the entire visible scrollback as `before` — without
        // this branch every dictation lowercases its first word because
        // the body ends with the trailing prompt indicator.
        if !currentLineHasRealContent(in: before) {
            var result = applyUppercaseFirstWord(refined)
            if !endsWithWhitespace {
                result = " " + result
            }
            return result
        }

        let placement = placement(for: lastChar)

        // Start from the refined text; we may prepend a space and/or
        // re-case the first word depending on `placement`.
        var result = refined

        switch placement.firstWordCase {
        case .forceLower:
            result = applyLowercaseFirstWord(result)
        case .forceUpper:
            result = applyUppercaseFirstWord(result)
        }

        if placement.needsLeadingSpace, !endsWithWhitespace {
            result = " " + result
        }

        return result
    }

    /// Box-drawing characters and shell / REPL prompt indicators that
    /// commonly appear on the cursor's line in Terminal / Claude Code
    /// without constituting "real" written content. When a line contains
    /// only these (and whitespace), the caret is at a fresh prompt and
    /// the dictation should start a new sentence.
    private static let decorationChars: Set<Character> = [
        "│", "╭", "╮", "╰", "╯", "─", "├", "┤", "┬", "┴", "┼",
        "║", "╔", "╗", "╚", "╝", "═",
        ">", "$", "#", "%", "❯", "›", "→", "»", "•", "◆", "◇"
    ]

    /// True when the line containing the cursor (text after the last
    /// newline in `before`) has any character other than whitespace or
    /// `decorationChars`. False means we're at a fresh prompt / paragraph.
    private static func currentLineHasRealContent(in before: String) -> Bool {
        let lineStart: String.Index
        if let lastNL = before.lastIndex(where: { $0.isNewline }) {
            lineStart = before.index(after: lastNL)
        } else {
            lineStart = before.startIndex
        }
        let line = before[lineStart...]
        return line.contains { ch in
            !ch.isWhitespace && !decorationChars.contains(ch)
        }
    }

    // MARK: - Classification

    private enum FirstWordCase {
        case forceLower
        case forceUpper
    }

    private struct Placement {
        let firstWordCase: FirstWordCase
        /// True when a leading space should be inserted if `before`
        /// didn't already end in whitespace.
        let needsLeadingSpace: Bool
    }

    private static func placement(for lastChar: Character) -> Placement {
        // Hard sentence breaks — capitalize the first word.
        // Opening bracket / quote mid-sentence would normally want a
        // capital too (e.g. `she said "Hello`) so treat those as
        // sentence-style too.
        let sentenceBreakers: Set<Character> = [
            ".", "!", "?", ":",
            "\n", "\r",
            "\"", "“", "'", "‘",
            "(", "[", "{", "<"
        ]
        if sentenceBreakers.contains(lastChar) {
            return Placement(firstWordCase: .forceUpper, needsLeadingSpace: true)
        }

        // Mid-sentence continuations — lowercase the first word, add a
        // space. Covers letters, digits, commas, semicolons, dashes,
        // slashes, closing brackets, etc.
        return Placement(firstWordCase: .forceLower, needsLeadingSpace: true)
    }

    // MARK: - First-word lowercasing

    /// Lowercases the first alphabetic character of `s`, unless the
    /// first whitespace-delimited token is one of
    /// `preservedFirstTokens` or looks like an acronym (two or more
    /// consecutive uppercase letters at the very start).
    private static func applyLowercaseFirstWord(_ s: String) -> String {
        guard let firstAlpha = s.firstIndex(where: { $0.isLetter }) else {
            return s
        }

        // Identify the first whitespace-delimited token starting at
        // `firstAlpha`. This excludes leading punctuation like `"` or
        // `(` which may precede the word the user actually said.
        let tokenEnd = s[firstAlpha...].firstIndex(where: { $0.isWhitespace || $0.isNewline })
            ?? s.endIndex
        let token = String(s[firstAlpha..<tokenEnd])

        if preservedFirstTokens.contains(token) {
            return s
        }

        // Acronym heuristic: ≥2 consecutive uppercase letters at the
        // start of the token (e.g. "API", "URL", "HTTP").
        if isAcronymStart(token) {
            return s
        }

        // Safe to lowercase: replace just the first alphabetic char.
        let ch = s[firstAlpha]
        let lowered = Character(ch.lowercased())
        var out = s
        out.replaceSubrange(firstAlpha...firstAlpha, with: String(lowered))
        return out
    }

    /// Uppercases the first alphabetic character of `s`. Skips when:
    ///   - the character is already uppercase,
    ///   - the first whitespace-delimited token is mixed-case starting
    ///     lowercase (e.g. "iOS", "iPhone", "useEffect", "kubectl") —
    ///     uppercasing those would corrupt the identifier.
    private static func applyUppercaseFirstWord(_ s: String) -> String {
        guard let firstAlpha = s.firstIndex(where: { $0.isLetter }) else {
            return s
        }

        let ch = s[firstAlpha]
        if ch.isUppercase { return s }

        let tokenEnd = s[firstAlpha...].firstIndex(where: { $0.isWhitespace || $0.isNewline })
            ?? s.endIndex
        let token = s[firstAlpha..<tokenEnd]

        // Mixed-case identifier guard: starts lowercase and contains an
        // uppercase letter later (e.g. "iOS", "useEffect"). Capitalizing
        // these would silently corrupt code-style identifiers the user
        // intentionally dictated lowercase.
        if token.dropFirst().contains(where: { $0.isUppercase && $0.isLetter }) {
            return s
        }

        let upped = Character(ch.uppercased())
        var out = s
        out.replaceSubrange(firstAlpha...firstAlpha, with: String(upped))
        return out
    }

    private static func isAcronymStart(_ token: String) -> Bool {
        let prefix = token.prefix(2)
        guard prefix.count == 2 else { return false }
        return prefix.allSatisfy { $0.isUppercase && $0.isLetter }
    }
}
