import Foundation
import SwiftData
import Testing
@testable import TCGCollection2

func product(id: Int = 1, game: String = "riftbound", groupID: Int = 1, name: String = "Card", number: String = "",
             rarity: String = "", cardType: String = "", fields: [String: String] = [:]) -> ProductRecord {
    let cardName = CardName.base(name, game: Games.game(game)!)
    return ProductRecord(productID: id, gameID: game, groupID: groupID, name: name, cardName: cardName,
                         searchKey: CardName.searchKey(cardName), number: number, rarity: rarity,
                         cardType: cardType, typeFacets: [], rulesText: "", url: "", fields: fields)
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tcg-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The order of the calls the fakes below receive, when they share one log.
actor CallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

/// Answers every request with one body, or with a body chosen per URL; counts the calls.
/// The first `networkErrors` calls throw a transport error instead, as with no network.
actor FakeFetcher: DataFetching {
    private let body: Data
    private let status: Int
    private let bodies: [URL: Data]
    private let log: CallLog?
    private var networkErrors: Int
    private(set) var calls = 0

    init(body: Data = Data(), status: Int = 200, bodies: [URL: Data] = [:], networkErrors: Int = 0, log: CallLog? = nil) {
        self.body = body
        self.status = status
        self.bodies = bodies
        self.networkErrors = networkErrors
        self.log = log
    }

    func data(from url: URL) async throws -> (Data, Int) {
        calls += 1
        await log?.add("fetch \(url.lastPathComponent)")
        try await Task.sleep(for: .milliseconds(50))
        if networkErrors > 0 {
            networkErrors -= 1
            throw URLError(.notConnectedToInternet)
        }
        return (bodies[url] ?? body, status)
    }
}

/// A tcgcsv client. `groups` is the set list of `category`; every other category has no sets.
/// Every set answers `products` unless `setBody` chose another body. Counts calls and concurrency.
actor FakeCatalog: TCGCSVFetching {
    private static let noSets = Data(#"{"success":true,"errors":[],"results":[],"totalItems":0}"#.utf8)

    private let groupsBody: Data
    private let productsBody: Data
    private let category: Int
    private let log: CallLog?
    private var bodies: [Int: Data] = [:]
    private var failAfter: Int?
    private var started = 0
    private var running = 0
    private(set) var productCalls = 0
    private(set) var maxConcurrent = 0
    private(set) var groupCalls = 0
    private var groupsFail = false

    init(groups: Data, products: Data, category: Int = 89, log: CallLog? = nil) {
        groupsBody = groups
        productsBody = products
        self.category = category
        self.log = log
    }

    func failEveryCall(after count: Int?) { failAfter = count; started = 0 }
    func resetCounts() { productCalls = 0; started = 0; maxConcurrent = 0 }
    func setBody(_ data: Data, forGroup group: Int) { bodies[group] = data }
    func failGroups(_ fail: Bool) { groupsFail = fail }

    func groups(category: Int) async throws -> Data {
        groupCalls += 1
        await log?.add("groups \(category)")
        if groupsFail { throw TCGCSVClientError(status: 500) }
        return category == self.category ? groupsBody : Self.noSets
    }

    func products(category: Int, group: Int) async throws -> Data {
        productCalls += 1
        started += 1
        let index = started
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        if let failAfter, index > failAfter { throw TCGCSVClientError(status: 503) }
        return bodies[group] ?? productsBody
    }
}

/// Hands out a fixture file as the archive of a day (`files`: day -> fixture name); any other day is a 404.
actor FakeArchive: ArchiveFetching {
    private let files: [String: String]
    private let log: CallLog?
    private(set) var calls: [String] = []

    init(files: [String: String] = ["2026-01-02": "prices-2026-01-02.ppmd.7z"], log: CallLog? = nil) {
        self.files = files
        self.log = log
    }

    func download(day: String, to file: URL) async throws -> Bool {
        calls.append(day)
        await log?.add("archive \(day)")
        guard let name = files[day] else { return false }
        try FileManager.default.copyItem(at: fixtureURL(name), to: file)
        return true
    }
}

extension CatalogStore {
    /// True when this store's work runs on the main thread. It must never do (the views call it from the main actor).
    func runsOnMainThread() -> Bool { Thread.isMainThread }
}

/// A store with a schema the catalog never had: SwiftData cannot say which version it is, Core Data reads its metadata.
enum ForeignSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model final class Note {
        var text: String
        init(text: String) { self.text = text }
    }

    /// Writes a store of this schema, with one row, at `url`.
    static func writeStore(at url: URL) throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ForeignSchema.self), configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        context.insert(Note(text: "x"))
        try context.save()
    }
}

/// The store was still open after `waitUntilClosed` waited 5 s for it to close.
struct StoreStillOpen: Error {}

/// Writes a catalog store with `products` (and their set 1) at `url` and closes it (`waitUntilClosed`).
func writeClosedStore(at url: URL, products: [ProductRecord] = [product(id: 1)]) async throws {
    do {
        let schema = Schema(versionedSchema: CatalogSchemaV2.self)
        let container = try ModelContainer(for: schema, migrationPlan: CatalogMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        context.insert(CatalogSet(groupID: 1, gameID: "riftbound", name: "Set", abbreviation: "", publishedOn: nil,
                                  fetchedAt: .now, rulesVersion: CatalogRules.version))
        for record in products { context.insert(CatalogProduct(record)) }
        try context.save()
    }
    try await waitUntilClosed(url)
}

/// Writes a phase 1 store (the V1 schema) at `url`: set 24819 and the Riftbound fixture products. Closes it.
func writePhase1Store(at url: URL) async throws {
    do {
        let container = try ModelContainer(for: Schema(versionedSchema: CatalogSchemaV1.self), configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        context.insert(CatalogSchemaV1.CatalogSet(groupID: 24819, gameID: "riftbound", name: "Radiance", abbreviation: "RAD",
                                                  publishedOn: nil, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        for record in try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!).cards {
            context.insert(CatalogSchemaV1.CatalogProduct(record))
        }
        try context.save()
    }
    try await waitUntilClosed(url)
}

/// Waits until the store at `url` is closed, then removes its `-wal` and `-shm` files: the store file alone holds every
/// row then. Core Data empties the -wal when it closes a store, but it closes a released container later, on its own
/// schedule (seen: an autorelease pool is not enough).
func waitUntilClosed(_ url: URL) async throws {
    func walSize() -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0 }
    let end = ContinuousClock.now + .seconds(5)
    while walSize() > 0 {
        guard ContinuousClock.now < end else { throw StoreStillOpen() }
        try await Task.sleep(for: .milliseconds(10))
    }
    for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}

/// The byte size and the modification date of a file.
func sizeAndDate(_ url: URL) throws -> (size: Int, date: Date) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (try #require(attributes[.size] as? Int), try #require(attributes[.modificationDate] as? Date))
}
