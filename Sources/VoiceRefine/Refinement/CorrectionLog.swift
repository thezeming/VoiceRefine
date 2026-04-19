import Foundation

/// Append-only log of every "Correct last…" save, plus the original
/// recorded audio when still available. Lives in
/// `~/Library/Application Support/VoiceRefine/`:
///   - `corrections.jsonl` — one entry per line
///   - `corrections/<timestamp>.wav` — copy of the recording at correction
///     time (only present when the most-recent dictation's WAV hasn't
///     been overwritten by a newer one).
///
/// Designed for offline analysis: feed the JSONL into an LLM (or any
/// diff tool) to spot recurring transcription / refinement mistakes, and
/// re-feed the WAVs through alternative ASR models if you want to
/// compare. Schema is intentionally flat and self-documenting.
enum CorrectionLog {

    struct Entry: Codable {
        let timestamp: String
        let raw: String
        let originalRefined: String
        let correctedRefined: String
        let glossaryAdditions: [String]
        let frontmostAppBundleID: String?
        /// Path of the saved WAV, relative to the corrections folder.
        /// Nil when the source `last.wav` was already gone.
        let audioPath: String?
    }

    /// Append a single entry; copy the latest recording if available.
    /// Failures are logged via NSLog and otherwise silent — the user just
    /// loses the record for that one correction, never blocks the paste.
    static func append(
        raw: String,
        originalRefined: String,
        correctedRefined: String,
        glossaryAdditions: [String],
        frontmostAppBundleID: String?,
        sourceWavURL: URL
    ) {
        let fm = FileManager.default
        let folder = supportDirectory()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("VoiceRefine: CorrectionLog could not create folder: \(error)")
            return
        }

        let timestamp = Self.timestampString()
        let audioPath: String?
        if fm.fileExists(atPath: sourceWavURL.path) {
            let audioFolder = folder.appendingPathComponent("corrections", isDirectory: true)
            try? fm.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            let dest = audioFolder.appendingPathComponent("\(timestamp).wav")
            do {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: sourceWavURL, to: dest)
                audioPath = "corrections/\(timestamp).wav"
            } catch {
                NSLog("VoiceRefine: CorrectionLog could not copy audio: \(error)")
                audioPath = nil
            }
        } else {
            audioPath = nil
        }

        let entry = Entry(
            timestamp: timestamp,
            raw: raw,
            originalRefined: originalRefined,
            correctedRefined: correctedRefined,
            glossaryAdditions: glossaryAdditions,
            frontmostAppBundleID: frontmostAppBundleID,
            audioPath: audioPath
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else {
            NSLog("VoiceRefine: CorrectionLog encode failed")
            return
        }

        let logURL = folder.appendingPathComponent("corrections.jsonl")
        let appendBytes = (line + "\n").data(using: .utf8) ?? Data()
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: appendBytes)
            }
        } else {
            try? appendBytes.write(to: logURL, options: .atomic)
        }
    }

    /// Folder hosting the JSONL + audio. Public so AdvancedTab can offer
    /// a "Reveal in Finder" button.
    static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VoiceRefine", isDirectory: true)
    }

    private static func timestampString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // Filesystem-safe: replace ':' with '-' for the audio filename.
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
