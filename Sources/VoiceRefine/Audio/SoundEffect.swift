import AppKit

/// Plays short system sounds at recording start / stop when the user
/// has enabled the `playStartStopSound` preference.
///
/// Call `.start.play()` *before* `AudioRecorder.start()` and
/// `.stop.play()` *after* `AudioRecorder.stop()` so the chirp isn't
/// captured by the microphone tap and sent to Whisper.
///
/// `NSSound(named:)` returns nil if the user has removed the named
/// system sound — in that case we silently no-op rather than crash or
/// fall through to a different chirp.
enum SoundEffect {
    case start
    case stop

    private var soundName: NSSound.Name {
        switch self {
        case .start: return NSSound.Name("Tink")
        case .stop:  return NSSound.Name("Pop")
        }
    }

    func play() {
        guard UserDefaults.standard.bool(forKey: PrefKey.playStartStopSound) else { return }
        NSSound(named: soundName)?.play()
    }
}
