import Foundation

/// Computes word-level additions between two strings.
///
/// Used by the "Correct last…" window to discover newly-introduced terms
/// the user typed into the correction editor — those terms are candidates
/// for the learned glossary.
enum TokenDiff {
    /// Common English function words that should never be added to the
    /// learned glossary even when they are new in the corrected text.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but",
        "is", "are", "was", "were", "be", "been", "being",
        "to", "of", "in", "on", "at", "by", "for", "with",
        "it", "its", "this", "that", "i", "you", "we", "they",
        "he", "she", "not", "no", "so", "as", "if", "do"
    ]

    /// Splits `text` on whitespace and punctuation boundaries, returning
    /// an array of normalised (lowercased) tokens.
    private static func tokenize(_ text: String) -> [String] {
        // Split on whitespace and punctuation. CharacterSet.punctuationCharacters
        // covers the usual suspects (. , ; : ! ? ' " etc.).
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text
            .components(separatedBy: separators)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Returns tokens in `new` that are absent from `old` and look like real
    /// words: at least 2 characters long, contain at least one letter, and
    /// are not common function words.
    ///
    /// The result is deduped and preserves left-to-right order of first
    /// appearance in `new`.
    static func additions(old: String, new: String) -> [String] {
        let oldSet = Set(tokenize(old))
        let newTokens = tokenize(new)

        var seen = Set<String>()
        var result: [String] = []

        for token in newTokens {
            guard !seen.contains(token) else { continue }
            seen.insert(token)

            guard !oldSet.contains(token) else { continue }
            guard isRealWord(token) else { continue }

            result.append(token)
        }
        return result
    }

    /// A token is a "real word" if it has at least 2 characters, contains
    /// at least one ASCII letter, and is not a stop word.
    private static func isRealWord(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        guard token.contains(where: { $0.isLetter }) else { return false }
        guard !stopWords.contains(token) else { return false }
        return true
    }
}
