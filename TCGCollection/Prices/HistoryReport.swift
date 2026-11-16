#if DEBUG
import Darwin
import Foundation

/// `-catalogReport YES`, the price history part (phase 5A task 7), printed after `SetReport`: the archives on disk in the
/// window (H5), one first pass over them for every game the model's own pass tracked (no history: every archive read, H8),
/// each history's size, a one-printing fill (a product new to one history, read from every archive: H12's measure, whose
/// threshold is 3 s per archive), and the time to make a `PriceChart` from a 90-day series. It runs after the model's own
/// pass (`waitForHistory`), on the model's tracked sets (`historyTracked`), so the archives are in the system's file cache
/// by then. The written numbers are in `docs/reports/2026-11-catalog-report.md`, "Price history, phase 5A check". It
/// prints counts of days, archives and products, sizes and times only: no card name and no product id.
@MainActor
enum HistoryReport {
    /// H12: a one-printing fill over this per archive asks for a group filter of the archive reader.
    static let fillLimit: Duration = .seconds(3)

    static func text(model: AppModel) async throws -> String {
        for _ in 0..<600 where !model.library.isLoaded { try await Task.sleep(for: .milliseconds(100)) }
        await model.waitForHistory()
        let window = PriceDay.window(endingOn: PriceDay.wanted(now: model.now()))
        let onDisk = HistoryPass.archiveDays(in: model.paths.archives)
        let inWindow = onDisk.filter { window.contains($0) }.sorted()
        var lines = ["== Price history (phase 5A): the archives on disk, a first pass, a one-printing fill (H12), the chart",
                     "window \(window.lowerBound)…\(window.upperBound); archives on disk \(onDisk.count), "
                         + "in the window \(inWindow.count)" + (inWindow.isEmpty ? "" : " (\(inWindow[0])…\(inWindow[inWindow.count - 1]))")]
        let tracked = model.syncedGames.compactMap { game in
            model.historyTracked[game.id].map { (game: game, ids: $0) }
        }
        lines.append("followed games the model's pass tracked: \(tracked.count) of \(model.syncedGames.count); "
                     + "tracked products in all: \(tracked.reduce(0) { $0 + $1.ids.count })")
        guard !inWindow.isEmpty, !tracked.isEmpty else {
            lines.append(inWindow.isEmpty ? "no archive in the window: nothing measured" : "no game was passed: nothing measured")
            return lines.joined(separator: "\n") + "\n"
        }

        // The first pass: every tracked game with no history, so every archive in the window is read once for all games.
        let first = ArchiveClock()
        let games = tracked.map { HistoryPass.Game(id: $0.game.id, categoryID: $0.game.categoryID, history: nil, tracked: $0.ids) }
        let peakBefore = peakResident()
        let start = ContinuousClock.now
        let result = await HistoryPass.run(games: games, archives: model.paths.archives, window: window, failedDays: [],
                                           read: first.reader)
        let total = ContinuousClock.now - start
        lines.append("first pass (\(games.count) games, no history): " + archiveLine(first.times, total: total)
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
            lines.append("\(game.name): \(history.products.count) products, \(history.days.count) days, "
                         + "\(kilobytes(data.count)) written; equal to the model's history: \(same)")
            // H12: one product new to the history, read from every archive of the window.
            let catalog = try await CatalogStore(modelContainer: model.reader.modelContainer).productIDs(game: game.id)
            guard let new = newProduct(catalog: catalog, tracked: ids) else {
                lines.append("  one-printing fill: no product of the catalog is untracked")
                continue
            }
            let fill = ArchiveClock()
            let fillStart = ContinuousClock.now
            let filled = await HistoryPass.run(
                games: [HistoryPass.Game(id: game.id, categoryID: game.categoryID, history: history, tracked: ids.union([new]))],
                archives: model.paths.archives, window: window, failedDays: [], read: fill.reader)
            let fillTotal = ContinuousClock.now - fillStart
            lines.append("  one-printing fill: " + archiveLine(fill.times, total: fillTotal, limit: fillLimit)
                         + "; the product read: \(filled.histories[game.id]?.has(productID: new) == true)")
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
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pure parts (unit-tested)

    /// `6 archives read, median 1.20 s, max 1.50 s per archive, total 7.30 s`, and ` ** over 3 s per archive **` when
    /// `limit` is given and the slowest archive took longer.
    static func archiveLine(_ times: [Duration], total: Duration, limit: Duration? = nil) -> String {
        let sorted = times.sorted()
        guard let slowest = sorted.last else { return "0 archives read, total \(secondsText(total))" }
        let median = sorted[sorted.count / 2]
        var line = "\(sorted.count) \(sorted.count == 1 ? "archive" : "archives") read, median \(secondsText(median)), "
            + "max \(secondsText(slowest)) per archive, total \(secondsText(total))"
        if let limit, slowest > limit { line += "  ** over \(secondsText(limit)) per archive **" }
        return line
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

    // MARK: Times and sizes

    /// The time of each archive read, through the pass's injected reader.
    private nonisolated final class ArchiveClock: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [Duration] = []

        var times: [Duration] { lock.withLock { durations } }

        var reader: HistoryPass.Reader {
            { [self] url, categories, each in
                let start = ContinuousClock.now
                defer {
                    let took = ContinuousClock.now - start
                    lock.withLock { durations.append(took) }
                }
                try PriceArchive.read(url, categories: categories, each: each)
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
