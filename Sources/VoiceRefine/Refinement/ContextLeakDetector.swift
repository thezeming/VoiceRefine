import Foundation

/// Heuristic check for the dominant catastrophic-failure mode of the
/// refinement stage: a small local model copies the body of
/// `<text_before_cursor>` (or `<selected_text>`) verbatim into its
/// output instead of cleaning the actual transcript. The
/// `RefinementOutputSanitizer` strips the surrounding `<transcript>`
/// tags, which paradoxically makes the leaked output look more
/// legitimate — so we need a separate guard at the pipeline level.
///
/// Heuristic: if the output shares an 80-char contiguous run with any
/// context field, treat as a leak. 80 chars is well above the longest
/// run that two unrelated pieces of English speech share by chance,
/// while still small enough to catch partial leaks (model paraphrases
/// the start, then copies a paragraph from context).
enum ContextLeakDetector {
    static let minRunChars = 80
    static let minOutputChars = 100

    struct Result {
        let leaked: Bool
        let matchedField: String?
        let sample: String?

        static let clean = Result(leaked: false, matchedField: nil, sample: nil)
    }

    static func evaluate(output: String, context: RefinementContext) -> Result {
        guard output.count >= minOutputChars else { return .clean }
        let candidates: [(String, String?)] = [
            ("text_before_cursor", context.textBeforeCursor),
            ("selected_text",     context.selectedText),
        ]
        for (field, source) in candidates {
            guard let source, source.count >= minRunChars else { continue }
            if let hit = sharedRun(output, source, length: minRunChars) {
                return Result(leaked: true, matchedField: field, sample: hit)
            }
        }
        return .clean
    }

    /// Returns the first contiguous run of exactly `length` characters
    /// that appears in both `a` and `b`, or nil. Operates on grapheme
    /// clusters via Array(String) so emoji/combining marks aren't
    /// torn — false negatives on a short emoji run beat the alternative
    /// of UTF-16 mid-codepoint slicing.
    private static func sharedRun(_ a: String, _ b: String, length: Int) -> String? {
        let aArr = Array(a)
        let bArr = Array(b)
        guard aArr.count >= length, bArr.count >= length else { return nil }

        var bWindows = Set<String>()
        bWindows.reserveCapacity(bArr.count - length + 1)
        for i in 0...(bArr.count - length) {
            bWindows.insert(String(bArr[i..<(i + length)]))
        }
        for i in 0...(aArr.count - length) {
            let window = String(aArr[i..<(i + length)])
            if bWindows.contains(window) { return window }
        }
        return nil
    }
}
