#if DEBUG
import Foundation
import SwiftData

/// `-catalogReport YES`: checks of the full catalog against the rules of spec 4.1, 4.2 and 5.1, printed
/// as text.
nonisolated enum CatalogReport {
    /// A card key whose printings have more than one card type (spec 5.1: the builder reports collisions).
    struct Collision: Equatable, Sendable {
        let cardKey: String
        let names: [String]
        let cardTypes: [String]
    }

    /// The card keys whose printings have more than one distinct card type, per game; sorted by game id, then key.
    static func collisions(_ products: [ProductRecord]) -> [Collision] {
        var names: [String: [String: Set<String>]] = [:]
        var types: [String: [String: Set<String>]] = [:]
        for product in products {
            let key = CardName.searchKey(product.cardName)
            names[product.gameID, default: [:]][key, default: []].insert(product.name)
            types[product.gameID, default: [:]][key, default: []].insert(product.cardType)
        }
        return types.keys.sorted().flatMap { game in
            let keys = types[game]!.filter { $0.value.count > 1 }.keys.sorted()
            return keys.map { Collision(cardKey: $0, names: names[game]![$0]!.sorted(), cardTypes: types[game]![$0]!.sorted()) }
        }
    }

    /// The whole report. Timings come first, before any step reads a whole game. They use a store of their
    /// own on the same container: the open window reads through `store` at the same time, and a serial
    /// store would put those reads in front of a timed call.
    static func text(store: CatalogStore, prices: [String: GamePrices], ygo: YGOPictureIndex?) async throws -> String {
        let timings = try await timings(store: CatalogStore(modelContainer: store.modelContainer))
        var lines: [String] = []
        for game in Games.all {
            // A store of its own per game, so the rows of one game leave memory after its section.
            let scan = CatalogStore(modelContainer: store.modelContainer)
            lines += try await section(game, store: scan, prices: prices[game.id], ygo: ygo)
            lines.append("")
        }
        lines += files(store: store)
        lines.append("")
        lines += timings
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: One game

    private static func section(_ game: GameDefinition, store: CatalogStore, prices: GamePrices?,
                                ygo: YGOPictureIndex?) async throws -> [String] {
        let progress = try await store.progress(game: game.id)
        let sets = try await store.sets(game: game.id)
        let fetched = try await store.fetchDates(game: game.id)
        let products = try await store.allProducts(game: game.id)
        var lines = ["== \(game.name) (\(game.id))"]

        lines.append("sets: \(progress.total) total, \(progress.fetched) fetched, \(progress.failed) failed")
        let perSet = Dictionary(grouping: products, by: \.groupID).mapValues(\.count)
        let emptySets = sets.filter { fetched[$0.groupID] != nil && perSet[$0.groupID] == nil }
        lines.append("fetched sets with no kept product: \(emptySets.count)")
        lines += emptySets.prefix(40).map { "  \($0.groupID) \($0.name)" }

        lines.append("products kept: \(products.count)")
        lines.append("cards (distinct card key): \(Set(products.map { CardName.searchKey($0.cardName) }).count)")
        lines.append("empty number: \(products.count { $0.number.isEmpty }), empty rarity: \(products.count { $0.rarity.isEmpty }), "
                     + "empty rules text: \(products.count { $0.rulesText.isEmpty })")

        let noFacet = Set(products.filter { game.typeFacets($0.cardType).isEmpty }.map(\.cardType)).sorted()
        lines.append("card types with no type facet: \(noFacet.count)")
        lines += noFacet.prefix(40).map { "  \($0)" }
        var facets: [String: Int] = [:]
        for product in products { for facet in product.typeFacets { facets[facet, default: 0] += 1 } }
        let odd = facets.keys.filter { !$0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } }.sorted()
        lines.append("type facets: \(facets.count); with a character that is not a letter: \(odd.count) \(odd)")
        lines += facets.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "  \($0.key): \($0.value)" }

        let found = collisions(products)
        lines.append("collisions: \(found.count)")
        lines += found.prefix(40).map { "  \($0.cardKey): \($0.cardTypes.joined(separator: " | ")) — \(shortList($0.names))" }

        if let prices {
            let ids = Set(products.map(\.productID))
            let noRow = products.count { prices.rows[$0.productID] == nil }
            let lowOnly = products.count { product in
                let shown = (prices.rows[product.productID] ?? [:]).values.compactMap(\.shown)
                return !shown.isEmpty && shown.allSatisfy(\.isLow)
            }
            let notKept = prices.rows.keys.count { !ids.contains($0) }
            lines.append("prices of \(prices.day): \(noRow) printings with no price row, \(lowOnly) with a low price only, "
                         + "\(notKept) priced product\(notKept == 1 ? "" : "s") not in the catalog")
        } else {
            lines.append("prices: no file")
        }

        if game.pictures == .ygoprodeck {
            lines += pictureLines(products, ygo: ygo)
        }

        // Spec 4.1 keeps a product when it has a card type. These samples show what that lets through.
        let fewest = products.sorted { ($0.fields.count, $0.productID) < ($1.fields.count, $1.productID) }
        lines.append("kept products with the shortest field lists (15):")
        lines += fewest.prefix(15).map { "  \($0.name) — \($0.cardType) — [\($0.fields.keys.sorted().joined(separator: ", "))]" }
        let bare = fewest.filter { $0.number.isEmpty && $0.rarity.isEmpty }
        lines.append("kept products with no number and no rarity: \(bare.count)")
        lines += bare.prefix(15).map { "  \($0.name) — \($0.cardType)" }
        let sealed = fewest.filter(looksSealed)
        lines.append("kept products with a sealed-product word in the name: \(sealed.count)")
        lines += sealed.prefix(40).map { "  \($0.name) — \($0.cardType) — \($0.number.isEmpty ? "no number" : $0.number)" }
        return lines
    }

    private static func pictureLines(_ products: [ProductRecord], ygo: YGOPictureIndex?) -> [String] {
        guard let ygo else { return ["pictures: no Yu-Gi-Oh! index"] }
        var byCode = 0, byName = 0
        var missing: [ProductRecord] = []
        for product in products {
            // The order of `YGOPictureIndex.pictureID`: the set code first, then the card name.
            if ygo.codes[product.number] != nil {
                byCode += 1
            } else if ygo.names[CardName.searchKey(product.cardName)] != nil {
                byName += 1
            } else {
                missing.append(product)
            }
        }
        return ["pictures: \(byCode) by set code, \(byName) by name, \(missing.count) not matched"]
            + missing.prefix(40).map { "  \($0.name) (\($0.number)) — \($0.cardType)" }
    }

    private static let sealedWords: Set<String> = ["booster", "box", "pack", "bundle", "display", "case", "tin", "kit",
                                                   "sleeves", "playmat", "binder", "starter", "collection", "lot", "deck"]

    private static func looksSealed(_ product: ProductRecord) -> Bool {
        CardName.searchKey(product.name).split(separator: " ").contains { sealedWords.contains(String($0)) }
    }

    private static func shortList(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: "; ") : names.prefix(4).joined(separator: "; ") + "; +\(names.count - 4) more"
    }

    // MARK: Files and timings

    private static func files(store: CatalogStore) -> [String] {
        guard let url = store.modelContainer.configurations.first?.url else { return ["== Files: no store file"] }
        let support = url.deletingLastPathComponent()
        let storeSizes = ["", "-wal", "-shm"].map { size(URL(fileURLWithPath: url.path + $0)) }
        var lines = ["== Files (MB = 1,000,000 bytes)",
                     "catalog.store: \(megabytes(storeSizes[0])) (+ -wal \(megabytes(storeSizes[1])), -shm \(megabytes(storeSizes[2])))"]
        for game in Games.all {
            // The file name of `AppPaths.prices`. The decode is the work `PriceTable.load` does on the main actor.
            let file = support.appending(path: "prices-\(game.id).json")
            let decode = median(3) { _ = try? JSONDecoder().decode(GamePrices.self, from: Data(contentsOf: file)) }
            lines.append("prices-\(game.id).json: \(megabytes(size(file))), read and decode \(milliseconds(decode)) (median of 3)")
        }
        lines.append("ygo-index.json: \(megabytes(size(support.appending(path: "ygo-index.json"))))")
        return lines
    }

    private static func timings(store: CatalogStore) async throws -> [String] {
        var lines = ["== Times (median; search: limit 301 as in the gallery, 5 runs; filter lists: 3 runs)"]
        for game in Games.all {
            var parts: [String] = []
            for text in ["a", "dragon"] {
                let time = try await median(5) { _ = try await store.search(game: game.id, text: text, filter: .init(), limit: 301) }
                parts.append("search \"\(text)\" \(milliseconds(time))")
            }
            let lists = try await median(3) {
                _ = try await store.rarities(game: game.id)
                _ = try await store.typeFacets(game: game.id)
            }
            parts.append("rarities + typeFacets \(milliseconds(lists))")
            lines.append("\(game.name): " + parts.joined(separator: ", "))
        }
        return lines
    }

    private static func median(_ runs: Int, _ work: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = clock.now
            try await work()
            times.append(clock.now - start)
        }
        return times.sorted()[runs / 2]
    }

    private static func median(_ runs: Int, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<runs).map { _ in clock.measure(work) }.sorted()[runs / 2]
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }
}

extension CatalogStore {
    /// Every product of one game. Only for the report: it holds the whole game in memory.
    func allProducts(game: String) throws -> [ProductRecord] {
        try modelContext.fetch(FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.gameID == game })).map(\.record)
    }
}
#endif
