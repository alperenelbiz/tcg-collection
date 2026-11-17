#if DEBUG
import Darwin
import Foundation

/// `-catalogReport YES`, the price history part (phase 5A task 7; phase 5B task 3: it measures day files), printed after
/// `SetReport`: the day files on disk in the window (H5, K5), one first pass over them for every game the model's own pass
/// tracked (no history: every day file read, H8; the time per day file is the open and the lookups of that day), each
/// history's size and whether it equals the model's, a one-printing fill (a product new to one history: per day file
/// over the day files on disk, and over 90 days by reading the newest day file under every day name of the window, as
/// the unit test R2 does), the time to make a `PriceChart` from a 90-day series, and the time of one archive decode
/// through the gate when an archive is still on disk. It runs after the model's own pass (`waitForHistory`), on the
/// model's tracked sets (`historyTracked`), so the day files are in the system's file cache by then (warm times). It
/// prints counts of days and files, sizes and times only: no card name, no product id and no count of products (they
/// come from the owner's collection). The peak memory is the process's lifetime `ru_maxrss`; the chart's time is
/// `PriceChart`'s construction, not the view's rendering. It reads no archive itself: the one decode goes through the gate.
@MainActor
enum HistoryReport {
    static func text(model: AppModel) async throws -> String {
        for _ in 0..<600 where !model.library.isLoaded { try await Task.sleep(for: .milliseconds(100)) }
        await model.waitForHistory()
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: model.now()))
        let onDisk = await model.archiveGate.dayFiles()
        let inWindow = onDisk.filter { window.contains($0) }.sorted()
        var lines = ["== Price history (phase 5B): the day files on disk, a first pass, a one-printing fill, the chart, a decode",
                     "window \(window.lowerBound)…\(window.upperBound); day files on disk \(onDisk.count), "
                         + "in the window \(inWindow.count)" + (inWindow.isEmpty ? "" : " (\(inWindow[0])…\(inWindow[inWindow.count - 1]))")]
        let tracked = model.syncedGames.compactMap { game in
            model.historyTracked[game.id].map { (game: game, ids: $0) }
        }
        lines.append("followed games the model's pass tracked: \(tracked.count) of \(model.syncedGames.count)")
        if inWindow.isEmpty || tracked.isEmpty {
            lines.append(inWindow.isEmpty ? "no day file in the window: no pass measured" : "no game was passed: no pass measured")
        } else {
            try await passes(model: model, window: window, days: Set(inWindow), newest: inWindow[inWindow.count - 1],
                             tracked: tracked, into: &lines)
        }

        // The chart: one `PriceChart` of a 90-day series, as the card page makes it on each change of the history.
        let series = series(window: window)
        var made: [Duration] = []
        for _ in 0..<21 {
            let chartStart = ContinuousClock.now
            _ = PriceChart(points: series, window: window)
            made.append(ContinuousClock.now - chartStart)
        }
        lines.append("PriceChart(points:window:) of a 90-day series (made up): "
                     + String(format: "%.3f ms", made.sorted()[made.count / 2] / .milliseconds(1)) + " median of 21")

        // One archive decode through the gate (K3), when an archive of the window is still on disk (the launch's migration
        // decodes every one, so usually none is left; one whose decode failed in this run is not tried again).
        let gate = model.archiveGate
        if let day = await gate.archiveDays(in: window).first {
            let start = ContinuousClock.now
            do {
                let decoded = try await gate.decodeDay(day: day, games: Games.all)
                lines.append("archive decode through the gate (\(day)): " + secondsText(ContinuousClock.now - start)
                             + (decoded.wroteDayFile ? ", day file written" : ", its day file was there already"))
            } catch {
                lines.append("archive decode through the gate (\(day)): failed after \(secondsText(ContinuousClock.now - start))")
            }
        } else {
            lines.append("archive decode: no archive of the window on disk (each became its day file at launch)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The first pass, each history, and the one-printing fills.
    private static func passes(model: AppModel, window: ClosedRange<String>, days: Set<String>, newest: String,
                               tracked: [(game: GameDefinition, ids: Set<Int>)], into lines: inout [String]) async throws {
        let folder = model.paths.priceDays
        // The first pass: every tracked game with no history, so every day file in the window is read once for all games.
        let first = DayClock()
        let games = tracked.map { HistoryPass.Game(id: $0.game.id, categoryID: $0.game.categoryID, history: nil, tracked: $0.ids) }
        let peakBefore = peakResident()
        let start = ContinuousClock.now
        let result = await HistoryPass.run(games: games, days: days, window: window, failedDays: [],
                                           read: first.reader(HistoryPass.dayFileReader(in: folder)))
        let end = ContinuousClock.now
        lines.append("first pass (\(games.count) games, no history): " + dayLine(first.times(end: end), total: end - start)
                     + "; days failed \(result.failedDays.count)")
        lines.append("peak resident size of the process: \(megabytes(peakBefore)) before the pass, "
                     + "\(megabytes(peakResident())) after it (a lifetime peak: it shows the pass only when it rose)")

        for (game, ids) in tracked {
            guard let history = result.histories[game.id] else {
                lines.append("\(game.name): no history after the pass")
                continue
            }
            let data = history.data()
            let same = model.history(game: game.id) == history
            lines.append("\(game.name): \(history.days.count) days, \(kilobytes(data.count)) written; "
                         + "equal to the model's history: \(same)")
            // One product new to the history, read from every day file of the window.
            let catalog = try await CatalogStore(modelContainer: model.reader.modelContainer).productIDs(game: game.id)
            guard let new = newProduct(catalog: catalog, tracked: ids) else {
                lines.append("  one-printing fill: no product of the catalog is untracked")
                continue
            }
            let fillGame = [HistoryPass.Game(id: game.id, categoryID: game.categoryID, history: history, tracked: ids.union([new]))]
            let fill = DayClock()
            let fillStart = ContinuousClock.now
            let filled = await HistoryPass.run(games: fillGame, days: days, window: window, failedDays: [],
                                               read: fill.reader(HistoryPass.dayFileReader(in: folder)))
            let fillEnd = ContinuousClock.now
            lines.append("  one-printing fill: " + dayLine(fill.times(end: fillEnd), total: fillEnd - fillStart)
                         + "; the product read: \(filled.histories[game.id]?.has(productID: new) == true)")
            // 90 days: the newest day file read under every day name of the window (a history without those days, so
            // every one is planned).
            let ninety = DayClock()
            let newestReader = HistoryPass.dayFileReader(in: folder)
            let ninetyGame = [HistoryPass.Game(id: game.id, categoryID: game.categoryID, history: nil, tracked: [new])]
            let ninetyStart = ContinuousClock.now
            _ = await HistoryPass.run(games: ninetyGame, days: Set(PriceDay.days(in: window)), window: window,
                                      failedDays: [], read: ninety.reader { _ in try newestReader(newest) })
            let ninetyEnd = ContinuousClock.now
            lines.append("  one-printing fill over 90 days (the newest day file under each day): "
                         + dayLine(ninety.times(end: ninetyEnd), total: ninetyEnd - ninetyStart))
        }
    }

    // MARK: Pure parts (unit-tested)

    /// `6 day files read, median 1.2 ms, max 1.5 ms per day file, total 7.3 ms`.
    static func dayLine(_ times: [Duration], total: Duration) -> String {
        let sorted = times.sorted()
        guard let slowest = sorted.last else { return "0 day files read, total \(millisecondsText(total))" }
        let median = sorted[sorted.count / 2]
        return "\(sorted.count) \(sorted.count == 1 ? "day file" : "day files") read, median \(millisecondsText(median)), "
            + "max \(millisecondsText(slowest)) per day file, total \(millisecondsText(total))"
    }

    /// The time of each day from the start of each read to the start of the next (the last to `end`): the open and the
    /// lookups of that day.
    nonisolated static func spans(starts: [ContinuousClock.Instant], end: ContinuousClock.Instant) -> [Duration] {
        starts.indices.map { i in (i + 1 < starts.count ? starts[i + 1] : end) - starts[i] }
    }

    /// The smallest product id of the catalog that is not tracked; nil when every one is.
    static func newProduct(catalog: [Int], tracked: Set<Int>) -> Int? {
        catalog.filter { !tracked.contains($0) }.min()
    }

    /// A made-up series with a price on every day of `window`, a low price on every seventh day.
    static func series(window: ClosedRange<String>) -> [HistoryPoint] {
        PriceDay.days(in: window).enumerated().map { index, day in
            HistoryPoint(day: day, amount: 10 + Double(index % 13) / 4, isLow: index % 7 == 6)
        }
    }

    static func secondsText(_ duration: Duration) -> String {
        String(format: "%.2f s", duration / .seconds(1))
    }

    static func millisecondsText(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration / .milliseconds(1))
    }

    // MARK: Times and sizes

    /// The start of each day file's read, through the pass's injected reader (the pass reads one day at a time).
    private nonisolated final class DayClock: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [ContinuousClock.Instant] = []

        func times(end: ContinuousClock.Instant) -> [Duration] { HistoryReport.spans(starts: lock.withLock { starts }, end: end) }

        func reader(_ open: @escaping HistoryPass.Reader) -> HistoryPass.Reader {
            { [self] day in
                lock.withLock { starts.append(ContinuousClock.now) }
                return try open(day)
            }
        }
    }

    /// The process's peak resident size so far (`getrusage`: bytes on macOS).
    private static func peakResident() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return usage.ru_maxrss
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    private static func kilobytes(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1_000)
    }
}
#endif
