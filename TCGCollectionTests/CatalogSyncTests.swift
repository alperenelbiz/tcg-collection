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
        #expect(SyncPlan.due(sets: sets, fetchDates: dates, now: now, rebuild: false) == [2, 4, 5])
        #expect(SyncPlan.due(sets: sets, fetchDates: dates, now: now, rebuild: true) == [1, 2, 3, 4, 5])
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
        await rig.fake.failEveryCall(after: nil); await rig.fake.resetCounts()
        let second = await rig.run()
        #expect(second.fetched == 9); #expect(await rig.fake.productCalls == 9)
        #expect(second.newSets == ["riftbound": 9])
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
        let result = await rig.run(rebuild: true)
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
        #expect(result == SyncResult(fetched: 0, failed: 1, newSets: [:]))
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
}
