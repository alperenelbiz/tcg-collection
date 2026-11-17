import Foundation
import Testing
@testable import TCGCollection2

struct PriceSyncTests {
    let fake: FakeArchive
    let paths = AppPaths(root: tempRoot())
    // An actor made in a stored-property initializer, when the actor is declared in another file, breaks the
    // module emit of Xcode 27.0 ("'nonisolated' modifier cannot be applied to this declaration").
    init() { fake = FakeArchive() }
    var sync: PriceSync { PriceSync(paths: paths, client: fake) }

    @Test func wantedDayFollowsThePublishTime() {
        #expect(PriceDay.wanted(now: TCGDate.date("2026-11-11T15:36:00")!) == "2026-11-10")
        #expect(PriceDay.wanted(now: TCGDate.date("2026-11-11T20:31:00")!) == "2026-11-11")
        #expect(PriceDay.before("2026-03-01") == "2026-02-28")
    }

    @Test func downloadsOnceAndFillsEveryGame() async throws {
        let sync = self.sync
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        #expect(out?["cyberpunk"]?.rows.count == 18); #expect(out?["riftbound"]?.day == "2026-01-02")
        #expect(out?["magic-the-gathering"]?.rows.isEmpty == true)
        _ = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T11:00:00")!, haveDay: nil)
        #expect(await fake.calls == ["2026-01-02"])
    }

    @Test func skipsWhenTheDayIsAlreadyLoaded() async throws {
        #expect(try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: "2026-01-02") == nil)
        #expect(await fake.calls.isEmpty)
    }

    @Test func fallsBackOneDayOnA404() async throws {
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T21:00:00")!, haveDay: nil)
        #expect(out?["riftbound"]?.day == "2026-01-02"); #expect(await fake.calls == ["2026-01-03", "2026-01-02"])
    }

    @Test func returnsNilWhenNeitherDayExists() async throws {
        #expect(try await sync.run(games: Games.all, now: TCGDate.date("2026-02-10T10:00:00")!, haveDay: nil) == nil)
        #expect(await fake.calls == ["2026-02-09", "2026-02-08"])
    }

    @Test func aBrokenFileOnDiskIsRethrownAndKept() async throws {
        let file = paths.archives.appending(path: "prices-2026-01-02.ppmd.7z")
        try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("not-an-archive.7z"), to: file)
        await #expect(throws: PriceArchiveError.self) {
            try await self.sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await fake.calls.isEmpty)
    }
}

/// Phase 5B task 5, review round 1: the download lane remembers a request that threw (findings 1) and every day it
/// downloaded, in the preferences (finding 2, A47).
struct ArchiveDownloadsTests {
    let paths = AppPaths(root: tempRoot())

    @Test func aRequestThatThrewIsNotRepeatedInTheRun() async throws {
        let network = BackfillNetwork(serveAll: true, failing: ["2026-01-02"])
        let sync = PriceSync(paths: paths, client: network)
        let now = TCGDate.date("2026-01-03T10:00:00")!
        await #expect(throws: URLError.self) { try await sync.run(games: Games.all, now: now, haveDay: nil) }
        // A later Refresh tries a different day once, never the one that threw.
        let out = try await sync.run(games: Games.all, now: now, haveDay: nil)
        #expect(out?["riftbound"]?.day == "2026-01-01")
        #expect(await network.calls == ["2026-01-02", "2026-01-01"])
    }

    @Test func aBackgroundFailureStopsTheBackgroundButNotThePriceStep() async throws {
        let network = BackfillNetwork(serveAll: true, statuses: ["2026-01-01": 429])
        let sync = PriceSync(paths: paths, client: network)
        await #expect(throws: TCGCSVClientError.self) { try await sync.downloads.download(day: "2026-01-01", background: true) }
        #expect(try await sync.downloads.download(day: "2025-12-31", background: true) == .stopped)
        // The price step whose wanted day is the one that got the 429: it asks the day before instead.
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-02T10:00:00")!, haveDay: nil)
        #expect(out?["riftbound"]?.day == "2025-12-31")
        #expect(await network.calls == ["2026-01-01", "2025-12-31"])
    }

    @Test func theRecordRefusesADayDownloadedInAnEarlierRun() async throws {
        let record = try #require(UserDefaults(suiteName: paths.support.appending(path: "record").path))
        let first = BackfillNetwork(serveAll: true)
        let now = TCGDate.date("2026-01-03T10:00:00")!
        _ = try await PriceSync(paths: paths, client: first, record: PriceDaysRecord(record)).run(games: Games.all, now: now, haveDay: nil)
        #expect(record.stringArray(forKey: ArchiveDownloads.recordKey) == ["2026-01-02"])
        try FileManager.default.removeItem(at: paths.priceDay("2026-01-02"))
        let second = BackfillNetwork(serveAll: true)
        _ = try await PriceSync(paths: paths, client: second, record: PriceDaysRecord(record)).run(games: Games.all, now: now, haveDay: nil)
        #expect(await second.calls == ["2026-01-01"])
    }

