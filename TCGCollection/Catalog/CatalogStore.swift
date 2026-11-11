import CoreData
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

/// Why the store file could not be opened (P8).
nonisolated enum StoreOpenFailure: Sendable, Equatable {
    /// The file is corrupt or not a database, or its migration failed: it is moved aside and the catalog downloaded again.
    case unreadable
    /// Anything else (a full disk, no permission): the file stays where it is. The text says what happened.
    case other(String)
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

    /// Opens the store file at `url` with the current schema, and migrates a store of an older version first.
    /// What it throws is judged by `classify(_:)`.
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: CatalogSchemaV2.self)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, migrationPlan: CatalogMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        } catch {
            throw Self.openError(error, url: url)
        }
        self.init(modelContainer: container)
    }

    /// An empty store that lives in memory only: the last fallback when no store file can be opened. It needs no disk.
    static func inMemory() throws -> CatalogStore {
        let schema = Schema(versionedSchema: CatalogSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return CatalogStore(modelContainer: try ModelContainer(for: schema, configurations: configuration))
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
                // A set with no products yet has nothing stored under older rules.
                modelContext.insert(CatalogSet(groupID: record.groupID, gameID: record.gameID, name: record.name,
                                               abbreviation: record.abbreviation, publishedOn: record.publishedOn,
                                               rulesVersion: CatalogRules.version))
            }
        }
        try modelContext.save()
    }

    /// Replaces the products of one set in one transaction and records the date and the current rules version on the
    /// set. A set row that does not exist yet is created (with an empty name) from the game of the first product;
    /// `upsertSets` fills it later.
    func replaceProducts(of groupID: Int, with products: [ProductRecord], at date: Date) throws {
        try modelContext.delete(model: CatalogProduct.self, where: #Predicate { $0.groupID == groupID })
        for product in products { modelContext.insert(CatalogProduct(product)) }
        if let row = try setRow(groupID) {
            row.fetchedAt = date
            row.failed = false
            row.rulesVersion = CatalogRules.version
        } else if let game = products.first?.gameID {
            modelContext.insert(CatalogSet(groupID: groupID, gameID: game, name: "", abbreviation: "",
                                           publishedOn: nil, fetchedAt: date, rulesVersion: CatalogRules.version))
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

    /// The rules version of every set of the game (group id: version).
    func rulesVersions(game: String) throws -> [Int: Int] {
        Dictionary(try setRows(game: game).map { ($0.groupID, $0.rulesVersion) }, uniquingKeysWith: { first, _ in first })
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

        // A batch starts after the last row of the one before, by key, not at an offset: the writer commits between
        // two batches, and rows it inserts before an offset would push rows already read into the next batch.
        // The key sort is `.lexical`, the order of `>` in the predicate. The default for a String
        // (`.localizedStandard`) puts "card 2" before "card 10", and the next batch would then skip "card 10".
        func batch(after last: (key: String, id: Int)?) throws -> [CatalogProduct] {
            let paging = last != nil, lastKey = last?.key ?? "", lastID = last?.id ?? 0
            var descriptor = FetchDescriptor<CatalogProduct>(
                predicate: #Predicate {
                    $0.gameID == game
                        && (first == "" || $0.searchKey.contains(first))
                        && (!useGroup || $0.groupID == group)
                        && (!useRarity || $0.rarity == rarity)
                        && (!useFacet || $0.facetText.contains(facet))
                        && (!paging || $0.cardKey > lastKey || ($0.cardKey == lastKey && $0.productID > lastID))
                },
                sortBy: [SortDescriptor(\.cardKey, comparator: .lexical), SortDescriptor(\.productID)])
            descriptor.fetchLimit = batchSize
            return try modelContext.fetch(descriptor)
        }

        let publishDates = Dictionary(
            try setRows(game: game).compactMap { row in row.publishedOn.map { (row.groupID, $0) } },
            uniquingKeysWith: { first, _ in first })

        var cards: [CardSummary] = []
        var currentKey = ""
        var currentPrintings: [ProductRecord] = []
        var last: (key: String, id: Int)?
        func closeCard() {
            guard let cover = currentPrintings.max(by: { Self.older($0, than: $1, dates: publishDates) }) else { return }
            cards.append(CardSummary(id: currentKey, name: cover.cardName, cover: cover,
                                     productIDs: currentPrintings.map(\.productID)))
            currentPrintings = []
        }
        scan: while true {
            let batch = try batch(after: last)
            for product in batch {
                if !others.allSatisfy({ product.searchKey.contains($0) }) { continue }
                if product.cardKey != currentKey {
                    closeCard()
                    if cards.count == limit { break scan }
                    currentKey = product.cardKey
                }
                currentPrintings.append(product.record)
            }
            guard batch.count == batchSize, let end = batch.last else { break }
            last = (end.cardKey, end.productID)
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
        descriptor.propertiesToFetch = [\.rarity, \.facetText]
        for row in try modelContext.fetch(descriptor) {
            for value in values(row) where !value.isEmpty { seen.insert(value) }
        }
        return seen.sorted()
    }
}

// MARK: - Open errors (P8)

extension CatalogStore {
    /// SQLite primary result codes of a file that is bad in itself: SQLITE_CORRUPT, SQLITE_NOTADB.
    private nonisolated static let unreadableSQLiteCodes: Set<Int> = [11, 26]
    /// Core Data codes of a store that cannot be migrated: NSPersistentStoreIncompatibleVersionHashError,
    /// NSMigrationError, NSMigrationMissingSourceModelError, NSMigrationMissingMappingModelError.
    private nonisolated static let unreadableCocoaCodes: Set<Int> = [134100, 134110, 134130, 134140]

    /// `.unreadable` when the error or one of its causes says that the file is corrupt or not a database, or that its
    /// migration failed; `.other` for everything else (a full disk, no permission, a folder that cannot be written).
    nonisolated static func classify(_ error: any Error) -> StoreOpenFailure {
        causes(of: error).contains(where: isUnreadable) ? .unreadable : .other(reason(error))
    }

    /// The text of the outermost cause that is not SwiftData's own: a `SwiftDataError` reads "SwiftData.SwiftDataError
    /// error 1" whatever happened.
    nonisolated static func reason(_ error: any Error) -> String {
        (causes(of: error).first { !($0 is SwiftDataError) } ?? error).localizedDescription
    }

    private nonisolated static func isUnreadable(_ error: any Error) -> Bool {
        // A store written with a schema that no version of the migration plan has (seen for another app's schema and
        // for a newer version of ours): SwiftData throws this with no cause.
        if let swiftData = error as? SwiftDataError { return swiftData == .unknownDataStoreSchema }
        let error = error as NSError
        // An extended SQLite code keeps the primary code in its low byte (SQLITE_READONLY_DIRECTORY is 1544 = 8 + 6 << 8).
        func unreadableSQLite(_ code: Int) -> Bool { unreadableSQLiteCodes.contains(code & 0xFF) }
        if error.domain == NSSQLiteErrorDomain, unreadableSQLite(error.code) { return true }
        if error.domain == NSCocoaErrorDomain, unreadableCocoaCodes.contains(error.code) { return true }
        // Core Data also puts an SQLite code in the user info of a Cocoa error (seen: 256 with 1544 for a read-only folder).
        if let code = error.userInfo[NSSQLiteErrorDomain] as? Int, unreadableSQLite(code) { return true }
        return false
    }

    /// The error, the Core Data error that a `SwiftDataError` keeps, and every underlying error, depth first.
    private nonisolated static func causes(of error: any Error) -> [any Error] {
        var found = [error]
        if let wrapped = wrappedCocoaError(error) { found += causes(of: wrapped) }
        for underlying in (error as NSError).underlyingErrors { found += causes(of: underlying) }
        return found
    }

    /// SwiftData keeps the Core Data error that stopped a container in `_underlyingCocoaError`, which it does not make
    /// public (seen on macOS 27). Nil when the error has none, or when a later SwiftData no longer has that property.
    private nonisolated static func wrappedCocoaError(_ error: any Error) -> (any Error)? {
        guard error is SwiftDataError else { return nil }
        return Mirror(reflecting: error).children.first { $0.label == "_underlyingCocoaError" }?.value as? any Error
    }

    /// For a file that is not a database or is corrupt, SwiftData throws `loadIssueModelContainer` with no cause and
    /// writes the SQLite error only to its log (seen on macOS 27). Reading the file's metadata through Core Data gives
    /// that error back; it is thrown instead. Any other error is thrown as it is.
    private nonisolated static func openError(_ error: any Error, url: URL) -> any Error {
        guard case SwiftDataError.loadIssueModelContainer = error, wrappedCocoaError(error) == nil,
              FileManager.default.fileExists(atPath: url.path) else { return error }
        do {
            _ = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
            return error
        } catch let metadataError {
            return metadataError
        }
    }
}
