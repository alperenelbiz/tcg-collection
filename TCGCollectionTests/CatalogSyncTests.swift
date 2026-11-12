import Foundation
import Testing
@testable import TCGCollection2

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncProgress] = []
    func append(_ item: SyncProgress) { lock.lock(); items.append(item); lock.unlock() }
    var all: [SyncProgress] { lock.lock(); defer { lock.unlock() }; return items }
    var last: SyncProgress? { all.last }
}

private struct Rig {
    let sync: CatalogSync
    let store: CatalogStore
    let fake: FakeCatalog
    let riftbound = Games.game("riftbound")!
    let now = TCGDate.date("2026-11-11T10:00:00")!
    let progressLog = ProgressLog()

    init(products: Data? = nil) async throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.store")
        store = try CatalogStore(url: url)
        fake = FakeCatalog(groups: try fixture("groups-89.json"), products: try products ?? fixture("products-89.json"))
        sync = CatalogSync(store: store, client: fake)
    }

    func run(rebuild: Bool = false, at date: Date? = nil) async -> SyncResult {
        await sync.run(games: [riftbound], now: date ?? now, rebuild: rebuild) { progressLog.append($0) }
    }
}

struct CatalogSyncTests {
    @Test func dueSetsFollowTheRule() {
        let now = TCGDate.date("2026-11-11T10:00:00")!
        func set(_ id: Int, _ day: String?) -> SetRecord {
            .init(groupID: id, gameID: "riftbound", name: "", abbreviation: "",
                  publishedOn: day.flatMap { TCGDate.date($0 + "T00:00:00") })
        }
        let sets = [set(1, "2025-07-30"), set(2, "2026-10-23"), set(3, "2027-01-29"), set(4, "2025-07-30"), set(5, nil)]
        let today = TCGDate.date("2026-11-11T01:00:00")!, yesterday = TCGDate.date("2026-11-10T23:00:00")!
        let dates = [1: yesterday, 2: yesterday, 3: today, 5: yesterday]            // 4 was never fetched
        let current = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, CatalogRules.version) })
        #expect(SyncPlan.due(sets: sets, fetchDates: dates, rulesVersions: current, now: now, rebuild: false) == [2, 4, 5])
        #expect(SyncPlan.due(sets: sets, fetchDates: dates, rulesVersions: current, now: now, rebuild: true) == [1, 2, 4, 5])   // 3: fetched today
    }

    @Test func anOldRulesVersionMakesASetDueButNotOnTheDayItWasFetched() {      // Review Focus 3
        let now = TCGDate.date("2026-11-13T10:00:00")!
        func set(_ id: Int) -> SetRecord { .init(groupID: id, gameID: "riftbound", name: "", abbreviation: "", publishedOn: TCGDate.date("2025-01-01T00:00:00")) }
        let today = TCGDate.date("2026-11-13T01:00:00")!, yesterday = TCGDate.date("2026-11-12T20:00:00")!
        let due = SyncPlan.due(sets: [set(1), set(2), set(3)], fetchDates: [1: yesterday, 2: today, 3: yesterday],
                               rulesVersions: [1: 1, 2: 1, 3: CatalogRules.version], now: now, rebuild: false)
        #expect(due == [1])                                               // 2 was fetched today; 3 is current
    }

    /// I2: the day kept as `lastCatalogFetchDay` is the UTC day, also where the local day has already changed.
    @Test func theDayOfADateIsItsUTCDay() {
        #expect(SyncPlan.utcDay(TCGDate.date("2026-11-12T23:30:00")!) == "2026-11-12")   // 02:30 on the 13th in Istanbul
        #expect(SyncPlan.utcDay(TCGDate.date("2026-11-13T00:00:00")!) == "2026-11-13")
        #expect(SyncPlan.utcDay(TCGDate.date("2027-01-02T10:00:00")!) == "2027-01-02")
    }

    @Test func aSetMissingFromTheRulesVersionsCountsAsCurrent() {
        let now = TCGDate.date("2026-11-13T10:00:00")!
        let old = SetRecord(groupID: 1, gameID: "riftbound", name: "", abbreviation: "", publishedOn: TCGDate.date("2025-01-01T00:00:00"))
        let yesterday = TCGDate.date("2026-11-12T20:00:00")!
        #expect(SyncPlan.due(sets: [old], fetchDates: [1: yesterday], rulesVersions: [:], now: now, rebuild: false).isEmpty)
    }

    @Test func aRunWritesTheCurrentRulesVersion() async throws {
        let rig = try await Rig()
        _ = await rig.run()
        #expect(Set(try await rig.store.rulesVersions(game: "riftbound").values) == [CatalogRules.version])
    }

    @Test func afterARuleChangeEverySetIsFetchedOnceOnTheNextDay() async throws {
        let rig = try await Rig()
        _ = await rig.run()
        try await rig.store.setRulesVersion(1, game: "riftbound")
        await rig.fake.resetCounts()
        _ = await rig.run(at: rig.now.addingTimeInterval(3600))
        #expect(await rig.fake.productCalls == 0)                             // same UTC day
        _ = await rig.run(at: rig.now.addingTimeInterval(86_400))
        #expect(await rig.fake.productCalls == 14)
        await rig.fake.resetCounts()
        _ = await rig.run(at: rig.now.addingTimeInterval(2 * 86_400))
        // No second rules re-fetch: only the 3 sets the recent-set rule keeps due (published 2026-10-23, 2026-12-04, 2027-01-29).
        #expect(await rig.fake.productCalls == 3)
    }

    /// I4: "Rebuild catalog" fetches every set that was not fetched today (UTC), so a second rebuild that day fetches none.
    @Test func aSecondRebuildTheSameDayFetchesNoSetAgain() async throws {
        let rig = try await Rig()
        _ = await rig.run(rebuild: true)
        await rig.fake.resetCounts()
        let second = await rig.run(rebuild: true, at: rig.now.addingTimeInterval(3600))
        #expect(await rig.fake.productCalls == 0)
        #expect(second == SyncResult(fetched: 0, failed: 0, newSets: [:]))
    }

    @Test func firstRunFillsTheStoreAndReportsProgress() async throws {
        let rig = try await Rig()
        let result = await rig.run()
        #expect(result == SyncResult(fetched: 14, failed: 0, newSets: ["riftbound": 14]))
        #expect(rig.progressLog.last == SyncProgress(gameID: "riftbound", done: 14, total: 14, failed: 0))
        #expect(rig.progressLog.all.count == 14)
        #expect(try await rig.store.progress(game: "riftbound") == SetProgress(total: 14, fetched: 14, failed: 0))
    }

    @Test func aSecondRunTheSameDayFetchesNoSetAgain() async throws {
        let rig = try await Rig()
        _ = await rig.run()
        let before = await rig.fake.productCalls
        let second = await rig.run(at: rig.now.addingTimeInterval(3600))
        #expect(await rig.fake.productCalls == before)
        #expect(second == SyncResult(fetched: 0, failed: 0, newSets: [:]))
    }

    @Test func aRunThatStopsHalfwayContinuesWithTheRest() async throws {
        let rig = try await Rig()
        await rig.fake.failEveryCall(after: 5)                                      // "the network drops"
        let first = await rig.run()
        #expect(first.fetched == 5 && first.failed == 9)
        // B11: the progress line counts the sets of the game that are not due any more in this run, failed ones too.
        #expect(rig.progressLog.last == SyncProgress(gameID: "riftbound", done: 14, total: 14, failed: 9))
        let firstRunEvents = rig.progressLog.all.count
        await rig.fake.failEveryCall(after: nil); await rig.fake.resetCounts()
        let second = await rig.run()
        #expect(second.fetched == 9); #expect(await rig.fake.productCalls == 9)
        #expect(second.newSets == ["riftbound": 9])
        let resumed = rig.progressLog.all.dropFirst(firstRunEvents)                 // continues, it does not start at 0
        #expect(resumed.first == SyncProgress(gameID: "riftbound", done: 6, total: 14, failed: 0))
        #expect(resumed.last == SyncProgress(gameID: "riftbound", done: 14, total: 14, failed: 0))
    }

    @Test func aSetWithAWrongBodyIsSkippedAndCounted() async throws {
        let rig = try await Rig()
        await rig.fake.setBody(Data("<Error><Code>NoSuchKey</Code></Error>".utf8), forGroup: 24819)
        let result = await rig.run()
        #expect(result.fetched == 13 && result.failed == 1)
        #expect(try await rig.store.progress(game: "riftbound") == SetProgress(total: 14, fetched: 13, failed: 1))
    }

    @Test func aBodyWithSuccessFalseDoesNotEraseTheSet() async throws {
        let rig = try await Rig()
        _ = await rig.run()
        await rig.fake.setBody(Data(#"{"success":false,"errors":["x"],"results":[]}"#.utf8), forGroup: 24819)
        let result = await rig.run(rebuild: true, at: rig.now.addingTimeInterval(86_400))   // the next day: every set is due
        #expect(result.fetched == 13 && result.failed == 1)
        #expect(try await rig.store.product(721334) != nil)                         // the old products stay
    }

    @Test func aSetOfSealedProductsOnlyIsASuccessWithNoCards() async throws {
        let rig = try await Rig(products: Data(#"{"success":true,"errors":[],"results":[],"totalItems":0}"#.utf8))
        let result = await rig.run()
        #expect(result == SyncResult(fetched: 14, failed: 0, newSets: ["riftbound": 14]))
    }

    @Test func aFailedSetListSkipsTheGameAndCountsOneFailure() async throws {
        let rig = try await Rig()
        await rig.fake.failGroups(true)
        let result = await rig.run()
        #expect(result == SyncResult(fetched: 0, failed: 0, failedSetLists: 1, newSets: [:]))   // I2: apart from sets
        #expect(await rig.fake.productCalls == 0)
    }

    /// I1: a cancelled run stops starting sets and marks none failed: a cancelled fetch says nothing about the set.
    @Test(.timeLimit(.minutes(1))) func aCancelledRunMarksNoSetFailed() async throws {
        let rig = try await Rig()
        let run = Task { await rig.run() }
        while await rig.fake.productCalls == 0 { try await Task.sleep(for: .milliseconds(1)) }
        run.cancel()
        let result = await run.value
        #expect(try await rig.store.progress(game: "riftbound").failed == 0)
        #expect(result.failed == 0)
        #expect(await rig.fake.productCalls < 14)                                   // no set was started after the cancel
    }

    @Test func neverMoreThanFourRequestsAtOnce() async throws {
        let rig = try await Rig()
        _ = await rig.run()
        let most = await rig.fake.maxConcurrent
        #expect(most <= 4)
        #expect(most > 1)                                                           // the test would pass for a serial run too
    }

    @Test func anExcludedSetIsNeverFetchedAndIsRemoved() async throws {           // A6, B10
        let magic = Games.game("magic-the-gathering")!
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.store")
        let store = try CatalogStore(url: url)
        let body = Data(#"{"success":true,"errors":[],"results":[{"groupId":24684,"name":"Reality Fracture","abbreviation":"RF","publishedOn":"2026-10-02T00:00:00","categoryId":1},{"groupId":24690,"name":"Art Series: The Hobbit","abbreviation":"AH","publishedOn":"2026-10-02T00:00:00","categoryId":1}]}"#.utf8)
        let fake = FakeCatalog(groups: body, products: try fixture("products-1.json"), category: 1)
        // An earlier rules version stored the Art Series set with a product.
        try await store.upsertSets([SetRecord(groupID: 24690, gameID: magic.id, name: "Art Series: The Hobbit", abbreviation: "AH", publishedOn: nil)])
        try await store.replaceProducts(of: 24690, with: [product(id: 7, game: magic.id, groupID: 24690, name: "Smaug", number: "1", rarity: "M", cardType: "Creature")], at: .now)
        let sync = CatalogSync(store: store, client: fake)
        let now = TCGDate.date("2026-11-11T10:00:00")!
        let result = await sync.run(games: [magic], now: now, rebuild: false) { _ in }
        #expect(await fake.productGroups == [24684]); #expect(result.fetched == 1)
        #expect(try await store.sets(game: "magic-the-gathering").map(\.groupID) == [24684])
        #expect(try await store.search(game: "magic-the-gathering", text: "", filter: .init(groupID: 24690), limit: 10).isEmpty)
    }

    @Test func progressMovesDuringAReFetch() async throws {                       // B11
        let rig = try await Rig()
        _ = await rig.run()
        try await rig.store.setRulesVersion(1, game: "riftbound")
        let before = rig.progressLog.all.count
        _ = await rig.run(at: rig.now.addingTimeInterval(86_400))
        let log = Array(rig.progressLog.all.dropFirst(before))
        #expect(log.first?.done == 1); #expect(log.last == SyncProgress(gameID: "riftbound", done: 14, total: 14, failed: 0))
        #expect(log.map(\.done) == log.map(\.done).sorted()); #expect(log.count == 14)
    }

    @Test func aRunWithNothingDueReportsAllDoneOnce() async throws {              // B11
        let rig = try await Rig()
        _ = await rig.run()
        let before = rig.progressLog.all.count
        _ = await rig.run(at: rig.now.addingTimeInterval(3600))
        #expect(Array(rig.progressLog.all.dropFirst(before)) == [SyncProgress(gameID: "riftbound", done: 14, total: 14, failed: 0)])
    }
}
