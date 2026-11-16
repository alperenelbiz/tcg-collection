#if DEBUG
import Foundation
import SwiftData

/// `-catalogReport YES`, the sets part (phase 4A task 5), printed after `DeckReport`: per game the set index (sets,
/// products, the scan's time, the file's size and read), the shape of its sets, the time of the Sets list's rows
/// (`SetMaths.rows` through `SetsScreenState.rows`, "All sets" and "My sets") with the store's prices and with a synthetic
/// price table, and the largest set's page read. It prints counts, times and sizes only: no set or card name, and of the owner's collection
/// only its row count and how many sets it touches.
@MainActor
enum SetReport {
    static func text(model: AppModel) async throws -> String {
        // The launch's scans (a game with products and no file) end first, so the files read below are the model's own.
        await model.waitForSetIndexes()
        for _ in 0..<600 where !model.library.isLoaded { try await Task.sleep(for: .milliseconds(100)) }
        var lines = ["== Sets (phase 4A): the set index, the Sets list's rows, a set's page "
                     + "(scan: a fresh store each run, 3 runs; other times: median of 3 unless said)",
                     "user folder read: \(model.library.isLoaded)"]
        for game in Games.all {
            lines += try await gameLines(game, model: model)
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func gameLines(_ game: GameDefinition, model: AppModel) async throws -> [String] {
        let container = model.reader.modelContainer
        var lines = ["\(game.name):"]
        // The scan, as the model's queue runs it: throwaway stores on the container, never `reader`.
        var index = SetIndex(sets: [:])
        var scans: [Duration] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            index = try await CatalogStore.setIndex(game: game.id, container: container)
            scans.append(ContinuousClock.now - start)
        }
        // The scan's two halves alone: the key ranges read (the same fetches, one after another) and the sort of every set
        // (`SetOrder.sorted`).
        var entries: [Int: [(number: String, name: String, id: Int)]] = [:]
        let fetch = try await durations(1) {
            entries = [:]
            let ends = CatalogStore.nameRangeEnds.map { Optional($0) }
            for (low, high) in zip([nil] + ends, ends + [nil]) {
                for row in try await CatalogStore(modelContainer: container).setIndexRows(game: game.id, after: low, through: high) {
                    entries[row.groupID, default: []].append((row.number, row.name, row.productID))
                }
            }
        }
        let sort = await durations(1) { _ = entries.mapValues(SetOrder.sorted) }
        // Before final fix A2: the paged scan by product id, once (its index must equal the new one).
        var old = SetIndex(sets: [:])
        let before = try await durations(1) { old = try await CatalogStore(modelContainer: container).setIndexByProductID(game: game.id) }
        let storeProducts = try await CatalogStore(modelContainer: container).productIDs(game: game.id).count
        let sizes = index.sets.values.map(\.count).sorted()
        let indexed = sizes.reduce(0, +)
        let storeSets = try await model.reader.sets(game: game.id)
        let listed = storeSets.filter { !(index.sets[$0.groupID] ?? []).isEmpty }.count
        lines.append("  index: \(index.sets.count) sets, \(indexed) products (store: \(storeProducts) products, "
                     + "\(storeSets.count) set rows, \(listed) of them listed)")
        lines.append("  setIndex(game:container:) scan: \(ms(scans[0])) first, \(ms(scans.sorted()[1])) median of 3"
                     + (scans.contains { $0 > .seconds(3) } ? "  ** over 3 s **" : "")
                     + "; alone: key ranges read one after another \(ms(fetch)), sort \(ms(sort))")
        lines.append("  before final fix A2, the paged scan by product id: \(ms(before)); its index equal to this scan's: \(old == index)")
        let file = model.paths.sets(game.id)
        if FileManager.default.fileExists(atPath: file.path) {
            let read = await durations(3) { _ = SetIndex.read(file) }
            let same = SetIndex.read(file) == index
            lines.append("  sets-\(game.id).json: \(kilobytes(size(file))), read and decode \(preciseMs(read)); "
                         + "equal to this scan: \(same)")
        } else {
            lines.append("  sets-\(game.id).json: no file")
        }
        if !sizes.isEmpty {
            let unnumbered = try await withoutNumber(index, game: game.id, container: container)
            lines.append("  products per set: largest \(sizes.last!), median \(sizes[sizes.count / 2]), smallest \(sizes.first!); "
                         + "sets of 1 product \(sizes.count { $0 == 1 }), of 300 or more \(sizes.count { $0 >= 300 }); "
                         + "products without a number \(unnumbered)")
        }

        // The Sets list's rows (F7): the work of `SetsScreenState.makeRows` after its values are taken.
        let rows = model.library.rows(game: game.id)
        let prices = model.prices.table(game: game.id)
        var made: [SetRow] = []
        let readSets = try await durations(3) { _ = try await model.reader.sets(game: game.id) }
        let real = await durations(3) { made = SetsScreenState.rows(sets: storeSets, index: index, rows: rows, prices: prices) }
        let mine = made.count { $0.numbers.owned > 0 }
        let targets = made.reduce(0) { $0 + $1.numbers.total }
        let unpriced = made.reduce(0) { $0 + $1.numbers.missingUnpriced }
        lines.append("  collection rows \(rows.count); price table: \(prices.map { "day \($0.day)" } ?? "none")")
        lines.append("  rows (All sets, \(made.count) rows, \(targets) targets, \(unpriced) missing without a price): "
                     + "\(preciseMs(real))\(real.median > .milliseconds(300) ? "  ** over 300 ms **" : ""); "
                     + "reader.sets \(preciseMs(readSets))")
        let shownAll = await durations(3) { _ = SetMaths.shown(made, scope: .all, text: "", sort: .newest) }
        let shownMine = await durations(3) { _ = SetMaths.shown(made, scope: .mine, text: "", sort: .newest) }
        lines.append("  shown, Newest: All sets \(preciseMs(shownAll)); My sets (\(mine) sets with an owned target) "
                     + "\(preciseMs(shownMine))")
        let synthetic = syntheticPrices(game: game, index: index)
        var priced: [SetRow] = []
        let withPrices = await durations(3) {
            priced = SetsScreenState.rows(sets: storeSets, index: index, rows: rows, prices: synthetic)
        }
        let syntheticTargets = priced.reduce(0) { $0 + $1.numbers.total }
        lines.append("  rows with a SYNTHETIC price table (every product priced in \(synthetic.finishes.joined(separator: " and ")); "
                     + "\(syntheticTargets) targets): \(preciseMs(withPrices))"
                     + (withPrices.median > .milliseconds(300) ? "  ** over 300 ms **" : ""))

        // The largest set's page: one batched products read (`SetPageState.read`), then one render's work.
        if let largest = index.sets.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) {
            var read: [Int: ProductRecord] = [:]
            let fresh = CatalogStore(modelContainer: container)
            let first = try await durations(1) { read = try await fresh.products(ids: largest.value, game: game.id) }
            let again = try await durations(3) { read = try await model.reader.products(ids: largest.value, game: game.id) }
            let owned = SetOwned(rows: rows)
            var cells = 0
            let render = await durations(3) {
                let made = SetPage.cells(products: largest.value, read: read, owned: owned,
                                         priced: { synthetic.prices(productID: $0).map(\.finish) })
                _ = SetPage.numbers(products: largest.value, read: read, owned: owned,
                                    priced: { synthetic.prices(productID: $0).map(\.finish) },
                                    price: { synthetic.shown(key: $0) })
                cells = SetPage.shown(made, filter: .all, text: "", owned: owned).count
            }
            lines.append("  largest set's page (\(largest.value.count) products, \(read.count) read): read \(ms(first)) first, "
                         + "\(ms(again)) again on reader" + (first.median > .milliseconds(500) ? "  ** over 500 ms **" : "")
                         + "; one render's cells, numbers and filter with the synthetic prices \(preciseMs(render)), \(cells) cells")
        }
        return lines
    }

