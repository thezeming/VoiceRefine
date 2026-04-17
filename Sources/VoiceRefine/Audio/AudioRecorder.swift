import AVFoundation
import Foundation

/// Captures microphone audio while the hotkey is held, converting to
/// 16 kHz mono Int16 PCM on the fly so we can drop the raw bytes straight
/// into Whisper later (Phase 3). Appends little-endian samples into an
/// in-memory `Data` buffer; callers can pull out either the raw PCM or a
/// fully-formed WAV file.
final class AudioRecorder {
    enum RecorderError: Error, CustomStringConvertible {
        case converterUnavailable
        case engineStartFailed(Error)

        var description: String {
            switch self {
            case .converterUnavailable:           "Could not build AVAudioConverter."
            case .engineStartFailed(let err):     "AVAudioEngine.start failed: \(err.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.voicerefine.AudioRecorder", qos: .userInitiated)
    private var accumulatedData = Data()
    private var converter: AVAudioConverter?
    private(set) var isRecording: Bool = false

    let targetFormat: AVAudioFormat

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("Could not build 16 kHz mono Int16 AVAudioFormat.")
        }
        self.targetFormat = format
    }

    // MARK: - Control

    func start() throws {
        guard !isRecording else { return }
        queue.sync { accumulatedData.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }
        isRecording = true
    }

    @discardableResult
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        return queue.sync { accumulatedData }
    }

    // MARK: - Introspection

    var duration: TimeInterval {
        let bytes = queue.sync { accumulatedData.count }
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return 0 }
        return Double(bytes / bytesPerFrame) / targetFormat.sampleRate
    }

    var byteCount: Int {
        queue.sync { accumulatedData.count }
    }

    // MARK: - Tap handler

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if status == .error {
            if let error { NSLog("VoiceRefine: AVAudioConverter error: \(error)") }
            return
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let channels = outBuffer.int16ChannelData else { return }

        let byteCount = frameCount * MemoryLayout<Int16>.size
        let chunk = Data(bytes: channels.pointee, count: byteCount)
        queue.sync {
            accumulatedData.append(chunk)
        }
    }

    // MARK: - WAV export

    func writeWAV(to url: URL) throws {
        let pcm = queue.sync { accumulatedData }
        let sampleRate   = UInt32(targetFormat.sampleRate)
        let channels     = UInt16(targetFormat.channelCount)
        let bitsPerSample: UInt16 = 16
        let byteRate     = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign   = channels * bitsPerSample / 8
        let dataSize     = UInt32(pcm.count)
        let riffSize     = dataSize + 36

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLE(riffSize)
        wav.appendASCII("WAVE")

        wav.appendASCII("fmt ")
        wav.appendLE(UInt32(16))       // PCM subchunk size
        wav.appendLE(UInt16(1))        // AudioFormat = PCM
        wav.appendLE(channels)
        wav.appendLE(sampleRate)
        wav.appendLE(byteRate)
        wav.appendLE(blockAlign)
        wav.appendLE(bitsPerSample)

        wav.appendASCII("data")
        wav.appendLE(dataSize)
        wav.append(pcm)

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try wav.write(to: url, options: .atomic)
    }
}

private extension Data {
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
