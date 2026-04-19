import Foundation

/// Simple append-only diagnostic log that rotates once it grows past
/// `maxBytes`. `paste.log` and `context.log` share this so a year of
/// heavy dictation can't silently accumulate a character-count timeline
/// on disk.
///
/// Rotation is single-generation: on overflow the current file is
/// renamed to `<name>.old`, any previous `.old` is removed, and a fresh
/// log starts. Writes are best-effort — we never throw from the logging
/// path since callers are typically already on an error path.
///
/// Respects `PrefKey.disableDiagnosticLogs`: when set, `append` is a
/// no-op so privacy-conscious users can turn paste.log and context.log
/// off entirely from the Advanced tab.
struct RotatingLogFile {
    let url: URL
    let maxBytes: Int

    init(url: URL, maxBytes: Int = 256 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ message: String) {
        if UserDefaults.standard.bool(forKey: PrefKey.disableDiagnosticLogs) { return }

        let stamped = Self.dateFormatter.string(from: Date()) + " " + message + "\n"
        guard let data = stamped.data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateIfNeeded(incomingSize: data.count)

        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func rotateIfNeeded(incomingSize: Int) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return }
        if size + incomingSize < maxBytes { return }
        let backup = url.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
