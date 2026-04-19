import XCTest
@testable import VoiceRefine

final class ContextLeakDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func repeatedASCII(_ c: Character, length: Int) -> String {
        String(repeating: String(c), count: length)
    }

    private let leaked120 = String(
        "The quick brown fox jumps over the lazy dog while the rain falls " +
        "steadily on the rooftops of old houses.".prefix(120)
    )

    // MARK: - Too-short output

    func testTooShortOutput_neverFlagsEvenWithHugeMatchInContext() {
        let huge = repeatedASCII("a", length: 200)
        var ctx = RefinementContext.empty
        ctx.textBeforeCursor = huge

        // Output of 91 chars embedding a 90-char run of 'a' that exists in
        // context. Still under minOutputChars, so detector should short-
        // circuit before matching.
        var shortButWouldMatch = "x"
        shortButWouldMatch += repeatedASCII("a", length: 90)
        XCTAssertLessThan(shortButWouldMatch.count, ContextLeakDetector.minOutputChars)

        let result = ContextLeakDetector.evaluate(output: shortButWouldMatch, context: ctx)
        XCTAssertFalse(result.leaked)
        XCTAssertNil(result.matchedField)

        // Also vanilla case.
        let r2 = ContextLeakDetector.evaluate(output: "Short output under 100 chars.", context: ctx)
        XCTAssertFalse(r2.leaked)
        XCTAssertNil(r2.matchedField)
    }

    // MARK: - Clean paraphrase

    func testCleanParaphrase_unrelated200PlusCharsReturnsClean() {
        let output = String(
            repeating: "Totally unrelated sentences that paraphrase nothing specific. ",
            count: 6
        )
        XCTAssertGreaterThanOrEqual(output.count, 200)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor =
            "Completely different subject: railway timetables and harbour cranes loading cargo ships."
        ctx.selectedText =
            "More unrelated copy about mountain climbing routes that never overlap with the output."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertFalse(result.leaked)
        XCTAssertNil(result.matchedField)
    }

    // MARK: - Full leak via textBeforeCursor

    func testLeakViaTextBeforeCursor_flagsAndReturnsCorrectField() {
        let output = "Cleaned preamble. " + leaked120 + " Cleaned trailer."
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor = "Preceding context. " + leaked120 + " More context after."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertTrue(result.leaked)
        XCTAssertEqual(result.matchedField, "text_before_cursor")
        XCTAssertNotNil(result.sample)
    }

    // MARK: - Full leak via selectedText

    func testLeakViaSelectedText_flagsAndReturnsCorrectField() {
        let output = "Cleaned preamble. " + leaked120 + " Cleaned trailer."
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.selectedText = "Preceding selection. " + leaked120 + " More selection after."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertTrue(result.leaked)
        XCTAssertEqual(result.matchedField, "selected_text")
        XCTAssertNotNil(result.sample)
    }

    // MARK: - Threshold edges

    func testThresholdEdge_79CharSharedRunNotFlagged() {
        let run79 = String(
            "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+-=["
                .prefix(79)
        )
        XCTAssertEqual(run79.count, 79)

        let output = "Prefix unique 111. " + run79 + " suffix unique 222."
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor =
            "Totally different. " + run79 +
            " More different. Padding to be long enough to be considered."
        XCTAssertGreaterThanOrEqual((ctx.textBeforeCursor ?? "").count, ContextLeakDetector.minRunChars)

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertFalse(result.leaked, "79-char shared run should NOT trigger a leak")
        XCTAssertNil(result.matchedField)
    }

    func testThresholdEdge_80CharSharedRunFlagged() {
        let run80 = String(
            "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+-=[]"
                .prefix(80)
        )
        XCTAssertEqual(run80.count, 80)

        let output = "Prefix unique 111. " + run80 + " suffix unique 222."
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor =
            "Totally different. " + run80 + " More different. Padding to make it long."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertTrue(result.leaked, "80-char shared run SHOULD trigger a leak")
        XCTAssertEqual(result.matchedField, "text_before_cursor")
        XCTAssertNotNil(result.sample)
    }

    // MARK: - Grapheme safety

    func testGraphemeSafety_emojiAndCombiningMarksDoNotTrap_andASCIIOverlapStillDetected() {
        let emojiPrefix = "Hello 👋🏽 world — café"
        let output = emojiPrefix + " " + leaked120 + " trailing 🌟"
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor = "Safe prefix. " + leaked120 + " Safe trailing."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertTrue(result.leaked)
        XCTAssertEqual(result.matchedField, "text_before_cursor")
    }

    func testGraphemeSafety_emojiOutputWithoutOverlapReturnsClean() {
        let output = String(
            repeating: "Hello 👋🏽 world — café naïve résumé. ",
            count: 8
        )
        XCTAssertGreaterThanOrEqual(output.count, ContextLeakDetector.minOutputChars)

        var ctx = RefinementContext.empty
        ctx.textBeforeCursor =
            "Completely unrelated text about mountains and rivers and trains and bridges crossing them."

        let result = ContextLeakDetector.evaluate(output: output, context: ctx)
        XCTAssertFalse(result.leaked)
    }
}
