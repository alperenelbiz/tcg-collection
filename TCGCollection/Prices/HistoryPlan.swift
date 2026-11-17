import Foundation

/// What one history pass reads (H8), pure: per day, per game, the product ids to look up in that day's file. A day is
/// planned only when it is in the window, has a day file on disk (phase 5B, K5: `days`) and did not fail in this run. On
/// such a day a tracked product the game's history does not have is read; one it has is read only when the day is not in
/// its `days`. A day with nothing to read for any game is not planned, so one day file is opened once for all games.
nonisolated struct HistoryPlan: Sendable, Equatable {
    /// Day → game → product ids. Every day and every game listed has at least one product.
    let reads: [String: [String: Set<Int>]]

    /// The planned days, ascending.
    var days: [String] { reads.keys.sorted() }

    static func make(window: ClosedRange<String>, days: Set<String>, failedDays: Set<String>,
                     games: [String: (history: PriceHistory?, tracked: Set<Int>)]) -> HistoryPlan {
        var reads: [String: [String: Set<Int>]] = [:]
        for day in days where window.contains(day) && !failedDays.contains(day) {
            var dayReads: [String: Set<Int>] = [:]
            for (game, entry) in games {
                let known = entry.history?.days.contains(day) ?? false
                let ids = entry.tracked.filter { productID in
                    guard let history = entry.history, history.has(productID: productID) else { return true }
                    return !known
                }
                if !ids.isEmpty { dayReads[game] = ids }
            }
            if !dayReads.isEmpty { reads[day] = dayReads }
        }
        return HistoryPlan(reads: reads)
    }

    /// Whether a pass writes the game's file (H9, A42): only when `new` has a day or a product that `old` lacks (no file
    /// counts as empty). A removal alone never writes.
    static func writes(old: PriceHistory?, new: PriceHistory) -> Bool {
        let oldDays = Set(old?.days ?? [])
        if new.days.contains(where: { !oldDays.contains($0) }) { return true }
        return new.products.keys.contains { old?.has(productID: $0) != true }
    }
}
