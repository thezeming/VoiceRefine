import Foundation

/// Holds the most recently completed dictation result so the
/// "Correct last…" window can read it.
///
/// Only the most-recent entry is kept; no history. A separate history
/// actor may be added in a future task.
///
/// Written from `DictationPipeline` on the main thread (inside
/// `onTranscript`). Read by `CorrectionWindowController` on the main
/// thread. Both accesses are `@MainActor`-isolated.
@MainActor
final class LastRefinementStore {
    static let shared = LastRefinementStore()

    struct Entry {
        /// The raw transcript as received from the transcription provider.
        let raw: String
        /// The text that was ultimately pasted (post-refinement / sanitisation).
        let refined: String
        /// Context gathered at recording time (app name, selection, etc.).
        let context: RefinementContext?
        /// Bundle ID of the app that was frontmost when the paste happened.
        /// Used to re-activate that app before re-pasting a correction.
        let frontmostAppBundleID: String?
    }

    private(set) var last: Entry?

    func store(_ entry: Entry) {
        last = entry
    }
}
