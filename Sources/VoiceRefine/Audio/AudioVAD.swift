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
    ///     word boundaries are not clipped. Default: 200 ms.
    /// - Returns: A subrange of `data` containing just the voiced region
    ///   (plus hangover padding), or the original `data` unchanged if no
    ///   voiced frames are detected. Always byte-aligned to a 2-byte (Int16)
    ///   boundary.
    static func trim(
        _ data: Data,
        frameMs: Int = 20,
        silenceHangoverMs: Int = 200
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

        // --- Noise floor from edges (first ~100 ms and last ~100 ms) ---
        // Use 5 frames (= 100 ms at 20 ms / frame) or however many exist.
        let edgeFrames = max(1, 100 / frameMs)
        let leadCount  = min(edgeFrames, frameCount)
        let trailCount = min(edgeFrames, frameCount)

        let leadMax  = rms[0..<leadCount].max() ?? 0
        let trailMax = rms[(frameCount - trailCount)...].max() ?? 0
        let edgeMax  = min(leadMax, trailMax)

        // Guard against zero-floor (totally silent recording) so the voicing
        // threshold never collapses to zero.
        let noiseFloor: Float = max(edgeMax, 0.005)

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
