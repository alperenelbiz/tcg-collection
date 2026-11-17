import Foundation

/// One history pass (A37, H5, H8): reads the daily price archives on disk that `HistoryPlan` names into each game's
/// history, off the main actor, one archive at a time (an archive read holds about 117 MB). It reads `archives` and
/// nothing else, and writes nothing: the caller decides what to write (H9).
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
        /// The days whose archive could not be read, in this pass or before it in this run (the `failedDays` passed in):
        /// they are not tried again in this run (H8). A day a cancelled pass did not read is not one.
        var failedDays: Set<String>
    }

    /// Reads one archive: calls the closure for each `(category, group, rows)` of the asked categories.
    typealias Reader = @Sendable (URL, Set<Int>, (Int, Int, [PriceRow]) -> Void) throws -> Void

    /// Reads one day for a pass: a day file (`.prices`, phase 5B) through `PriceDayReader`, its rows as `PriceRow`s whose
    /// `Price.shown` is the stored price (group 0); any other file as an archive (`PriceArchive.read`).
    static func readDay(_ url: URL, _ categories: Set<Int>, _ each: (Int, Int, [PriceRow]) -> Void) throws {
        guard url.pathExtension == "prices" else {
            try PriceArchive.read(url, categories: categories, each: each)
            return
        }
        let reader = try PriceDayReader(url: url)
        for category in reader.categories where categories.contains(category) {
            let rows = reader.rows(category: category).map {
                PriceRow(productID: $0.productID, finish: $0.finish, price: PriceDayFile.price($0.price))
            }
            each(category, 0, rows)
        }
    }

    /// The file of one archive day: `prices-YYYY-MM-DD.ppmd.7z`, the name `PriceSync` downloads to.
    static func archiveName(day: String) -> String { "prices-\(day).ppmd.7z" }

    /// The days of the archives in the folder: every regular file named `prices-YYYY-MM-DD.ppmd.7z` of a real calendar
    /// day. Any other name, a hidden file or a folder is ignored; a folder that is not there has none.
    static func archiveDays(in archives: URL) -> Set<String> {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: archives, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var days = Set<String>()
        for url in urls {
            guard let match = url.lastPathComponent.wholeMatch(of: /prices-(\d{4}-\d{2}-\d{2})\.ppmd\.7z/),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let day = String(match.1)
            // A day the calendar does not have (2026-02-30) moves when it is read as a date: it is not an archive day.
            guard PriceDay.after(PriceDay.before(day)) == day, PriceDay.before(day) != day else { continue }
            days.insert(day)
        }
        return days
    }

    /// Reads the planned archives (`HistoryPlan.make`) one after another, ascending; checks for cancellation between
    /// archives (a cancelled pass returns what it has read, without a product new to the history whose planned days were not
    /// all attempted). Per planned day each game takes its planned products from
    /// that day's rows (`Price.shown`: market, else low marked; 0 is no price); a planned product with no row still counts
    /// as read. An archive that cannot be read adds its day to `failedDays` and nothing else. The day is the file name's.
    ///
    /// Phase 5B task 2 (until task 3 switches the pass to day files): with `dayFiles` (the `price-days` folder), a day
    /// with a day file counts as an archive day too, and its day file is read in place of its archive (the gate deletes
    /// an archive once its day file is written). `read` is then called with the day file's URL: `readDay` reads either.
    @concurrent
    static func run(games: [Game], archives: URL, dayFiles: URL? = nil, window: ClosedRange<String>,
                    failedDays: Set<String>, read: Reader = readDay) async -> Result {
        var entries: [String: (history: PriceHistory?, tracked: Set<Int>)] = [:]
        for game in games { entries[game.id] = (game.history, game.tracked) }
        let days = archiveDays(in: archives).union(dayFiles.map { PriceDayFile.days(in: $0) } ?? [])
        let plan = HistoryPlan.make(window: window, archiveDays: days, failedDays: failedDays, games: entries)
        let categories = Dictionary(games.map { ($0.categoryID, $0.id) }, uniquingKeysWith: { first, _ in first })
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
            var rows: [String: [Int: [String: ShownPrice]]] = [:]
            let wanted = Set(reads.keys.compactMap { categoryOf[$0] })
            func readFile(_ url: URL) throws {
                try read(url, wanted) { category, _, categoryRows in
                    guard let game = categories[category], let ids = reads[game] else { return }
                    for row in categoryRows where ids.contains(row.productID) {
                        guard let shown = row.price.shown else { continue }
                        rows[game, default: [:]][row.productID, default: [:]][row.finish] = shown
                    }
                }
            }
            let dayFile = dayFiles?.appending(path: PriceDayFile.fileName(day: day))
            let hasDayFile = { dayFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
            do {
                if hasDayFile(), let dayFile {
                    try readFile(dayFile)
                } else {
                    do {
                        try readFile(archives.appending(path: archiveName(day: day)))
                    } catch {
                        // The gate may have written the day file and deleted the archive since the plan was made.
                        guard hasDayFile(), let dayFile else { throw error }
                        rows = [:]
                        try readFile(dayFile)
                    }
                }
            } catch {
                failed.insert(day)
                continue
            }
            for (game, ids) in reads {
                var history = histories[game] ?? PriceHistory()
                history.setDay(day, rows: rows[game] ?? [:], for: ids)
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
