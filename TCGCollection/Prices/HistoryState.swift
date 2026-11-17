import Foundation

/// What the model can say about one printing's price history (A45, K6, H3), for the card page's block
/// (`AppModel.historyState(game:productID:)`). Every printing has its block (phase 5B task 4: 5A's `notTracked` is gone).
nonisolated enum HistoryState: Equatable, Sendable {
    /// Nothing to say yet: before the folder is read, with no or a missing folder, while the first-run question is due,
    /// for a game that is not followed or whose game file is refused.
    case unknown
    /// The printing's day-file prices are being read (off the main actor), or the day files give it no price and the
    /// game's history file is not read yet.
    case reading
    /// The points are there (`AppModel.dayPoints`): none, one day or more (5A's sentences, `PriceChart.note`).
    case ready
    /// The game's history file was written by a newer version of the app (H3), and the day files give no price.
    case newerVersion
    /// The game's history file is in iCloud and not downloaded yet (H3), and the day files give no price.
    case notDownloaded
}
