import XCTest
@testable import VoiceRefine

final class RefinementOutputSanitizerTests: XCTestCase {

    // MARK: - Identity

    func testIdentity_cleanTextPassesThrough() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Hello world."),
            "Hello world."
        )
    }

    func testIdentity_multiSentenceCleanTextPassesThrough() {
        let input = "The quick brown fox jumps over the lazy dog. Not a preamble here."
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), input)
    }

    // MARK: - Trimming

    func testTrimming_leadingAndTrailingWhitespaceStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("   Hello world.   "),
            "Hello world."
        )
    }

    func testTrimming_leadingAndTrailingNewlinesStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("\n\nHello world.\n\n"),
            "Hello world."
        )
    }

    func testTrimming_mixedWhitespaceAndNewlinesStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("  \n \t Hello world. \t \n  "),
            "Hello world."
        )
    }

    // MARK: - Code fences

    func testCodeFences_languageTaggedFenceStripped() {
        let input = "```swift\nlet x = 1\n```"
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), "let x = 1")
    }

    func testCodeFences_bareFenceStripped() {
        let input = "```\nHello world.\n```"
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), "Hello world.")
    }

    func testCodeFences_fenceWithMultipleLinesInside() {
        let input = "```swift\nlet x = 1\nlet y = 2\n```"
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize(input),
            "let x = 1\nlet y = 2"
        )
    }

    // MARK: - Stray tags

    func testStrayTags_transcriptTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<transcript>Hello</transcript>"),
            "Hello"
        )
    }

    func testStrayTags_contextTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<context>Hello</context>"),
            "Hello"
        )
    }

    func testStrayTags_appTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<app>Hello</app>"),
            "Hello"
        )
    }

    func testStrayTags_selectedTextTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<selected_text>Hello</selected_text>"),
            "Hello"
        )
    }

    func testStrayTags_textBeforeCursorTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize(
                "<text_before_cursor>Hello</text_before_cursor>"
            ),
            "Hello"
        )
    }

    func testStrayTags_glossaryTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<glossary>Hello</glossary>"),
            "Hello"
        )
    }

    func testStrayTags_metadataTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("<metadata>Hello</metadata>"),
            "Hello"
        )
    }

    func testStrayTags_midStringTagsStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("before <transcript>middle</transcript> after"),
            "before middle after"
        )
    }

    func testStrayTags_selfClosingStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Hello <transcript/> world"),
            "Hello  world"
        )
    }

    // MARK: - Leading preambles

    func testPreamble_heresTheCleanedText() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Here's the cleaned text:\nHello world."),
            "Hello world."
        )
    }

    func testPreamble_sureHereIsTheCleanedTranscript() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize(
                "Sure! Here is the cleaned transcript:\nHello world."
            ),
            "Hello world."
        )
    }

    func testPreamble_cleanedTranscriptColon() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Cleaned transcript:\nHello world."),
            "Hello world."
        )
    }

    func testPreamble_okayNewline() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Okay,\nHello world."),
            "Hello world."
        )
    }

    func testPreamble_sureNewline() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("Sure.\nHello world."),
            "Hello world."
        )
    }

    func testPreamble_heresWithNoColonIsPreserved() {
        // "Here's the patch I wrote." — NO colon — must stay verbatim.
        let input = "Here's the patch I wrote."
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), input)
    }

    // MARK: - Wrapping quotes

    func testWrappingQuotes_doubleStraightStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("\"Hello world.\""),
            "Hello world."
        )
    }

    func testWrappingQuotes_singleStraightStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("'Hello world.'"),
            "Hello world."
        )
    }

    func testWrappingQuotes_backticksStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("`Hello world.`"),
            "Hello world."
        )
    }

    func testWrappingQuotes_curlyDoubleStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("\u{201C}Hello world.\u{201D}"),
            "Hello world."
        )
    }

    func testWrappingQuotes_curlySingleStripped() {
        XCTAssertEqual(
            RefinementOutputSanitizer.sanitize("\u{2018}Hello world.\u{2019}"),
            "Hello world."
        )
    }

    func testWrappingQuotes_unmatchedOpenerLeftAlone() {
        let input = "\"Hello world."
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), input)
    }

    func testWrappingQuotes_unmatchedCloserLeftAlone() {
        let input = "Hello world.\""
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), input)
    }

    // MARK: - Combined (order)

    func testCombined_fenceAndTagAndPreambleAndQuote() {
        let input = """
        ```swift
        Here's the cleaned text:
        "<transcript>Hello world.</transcript>"
        ```
        """
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), "Hello world.")
    }

    func testCombined_tagAndPreamble() {
        let input = "Here's the cleaned text:\n<transcript>Hello world.</transcript>"
        XCTAssertEqual(RefinementOutputSanitizer.sanitize(input), "Hello world.")
    }
}
