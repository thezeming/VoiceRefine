import XCTest
@testable import VoiceRefine

final class AudioVADTests: XCTestCase {

    // MARK: - Helpers

    /// Build a Data block of `frameCount` 20 ms frames at the given amplitude.
    /// Each frame = 320 Int16 samples (20 ms × 16 000 Hz) = 640 bytes.
    private func frames(count: Int, amplitude: Int16) -> Data {
        let samplesPerFrame = 320
        var data = Data(count: count * samplesPerFrame * 2)
        data.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for i in 0..<(count * samplesPerFrame) {
                buf[i] = amplitude
            }
        }
        return data
    }

    // MARK: - Silence bail-out

    func testAllSilence_returnsOriginalData() {
        // 25 frames of near-silence (amplitude 50 ≈ 0.0015 rms — well below threshold)
        let silent = frames(count: 25, amplitude: 50)
        let result = AudioVAD.trim(silent)
        XCTAssertEqual(result, silent, "All-silent input should be returned unchanged")
    }

    // MARK: - Voiced-only passthrough

    func testAllVoiced_returnsOriginalOrEquivalent() {
        // 25 frames of loud audio (amplitude 16000 ≈ 0.49 rms — clearly voiced)
        let loud = frames(count: 25, amplitude: 16_000)
        let result = AudioVAD.trim(loud)
        // Must be byte-equivalent in content (may or may not be same Data instance)
        XCTAssertEqual(result.count, loud.count)
        XCTAssertEqual(result, loud)
    }

    // MARK: - Trim silent edges

    func testSilentLeadingAndTrailing_trimsToVoicedCore() {
        // Layout: 5 silent frames | 10 voiced frames | 5 silent frames
        let silent = frames(count: 5, amplitude: 50)      // ~0.0015 rms
        let voiced = frames(count: 10, amplitude: 16_000) // ~0.49 rms
        let input = silent + voiced + silent

        let result = AudioVAD.trim(input)

        // Result must be shorter than input (silence was trimmed).
        XCTAssertLessThan(result.count, input.count,
            "Trimmed output should be shorter than input with silent edges")

        // Result must be at least as long as the raw voiced region (200 ms hangover
        // can extend into the silent padding on either side).
        XCTAssertGreaterThanOrEqual(result.count, voiced.count,
            "Trimmed output must contain at least the voiced core")

        // Must be byte-aligned (even byte count).
        XCTAssertEqual(result.count % 2, 0, "Result must be Int16-aligned (even byte count)")
    }

    func testSilentLeading_trimsOnlyFront() {
        // Layout: 5 silent frames | 15 voiced frames (no silent tail)
        let silent = frames(count: 5, amplitude: 50)
        let voiced = frames(count: 15, amplitude: 16_000)
        let input = silent + voiced

        let result = AudioVAD.trim(input)

        XCTAssertLessThan(result.count, input.count,
            "Silent leading edge should be trimmed")
        XCTAssertGreaterThanOrEqual(result.count, voiced.count,
            "Full voiced region must be retained")
        XCTAssertEqual(result.count % 2, 0)
    }

    // MARK: - Byte alignment

    func testResultIsAlwaysByteAligned() {
        // Construct an odd-byte-count Data to exercise alignment guard.
        var base = frames(count: 10, amplitude: 16_000)
        base.append(0) // odd byte
        // VAD works on count/2 samples — the extra byte is just ignored;
        // returned slice must still be even.
        let result = AudioVAD.trim(base)
        XCTAssertEqual(result.count % 2, 0)
    }

    // MARK: - Empty / tiny input

    func testEmptyData_returnsEmpty() {
        let result = AudioVAD.trim(Data())
        XCTAssertEqual(result.count, 0)
    }

    func testSingleFrame_returnsOriginal() {
        // < 2 frames → guard fires, returns original unchanged
        let single = frames(count: 1, amplitude: 16_000)
        let result = AudioVAD.trim(single)
        XCTAssertEqual(result, single)
    }
}
