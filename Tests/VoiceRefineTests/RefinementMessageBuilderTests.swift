import XCTest
@testable import VoiceRefine

final class RefinementMessageBuilderTests: XCTestCase {

    // MARK: - Transcript first

    func testTranscriptAppearsFirstBeforeAnyContextBlock() {
        var ctx = RefinementContext.empty
        ctx.frontmostApp = "Xcode"
        ctx.selectedText = "let x = 1"

        let msg = RefinementMessageBuilder.userMessage(
            transcript: "hello world",
            context: ctx
        )

        XCTAssertTrue(
            msg.hasPrefix("<transcript>\nhello world\n</transcript>"),
            "Expected transcript block first, got:\n\(msg)"
        )

        let transcriptRange = msg.range(of: "</transcript>")
        let contextRange = msg.range(of: "<context>")
        XCTAssertNotNil(transcriptRange)
        XCTAssertNotNil(contextRange)
        if let t = transcriptRange, let c = contextRange {
            XCTAssertLessThan(t.lowerBound, c.lowerBound)
        }
    }

    // MARK: - Context omitted when empty

    func testEmptyContextProducesOnlyTranscriptBlock() {
        let msg = RefinementMessageBuilder.userMessage(
            transcript: "hello world",
            context: .empty
        )

        XCTAssertEqual(msg, "<transcript>\nhello world\n</transcript>")
        XCTAssertFalse(msg.contains("<context>"))
        XCTAssertFalse(msg.contains("</context>"))
        XCTAssertFalse(msg.contains("<glossary>"))
        XCTAssertFalse(msg.contains("</glossary>"))
    }

    // MARK: - Window title never appears

    func testWindowTitleIsNeverWrittenIntoOutput() {
        var ctx = RefinementContext.empty
        ctx.windowTitle = "Secret Project - main.swift"
        ctx.frontmostApp = "Xcode"

        let msg = RefinementMessageBuilder.userMessage(
            transcript: "hello",
            context: ctx
        )

        XCTAssertFalse(
            msg.contains("Secret Project"),
            "Window title leaked into output:\n\(msg)"
        )
        XCTAssertFalse(msg.contains("<window_title>"))
        XCTAssertFalse(msg.contains("windowTitle"))
    }

    func testWindowTitleAloneProducesNoContextBlock() {
        // hasContext is derived from frontmostApp / selectedText /
        // textBeforeCursor — windowTitle is intentionally excluded.
        var ctx = RefinementContext.empty
        ctx.windowTitle = "Whatever - file.swift"

        let msg = RefinementMessageBuilder.userMessage(
            transcript: "hello",
            context: ctx
        )

        XCTAssertEqual(msg, "<transcript>\nhello\n</transcript>")
        XCTAssertFalse(msg.contains("<context>"))
    }

    // MARK: - Glossary

    func testGlossaryProducesStandaloneBlock() {
        var ctx = RefinementContext.empty
        ctx.glossary = "kubectl\nnginx\nSwiftUI"

        let msg = RefinementMessageBuilder.userMessage(
            transcript: "hello",
            context: ctx
        )

        XCTAssertTrue(
            msg.contains("<glossary>\nkubectl\nnginx\nSwiftUI\n</glossary>"),
            "Expected glossary block in output, got:\n\(msg)"
        )
    }

    func testEmptyGlossaryProducesNoGlossaryBlock() {
        var ctx = RefinementContext.empty
        ctx.glossary = ""
        let msg = RefinementMessageBuilder.userMessage(transcript: "hi", context: ctx)
        XCTAssertFalse(msg.contains("<glossary>"))
    }

    // MARK: - XML escaping

    func testXMLEscaping_frontmostAppSpecialCharsAreEscaped() {
        var ctx = RefinementContext.empty
        ctx.frontmostApp = "A<B>&C"

        let msg = RefinementMessageBuilder.userMessage(transcript: "hi", context: ctx)

        XCTAssertTrue(msg.contains("<app>A&lt;B&gt;&amp;C</app>"), "Got: \(msg)")
        XCTAssertFalse(msg.contains("<app>A<B>&C</app>"), "Raw specials leaked: \(msg)")
    }

    func testXMLEscaping_selectedTextSpecialCharsAreEscaped() {
        var ctx = RefinementContext.empty
        ctx.selectedText = "if x < y && y > z"

        let msg = RefinementMessageBuilder.userMessage(transcript: "hi", context: ctx)

        XCTAssertTrue(
            msg.contains("<selected_text>if x &lt; y &amp;&amp; y &gt; z</selected_text>"),
            "Got: \(msg)"
        )
    }

    func testXMLEscaping_textBeforeCursorSpecialCharsAreEscaped() {
        var ctx = RefinementContext.empty
        ctx.textBeforeCursor = "x < y & y > z"

        let msg = RefinementMessageBuilder.userMessage(transcript: "hi", context: ctx)

        XCTAssertTrue(
            msg.contains("<text_before_cursor>x &lt; y &amp; y &gt; z</text_before_cursor>"),
            "Got: \(msg)"
        )
    }

    func testXMLEscaping_ampersandEscapedBeforeAngleBracketsNoDoubleEscape() {
        // Regression guard: "&lt;" must not be double-escaped to "&amp;lt;".
        var ctx = RefinementContext.empty
        ctx.frontmostApp = "&<>"

        let msg = RefinementMessageBuilder.userMessage(transcript: "hi", context: ctx)

        XCTAssertTrue(msg.contains("<app>&amp;&lt;&gt;</app>"), "Got: \(msg)")
        XCTAssertFalse(msg.contains("&amp;lt;"), "Double-escaped '<': \(msg)")
        XCTAssertFalse(msg.contains("&amp;gt;"), "Double-escaped '>': \(msg)")
        XCTAssertFalse(msg.contains("&amp;amp;"), "Double-escaped '&': \(msg)")
    }
}
