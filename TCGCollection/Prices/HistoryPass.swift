import Foundation

/// One history pass (A37, H5, H8; phase 5B task 3, K5): reads the price day files (`PriceDayFile`) that `HistoryPlan`
/// names into each game's history, off the main actor, one day file at a time: one binary-search lookup per planned
/// product (`PriceDayReader.prices(category:productID:)`), never a scan of a category. It reads no archive (archives are
/// the gate's alone: `ArchiveGate` turns each into its day file before any pass) and writes nothing: the caller decides
/// what to write (H9).
nonisolated enum HistoryPass {
    struct Game: Sendable {
        let id: String
        let categoryID: Int
        /// The history read from the game's file; nil when there is none.
        let history: PriceHistory?
        let tracked: Set<Int>
    }

    struct Result: Sendable {
        /// Each game's history after the pass: with the new days and products, then trimmed to the window, and to its
        /// tracked printings only when the pass added a day to it. A game whose plan was empty is as it went in (no entry
        /// when it went in with none).
        var histories: [String: PriceHistory]
        /// The days whose day file could not be read, in this pass or before it in this run (the `failedDays` passed
        /// in): they are not tried again in this run (H8). A day a cancelled pass did not read is not one.
        var failedDays: Set<String>
    }

    /// Opens the day file of one day for lookups. Throws when it does not read (`PriceDayFileError`, an IO error).
    typealias Reader = @Sendable (_ day: String) throws -> PriceDayReader

    /// The app's reader: `<folder>/<day>.prices`. A file whose header names another day than its name does not read
    /// (`PriceDayFileError.notADayFile`, the gate's rule for a day file).
    static func dayFileReader(in folder: URL) -> Reader {
        { day in
            let reader = try PriceDayReader(url: folder.appending(path: PriceDayFile.fileName(day: day)))
            guard reader.day == day else { throw PriceDayFileError.notADayFile }
            return reader
        }
    }

    /// Reads the planned days (`HistoryPlan.make` over `days`, the day files on disk: `ArchiveGate.dayFiles()`) one after
    /// another, ascending; checks for cancellation between day files (a cancelled pass returns what it has read, without a
    /// product new to the history whose planned days were not all attempted). Per planned day each game looks up its
    /// planned products in that day's file, in its category (a stored price is a shown price: market, else low marked;
    /// 0 is never stored); a planned product with no row still counts as read. A day file that does not read adds its day
    /// to `failedDays` and nothing else.
    @concurrent
    static func run(games: [Game], days: Set<String>, window: ClosedRange<String>, failedDays: Set<String>,
                    read: Reader) async -> Result {
        var entries: [String: (history: PriceHistory?, tracked: Set<Int>)] = [:]
        for game in games { entries[game.id] = (game.history, game.tracked) }
        let plan = HistoryPlan.make(window: window, days: days, failedDays: failedDays, games: entries)
        let categoryOf = Dictionary(games.map { ($0.id, $0.categoryID) }, uniquingKeysWith: { first, _ in first })

        var histories: [String: PriceHistory] = [:]
        for game in games { if let history = game.history { histories[game.id] = history } }
        var failed = failedDays
        let planned = Set(plan.reads.values.flatMap(\.keys))

        var attempted = Set<String>()
        for day in plan.days {
            if Task.isCancelled { break }
            attempted.insert(day)
            let reads = plan.reads[day]!
            let file: PriceDayReader
            do {
                file = try read(day)
            } catch {
                failed.insert(day)
                continue
            }
            for (game, ids) in reads {
                guard let category = categoryOf[game] else { continue }
                var rows: [Int: [String: ShownPrice]] = [:]
                for productID in ids {
                    let prices = file.prices(category: category, productID: productID)
                    if !prices.isEmpty { rows[productID] = prices }
                }
                var history = histories[game] ?? PriceHistory()
                history.setDay(day, rows: rows, for: ids)
                histories[game] = history
            }
        }

        // A product the input history lacked stays only when every day planned for it was attempted (read or failed):
        // else (a cancelled pass) every later pass would see it as known and never read the days it missed.
        for game in games where planned.contains(game.id) {
            var unfinished = Set<Int>()
            for (day, reads) in plan.reads where !attempted.contains(day) {
                for productID in reads[game.id] ?? [] where game.history?.has(productID: productID) != true {
                    unfinished.insert(productID)
                }
            }
            for productID in unfinished { histories[game.id]?.products[productID] = nil }
            // Products not tracked leave only when the pass added a day to the game (A42): a pass that only added products
            // keeps every product the history had. Days out of the window always go.
            guard let history = histories[game.id] else { continue }
            let oldDays = Set(game.history?.days ?? [])
            let addedDay = history.days.contains { !oldDays.contains($0) }
            histories[game.id] = history.trimmed(window: window,
                                                 keeping: addedDay ? game.tracked : Set(history.products.keys))
        }
        return Result(histories: histories, failedDays: failed)
    }
}
