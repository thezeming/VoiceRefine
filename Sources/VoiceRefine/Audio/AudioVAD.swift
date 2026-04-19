import Foundation

/// Energy-based voice-activity detection for Int16 PCM at 16 kHz mono.
///
/// Used to trim leading and trailing silence from recorded audio before
/// transcription, reducing latency and preventing short voiced utterances
/// from being dropped by the minimum-duration gate.
enum AudioVAD {

    // MARK: - Constants

    /// Samples per second for the expected audio format.
    private static let sampleRate: Int = 16_000

    // MARK: - Public API

    /// Trim leading and trailing silence from raw Int16 PCM data.
    ///
    /// - Parameters:
    ///   - data: Raw Int16 little-endian mono PCM at 16 kHz.
    ///   - frameMs: Analysis frame size in milliseconds. Default: 20 ms (= 320 samples).
    ///   - silenceHangoverMs: Extra padding to keep around voiced regions so
    ///     word boundaries are not clipped. Default: 300 ms.
    /// - Returns: A subrange of `data` containing just the voiced region
    ///   (plus hangover padding), or the original `data` unchanged if no
    ///   voiced frames are detected. Always byte-aligned to a 2-byte (Int16)
    ///   boundary.
    static func trim(
        _ data: Data,
        frameMs: Int = 20,
        silenceHangoverMs: Int = 300
    ) -> Data {
        let samplesPerFrame = frameMs * sampleRate / 1_000        // 320 @ 20 ms
        let bytesPerFrame = samplesPerFrame * 2                   // 640 bytes
        let totalSamples = data.count / 2
        let frameCount = totalSamples / samplesPerFrame

        // Need at least a couple of frames to be worth analysing.
        guard frameCount >= 2 else { return data }

        // --- Compute per-frame RMS ---
        var rms = [Float](repeating: 0, count: frameCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frameCount {
                let start = f * samplesPerFrame
                var sumSq: Float = 0
                for i in start..<(start + samplesPerFrame) {
                    let s = Float(samples[i]) / 32_768.0
                    sumSq += s * s
                }
                rms[f] = (sumSq / Float(samplesPerFrame)).squareRoot()
            }
        }

        // --- Noise floor from the 10th-percentile frame RMS ---
        //
        // The old edge-based estimate (min of first-100 ms max and
        // last-100 ms max) broke for long dictations that begin and end
        // with speech: both edges then carried voice-level energy, so
        // the noise floor inflated to near-speech level and the threshold
        // clipped the quieter leading syllables. P10 is dominated by
        // inter-word gaps and low-energy consonants even in continuous
        // speech, so it tracks the real mic-level noise regardless of
        // where the user happened to pause. The hard cap at 0.02 keeps
        // the estimate from drifting up in unusually loud environments
        // where even "silence" between syllables is non-trivial.
        let sorted = rms.sorted()
        let p10Index = max(0, min(sorted.count - 1, sorted.count / 10))
        let p10: Float = sorted[p10Index]
        let noiseFloor: Float = max(min(p10, 0.02), 0.005)

        // --- Voicing threshold ---
        let threshold: Float = max(noiseFloor * 3, 0.015)

        // --- Find first and last voiced frames ---
        guard let firstVoiced = rms.indices.first(where: { rms[$0] > threshold }),
              let lastVoiced  = rms.indices.last (where: { rms[$0] > threshold })
        else {
            // No voiced content detected — return original data unchanged.
            return data
        }

        // --- Apply hangover padding ---
        let hangoverFrames = silenceHangoverMs / frameMs
        let trimStart = max(0,           firstVoiced - hangoverFrames)
        let trimEnd   = min(frameCount,  lastVoiced  + hangoverFrames + 1)

        let startByte = trimStart * bytesPerFrame
        var endByte   = trimEnd   * bytesPerFrame

        // Clamp and ensure byte-aligned (even boundary for Int16).
        endByte = min(endByte, data.count)
        if endByte % 2 != 0 { endByte -= 1 }

        guard startByte < endByte else { return data }

        // If trim recovers essentially the whole buffer, skip the copy.
        if startByte == 0 && endByte == data.count { return data }

        return data.subdata(in: startByte..<endByte)
    }
}
