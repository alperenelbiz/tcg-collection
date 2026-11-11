import Foundation
import Testing
@testable import TCGCollection2

/// The fake catalog has the 14 Riftbound sets (groups-89.json) and no set for the other games.
/// The fake archive has the fixture archive as the one of 2026-01-02, and not-an-archive.7z as the one of 2026-01-03.
struct AppModelTests {
    /// On this morning (UTC) the app asks for the archive of 2026-01-02.
    static let day1 = TCGDate.date("2026-01-03T10:00:00")!
    /// On this morning it asks for the archive of 2026-01-03.
    static let day2 = TCGDate.date("2026-01-04T10:00:00")!

    let log = CallLog()
    let fakeCatalog: FakeCatalog
    let fakeArchive: FakeArchive
    let fakeFetcher: FakeFetcher

    init() throws {
        fakeCatalog = FakeCatalog(groups: try fixture("groups-89.json"), products: try fixture("products-89.json"), log: log)
        fakeArchive = FakeArchive(files: ["2026-01-02": "prices-2026-01-02.ppmd.7z", "2026-01-03": "not-an-archive.7z"], log: log)
        fakeFetcher = FakeFetcher(body: try fixture("cardinfo-sample.json"), log: log)
    }

    @MainActor private func model(_ arguments: [String], now: @escaping () -> Date = { Self.day1 }) -> AppModel {
        AppModel(options: .init(arguments: arguments), catalogClient: fakeCatalog, archiveClient: fakeArchive,
                 fetcher: fakeFetcher, now: now)
    }

    @Test func statusLines() {
        #expect(StatusText.catalog(.init(gameID: "magic-the-gathering", done: 120, total: 457, failed: 0), gameName: "Magic: The Gathering") == "Magic: The Gathering: 120 / 457 sets")
        #expect(StatusText.catalog(.init(gameID: "yu-gi-oh", done: 9, total: 659, failed: 3), gameName: "Yu-Gi-Oh!") == "Yu-Gi-Oh!: 9 / 659 sets · 3 failed")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 0, newSets: [:]), priceDay: "2026-11-10") == "Catalog up to date · prices of 2026-11-10")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 3, newSets: [:]), priceDay: nil) == "Catalog: 3 sets failed, they are tried again next time · no prices yet")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 1, newSets: [:]), priceDay: nil) == "Catalog: 1 set failed, it is tried again next time · no prices yet")
        #expect(StatusText.offline(priceDay: "2026-11-10") == "Offline · prices of 2026-11-10")
        #expect(StatusText.pricesLoaded(day: "2026-11-10") == "Loaded prices of 2026-11-10")
        #expect(StatusText.pricesLoaded(day: nil) == "No prices yet")
    }

    /// I2: a set list that could not be loaded is counted apart from failed sets, and named.
    @Test func statusLineNamesTheSetListsThatCouldNotBeLoaded() {
        #expect(StatusText.done(result: .init(fetched: 0, failed: 0, failedSetLists: 4, newSets: [:]), priceDay: nil) == "Catalog: the set list of 4 games could not be loaded · no prices yet")
        #expect(StatusText.done(result: .init(fetched: 3, failed: 0, failedSetLists: 1, newSets: [:]), priceDay: "2026-11-10") == "Catalog: the set list of 1 game could not be loaded · prices of 2026-11-10")
        #expect(StatusText.done(result: .init(fetched: 3, failed: 2, failedSetLists: 1, newSets: [:]), priceDay: nil) == "Catalog: the set list of 1 game could not be loaded; 2 sets failed, they are tried again next time · no prices yet")
    }

    /// I2: no network at first launch. Every set list fails; the final status is a failure that names the catalog first.
    @MainActor @Test func aStartWhoseSetListsAllFailEndsInAFailureThatNamesTheCatalog() async {
        await fakeCatalog.failGroups(true)
        let model = model(["app", "-store", tempRoot().path])
        await model.start()
        #expect(model.status == .failed("Catalog: the set list of 4 games could not be loaded · prices of 2026-01-02"))
    }