    /// Final fix wave, item 4: a 404 of a day with no newer day held (the newest days: not published yet, or a clock
    /// ahead) is not kept across runs; one older than a held day is.
    @Test func a404IsKeptOnlyBelowAHeldDay() async throws {
        let record = try #require(UserDefaults(suiteName: paths.support.appending(path: "record").path))
        let network = BackfillNetwork(served: ["2026-01-01"])
        let lane = ArchiveDownloads(paths: paths, client: network, record: PriceDaysRecord(record))
        #expect(try await lane.download(day: "2026-01-02", background: false) == .notFound)
        #expect(record.stringArray(forKey: ArchiveDownloads.notFoundKey) == nil)
        #expect(try await lane.download(day: "2026-01-01", background: true) == .downloaded)
        #expect(try await lane.download(day: "2025-12-31", background: true) == .notFound)
        #expect(record.stringArray(forKey: ArchiveDownloads.notFoundKey) == ["2025-12-31"])
        let next = ArchiveDownloads(paths: paths, client: network, record: PriceDaysRecord(record))
        #expect(try await next.download(day: "2025-12-31", background: false) == .notFound)
        #expect(try await next.download(day: "2026-01-02", background: false) == .notFound)
        #expect(await network.calls == ["2026-01-02", "2026-01-01", "2025-12-31", "2026-01-02"])
    }

    /// Final fix wave, item 9: archive requests time out (60 s without data, 120 s for the whole file), so a trickling
    /// download cannot hold a catalog step for long.
    @Test func archiveRequestsHaveTimeouts() {
        let configuration = ArchiveClient().session.configuration
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 120)
    }

    /// Item 9: a timeout is an ordinary failed request: not asked again in the run, and the background stops.
    @Test func aTimeoutStopsTheBackground() async throws {
        let network = BackfillNetwork(serveAll: true, timingOut: ["2026-01-01"])
        let lane = ArchiveDownloads(paths: paths, client: network)
        await #expect(throws: URLError.self) { try await lane.download(day: "2026-01-01", background: true) }
        #expect(try await lane.download(day: "2025-12-31", background: true) == .stopped)
        #expect(try await lane.download(day: "2026-01-01", background: false) == .failedBefore)
        #expect(await network.calls == ["2026-01-01"])
    }
}

/// Review round 2, A: the lane records a day at its 200, also when the client's move then fails.
struct ArchiveStoreFailureTests {
    let paths = AppPaths(root: tempRoot())

    @Test func aFailedMoveAfterA200IsRecordedAndNotAskedAgain() async throws {
        let record = try #require(UserDefaults(suiteName: paths.support.appending(path: "record").path))
        let network = BackfillNetwork(serveAll: true, moveFails: ["2026-01-02"])
        let now = TCGDate.date("2026-01-03T10:00:00")!
        await #expect(throws: ArchiveStoreError.self) {
            try await PriceSync(paths: paths, client: network, record: PriceDaysRecord(record))
                .run(games: Games.all, now: now, haveDay: nil)
        }
        #expect(record.stringArray(forKey: ArchiveDownloads.recordKey) == ["2026-01-02"])
        let second = BackfillNetwork(serveAll: true)
        _ = try await PriceSync(paths: paths, client: second, record: PriceDaysRecord(record))
            .run(games: Games.all, now: now, haveDay: nil)
        #expect(await second.calls == ["2026-01-01"])
    }
}

/// Phase 5B task 2 (K3, A47): the price step's tables come from the archive gate.
struct PriceSyncGateTests {
    let fake: FakeArchive
    let paths = AppPaths(root: tempRoot())
    init() { fake = FakeArchive() }

    @Test func thePriceStepDecodesOnceForTheTableAndTheDay() async throws {
        let reads = ArchiveGateTests.Reads()
        let gate = ArchiveGate(paths: paths, read: reads.read)
        let sync = PriceSync(paths: paths, client: fake, gate: gate)
        let out = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        #expect(reads.count == 1)
        #expect(out?["cyberpunk"]?.rows.count == 18)
        #expect(FileManager.default.fileExists(atPath: paths.priceDay("2026-01-02").path))
        #expect(!FileManager.default.fileExists(atPath: paths.archives.appending(path: "prices-2026-01-02.ppmd.7z").path))
        #expect(await gate.writtenCount == 1)
    }

    /// A day whose day file exists is never downloaded; its tables come from the day file.
    @Test func aDayWithADayFileIsNotDownloaded() async throws {
        let gate = ArchiveGate(paths: paths)
        let sync = PriceSync(paths: paths, client: fake, gate: gate)
        _ = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T10:00:00")!, haveDay: nil)
        let again = try await sync.run(games: Games.all, now: TCGDate.date("2026-01-03T11:00:00")!, haveDay: nil)
        #expect(await fake.calls == ["2026-01-02"])
        #expect(again?["riftbound"]?.day == "2026-01-02")
        // Not even when asked to download: the day file is the day.
        let turnedOn = try await sync.run(games: [Games.game("yu-gi-oh")!], now: TCGDate.date("2026-01-03T12:00:00")!,
                                          haveDay: nil, download: false)
        #expect(turnedOn?["yu-gi-oh"]?.day == "2026-01-02")
        #expect(await fake.calls == ["2026-01-02"])
    }
}
