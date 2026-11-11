import Foundation
@testable import TCGCollection2

func product(id: Int = 1, game: String = "riftbound", groupID: Int = 1, name: String = "Card", number: String = "",
             rarity: String = "", cardType: String = "", fields: [String: String] = [:]) -> ProductRecord {
    let cardName = CardName.base(name)
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
actor FakeFetcher: DataFetching {
    private let body: Data
    private let status: Int
    private let bodies: [URL: Data]
    private let log: CallLog?
    private(set) var calls = 0

    init(body: Data = Data(), status: Int = 200, bodies: [URL: Data] = [:], log: CallLog? = nil) {
        self.body = body
        self.status = status
        self.bodies = bodies
        self.log = log
    }

    func data(from url: URL) async throws -> (Data, Int) {
        calls += 1
        await log?.add("fetch \(url.lastPathComponent)")
        try await Task.sleep(for: .milliseconds(50))
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
