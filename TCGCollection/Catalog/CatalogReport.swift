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
        lines += await files(store: store)
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
        // A1 keeps a product with a number and a rarity but no card type: these are the printings it added.
        let typeless = products.filter { $0.cardType.isEmpty }.sorted { $0.productID < $1.productID }
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
        lines += unfacetedLines(products)
        lines += try await menuLines(game, store: store)

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
            lines += pictureLines(products, ygo: ygo, label: "pictures")
            lines += pictureLines(typeless, ygo: ygo, label: "pictures of the printings with an empty card type")
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

        lines.append("cards with an empty card type: \(typeless.count)")
        lines += typeless.prefix(40).map { "  \($0.name) — \($0.number) — \($0.rarity)" }
        let sealedNames = sealedLooking(typeless.map(\.name))
        lines.append("of those, with a sealed word in the name: \(sealedNames.count)")
        lines += sealedNames.map { "  \($0)" }
        lines += basicLines(game, products: products)
        return lines
    }

    /// Printings the Type menu cannot find (no stored type facet), and the words of their type lines (before the dash).
    private static func unfacetedLines(_ products: [ProductRecord]) -> [String] {
        let unfaceted = products.filter { $0.typeFacets.isEmpty }
        var lines = ["printings with no type facet: \(unfaceted.count) (\(unfaceted.count { $0.cardType.isEmpty }) with an empty card type)"]
        var words: [String: Int] = [:]
        for product in unfaceted where !product.cardType.isEmpty {
            for word in Set(product.cardType.components(separatedBy: " // ").flatMap(MagicTypes.typeWords)) {
                words[word, default: 0] += 1
            }
        }
        if !words.isEmpty {
            let top = words.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(20)
            lines.append("words of the type lines with no type facet (20 most common): "
                         + top.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines
    }

    /// The Type menu as the store computes it (`facetLists`), and whether the game's facets file holds the same lists.
    private static func menuLines(_ game: GameDefinition, store: CatalogStore) async throws -> [String] {
        let menu = try await store.facetLists(game: game.id)
        let name = "facets-\(game.id).json"
        let file: String
        if let support = supportFolder(store), case let url = facetsFile(game.id, in: support),
           FileManager.default.fileExists(atPath: url.path) {
            switch FacetLists.read(url) {
            case menu?: file = "the same lists"
            case let lists?: file = "differs from the store: rarities \(lists.rarities.count), types \(lists.types)"
            case nil: file = "cannot be decoded"
            }
        } else {
            file = "no file"
        }
        return ["type menu (\(menu.types.count)): \(menu.types.joined(separator: ", "))", "\(name): \(file)"]
    }

    /// Basic cards (distinct card keys, the first 40 listed) and basic printings (`GameDefinition.isBasicPrinting`).
    private static func basicLines(_ game: GameDefinition, products: [ProductRecord]) -> [String] {
        var keys = Set<String>()
        var printings = 0
        for product in products {
            let key = CardName.searchKey(product.cardName)
            if game.isBasicCard(name: product.name, cardType: product.cardType) { keys.insert(key) }
            if game.isBasicPrinting(product) { printings += 1 }
        }
        return ["basic cards: \(keys.count), basic printings: \(printings)"] + keys.sorted().prefix(40).map { "  \($0)" }
    }

    private static func pictureLines(_ products: [ProductRecord], ygo: YGOPictureIndex?, label: String) -> [String] {
        guard let ygo else { return ["\(label): no Yu-Gi-Oh! index"] }
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
        return ["\(label): \(byCode) by set code, \(byName) by name, \(missing.count) not matched"]
            + missing.prefix(40).map { "  \($0.name) (\($0.number)) — \($0.cardType)" }
    }

    /// The phase 1 check over every kept product: a wider list than `sealedProductWords`.
    private static let sealedWords: Set<String> = ["booster", "box", "pack", "bundle", "display", "case", "tin", "kit",
                                                   "sleeves", "playmat", "binder", "starter", "collection", "lot", "deck"]

    /// Words that name a sealed product. The check of the products A1 added (phase 2A, Review Focus 4).
    private static let sealedProductWords: Set<String> = ["box", "pack", "booster", "deck", "display", "bundle", "tin", "kit",
                                                          "case", "sleeves", "playmat"]

    /// The names that contain a word of `sealedProductWords` as a whole word, in any case, in their order.
    static func sealedLooking(_ names: [String]) -> [String] {
        names.filter { CardName.searchKey($0).split(separator: " ").contains { sealedProductWords.contains(String($0)) } }
    }

    private static func looksSealed(_ product: ProductRecord) -> Bool {
        CardName.searchKey(product.name).split(separator: " ").contains { sealedWords.contains(String($0)) }
    }

    private static func shortList(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: "; ") : names.prefix(4).joined(separator: "; ") + "; +\(names.count - 4) more"
    }

    // MARK: Files and timings

    private static func files(store: CatalogStore) async -> [String] {
        guard let url = store.modelContainer.configurations.first?.url else { return ["== Files: no store file"] }
        let support = url.deletingLastPathComponent()
        let storeSizes = ["", "-wal", "-shm"].map { size(URL(fileURLWithPath: url.path + $0)) }
        var lines = ["== Files (MB = 1,000,000 bytes, KB = 1,000 bytes)",
                     "catalog.store: \(megabytes(storeSizes[0])) (+ -wal \(megabytes(storeSizes[1])), -shm \(megabytes(storeSizes[2])))"]
        for game in Games.all {
            // The file name of `AppPaths.prices`. The decode is the work `PriceTable.load` does on the main actor.
            let file = support.appending(path: "prices-\(game.id).json")
            let decode = await durations(3) { _ = try? JSONDecoder().decode(GamePrices.self, from: Data(contentsOf: file)) }.median
            lines.append("prices-\(game.id).json: \(megabytes(size(file))), read and decode \(milliseconds(decode)) (median of 3)")
        }
        lines.append("ygo-index.json: \(megabytes(size(support.appending(path: "ygo-index.json"))))")
        for game in Games.all {
            // The filter menus' values: `AppModel` reads these files at launch instead of scanning the store (P4).
            let file = facetsFile(game.id, in: support)
            guard FileManager.default.fileExists(atPath: file.path) else {
                lines.append("facets-\(game.id).json: no file")
                continue
            }
            let read = await durations(3) { _ = FacetLists.read(file) }.median
            lines.append("facets-\(game.id).json: \(kilobytes(size(file))), read and decode \(preciseMilliseconds(read)) (median of 3)")
        }
        return lines
    }

    /// The folder of the store file (`AppPaths.support`); nil for a store in memory.
    private static func supportFolder(_ store: CatalogStore) -> URL? {
        guard let url = store.modelContainer.configurations.first?.url, url.path != "/dev/null" else { return nil }
        return url.deletingLastPathComponent()
    }

    /// The file name of `AppPaths.facets`.
    private static func facetsFile(_ gameID: String, in support: URL) -> URL {
        support.appending(path: "facets-\(gameID).json")
    }

    /// The texts of the search timings: one letter, a word of six letters, two words, a common word, and the empty text
    /// (the gallery before anything is typed).
    private static let timedSearches = ["a", "dragon", "lightning bolt", "the", ""]

    private static func timings(store: CatalogStore) async throws -> [String] {
        var lines = ["== Times (search: limit 301 as in the gallery, 7 runs, median / worst; filter lists: 3 runs, median)"]
        for game in Games.all {
            lines.append("\(game.name):")
            for text in timedSearches {
                var found: [CardSummary] = []
                let times = try await durations(7) {
                    found = try await store.search(game: game.id, text: text, filter: .init(), limit: 301)
                }
                lines.append("  search \"\(text)\" \(milliseconds(times.median)) / \(milliseconds(times.worst)); "
                             + resultLine(found))
            }
            let lists = try await durations(3) {
                _ = try await store.rarities(game: game.id)
                _ = try await store.typeFacets(game: game.id)
            }
            lines.append("  rarities + typeFacets \(milliseconds(lists.median))")
        }
        // The Collection's join reads its products by id (`products(ids:game:)`): ids spread over the whole game.
        let magic = try await store.productIDs(game: "magic-the-gathering")
        for count in [500, 2_000] where magic.count >= count {
            let ids = stride(from: 0, to: magic.count, by: magic.count / count).prefix(count).map { magic[$0] }
            var found = 0
            let times = try await durations(7) { found = try await store.products(ids: ids, game: "magic-the-gathering").count }
            lines.append("Magic products(ids:) of \(count) ids: \(milliseconds(times.median)) / \(milliseconds(times.worst)); "
                         + "\(found) found")
        }
        return lines
    }

    /// What a search returned, short enough to compare two runs: cards, printings, and a digest of every card key and
    /// product id in their order (FNV-1a, the same in every run).
    private static func resultLine(_ cards: [CardSummary]) -> String {
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for card in cards {
            for byte in "\(card.id)|\(card.cover.productID)|\(card.productIDs)\n".utf8 {
                digest = (digest ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        let printings = cards.map(\.printings).reduce(0, +)
        return "\(cards.count) cards, \(printings) printings, digest \(String(digest, radix: 16))"
    }

    private struct Durations {
        let sorted: [Duration]
        var median: Duration { sorted[sorted.count / 2] }
        var worst: Duration { sorted[sorted.count - 1] }
    }

    private static func durations(_ runs: Int, _ work: () async throws -> Void) async rethrows -> Durations {
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = clock.now
            try await work()
            times.append(clock.now - start)
        }
        return Durations(sorted: times.sorted())
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private static func kilobytes(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1_000)
    }

    private static func preciseMilliseconds(_ duration: Duration) -> String {
        String(format: "%.2f ms", duration / .milliseconds(1))
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

    /// Every product id of one game, ascending. Only for the report's timing of `products(ids:game:)`.
    func productIDs(game: String) throws -> [Int] {
        var descriptor = FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.gameID == game },
                                                         sortBy: [SortDescriptor(\.productID)])
        descriptor.propertiesToFetch = [\.productID]
        return try modelContext.fetch(descriptor).map(\.productID)
    }
}
#endif
