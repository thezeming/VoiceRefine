import Foundation
import Speech

/// Thin wrapper around the `Speech` framework's on-device asset catalogue.
/// Kept separate from `AppleSpeechProvider` so the Transcription tab and
/// Onboarding window can introspect support/install status without having
/// to spin up a full transcriber.
///
/// All entry points are `async` because `SpeechTranscriber.supportedLocales`
/// and `AssetInventory.assetInstallationRequest` are both async on the
/// shipping macOS 26 API.
@available(macOS 26, *)
enum AppleSpeechAssetManager {
    /// Locale identifiers (underscored POSIX form, e.g. `en_US`) that
    /// `SpeechTranscriber` can handle on this machine. Apple manages the
    /// list — it grows with OS updates.
    ///
    /// Falls back to a hard-coded list if the runtime query fails, so the
    /// Transcription tab always has *something* to render.
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

    /// Returns true iff the on-disk asset for `localeID` is already
    /// available — i.e. a transcribe call would run fully offline without
    /// kicking off a download.
    ///
    /// Implementation note: `AssetInventory.assetInstallationRequest` is
    /// the canonical "is a download required for these modules?" check. A
    /// nil return means no install is needed → asset is present.
    static func isInstalled(localeID: String) async -> Bool {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            return request == nil
        } catch {
            return false
        }
    }
}
