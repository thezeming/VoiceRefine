import Foundation

/// In-memory ring buffer of the last N dictation results.
///
/// Entries are stored newest-last (append order); `mostRecent()` returns
/// `entries.last`. The ring is capped at `capacity` items; when full the
/// oldest entry is dropped from the front. Written on paste-success so a
/// failed paste never pollutes the history.
///
/// All access is `@MainActor` — `DictationPipeline` already runs its
/// post-paste work on the main actor, and `MenuBarController` reads from
/// the main thread via the menu delegate callbacks.
@MainActor
final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    struct Entry {
        /// The raw speech-to-text transcript before refinement.
        let raw: String
        /// The refined text that was actually pasted.
        let refined: String
        /// The refinement context captured at dictation time (app name,
        /// selected text, text-before-cursor, glossary). All fields are
        /// value types so this is a safe snapshot — no reference aliasing.
        let context: RefinementContext?
        /// Bundle ID of the frontmost app at record time. Used by
        /// "Retry last" / "Correct last…" to re-activate the same app
        /// before pasting again.
        let frontmostAppBundleID: String?
        let timestamp: Date
    }

    private(set) var entries: [Entry] = []
    private let capacity = 20

    private init() {}

    /// Appends a new entry, trimming to `capacity` if needed.
    func record(
        raw: String,
        refined: String,
        context: RefinementContext?,
        frontmostAppBundleID: String?
    ) {
        let entry = Entry(
            raw: raw,
            refined: refined,
            context: context,
            frontmostAppBundleID: frontmostAppBundleID,
            timestamp: Date()
        )
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func mostRecent() -> Entry? { entries.last }

    func clear() { entries.removeAll() }
}
