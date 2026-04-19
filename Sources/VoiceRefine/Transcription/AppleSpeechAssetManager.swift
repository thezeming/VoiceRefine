import Foundation
import Speech

/// Thin wrapper around the `Speech` framework's on-device asset catalogue.
/// Kept separate from `AppleSpeechProvider` so the Transcription tab and
/// Onboarding window can introspect support/install status without having
/// to spin up a full transcriber.
///
/// All entry points are `async` because `SpeechTranscriber.supportedLocales`,
/// `AssetInventory.status` and `AssetInventory.assetInstallationRequest`
/// are all async on the shipping macOS 26 API.
@available(macOS 26, *)
enum AppleSpeechAssetManager {
    /// Mirrors `AssetInventory.Status` but is safe to surface at the app
    /// layer (the `Speech`-typed enum can't cross a non-`@available(macOS 26)`
    /// boundary).
    enum LocaleStatus: Equatable {
        case unsupported
        case supported      // recognised locale, asset not installed
        case downloading
        case installed
    }

    /// Locale identifiers (underscored POSIX form, e.g. `en_US`) that
    /// `SpeechTranscriber` can handle on this machine. Apple manages the
    /// list — it grows with OS updates. Falls back to a hard-coded list
    /// if the runtime query returns empty.
    static func supportedLocales() async -> [String] {
        let runtime = await SpeechTranscriber.supportedLocales
        // `Locale.identifier` uses `-` as the region separator on modern
        // macOS (BCP-47-ish); our hard-coded fallback list and the
        // `modelPreferenceKey` storage use the underscored POSIX form so
        // they survive a round-trip through `Locale(identifier:)`. Normalise
        // to `_` here so both sources compare equal.
        let ids = runtime.map { $0.identifier.replacingOccurrences(of: "-", with: "_") }
        if ids.isEmpty {
            return TranscriptionProviderID.appleSpeech.availableModels
        }
        return ids.sorted()
    }

    /// Current catalogue status for the locale's `SpeechTranscriber`
    /// asset. The authoritative source (`AssetInventory.status`) already
    /// handles the distinction between "never-downloaded" and
    /// "download-in-progress" for us.
    static func status(for localeID: String) async -> LocaleStatus {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: return .unsupported
        case .supported:   return .supported
        case .downloading: return .downloading
        case .installed:   return .installed
        @unknown default:  return .supported
        }
    }

    static func isInstalled(localeID: String) async -> Bool {
        await status(for: localeID) == .installed
    }

    /// Downloads and installs the asset for `localeID`. Reports progress
    /// as a fraction in [0, 1] plus a human-readable status line. Returns
    /// when the install is complete (or immediately, if the asset is
    /// already installed).
    static func installLocale(
        _ localeID: String,
        progress progressCallback: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Reserving keeps the OS from reaping the asset under storage
        // pressure later. Best-effort; a reservation failure (e.g. user
        // already has the max number of reserved locales) shouldn't block
        // the install.
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            progressCallback(1.0, "Installed \(localeID).")
            return
        }

        // `Progress.fractionCompleted` is KVO-observable. Hold the token
        // until the download finishes; invalidate in a defer so it always
        // releases even on a throw / cancel.
        let token = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { prog, _ in
            let frac = prog.fractionCompleted
            let pct = Int((frac * 100).rounded())
            progressCallback(frac, "Downloading \(localeID)… \(pct)%")
        }
        defer { token.invalidate() }

        try await request.downloadAndInstall()
        progressCallback(1.0, "Installed \(localeID).")
    }
}
