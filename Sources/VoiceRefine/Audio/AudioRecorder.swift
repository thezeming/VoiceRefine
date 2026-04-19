import AVFoundation
import Foundation
import os

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
    /// Protects the accumulated PCM buffer.  The tap callback fires on an
    /// audio thread; `OSAllocatedUnfairLock` is ~100× cheaper than
    /// `DispatchQueue.sync` for the tiny critical sections here (buffer-append
    /// or count-read — never any blocking work under the lock).
    private let bufferLock = OSAllocatedUnfairLock(initialState: Data())
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
        bufferLock.withLock { data in data.removeAll(keepingCapacity: true) }

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
        // Tap is already removed; reading the buffer here is safe but we still
        // go through the lock for correctness (a queued tap delivery could
        // theoretically be in-flight just before removeTap returns).
        return bufferLock.withLock { $0 }
    }

    // MARK: - Introspection

    var duration: TimeInterval {
        let bytes = bufferLock.withLock { $0.count }
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return 0 }
        return Double(bytes / bytesPerFrame) / targetFormat.sampleRate
    }

    var byteCount: Int {
        bufferLock.withLock { $0.count }
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
        bufferLock.withLock { data in data.append(chunk) }
    }

    // MARK: - WAV export

    /// Returns the accumulated PCM packaged as WAV bytes. Cloud
    /// transcription providers upload this; the disk write below uses
    /// the same bytes.
    func makeWAVData() -> Data {
        let pcm = bufferLock.withLock { $0 }
        return WAVEncoder.encode(
            pcm: pcm,
            sampleRate: Int(targetFormat.sampleRate),
            channels: Int(targetFormat.channelCount),
            bitsPerSample: 16
        )
    }

    func writeWAV(to url: URL) throws {
        let wav = makeWAVData()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try wav.write(to: url, options: .atomic)
    }
}