    @MainActor @Test func startFillsCatalogPricesAndTheIndex() async throws {
        let model = model(["app", "-store", tempRoot().path])
        await model.start()
        #expect(try await model.store.progress(game: "riftbound").fetched == 14)
        #expect(model.reader !== model.store)                                    // the views read through their own store
        #expect(try await model.reader.progress(game: "riftbound").fetched == 14)
        #expect(model.prices.day(game: "riftbound") == "2026-01-02"); #expect(model.ygoIndex != nil)
        #expect(model.status == .idle("Catalog up to date · prices of 2026-01-02"))
        #expect(model.catalogVersion > 0)
    }

    /// Controller ruling: the game on screen gets its cards and prices first, then the other games in `Games.all` order.
    @MainActor @Test func theGameOnScreenComesFirstThenPricesThenTheOtherGames() async {
        let model = model(["app", "-store", tempRoot().path, "-game", "riftbound"])
        await model.start()
        #expect(await log.entries == ["groups 89", "archive 2026-01-02", "groups 1", "groups 2", "groups 92", "fetch cardinfo.php"])
    }

    /// I1: the sync belongs to the model, not to a window. The first window closes while the sync runs (its task is
    /// cancelled); a new window's `start()` waits for that same sync instead of starting a second one.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSecondStartWhileOneRunsStartsNoSecondSync() async throws {
        let model = model(["app", "-store", tempRoot().path])
        let firstWindow = Task { await model.start() }
        while await fakeCatalog.groupCalls == 0 { try await Task.sleep(for: .milliseconds(2)) }
        firstWindow.cancel()                                                         // the window closes
        await model.start()                                                          // a new window opens
        #expect(await fakeCatalog.groupCalls == 4)                                   // one set list per game: one sync
        #expect(try await model.store.progress(game: "riftbound") == SetProgress(total: 14, fetched: 14, failed: 0))
        #expect(model.status == .idle("Catalog up to date · prices of 2026-01-02"))
    }

    @MainActor @Test func offlineStartTouchesNoNetwork() async {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        #expect(await fakeCatalog.groupCalls == 0); #expect(await fakeArchive.calls.isEmpty); #expect(await fakeFetcher.calls == 0)
        #expect(model.status == .idle("Offline · no prices yet"))
    }

    @MainActor @Test func aBrokenArchiveKeepsTheOldPricesAndSaysSo() async throws {   // Review Focus 5
        var today = Self.day1
        let model = model(["app", "-store", tempRoot().path], now: { today })
        await model.start()
        #expect(model.prices.day(game: "riftbound") == "2026-01-02")
        today = Self.day2                                                            // the fake hands out not-an-archive.7z
        await model.refresh(rebuild: false)                                          // start() runs once per app run
        #expect(await fakeArchive.calls == ["2026-01-02", "2026-01-03"])
        #expect(model.prices.day(game: "riftbound") == "2026-01-02")
        if case .failed(let text) = model.status { #expect(text.hasPrefix("Prices:")) } else { Issue.record("no failure shown") }
    }

    /// I6: a store file that cannot be read is moved aside into `unreadable-<date>`; a fresh store at the normal path
    /// is filled by the sync.
    @MainActor @Test func anUnreadableStoreIsMovedAsideAndDownloadedAgain() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try Data("not a database".utf8).write(to: paths.catalogStore)
        let model = model(["app", "-store", root.path])
        #expect(model.status == .idle("The catalog could not be read and is downloaded again."))
        let aside = try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }
        let folder = try #require(aside.first)
        #expect(aside.count == 1)
        #expect(try String(contentsOf: paths.support.appending(path: "\(folder)/catalog.store"), encoding: .utf8) == "not a database")
        await model.start()
        #expect(try await model.store.progress(game: "riftbound").fetched == 14)
        #expect(model.status == .idle("Catalog up to date · prices of 2026-01-02"))
    }

    /// I6: when no fresh store can be made either (here: the support folder cannot be written), the store lives in
    /// memory, the status says so, and nothing is downloaded.
    @MainActor @Test func aStoreThatCannotBeMadeRunsInMemoryWithTheSyncOff() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try Data("not a database".utf8).write(to: paths.catalogStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.support.path) }
        let model = model(["app", "-store", root.path])
        #expect(model.canSync == false)
        await model.start()
        if case .failed(let text) = model.status { #expect(text.hasPrefix("Catalog: the store cannot be opened")) } else { Issue.record("no failure shown") }
        #expect(await fakeCatalog.groupCalls == 0)
        try await model.store.replaceProducts(of: 1, with: [product(id: 1)], at: .now)   // the store in memory works
        #expect(try await model.reader.product(1) != nil)
    }

    /// P8: only a file that is corrupt or not a database, or a failed migration, is moved aside. Here the store is
    /// healthy but its folder cannot be written: the file stays, the model runs in memory with the sync off.
    @MainActor @Test func aStoreThatCannotBeOpenedForAnotherReasonIsNotMoved() async throws {
        // the support folder is made read-only after a healthy store was written; the model starts in memory,
        // the store file is still at its path, no unreadable-… folder exists, and start() makes no network call
        let root = tempRoot()
        let paths = AppPaths(root: root)
        do {
            let store = try CatalogStore(url: paths.catalogStore)
            try await store.replaceProducts(of: 1, with: [product(id: 1)], at: .now)
        }
        // SQLite opens a store in a read-only folder while its -wal and -shm files exist (seen on macOS 27); without
        // them the open fails with SQLITE_READONLY_DIRECTORY.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: paths.catalogStore.path + suffix) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.support.path) }
        let model = model(["app", "-store", root.path])
        let inMemory = model.store.modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly }
        #expect(inMemory)
        #expect(model.canSync == false)
        await model.start()
        if case .failed(let text) = model.status { #expect(text.hasPrefix("Catalog: the store cannot be opened")) } else { Issue.record("no failure shown") }
        #expect(FileManager.default.fileExists(atPath: paths.catalogStore.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }.isEmpty)
        #expect(await fakeCatalog.groupCalls == 0); #expect(await fakeArchive.calls.isEmpty); #expect(await fakeFetcher.calls == 0)
    }

    /// P8 where a move would work: the folder can be written, but the store file cannot be read (no permission).
    /// Phase 1 moved such a file aside and downloaded everything again.
    @MainActor @Test func aStoreFileThatCannotBeReadIsNotMoved() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        do {
            let store = try CatalogStore(url: paths.catalogStore)
            try await store.replaceProducts(of: 1, with: [product(id: 1)], at: .now)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.catalogStore.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.catalogStore.path) }
        let model = model(["app", "-store", root.path])
        #expect(model.canSync == false)
        await model.start()
        if case .failed(let text) = model.status { #expect(text.hasPrefix("Catalog: the store cannot be opened (")) } else { Issue.record("no failure shown") }
        #expect(FileManager.default.fileExists(atPath: paths.catalogStore.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }.isEmpty)
        #expect(await fakeCatalog.groupCalls == 0)
    }

    @MainActor @Test func theChosenGameIsRemembered() {
        let root = tempRoot().path
        let first = model(["app", "-store", root])
        first.gameID = "cyberpunk"
        #expect(model(["app", "-store", root]).gameID == "cyberpunk")
        #expect(model(["app", "-store", root, "-game", "riftbound"]).gameID == "riftbound")   // -game wins
        #expect(model(["app", "-store", root, "-game", "pokemon"]).gameID == "cyberpunk")     // an unknown id is ignored
        #expect(model(["app", "-store", tempRoot().path]).gameID == "magic-the-gathering")   // another root, nothing saved
    }

    @Test func theYuGiOhIndexIsFetchedWhenMissingOrAtMostOnceADayForNewSets() {   // D9
        let morning = TCGDate.date("2026-11-11T08:00:00")!, evening = TCGDate.date("2026-11-11T21:00:00")!
        let yesterday = TCGDate.date("2026-11-10T21:00:00")!
        #expect(AppModel.needsYGOIndex(hasIndex: false, newSets: 0, writtenAt: nil, now: evening))
        #expect(AppModel.needsYGOIndex(hasIndex: true, newSets: 0, writtenAt: yesterday, now: evening) == false)
        #expect(AppModel.needsYGOIndex(hasIndex: true, newSets: 2, writtenAt: yesterday, now: evening))
        #expect(AppModel.needsYGOIndex(hasIndex: true, newSets: 2, writtenAt: morning, now: evening) == false)
    }
}
