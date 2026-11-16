import Foundation

/// What the model can say about one printing's price history (A41, H3), for the card page's block
/// (`AppModel.historyState(game:productID:)`).
nonisolated enum HistoryState: Equatable, Sendable {
    /// Nothing to say yet: before the folder is read, with no or a missing folder, while the first-run question is due,
    /// for a game that is not followed or whose game file is refused.
    case unknown
    /// The printing is not tracked (A41): no collection row, for-sale entry, Wanted card or deck card holds it.
    case notTracked
    /// Tracked now, and not in the history in memory yet: a pass will read it from the archives on disk.
    case reading
    /// The history in memory has the printing (also with no price: it was read).
    case ready
    /// The game's history file was written by a newer version of the app: never rewritten, no history this run (H3).
    case newerVersion
    /// The game's history file is in iCloud and not downloaded yet: never rewritten (H3).
    case notDownloaded
}
