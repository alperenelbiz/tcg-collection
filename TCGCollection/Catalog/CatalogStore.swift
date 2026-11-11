import Foundation
import SwiftData

nonisolated struct CardFilter: Sendable, Equatable {
    var groupID: Int?
    var rarity: String?
    var typeFacet: String?
}

nonisolated struct CardSummary: Sendable, Identifiable, Hashable {
    /// The card key: all printings of one card share it.
    let id: String
    let name: String
    /// The printing from the newest set.
    let cover: ProductRecord
    /// Every printing that passed the filter, for the cheapest price.
    let productIDs: [Int]

    var printings: Int { productIDs.count }
}

nonisolated struct SetProgress: Sendable, Equatable {
    let total: Int
    let fetched: Int
    let failed: Int
}

/// Runs every job of one `CatalogStore` on that store's own serial queue.
/// SwiftData's `DefaultSerialModelExecutor` (what `@ModelActor` uses) runs a job on the thread that
/// calls the store, so a view's call ran on the main thread and froze the window (Task 10 report).
nonisolated final class CatalogExecutor: SerialModelExecutor, @unchecked Sendable {
    // Unchecked: `context` is made and used only on `queue`, where every job of the store runs.
    private let container: ModelContainer
    private let queue = DispatchSerialQueue(label: "CatalogStore", qos: .userInitiated)
    private var context: ModelContext?

    init(modelContainer: ModelContainer) {
        container = modelContainer
    }

    /// Made on first use, on the queue, so no part of it belongs to the thread that made the store.
    var modelContext: ModelContext {
        dispatchPrecondition(condition: .onQueue(queue))
        if let context { return context }
        let made = ModelContext(container)
        context = made
        return made
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}

/// The catalog in SwiftData. A `ModelActor` written by hand (not `@ModelActor`) so that it can use
/// `CatalogExecutor`: its work never runs on the caller's thread.
actor CatalogStore: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    private nonisolated let executor: CatalogExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// A store on an existing container: the reader of `AppModel` shares the writer's container.
    init(modelContainer: ModelContainer) {
        let executor = CatalogExecutor(modelContainer: modelContainer)
        self.executor = executor
        modelExecutor = executor
        self.modelContainer = modelContainer
    }

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema([CatalogSet.self, CatalogProduct.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        self.init(modelContainer: container)
    }

    // MARK: Sets

    /// Adds new sets and updates the others. A set keeps its `fetchedAt` and `failed`.
    func upsertSets(_ sets: [SetRecord]) throws {
        var existing: [Int: CatalogSet] = [:]
        for row in try modelContext.fetch(FetchDescriptor<CatalogSet>()) { existing[row.groupID] = row }
        for record in sets {
            if let row = existing[record.groupID] {
                row.gameID = record.gameID
                row.name = record.name
                row.abbreviation = record.abbreviation
                row.publishedOn = record.publishedOn
            } else {
                modelContext.insert(CatalogSet(groupID: record.groupID, gameID: record.gameID, name: record.name,
                                               abbreviation: record.abbreviation, publishedOn: record.publishedOn))
            }
        }
        try modelContext.save()
    }

    /// Replaces the products of one set in one transaction. A set row that does not exist yet is
    /// created (with an empty name) from the game of the first product; `upsertSets` fills it later.
    func replaceProducts(of groupID: Int, with products: [ProductRecord], at date: Date) throws {
        try modelContext.delete(model: CatalogProduct.self, where: #Predicate { $0.groupID == groupID })
        for product in products { modelContext.insert(CatalogProduct(product)) }
        if let row = try setRow(groupID) {
            row.fetchedAt = date
            row.failed = false
        } else if let game = products.first?.gameID {
            modelContext.insert(CatalogSet(groupID: groupID, gameID: game, name: "", abbreviation: "",
                                           publishedOn: nil, fetchedAt: date))
        }
        try modelContext.save()
    }

    /// Sets `failed`; an existing `fetchedAt` stays.
    func markFailed(_ groupID: Int) throws {
        guard let row = try setRow(groupID) else { return }
        row.failed = true
        try modelContext.save()
    }

    func sets(game: String) throws -> [SetRecord] {
        try setRows(game: game)
            .sorted { ($0.publishedOn ?? .distantPast, $1.name) > ($1.publishedOn ?? .distantPast, $0.name) }
            .map { SetRecord(groupID: $0.groupID, gameID: $0.gameID, name: $0.name,
                             abbreviation: $0.abbreviation, publishedOn: $0.publishedOn) }
    }

    func fetchDates(game: String) throws -> [Int: Date] {
        var dates: [Int: Date] = [:]
        for row in try setRows(game: game) { if let date = row.fetchedAt { dates[row.groupID] = date } }
        return dates
    }

    func progress(game: String) throws -> SetProgress {
        let rows = try setRows(game: game)
        return SetProgress(total: rows.count, fetched: rows.filter { $0.fetchedAt != nil }.count,
                           failed: rows.filter(\.failed).count)
    }

    // MARK: Search

    /// Cards that match every word of `text`, sorted by card key (the folded name), `limit` cards at most.
    /// A card's printings are only those that pass `filter`.
    /// `batchSize` is how many products one fetch reads; search stops reading once it has `limit` complete cards.
    func search(game: String, text: String, filter: CardFilter, limit: Int, batchSize: Int = 400) throws -> [CardSummary] {
        guard limit > 0, batchSize > 0 else { return [] }
        let words = CardName.searchKey(text).split(separator: " ").map(String.init)
        let first = words.first ?? ""
        let others = Array(words.dropFirst())
        let useGroup = filter.groupID != nil, group = filter.groupID ?? 0
        let useRarity = filter.rarity != nil, rarity = filter.rarity ?? ""
        let facetText = filter.typeFacet.map { "|\($0)|" }
        let useFacet = facetText != nil, facet = facetText ?? ""

        var descriptor = FetchDescriptor<CatalogProduct>(
            predicate: #Predicate {
                $0.gameID == game
                    && (first == "" || $0.searchKey.contains(first))
                    && (!useGroup || $0.groupID == group)
                    && (!useRarity || $0.rarity == rarity)
                    && (!useFacet || $0.facetText.contains(facet))
            },
            sortBy: [SortDescriptor(\.cardKey), SortDescriptor(\.productID)])
        descriptor.fetchLimit = batchSize

        let publishDates = Dictionary(
            try setRows(game: game).compactMap { row in row.publishedOn.map { (row.groupID, $0) } },
            uniquingKeysWith: { first, _ in first })

        var cards: [CardSummary] = []
        var currentKey = ""
        var currentPrintings: [ProductRecord] = []
        var offset = 0
        func closeCard() {
            guard let cover = currentPrintings.max(by: { Self.older($0, than: $1, dates: publishDates) }) else { return }
            cards.append(CardSummary(id: currentKey, name: cover.cardName, cover: cover,
                                     productIDs: currentPrintings.map(\.productID)))
            currentPrintings = []
        }
        scan: while true {
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            for product in batch {
                if !others.allSatisfy({ product.searchKey.contains($0) }) { continue }
                if product.cardKey != currentKey {
                    closeCard()
                    if cards.count == limit { break scan }
                    currentKey = product.cardKey
                }
                currentPrintings.append(product.record)
            }
            if batch.count < batchSize { break }
            offset += batch.count
        }
        if cards.count < limit { closeCard() }
        return cards
    }

    /// Every printing of one card, newest set first.
    func printings(game: String, cardKey: String) throws -> [ProductRecord] {
        let rows = try modelContext.fetch(FetchDescriptor<CatalogProduct>(
            predicate: #Predicate { $0.gameID == game && $0.cardKey == cardKey }))
        let dates = Dictionary(
            try setRows(game: game).compactMap { row in row.publishedOn.map { (row.groupID, $0) } },
            uniquingKeysWith: { first, _ in first })
        return rows.map(\.record).sorted { Self.older($1, than: $0, dates: dates) }
    }

    func product(_ productID: Int) throws -> ProductRecord? {
        var descriptor = FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.productID == productID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.record
    }

    func rarities(game: String) throws -> [String] {
        try distinct(game: game) { [$0.rarity] }
    }

    func typeFacets(game: String) throws -> [String] {
        try distinct(game: game) { $0.typeFacets }
    }

    func eraseAll() throws {
        try modelContext.delete(model: CatalogProduct.self)
        try modelContext.delete(model: CatalogSet.self)
        try modelContext.save()
    }

    // MARK: Helpers

    private func setRow(_ groupID: Int) throws -> CatalogSet? {
        var descriptor = FetchDescriptor<CatalogSet>(predicate: #Predicate { $0.groupID == groupID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func setRows(game: String) throws -> [CatalogSet] {
        try modelContext.fetch(FetchDescriptor<CatalogSet>(predicate: #Predicate { $0.gameID == game }))
    }

    /// True when `a` comes from an older set than `b` (a missing set date counts as oldest; ties by product id).
    private static func older(_ a: ProductRecord, than b: ProductRecord, dates: [Int: Date]) -> Bool {
        let da = dates[a.groupID] ?? .distantPast, db = dates[b.groupID] ?? .distantPast
        return da != db ? da < db : a.productID < b.productID
    }

    /// Distinct values of one product property, sorted. Reads only the needed property of each product.
    private func distinct(game: String, _ values: (CatalogProduct) -> [String]) throws -> [String] {
        var seen = Set<String>()
        var descriptor = FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.gameID == game })
        descriptor.propertiesToFetch = [\.rarity, \.typeFacets]
        for row in try modelContext.fetch(descriptor) {
            for value in values(row) where !value.isEmpty { seen.insert(value) }
        }
        return seen.sorted()
    }
}
