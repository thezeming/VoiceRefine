import XCTest
import AVFoundation
@testable import VoiceRefine

final class WAVEncoderTests: XCTestCase {

    // MARK: - Helpers

    private func readLE_UInt16(_ data: Data, at off: Int) -> UInt16 {
        let lo = UInt16(data[off])
        let hi = UInt16(data[off + 1])
        return lo | (hi << 8)
    }

    private func readLE_UInt32(_ data: Data, at off: Int) -> UInt32 {
        let b0 = UInt32(data[off])
        let b1 = UInt32(data[off + 1])
        let b2 = UInt32(data[off + 2])
        let b3 = UInt32(data[off + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func readASCII4(_ data: Data, at off: Int) -> String {
        String(bytes: data[off..<(off + 4)], encoding: .ascii) ?? ""
    }

    // MARK: - Header correctness

    func testHeaderContainsRIFFWaveFmtAndData_withCorrectFields() {
        let sampleRate = 16_000
        let channels = 1
        let bitsPerSample = 16
        let seconds = 0.25
        let expectedFrames = Int(Double(sampleRate) * seconds)
        let bytesPerFrame = channels * bitsPerSample / 8
        let pcmByteCount = expectedFrames * bytesPerFrame
        let pcm = Data(count: pcmByteCount)

        XCTAssertEqual(pcm.count, expectedFrames * bytesPerFrame)

        let wav = WAVEncoder.encode(
            pcm: pcm,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        XCTAssertEqual(readASCII4(wav, at: 0), "RIFF")
        XCTAssertEqual(readLE_UInt32(wav, at: 4), UInt32(pcm.count + 36))
        XCTAssertEqual(readASCII4(wav, at: 8), "WAVE")

        XCTAssertEqual(readASCII4(wav, at: 12), "fmt ")
        XCTAssertEqual(readLE_UInt32(wav, at: 16), 16)
        XCTAssertEqual(readLE_UInt16(wav, at: 20), 1) // PCM
        XCTAssertEqual(readLE_UInt16(wav, at: 22), UInt16(channels))
        XCTAssertEqual(readLE_UInt32(wav, at: 24), UInt32(sampleRate))
        let expectedByteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        XCTAssertEqual(readLE_UInt32(wav, at: 28), expectedByteRate)
        XCTAssertEqual(readLE_UInt16(wav, at: 32), UInt16(channels * bitsPerSample / 8))
        XCTAssertEqual(readLE_UInt16(wav, at: 34), UInt16(bitsPerSample))

        XCTAssertEqual(readASCII4(wav, at: 36), "data")
        XCTAssertEqual(readLE_UInt32(wav, at: 40), UInt32(pcm.count))
    }

    func testRawPCMLengthMatchesFramesTimesBytesPerFrame() {
        let sampleRate = 16_000
        let channels = 1
        let bitsPerSample = 16
        let frames = 4_000
        let bytesPerFrame = channels * bitsPerSample / 8

        var pcm = Data(capacity: frames * bytesPerFrame)
        for i in 0..<frames {
            var sample = Int16(truncatingIfNeeded: i % 30_000)
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        XCTAssertEqual(pcm.count, frames * bytesPerFrame)

        let wav = WAVEncoder.encode(
            pcm: pcm,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        // Everything after the 44-byte header = raw PCM.
        let rawPCMLengthInFile = wav.count - 44
        XCTAssertEqual(rawPCMLengthInFile, frames * bytesPerFrame)
        XCTAssertEqual(readLE_UInt32(wav, at: 40), UInt32(frames * bytesPerFrame))
    }

    // MARK: - Round-trip through AVAudioFile

    func testRoundTripThroughAVAudioFileReportsSameSampleRateAndChannelCount() throws {
        let sampleRate = 16_000
        let channels = 1
        let bitsPerSample = 16
        let frames = 2_000 // ~125 ms @ 16 kHz
        let bytesPerFrame = channels * bitsPerSample / 8

        // Simple 200 Hz sine wave so the file isn't entirely silent.
        var pcm = Data(capacity: frames * bytesPerFrame)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let s = sin(2.0 * .pi * 200.0 * t)
            var sample = Int16(s * 16_000)
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        let wav = WAVEncoder.encode(
            pcm: pcm,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voicerefine-wavencoder-test-\(UUID().uuidString).wav")
        try wav.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let file = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(file.fileFormat.sampleRate, Double(sampleRate))
        XCTAssertEqual(file.fileFormat.channelCount, UInt32(channels))
        XCTAssertEqual(file.length, Int64(frames))
    }
}