    /// The products of the game with an empty number (they sort after the numbered ones, F4).
    private static func withoutNumber(_ index: SetIndex, game: String, container: ModelContainer) async throws -> Int {
        let ids = Array(index.sets.values.joined())
        let products = try await CatalogStore(modelContainer: container).products(ids: ids, game: game)
        return products.values.count { $0.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A price table that prices every indexed product in two finishes (Magic, Riftbound, Cyberpunk: Normal $1.00 and Foil
    /// $2.00; Yu-Gi-Oh!: 1st Edition and Unlimited), so the rows' cost path runs with prices. Made up: only for the times.
    private static func syntheticPrices(game: GameDefinition, index: SetIndex) -> GamePrices {
        let finishes = game.id == "yu-gi-oh" ? ["1st Edition", "Unlimited"] : ["Normal", "Foil"]
        var rows: [Int: [Int: Price]] = [:]
        for product in index.sets.values.joined() {
            rows[product] = [0: Price(market: 1, low: nil, mid: nil, high: nil), 1: Price(market: 2, low: nil, mid: nil, high: nil)]
        }
        return GamePrices(day: "synthetic", finishes: finishes, rows: rows)
    }

    // MARK: Times and sizes

    private struct Durations {
        let sorted: [Duration]
        var median: Duration { sorted[sorted.count / 2] }
    }

    private static func durations(_ runs: Int, _ work: () async throws -> Void) async rethrows -> Durations {
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await work()
            times.append(ContinuousClock.now - start)
        }
        return Durations(sorted: times.sorted())
    }

    private static func ms(_ times: Durations) -> String { ms(times.median) }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    private static func preciseMs(_ times: Durations) -> String {
        String(format: "%.2f ms", times.median / .milliseconds(1))
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func kilobytes(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1_000)
    }
}

extension CatalogStore {
    /// The set index's scan of phase 4A before its final fix A2: the game's products in pages of `pageSize` rows by
    /// product id (`gameID == ? AND productID > ? ORDER BY productID LIMIT n`), each page sorted by SQLite in a temporary
    /// B-tree. Kept only to compare its index with `setIndex(game:container:)` (a unit test, and the report's "before").
    func setIndexByProductID(game: String, pageSize: Int = 2_000) throws -> SetIndex {
        var bySet: [Int: [(number: String, name: String, id: Int)]] = [:]
        var last = Int.min
        while true {
            let after = last
            var descriptor = FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.gameID == game && $0.productID > after },
                                                             sortBy: [SortDescriptor(\.productID)])
            descriptor.fetchLimit = max(pageSize, 1)
            descriptor.propertiesToFetch = [\.productID, \.groupID, \.number, \.name]
            let page = try modelContext.fetch(descriptor)
            for row in page { bySet[row.groupID, default: []].append((row.number, row.name, row.productID)) }
            guard page.count == descriptor.fetchLimit, let end = page.last else { break }
            last = end.productID
        }
        return SetIndex(sets: bySet.mapValues(SetOrder.sorted))
    }
}
#endif
