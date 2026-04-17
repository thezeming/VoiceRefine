import Foundation

/// Builds a minimal RIFF/WAVE file from raw little-endian PCM. Used by
/// AudioRecorder to persist `last.wav` and by cloud transcription
/// providers that upload WAV bytes to a REST endpoint.
enum WAVEncoder {
    static func encode(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        precondition(bitsPerSample % 8 == 0, "bitsPerSample must be a multiple of 8")

        let byteRate   = UInt32(sampleRate * channels * bitsPerSample / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        let dataSize   = UInt32(pcm.count)
        let riffSize   = dataSize + 36

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLE(riffSize)
        wav.appendASCII("WAVE")

        wav.appendASCII("fmt ")
        wav.appendLE(UInt32(16))                  // fmt chunk size
        wav.appendLE(UInt16(1))                   // PCM
        wav.appendLE(UInt16(channels))
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(byteRate)
        wav.appendLE(blockAlign)
        wav.appendLE(UInt16(bitsPerSample))

        wav.appendASCII("data")
        wav.appendLE(dataSize)
        wav.append(pcm)
        return wav
    }
}

extension Data {
    mutating func appendASCII(_ s: String) {
        append(contentsOf: s.utf8)
    }
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
