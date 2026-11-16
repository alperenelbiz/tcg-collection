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
        #expect(StatusText.done(result: .init(fetched: 2, failed: 0, newSets: [:]), priceDay: "2026-11-10", rulesPending: 0) == "Catalog up to date · prices of 2026-11-10")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 0, newSets: [:]), priceDay: "2026-11-10", rulesPending: 3) == "Catalog up to date · 3 sets are updated tomorrow · prices of 2026-11-10")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 0, newSets: [:]), priceDay: nil, rulesPending: 1) == "Catalog up to date · 1 set is updated tomorrow · no prices yet")
        #expect(StatusText.done(result: .init(fetched: 2, failed: 1, newSets: [:]), priceDay: nil, rulesPending: 5) == "Catalog: 1 set failed, it is tried again next time · no prices yet")
        #expect(StatusText.offline(priceDay: "2026-11-10") == "Offline · prices of 2026-11-10")
        #expect(StatusText.pricesLoaded(day: "2026-11-10") == "Loaded prices of 2026-11-10")
        #expect(StatusText.pricesLoaded(day: nil) == "No prices yet")
    }

    /// I2: the status line and the empty screen while a fresh store waits for the next UTC day.
    @Test func theLineOfAStoreThatWaitsForTheNextDay() {
        #expect(StatusText.resetWaits == "The catalog is downloaded again tomorrow: its sets were already fetched today.")
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

    /// A removal alone (no set fetched) refreshes the menus, the version counters and the history: the Art Series set
    /// was stored and fetched today under rules version 2.
    @MainActor @Test func aRemovalAloneRefreshesTheStoreViews() async throws {
        let magic = Games.game("magic-the-gathering")!
        let body = Data(#"{"success":true,"errors":[],"results":[{"groupId":24684,"name":"Reality Fracture","abbreviation":"RF","publishedOn":"2026-10-02T00:00:00","categoryId":1},{"groupId":24690,"name":"Art Series: The Hobbit","abbreviation":"AH","publishedOn":"2026-10-02T00:00:00","categoryId":1}]}"#.utf8)
        let catalog = FakeCatalog(groups: body, products: try fixture("products-1.json"), category: 1, log: log)
        let root = tempRoot()
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path]), catalogClient: catalog,
                             archiveClient: fakeArchive, fetcher: fakeFetcher, now: { Self.day1 })
        let day = Self.day1
        try await model.store.upsertSets([SetRecord(groupID: 24690, gameID: magic.id, name: "Art Series: The Hobbit", abbreviation: "AH", publishedOn: nil)])
        try await model.store.replaceProducts(of: 24690, with: [product(id: 7, game: magic.id, groupID: 24690, name: "Smaug", number: "1", rarity: "Only Art Series", cardType: "Creature")], at: day)
        try await model.store.replaceProducts(of: 24684, with: try ProductParser.products(fixture("products-1.json"), game: magic).cards, at: day)
        try await model.store.setRulesVersion(2, game: magic.id)
        let before = (model.catalogVersion, model.filtersVersion)
        await model.start()
        #expect(await catalog.productCalls == 0)
        #expect(try await model.store.sets(game: magic.id).map(\.groupID) == [24684])
        #expect(try await model.store.search(game: magic.id, text: "", filter: .init(groupID: 24690), limit: 10).isEmpty)
        #expect(model.catalogVersion > before.0); #expect(model.filtersVersion > before.1)
        let lists = try #require(FacetLists.read(model.paths.facets(magic.id)))
        #expect(!lists.rarities.contains("Only Art Series"))
        #expect(!lists.rarities.isEmpty)
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

    /// Fix round 2, item 1: a game's catalog is settled once its catalog step of the running sync has ended, also with
    /// failed sets; before that (from launch, while due) and while it runs it is not. The price step runs between the game
    /// on screen and the other games: there the first is settled and the others are not.
    @MainActor @Test(.timeLimit(.minutes(1))) func aGamesCatalogIsSettledWhenItsStepHasEnded() async throws {
        let archive = GatedArchive()
        let model = AppModel(options: .init(arguments: ["app", "-store", tempRoot().path, "-game", "riftbound"]),
                             catalogClient: fakeCatalog, archiveClient: archive, fetcher: fakeFetcher, now: { Self.day1 })
        #expect(!model.catalogSettled(game: "riftbound"))                           // due in this run
        let run = Task { await model.start() }
        while await !archive.called { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.catalogSettled(game: "riftbound"))                            // its step ended; prices run
        #expect(!model.catalogSettled(game: "cyberpunk"))                           // still due
        await archive.release()
        await run.value
        #expect(Games.all.allSatisfy { model.catalogSettled(game: $0.id) })
    }

    @MainActor @Test func aStepWithFailedSetsEndsSettledAndOfflineIsSettled() async throws {
        await fakeCatalog.failEveryCall(after: 5)
        let model = model(["app", "-store", tempRoot().path])
        await model.start()
        #expect(try await model.store.progress(game: "riftbound").failed == 9)
        #expect(model.catalogSettled(game: "riftbound"))
        let offline = self.model(["app", "-store", tempRoot().path, "-offline", "YES"])
        #expect(offline.catalogSettled(game: "riftbound"))                          // no step in this run
    }

    /// `-exportPDF`: the screen it names takes the file once; another screen gets nothing.
    @MainActor @Test func theLaunchPDFIsTakenOnceByItsScreen() {
        let root = tempRoot()
        let file = root.appending(path: "out.pdf")
        let model = model(["app", "-store", root.path, "-offline", "YES", "-screen", "for-sale", "-exportPDF", file.path])
        #expect(model.takeLaunchPDF(for: .wanted) == nil)
        #expect(model.takeLaunchPDF(for: .forSale)?.path == file.path)
        #expect(model.takeLaunchPDF(for: .forSale) == nil)
        let outside = self.model(["app", "-store", root.path, "-offline", "YES", "-screen", "for-sale", "-exportPDF",
                                  tempRoot().appending(path: "out.pdf").path])
        #expect(outside.takeLaunchPDF(for: .forSale) == nil)
    }

    /// The save panel of a PDF ended: a failure that is not a cancel is said in the status line; a save or a cancel is not.
    @MainActor @Test func aFailedPDFSaveIsSaidInTheStatusLine() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        model.pdfSaveEnded(.failure(CocoaError(.userCancelled)))
        #expect(model.statusNotice == nil)
        model.pdfSaveEnded(.success(URL(fileURLWithPath: "/tmp/riftbound-wanted-2026-11-13.pdf")))
        #expect(model.statusNotice == nil)
        let error = CocoaError(.fileWriteOutOfSpace)
        model.pdfSaveEnded(.failure(error))
        #expect(model.statusNotice == "The PDF could not be saved: \(error.localizedDescription)")
    }

    /// E8: the status line says it once when the count of pending cards goes up; a first value (the base after the
    /// folder's first read) says nothing.
    @Test func thePendingNoticeOnlyWhenTheCountGoesUp() {
        #expect(AppModel.pendingNotice(was: 0, now: 1) == "1 card needs a sharing decision.")
        #expect(AppModel.pendingNotice(was: 1, now: 3) == "3 cards need a sharing decision.")
        #expect(AppModel.pendingNotice(was: 3, now: 3) == nil)
        #expect(AppModel.pendingNotice(was: 3, now: 1) == nil)
        #expect(AppModel.pendingNotice(was: nil, now: 3) == nil)
        #expect(AppModel.pendingNotice(was: nil, now: 0) == nil)
    }

    /// E8 on the model: the first known count of a game is its base (cards already pending at launch say nothing); a
    /// count that goes up says it; an unknown count (no read yet) changes nothing; another game starts a new base.
    @MainActor @Test func thePendingCountOfTheGameOnScreenIsSaidWhenItGoesUp() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-game", "riftbound"])
        model.pendingCountChanged(nil, game: "riftbound")
        model.pendingCountChanged(2, game: "riftbound")
        #expect(model.statusNotice == nil)
        model.pendingCountChanged(nil, game: "riftbound")
        model.pendingCountChanged(2, game: "riftbound")
        #expect(model.statusNotice == nil)
        model.pendingCountChanged(1, game: "riftbound")
        #expect(model.statusNotice == nil)
        model.pendingCountChanged(2, game: "riftbound")
        #expect(model.statusNotice == "2 cards need a sharing decision.")
        model.gameID = "yu-gi-oh"
        model.pendingCountChanged(2, game: "riftbound")                 // a late value of the old game: not the base
        model.pendingCountChanged(4, game: "yu-gi-oh")
        #expect(model.statusNotice == "2 cards need a sharing decision.")
        model.pendingCountChanged(5, game: "yu-gi-oh")
        #expect(model.statusNotice == "5 cards need a sharing decision.")
    }

    /// Final fix A2: the pending notice never replaces the for-sale clamp notice; it waits and is said, with the count of
    /// that moment, once the clamp notice is gone.
    @MainActor @Test(.timeLimit(.minutes(1))) func thePendingNoticeWaitsBehindTheClampNotice() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-game", "riftbound"])
        await model.start()
        model.noticeDuration = .milliseconds(300)
        model.pendingCountChanged(0, game: "riftbound")
        let key = PrintingKey(productID: 1, finish: "Normal")
        model.library.setCount(3, game: "riftbound", key: key, name: "A")
        model.library.setForSale(3, game: "riftbound", key: key, name: "A")
        model.library.setCount(1, game: "riftbound", key: key, name: "")
        try await until { model.statusNotice == "2 copies are no longer for sale." }
        model.pendingCountChanged(1, game: "riftbound")
        #expect(model.statusNotice == "2 copies are no longer for sale.")
        model.pendingCountChanged(2, game: "riftbound")
        #expect(model.statusNotice == "2 copies are no longer for sale.")
        try await until { model.statusNotice == "2 cards need a sharing decision." }
        try await until { model.statusNotice == nil }                            // said once
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.statusNotice == nil)
    }

    /// Final fix A2: behind an import's summary ("Imported: …") the pending notice waits, then is said.
    @MainActor @Test(.timeLimit(.minutes(1))) func thePendingNoticeWaitsBehindAnImportsSummary() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-game", "riftbound"])
        await model.start()
        model.noticeDuration = .milliseconds(300)
        model.pendingCountChanged(0, game: "riftbound")
        await model.importApplied(.init(gameID: "riftbound", games: ["riftbound"], summary: "2 new"))
        #expect(model.statusNotice == "Imported: 2 new")
        model.pendingCountChanged(1, game: "riftbound")
        #expect(model.statusNotice == "Imported: 2 new")
        try await until { model.statusNotice == "1 card needs a sharing decision." }
    }

    /// Final fix A2: a pending notice that waited is not said when the count is back at or under its base by the time the
    /// other notice is gone.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWaitingPendingNoticeIsDroppedWhenTheCountFallsBack() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-game", "riftbound"])
        await model.start()
        model.noticeDuration = .milliseconds(300)
        model.pendingCountChanged(1, game: "riftbound")
        await model.importApplied(.init(gameID: "riftbound", games: ["riftbound"], summary: "2 new"))
        model.pendingCountChanged(3, game: "riftbound")
        model.pendingCountChanged(1, game: "riftbound")
        #expect(model.statusNotice == "Imported: 2 new")
        try await until { model.statusNotice == nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.statusNotice == nil)
    }

    /// Final fix A1: the sharing sheet's flag never outlives the sheet: its dismissal, and Wanted going away under it, clear
    /// the flag and the window's rows, so `showsSheet` is false again when no other sheet is open.
    @MainActor @Test func theSharingSheetsFlagEndsWithTheSheet() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        let state = WantedScreenState(gameID: "riftbound")
        let need = CardNeed(cardKey: "x", name: "X", users: [], owned: 0, answer: nil, isBasic: false, sum: 2, need: 2,
                            inConflict: true, pending: true, fromDecks: 2)
        state.sharingNeeds = [need]
        model.showsSharing = true
        #expect(model.showsSheet)
        state.endSharing(model: model)                  // the sheet's onDismiss and Wanted's onDisappear
        #expect(!model.showsSharing && !model.showsSheet && state.sharingNeeds.isEmpty)
        // With another sheet open, `showsSheet` stays true for that one.
        state.sharingNeeds = [need]
        model.showsSharing = true
        model.showsNewDeck = true
        state.endSharing(model: model)
        #expect(!model.showsSharing && model.showsSheet && state.sharingNeeds.isEmpty)
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

    /// Feedback 1: the launch cleans the picture cache once, in the background, in the folder of the run's root
    /// (`<root>/caches/pictures`): here the old small pictures go, a full-size one and the price archives stay.
    @MainActor @Test func theLaunchCleansThePictureCacheOfItsRoot() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.pictures, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.archives, withIntermediateDirectories: true)
        let small = paths.pictures.appending(path: "tcgplayer-cdn.tcgplayer.com-product-1_200w.jpg")
        let full = paths.pictures.appending(path: "tcgplayer-cdn.tcgplayer.com-product-1_in_1000x1000.jpg")
        let archive = paths.archives.appending(path: "prices-2026-01-02.ppmd.7z")
        for file in [small, full, archive] { try Data(repeating: 1, count: 2000).write(to: file) }
        #expect(paths.pictures == root.appending(path: "caches/pictures", directoryHint: .isDirectory))
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.pictureCleaning == nil)                                        // not before the launch
        await model.start()
        let deleted = await model.pictureCleaning?.value
        #expect(deleted == ["tcgplayer-cdn.tcgplayer.com-product-1_200w.jpg"])
        #expect(!fm.fileExists(atPath: small.path))
        #expect(fm.fileExists(atPath: full.path) && fm.fileExists(atPath: archive.path))
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

    /// P8 (as changed by fix round 1 of task 4): only a file that is corrupt or not a database is moved aside; a failed
    /// migration keeps the file. Here the store is healthy but its folder cannot be written: the file stays, the model
    /// runs in memory with the sync off.
    @MainActor @Test func aStoreThatCannotBeOpenedForAnotherReasonIsNotMoved() async throws {
        // the support folder is made read-only after a healthy store was written; the model starts in memory,
        // the store file is still at its path, no unreadable-… folder exists, and start() makes no network call
        let root = tempRoot()
        let paths = AppPaths(root: root)
        // SQLite opens a store in a read-only folder while its -wal and -shm files exist (seen on macOS 27); without
        // them the open fails with SQLITE_READONLY_DIRECTORY. `writeClosedStore` leaves none.
        try await writeClosedStore(at: paths.catalogStore)
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
        try await writeClosedStore(at: paths.catalogStore)
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

    /// Fix round 1, item 1: a store whose schema this build does not know is a readable database (Core Data reads its
    /// metadata). It is kept: in memory, sync off, and a text that says what to do.
    @MainActor @Test func aStoreOfAnUnknownSchemaIsKept() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try ForeignSchema.writeStore(at: paths.catalogStore)
        let model = model(["app", "-store", root.path])
        #expect(model.canSync == false)
        await model.start()
        #expect(model.status == .failed("This catalog was written by a newer version of the app. Update the app, or reset the catalog."))
        #expect(FileManager.default.fileExists(atPath: paths.catalogStore.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }.isEmpty)
        #expect(await fakeCatalog.groupCalls == 0)
    }

    /// M8: a store kept for lack of disk space offers no reset: a reset frees nothing and downloads onto a full disk. A
    /// store kept for another reason offers one; a store that opens needs none.
    @MainActor @Test func aStoreKeptForLackOfSpaceOffersNoReset() async throws {
        let root = tempRoot()
        try await writePhase1Store(at: AppPaths(root: root).catalogStore)          // it needs a migration
        let full = AppModel(options: .init(arguments: ["app", "-store", root.path]), catalogClient: fakeCatalog,
                            archiveClient: fakeArchive, fetcher: fakeFetcher, now: { Self.day1 }, availableCapacity: { _ in 0 })
        #expect(full.storeFailure?.hasPrefix("Not enough free disk space to update the catalog") == true)
        #expect(full.canResetCatalog == false)

        let foreign = tempRoot()
        try ForeignSchema.writeStore(at: AppPaths(root: foreign).catalogStore)
        #expect(model(["app", "-store", foreign.path]).canResetCatalog)
        #expect(model(["app", "-store", tempRoot().path]).canResetCatalog == false)
    }

    /// A store file cut short: Core Data cannot read its metadata (SQLITE_CORRUPT). It is moved aside and downloaded again.
    @MainActor @Test func aTruncatedStoreIsMovedAsideAndDownloadedAgain() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore)
        let handle = try FileHandle(forUpdating: paths.catalogStore)
        try handle.truncate(atOffset: 8192)
        try handle.close()
        let model = model(["app", "-store", root.path])
        #expect(model.status == .idle("The catalog could not be read and is downloaded again."))
        let aside = try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }
        #expect(aside.count == 1)
        await model.start()
        #expect(try await model.store.progress(game: "riftbound").fetched == 14)
    }

    /// Fix round 1, item 2: in the store-failure state "Reset the catalog…" sets a flag in the model's preferences. The
    /// next launch on the same root sets the store aside, opens a fresh one, clears the flag, and syncs normally.
    @MainActor @Test func aResetAskedForAfterAStoreFailureHappensAtTheNextLaunch() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try ForeignSchema.writeStore(at: paths.catalogStore)                   // kept: the model runs in memory
        let failed = model(["app", "-store", root.path])
        #expect(failed.storeFailure == StatusText.storeFromNewerVersion)
        #expect(failed.catalogResetRequested == false)
        failed.requestCatalogReset()
        #expect(failed.catalogResetRequested)
        let preferences = try #require(UserDefaults(suiteName: paths.support.appending(path: "preferences").path))
        #expect(preferences.bool(forKey: "resetCatalogOnNextLaunch"))

        let next = model(["app", "-store", root.path])                         // the next launch
        #expect(next.storeFailure == nil); #expect(next.canSync)
        #expect(next.status == .idle("The catalog was reset and is downloaded again."))
        #expect(preferences.bool(forKey: "resetCatalogOnNextLaunch") == false)
        let aside = try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }
        let folder = try #require(aside.first)
        #expect(aside.count == 1)
        #expect(FileManager.default.fileExists(atPath: paths.support.appending(path: "\(folder)/catalog.store").path))
        await next.start()
        #expect(try await next.store.progress(game: "riftbound").fetched == 14)
        #expect(next.status == .idle("Catalog up to date · prices of 2026-01-02"))
    }

    /// The status line and the empty screen while the catalog sync waits for the next UTC day.
    private static let waits = "The catalog is downloaded again tomorrow: its sets were already fetched today."

    /// The model's preferences of a store root (`<root>/support/preferences.plist`).
    private func preferences(_ root: URL) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: AppPaths(root: root).support.appending(path: "preferences").path))
    }

    /// I2, controller ruling 2: tcgcsv's day rule outlives the store. After a reset on the UTC day of a fetch, the catalog
    /// sync waits for the next UTC day: in the launch that sets the store aside (also Refresh, Rebuild and Try again)
    /// and in every later launch that day. One UTC day later the sync runs. The price and index steps keep their own
    /// once-a-day rules: here they find the day's prices and the index on disk and ask for nothing.
    @MainActor @Test func aResetOnTheDayOfAFetchWaitsForTheNextUTCDay() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let preferences = try self.preferences(root)
        do {                                                                    // the launch that fetches, on day1
            let first = model(["app", "-store", root.path])
            await first.start()
            #expect(try await first.store.progress(game: "riftbound").fetched == 14)
            #expect(preferences.string(forKey: "lastCatalogFetchDay") == "2026-01-03")
            first.requestCatalogReset()
        }
        try await waitUntilClosed(paths.catalogStore)                           // the app has quit
        let groups = await fakeCatalog.groupCalls, products = await fakeCatalog.productCalls
        let archives = await fakeArchive.calls, fetches = await fakeFetcher.calls

        let reset = model(["app", "-store", root.path])                         // the reset launch, the same UTC day
        #expect(reset.status == .idle(Self.waits)); #expect(reset.catalogWaits) // the move alone says so, before a read
        await reset.start()
        await reset.refresh(rebuild: false)                                      // Refresh, and Try again
        await reset.refresh(rebuild: true)                                       // Rebuild
        #expect(reset.status == .idle(Self.waits)); #expect(reset.catalogWaits) // the empty screen: no Try again
        #expect(try await reset.store.progress(game: "riftbound").fetched == 0) // the fresh store
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("unreadable-") }.count == 1)

        let later = model(["app", "-store", root.path])                         // a later launch, the same UTC day
        await later.start()
        #expect(later.catalogWaits); #expect(later.status == .idle(Self.waits))
        #expect(await fakeCatalog.groupCalls == groups); #expect(await fakeCatalog.productCalls == products)
        #expect(await fakeArchive.calls == archives); #expect(await fakeFetcher.calls == fetches)

        let tomorrow = model(["app", "-store", root.path], now: { Self.day2 })  // a launch one UTC day later
        await tomorrow.start()
        #expect(tomorrow.catalogWaits == false)
        #expect(await fakeCatalog.groupCalls == groups + 4); #expect(await fakeCatalog.productCalls == products + 14)
        #expect(try await tomorrow.store.progress(game: "riftbound").fetched == 14)
        #expect(preferences.string(forKey: "lastCatalogFetchDay") == "2026-01-04")
    }

    /// I2, the other way a store is set aside: a file that cannot be read, on the UTC day of the last fetch.
    @MainActor @Test func anUnreadableStoreOnTheDayOfAFetchWaitsForTheNextUTCDay() async throws {
        let root = tempRoot()
        try preferences(root).set("2026-01-03", forKey: "lastCatalogFetchDay")
        try Data("not a database".utf8).write(to: AppPaths(root: root).catalogStore)
        let model = model(["app", "-store", root.path])
        #expect(model.status == .idle(Self.waits))
        await model.start()
        #expect(await fakeCatalog.groupCalls == 0); #expect(await fakeCatalog.productCalls == 0)
        #expect(model.status == .idle(Self.waits))
    }

    /// I2, must not hold: a brand-new install has no `lastCatalogFetchDay`.
    @MainActor @Test func aBrandNewInstallIsNotHeld() async throws {
        let root = tempRoot()
        #expect(try preferences(root).string(forKey: "lastCatalogFetchDay") == nil)
        let model = model(["app", "-store", root.path])
        await model.start()
        #expect(model.catalogWaits == false)
        #expect(await fakeCatalog.groupCalls == 4); #expect(await fakeCatalog.productCalls == 14)
    }

    /// I2, must not hold: a first download cut short on the day it ran. The day is today, but the store has fetched
    /// sets: the next launch that day fetches the remaining sets.
    @MainActor @Test func aFirstDownloadCutShortGoesOnTheSameDay() async throws {
        let root = tempRoot()
        await fakeCatalog.failEveryCall(after: 5)                                // the network drops after 5 sets
        do {
            let first = model(["app", "-store", root.path])
            await first.start()
            #expect(try await first.store.progress(game: "riftbound").fetched == 5)
        }
        #expect(try preferences(root).string(forKey: "lastCatalogFetchDay") == "2026-01-03")
        await fakeCatalog.failEveryCall(after: nil)
        await fakeCatalog.resetCounts()
        let next = model(["app", "-store", root.path])                           // the same UTC day
        await next.start()
        #expect(next.catalogWaits == false)
        #expect(await fakeCatalog.productCalls == 9)                             // the 9 sets not fetched yet
        #expect(try await next.store.progress(game: "riftbound").fetched == 14)
    }

    /// I2, must not hold: the next UTC day. The store file is gone (deleted by hand) on the day of a fetch: the sync
    /// waits. When the clock passes midnight UTC, Refresh runs it.
    @MainActor @Test func theNextUTCDayIsNotHeld() async throws {
        let root = tempRoot()
        try preferences(root).set("2026-01-03", forKey: "lastCatalogFetchDay")
        var today = Self.day1
        let model = model(["app", "-store", root.path], now: { today })
        await model.start()
        #expect(model.catalogWaits); #expect(await fakeCatalog.groupCalls == 0)
        // Not held: this root has no prices and no index yet, so the price and index steps fetch them once.
        #expect(await fakeArchive.calls == ["2026-01-02"]); #expect(await fakeFetcher.calls == 1)
        #expect(model.status == .idle(Self.waits))
        today = Self.day2
        await model.refresh(rebuild: false)
        #expect(model.catalogWaits == false)
        #expect(await fakeCatalog.groupCalls == 4); #expect(await fakeCatalog.productCalls == 14)
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

    /// The sidebar selection is kept in the root's preferences (key `screen`); a new root opens on the Collection.
    @MainActor @Test func theChosenScreenIsRemembered() {
        let root = tempRoot().path
        let first = model(["app", "-store", root])
        #expect(first.screen == .collection)
        first.screen = .allCards
        #expect(model(["app", "-store", root]).screen == .allCards)
        #expect(model(["app", "-store", root, "-screen", "collection"]).screen == .collection)   // -screen wins
        #expect(model(["app", "-store", root, "-screen", "sold"]).screen == .allCards)           // an unknown name is ignored
        #expect(model(["app", "-store", tempRoot().path]).screen == .collection)                 // another root, nothing saved
        model(["app", "-store", root]).screen = .forSale
        #expect(model(["app", "-store", root]).screen == .forSale)
        #expect(model(["app", "-store", root, "-screen", "for-sale"]).screen == .forSale)
        model(["app", "-store", root]).screen = .wanted
        #expect(model(["app", "-store", root]).screen == .wanted)
        #expect(model(["app", "-store", root, "-screen", "wanted"]).screen == .wanted)
    }

    /// Phase 3A: a deck screen is stored as `deck:<id>`. A stored or launched deck that is not in the game's file once the
    /// folder is read opens the Collection; one that is there stays. A game switch leaves a deck screen for the Collection
    /// (a deck belongs to one game).
    @MainActor @Test func aDeckScreenIsRememberedAndFallsBackWhenItsDeckIsGone() async throws {
        let root = tempRoot()
        let user = AppPaths.userTestRoot(root)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data(#"{"version":1,"decks":[{"id":"kept","name":"K","format":"standard","active":false,"cards":[]}]}"#.utf8)
            .write(to: user.appending(path: "riftbound.json"))
        let first = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound"])
        first.screen = .deck("kept")
        let again = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound"])
        #expect(again.screen == .deck("kept"))
        await again.start()
        #expect(again.screen == .deck("kept"))
        again.gameID = "cyberpunk"
        #expect(again.screen == .collection)

        let launched = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "deck:gone"])
        #expect(launched.screen == .deck("gone"))
        await launched.start()
        #expect(launched.screen == .collection)
    }

    /// The New Deck sheet is one of the app's sheets: For Sale's Sold dialog does not open again under it.
    @MainActor @Test func theNewDeckSheetCountsAsASheet() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        #expect(!model.showsSheet)
        model.showsNewDeck = true
        #expect(model.showsSheet)
    }

    /// `-card` opens a card page, which lives under All cards: the screen follows, whatever `-screen` says.
    @MainActor @Test func aLaunchCardShowsAllCards() async throws {
        let root = tempRoot()
        try await writeClosedStore(at: AppPaths(root: root).catalogStore,
                                   products: try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!).cards)
        let model = model(["app", "-store", root.path, "-offline", "YES", "-screen", "collection", "-card", "721334"])
        #expect(model.screen == .collection)
        await model.start()
        #expect(model.pendingCard?.startProductID == 721334); #expect(model.screen == .allCards)
    }

    @Test func theYuGiOhIndexIsFetchedWhenMissingOrAtMostOnceADayForNewSets() {   // D9
        let morning = TCGDate.date("2026-11-11T08:00:00")!, evening = TCGDate.date("2026-11-11T21:00:00")!
        let yesterday = TCGDate.date("2026-11-10T21:00:00")!
        func needs(_ hasIndex: Bool, current: Bool = true, newSets: Int = 0, attempted: Bool = false, written: Date?) -> Bool {
            AppModel.needsYGOIndex(hasIndex: hasIndex, isCurrent: current, newSets: newSets, attemptedToday: attempted,
                                   writtenAt: written, now: evening)
        }
        #expect(needs(false, written: nil))
        #expect(needs(true, written: yesterday) == false)
        #expect(needs(true, newSets: 2, written: yesterday))
        #expect(needs(true, newSets: 2, written: morning) == false)
        // An index of an older version (no types) is fetched once, not on the day it was written, and without new sets.
        #expect(needs(true, current: false, written: yesterday))
        #expect(needs(true, current: false, written: morning) == false)
        #expect(needs(true, current: false, written: nil))
        #expect(needs(true, current: true, written: yesterday) == false)
        // A request already made today (it may have failed) forbids another, in every case.
        #expect(needs(false, attempted: true, written: nil) == false)
        #expect(needs(true, current: false, attempted: true, written: yesterday) == false)
        #expect(needs(true, newSets: 3, attempted: true, written: yesterday) == false)
    }

    /// A failing `cardinfo.php` is asked once per UTC day: a second sync step the same day sends nothing.
    @MainActor @Test func aFailedYuGiOhIndexRequestIsNotRepeatedTheSameDay() async throws {
        let failing = FakeFetcher(body: Data(), status: 503)
        let root = tempRoot()
        let make = {
            AppModel(options: .init(arguments: ["app", "-store", root.path]), catalogClient: self.fakeCatalog,
                     archiveClient: self.fakeArchive, fetcher: failing, now: { Self.day1 })
        }
        let first = make()
        await first.start()
        #expect(await failing.calls == 1 && first.ygoIndex == nil)
        await first.refresh(rebuild: false)
        await make().start()                                                       // another launch, same root and day
        #expect(await failing.calls == 1)
    }

    @MainActor @Test func theFilterListsAreWrittenAfterASyncAndReadAtTheNextLaunch() async throws {
        let root = tempRoot()
        let first = model(["app", "-store", root.path])
        #expect(first.facets(game: "riftbound") == nil)
        await first.start()
        let paths = AppPaths(root: root)
        let lists = try #require(first.facets(game: "riftbound"))
        #expect(lists.types.contains("Gear")); #expect(FacetLists.read(paths.facets("riftbound")) == lists)
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(second.facets(game: "riftbound") == lists)                          // before any store read
    }

    /// F3: a launch on a root with products and no sets file makes the file and the index, also offline; a game without
    /// products gets none.
    @MainActor @Test func aMissingSetIndexIsMadeFromTheStoreAtLaunch() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore,
                                   products: [product(id: 2, number: "10"), product(id: 1, number: "2"), product(id: 3, number: "")])
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.setIndexes["riftbound"] == nil)
        await model.start()
        await model.waitForSetIndexes()
        #expect(model.setIndexes["riftbound"] == SetIndex(sets: [1: [1, 2, 3]]))
        #expect(SetIndex.read(paths.sets("riftbound")) == model.setIndexes["riftbound"])
        #expect(model.setIndexes["yu-gi-oh"] == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.sets("yu-gi-oh").path))
    }

    /// F3: a launch with the sets file reads it before any store read and does not scan: a made-up file that differs
    /// from the store is kept as it is.
    @MainActor @Test func aSetIndexFileIsReadAtLaunchWithoutAScan() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: [product(id: 1, number: "1")])
        let first = model(["app", "-store", root.path, "-offline", "YES"])
        await first.start()                                                         // makes the facets and sets files
        await first.waitForSetIndexes()
        #expect(first.setIndexes["riftbound"] == SetIndex(sets: [1: [1]]))
        let madeUp = SetIndex(sets: [77: [5, 6]])
        try madeUp.write(to: paths.sets("riftbound"))
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(!second.setIndexIsDue("riftbound"))                                  // a file and no mark
        var scanned: [String] = []
        second.setIndexScanHook = { scanned.append($0) }
        await second.start()
        await second.waitForSetIndexes()
        #expect(second.setIndexes["riftbound"] == madeUp)                            // no scan replaced it
        #expect(SetIndex.read(paths.sets("riftbound")) == madeUp)
        #expect(!scanned.contains("riftbound"))
    }

    /// Final fix A1: the files are read by the launch, off the main actor, not by `init`: a new model has no index (the
    /// first window's state does not wait for the read) and every game counts as in work until the launch has read them;
    /// the launch then sets the file's index, raises its version, and scans nothing.
    @MainActor @Test func theSetIndexFilesAreReadByTheLaunchNotByInit() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: [product(id: 1, number: "1")])
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let madeUp = SetIndex(sets: [77: [5, 6]])
        try madeUp.write(to: paths.sets("riftbound"))
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.setIndexes.isEmpty)
        #expect(model.setIndexVersions.isEmpty)
        #expect(model.setIndexInWork("riftbound"))
        var scanned: [String] = []
        model.setIndexScanHook = { scanned.append($0) }
        await model.start()
        await model.waitForSetIndexes()
        #expect(model.setIndexes["riftbound"] == madeUp)
        #expect(model.setIndexVersions["riftbound"] == 1)
        #expect(!scanned.contains("riftbound"))
        #expect(!model.setIndexInWork("riftbound"))
        #expect(model.setIndexesInWork.isEmpty)
    }

    /// Final fix A3: a catalog step that changed a game marks its index due at its first set; when the index is not
    /// stored (here: the scan fails, as a quit before it would leave it), the next launch scans the game although its file
    /// exists, and clears the mark once the index is stored.
    @MainActor @Test func aDueSetIndexSurvivesAQuitAndIsScannedAtTheNextLaunch() async throws {
        struct Failed: Error {}
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let madeUp = SetIndex(sets: [77: [5, 6]])
        try madeUp.write(to: paths.sets("riftbound"))
        let first = model(["app", "-store", root.path])
        first.setIndexScanHook = { _ in throw Failed() }
        await first.start()                                                          // the step stores the 14 sets
        await first.waitForSetIndexes()
        #expect(first.setIndexIsDue("riftbound"))
        #expect(!first.setIndexIsDue("yu-gi-oh"))                                    // no set of it in the fake catalog
        #expect(SetIndex.read(paths.sets("riftbound")) == madeUp)
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        var scanned: [String] = []
        second.setIndexScanHook = { scanned.append($0) }
        await second.start()
        await second.waitForSetIndexes()
        #expect(scanned == ["riftbound"])
        let index = try #require(second.setIndexes["riftbound"])
        #expect(index != madeUp)
        #expect(!index.sets.isEmpty)
        #expect(SetIndex.read(paths.sets("riftbound")) == index)
        #expect(!second.setIndexIsDue("riftbound"))                                  // cleared after the scan
        let third = model(["app", "-store", root.path, "-offline", "YES"])
        scanned = []
        third.setIndexScanHook = { scanned.append($0) }
        await third.start()
        await third.waitForSetIndexes()
        #expect(scanned.isEmpty)                                                     // a file and no mark: no scan
    }

    /// Final fix follow-up: a store that runs in memory (its file could not be opened) never writes an index file: a
    /// marked game is not scanned (the empty store would write `{}` over a good file), and its mark stays; a game
    /// without a file is not scanned either.
    @MainActor @Test func aStoreInMemoryWritesNoIndexAndKeepsTheMarks() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try ForeignSchema.writeStore(at: paths.catalogStore)                        // kept: the model runs in memory
        let good = SetIndex(sets: [77: [5, 6]])
        try good.write(to: paths.sets("riftbound"))
        let bytes = try Data(contentsOf: paths.sets("riftbound"))
        let preferences = try #require(UserDefaults(suiteName: paths.support.appending(path: "preferences").path))
        AppModel.markSetIndexDue("riftbound", in: preferences)
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.storeFailure != nil)
        var scanned: [String] = []
        model.setIndexScanHook = { scanned.append($0) }
        await model.start()
        await model.waitForSetIndexes()
        model.requestSetIndex("yu-gi-oh")                                            // a request in this run too
        await model.waitForSetIndexes()
        #expect(scanned.isEmpty)
        #expect(try Data(contentsOf: paths.sets("riftbound")) == bytes)
        #expect(model.setIndexes["riftbound"] == good)                               // the file is still read
        #expect(model.setIndexIsDue("riftbound"))
        #expect(!FileManager.default.fileExists(atPath: paths.sets("yu-gi-oh").path))
        #expect(model.setIndexesInWork.isEmpty)
    }

    /// A3: the mark of an index stored while the game's catalog step is still to come stays until that step ends; a step
    /// that does not change the game then clears it (no scan needed), so an online launch does not scan the game again.
    @MainActor @Test func aDueMarkStoredDuringItsStepIsClearedWhenTheStepChangesNothing() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let first = model(["app", "-store", root.path])
        await first.start()
        await first.waitForSetIndexes()
        #expect(!first.setIndexIsDue("riftbound"))
        // A mark left by a step cut short: the next launch (same UTC day: nothing is fetched again) scans the game during
        // its pending step, then the step ends without a change.
        AppModel.markSetIndexDue("riftbound", in: UserDefaults(suiteName: paths.support.appending(path: "preferences").path)!)
        let second = model(["app", "-store", root.path])
        var scanned: [String] = []
        second.setIndexScanHook = { scanned.append($0) }
        await second.start()
        await second.waitForSetIndexes()
        #expect(scanned == ["riftbound"])
        #expect(!second.setIndexIsDue("riftbound"))
    }

    /// F3: a catalog step that changed a game writes its set index after its facets file, once the step has told the
    /// menus; the next launch reads it.
    @MainActor @Test func theSetIndexIsWrittenAfterASync() async throws {
        let root = tempRoot()
        let first = model(["app", "-store", root.path])
        var seen: [(game: String, facets: Bool)] = []
        first.setIndexScanHook = { game in seen.append((game, first.facets(game: game) != nil)) }
        await first.start()
        await first.waitForSetIndexes()
        let index = try #require(first.setIndexes["riftbound"])
        #expect(!index.sets.isEmpty)
        #expect(SetIndex.read(AppPaths(root: root).sets("riftbound")) == index)
        let riftbound = seen.filter { $0.game == "riftbound" }
        let afterFacets = riftbound.allSatisfy { $0.facets }
        #expect(!riftbound.isEmpty); #expect(afterFacets)
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        await second.start()
        await second.waitForSetIndexes()
        #expect(second.setIndexes["riftbound"] == index)
    }

    /// The owner's first launch after phase 4A: facets files, no sets files. The facets are not scanned again, and the
    /// launch (its sync, prices and settled state) ends while every index scan is still held; the index comes after.
    @MainActor @Test func aLaunchWithFacetsAndNoSetIndexDoesNotWaitForTheIndex() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        let first = model(["app", "-store", root.path])
        await first.start()
        await first.waitForSetIndexes()
        let made = try #require(first.setIndexes["riftbound"])
        try FileManager.default.removeItem(at: paths.sets("riftbound"))
        let madeUpLists = FacetLists(rarities: ["Made Up"], types: ["Made Up"])
        try madeUpLists.write(to: paths.facets("riftbound"))
        let second = model(["app", "-store", root.path])
        let (release, releaser) = AsyncStream.makeStream(of: Void.self)
        var held: [String] = []
        second.setIndexScanHook = { game in
            held.append(game)
            for await _ in release {}
        }
        await second.start()                                                         // returns with the scan held
        #expect(second.status == .idle("Catalog up to date · prices of 2026-01-02"))
        #expect(second.catalogSettled(game: "riftbound"))
        #expect(second.setIndexes["riftbound"] == nil)
        #expect(second.facets(game: "riftbound") == madeUpLists)                     // no facets scan
        #expect(FacetLists.read(paths.facets("riftbound")) == madeUpLists)
        #expect(held == ["riftbound"])
        #expect(second.setIndexInWork("riftbound"))                                  // A4: the list says "being read"
        #expect(!second.setIndexInWork("yu-gi-oh"))
        releaser.finish()
        await second.waitForSetIndexes()
        #expect(!second.setIndexInWork("riftbound"))
        #expect(second.setIndexes["riftbound"] == made)
        #expect(SetIndex.read(paths.sets("riftbound")) == made)
    }

    /// A failed scan keeps the old index in memory and the old file: a first good scan, then a failing one (B).
    @MainActor @Test func aFailedSetIndexScanKeepsTheOldIndex() async throws {
        struct Failed: Error {}
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: [product(id: 1, number: "1")])
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        model.setIndexScanHook = { _ in throw Failed() }
        await model.start()                                                          // no sets file: a scan is asked for
        await model.waitForSetIndexes()
        #expect(model.setIndexes["riftbound"] == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.sets("riftbound").path))
        model.setIndexScanHook = nil
        model.requestSetIndex("riftbound")                                           // a first good scan
        await model.waitForSetIndexes()
        let good = SetIndex(sets: [1: [1]])
        #expect(model.setIndexes["riftbound"] == good)
        let file = try Data(contentsOf: paths.sets("riftbound"))
        let version = model.setIndexVersions["riftbound"]
        try await model.store.replaceProducts(of: 1, with: [product(id: 1, number: "1"), product(id: 2, number: "2")], at: .now)
        model.setIndexScanHook = { _ in throw Failed() }
        model.requestSetIndex("riftbound")                                           // then a failing one
        await model.waitForSetIndexes()
        #expect(model.setIndexes["riftbound"] == good)
        #expect(model.setIndexVersions["riftbound"] == version)
        #expect(try Data(contentsOf: paths.sets("riftbound")) == file)
        #expect(model.setIndexIsDue("riftbound"))                                    // the mark stays for the next launch
    }

    /// A newer request for a game replaces its queued one, the game on screen goes first, and a cancel drops the queue
    /// and stores nothing of the scan it stops.
    @MainActor @Test func theIndexQueueTakesTheGameOnScreenFirstAndKeepsOneRequestPerGame() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES", "-game", "magic-the-gathering"])
        let (release, releaser) = AsyncStream.makeStream(of: Void.self)
        let (entered, enter) = AsyncStream.makeStream(of: String.self)
        var order: [String] = []
        model.setIndexScanHook = { game in
            order.append(game)
            enter.yield(game)
            if order.count == 1 { for await _ in release {} }
        }
        model.requestSetIndex("riftbound")                                           // runs, held
        var gate = entered.makeAsyncIterator()
        #expect(await gate.next() == "riftbound")                                    // the first scan is in its hook
        model.requestSetIndex("yu-gi-oh")
        model.requestSetIndex("cyberpunk")
        model.requestSetIndex("magic-the-gathering")                                 // the game on screen
        model.requestSetIndex("yu-gi-oh")                                            // replaces the queued one
        releaser.finish()
        await model.waitForSetIndexes()
        #expect(order == ["riftbound", "magic-the-gathering", "cyberpunk", "yu-gi-oh"])
        try await model.store.replaceProducts(of: 1, with: [product(id: 1)], at: .now)
        let before = model.setIndexes
        order = []
        let (hold, holder) = AsyncStream.makeStream(of: Void.self)
        let (held, heldIn) = AsyncStream.makeStream(of: String.self)
        model.setIndexScanHook = { game in
            order.append(game)
            heldIn.yield(game)
            for await _ in hold {}
        }
        model.requestSetIndex("riftbound")
        var heldGate = held.makeAsyncIterator()
        #expect(await heldGate.next() == "riftbound")
        model.requestSetIndex("yu-gi-oh")
        model.cancelSetIndexes()
        holder.finish()
        await model.waitForSetIndexes()
        #expect(order == ["riftbound"])
        #expect(model.setIndexes == before)
        #expect(model.setIndexes["riftbound"] != SetIndex(sets: [1: [1]]))
    }

    /// The owner's migrated store has no facets files: the lists are computed once at launch, also offline.
    @MainActor @Test func aMissingFilterFileIsMadeFromTheStoreAtLaunch() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: try ProductParser.products(fixture("products-89.json"), game: Games.game("riftbound")!).cards)
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.facets(game: "riftbound") == nil)
        let before = model.filtersVersion
        await model.start()
        #expect(model.facets(game: "riftbound")?.types.contains("Gear") == true)
        #expect(FacetLists.read(paths.facets("riftbound")) == model.facets(game: "riftbound"))
        #expect(model.facets(game: "yu-gi-oh") == nil)                              // no products: no file
        #expect(model.filtersVersion > before)
        #expect(await fakeCatalog.groupCalls == 0)
    }

    /// After a rule change the sets fetched today wait for the next day; the status line says how many.
    @MainActor @Test func theStatusCountsTheSetsThatWaitForTheNextDay() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path])
        await model.start()
        #expect(model.status == .idle("Catalog up to date · prices of 2026-01-02"))
        try await model.store.setRulesVersion(1, game: "riftbound")
        await model.refresh(rebuild: false)                                          // same day: nothing is fetched
        #expect(await fakeCatalog.productCalls == 14)
        #expect(model.status == .idle("Catalog up to date · 14 sets are updated tomorrow · prices of 2026-01-02"))
    }

    // MARK: - The user folder

    /// `-store`: the collection is in `<root>/user`, made at launch with its settings file; no sheet; `start()` loads it.
    @MainActor @Test func aStoreRootKeepsTheCollectionInItsUserFolder() async throws {
        let root = tempRoot(), user = AppPaths.userTestRoot(root)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try UserFiles.write(Data(#"{"version":1,"collection":[{"productID":5,"finish":"Normal","count":2}]}"#.utf8),
                            to: user.appending(path: "riftbound.json"))
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(!model.needsUserFolder); #expect(model.library.folder == user)
        #expect(FileManager.default.fileExists(atPath: user.appending(path: "settings.json").path))
        await model.start()
        #expect(model.library.rows(game: "riftbound").map(\.count) == [2])
    }

    /// A `-store` run keeps `<root>/user`: the sheet cannot move it anywhere, not even into the root.
    @MainActor @Test func aFixedFolderIsNotChanged() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        await model.start()
        await #expect(throws: UserFolderError.fixed) { try await model.useICloudDrive() }
        await #expect(throws: UserFolderError.fixed) { try await model.useFolder(root.appending(path: "support")) }
        #expect(model.library.folder == AppPaths.userTestRoot(root))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "icloud").path))
    }

    /// Item 3: the stored folder is gone. The sheet names where it was, and the stored bookmark is kept until a choice.
    @MainActor @Test func aStoredFolderThatIsGoneIsNamedAndItsBookmarkKept() async throws {
        let root = tempRoot(), gone = root.appending(path: "icloud").appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let mark = try UserFolder.bookmark(for: gone)
        try FileManager.default.removeItem(at: gone)
        let preferences = try #require(UserDefaults(suiteName: AppPaths(root: root).support.appending(path: "preferences").path))
        preferences.set(mark, forKey: AppModel.userFolderBookmarkKey)
        let model = model(["app", "-store", root.path, "-offline", "YES", "-askUserFolder", "YES"])
        #expect(model.needsUserFolder); #expect(model.library.folder == nil)
        guard case .gone(let path) = model.userFolderSetup.lost else {
            Issue.record("lost: \(String(describing: model.userFolderSetup.lost))"); return
        }
        #expect(UserFolder.isSameFolder(URL(fileURLWithPath: path), gone), "\(path)")
        await model.start()
        #expect(preferences.data(forKey: AppModel.userFolderBookmarkKey) == mark)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// `-askUserFolder YES`: the sheet is needed; a folder outside the root is refused; "Use iCloud Drive" makes
    /// `<root>/icloud/TCG Collection` with its settings file and keeps a bookmark that the next launch resolves.
    @MainActor @Test func askingForTheFolderStaysInTheRoot() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES", "-askUserFolder", "YES"])
        #expect(model.needsUserFolder); #expect(model.library.folder == nil)
        await model.start()
        let outside = tempDir()
        await #expect(throws: UserFolderError.outside(path: root.path)) { try await model.useFolder(outside) }
        #expect(model.needsUserFolder)
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "settings.json").path))
        let preferences = try #require(UserDefaults(suiteName: model.paths.support.appending(path: "preferences").path))
        #expect(preferences.data(forKey: AppModel.userFolderBookmarkKey) == nil)

        try await model.useICloudDrive()
        let folder = root.appending(path: "icloud").appending(path: "TCG Collection")
        #expect(!model.needsUserFolder); #expect(model.library.folder == folder)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "settings.json").path))
        model.library.setCount(1, game: "riftbound", key: .init(productID: 1, finish: "Normal"), name: "A")
        await model.library.flush()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "riftbound.json").path))
        let bookmark = try #require(preferences.data(forKey: AppModel.userFolderBookmarkKey))
        let next = UserFolder.setup(storeRoot: root, isDebugBuild: true, askUserFolder: true, bookmark: bookmark) { nil }
        guard case .iCloud(let again) = next.choice else { Issue.record("next launch: \(next.choice)"); return }
        #expect(again.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    }

    // MARK: CSV import (phase 2B task 7)

    /// After an import the Collection shows the first imported game, and the status line says the summary until the next
    /// status (here: the launch's offline line) replaces it; the status itself is not lost.
    @MainActor @Test func anImportSaysItsSummaryOnceInTheStatusLine() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES", "-screen", "all-cards"])
        model.importing = ImportModel(unreadable: "x", fileName: "x.csv", library: model.library, reader: model.reader)
        await model.importApplied(.init(gameID: "yu-gi-oh", games: ["yu-gi-oh"], summary: "2 new"))
        #expect(model.statusNotice == "Imported: 2 new")
        #expect(model.gameID == "yu-gi-oh" && model.screen == .collection && model.importing == nil)
        await model.start()
        #expect(model.statusNotice == nil)
        #expect(model.status == .idle("Offline · no prices yet"))
    }

    /// An import of the Riftbound fixture file into the model's empty collection, compared on the fixture catalog.
    @MainActor private func preparedImport(_ model: AppModel) async throws -> ImportModel {
        let importing = ImportModel(data: try fixture("collection-riftbound.csv"), fileName: "collection-riftbound.csv",
                                    library: model.library, reader: try await filledStore(), catalogSettled: { _ in true })
        model.importing = importing
        await importing.prepare()
        return importing
    }

    /// Final fix A2: "Imported: …" is said once the import's write ran, not when it was queued.
    @MainActor @Test(.timeLimit(.minutes(1))) func anImportIsSaidOnlyAfterItsWrite() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let importing = try await preparedImport(model)
        model.library.writeDelay = .milliseconds(400)
        let applied = try #require(importing.apply())
        let said = Task { await model.importApplied(applied) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.library.hasPendingWork)
        #expect(model.importing == nil && model.screen == .collection)          // the sheet closes at once
        #expect(model.statusNotice == nil)                                        // the write has not run yet
        await said.value
        #expect(!model.library.hasPendingWork)
        #expect(model.statusNotice == "Imported: 3 new")
    }

    /// Final fix A2: the write of an imported game failed (the folder is read-only between the comparison and the write):
    /// the status line says that game's problem, the one the problem line shows, and never "Imported: …".
    @MainActor @Test func anImportWhoseWriteFailedSaysTheProblemInstead() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let folder = try #require(model.library.folder)
        let importing = try await preparedImport(model)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let applied = try #require(importing.apply())
        #expect(applied.games == ["riftbound"])
        await model.importApplied(applied)
        let problem = try #require(model.library.problem(game: "riftbound"))
        #expect(problem.hasPrefix("riftbound.json could not be saved"))
        #expect(model.statusNotice == problem)
        #expect(model.gameID == "riftbound" && model.screen == .collection && model.importing == nil)
    }

    // MARK: The for-sale notice (phase 2C task 2, C8)

    /// Waits until `condition` holds; fails after 10 s.
    @MainActor private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// C7: a sale writes the price of that moment (the price table's, for the printing's finish) and says nothing.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleWritesThePriceOfTheMoment() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        try model.prices.replace("riftbound", with: fixturePrices(), paths: model.paths)
        let key = PrintingKey(productID: 721334, finish: "Normal")
        model.library.setCount(3, game: "riftbound", key: key, name: "Dockside Lock-Up")
        model.library.setForSale(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        #expect(model.sell(2, game: "riftbound", key: key))
        #expect(model.library.sold(game: "riftbound").map(\.price) == [5.12])
        #expect(model.library.count(game: "riftbound", key: key) == 1)
        #expect(model.statusNotice == nil)
    }

    /// Fix round 1: a sale the library refuses (the copies for sale changed while the dialog was open: here 1 left of the
    /// 2 it offered) sells nothing, and the status line says so.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRefusedSaleIsSaid() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let key = PrintingKey(productID: 721334, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        model.library.setForSale(1, game: "riftbound", key: key, name: "Dockside Lock-Up")
        let version = model.library.version
        #expect(!model.sell(2, game: "riftbound", key: key))
        #expect(model.statusNotice == "Nothing was sold: the copies for sale changed.")
        #expect(model.library.version == version && model.library.sold(game: "riftbound").isEmpty)
        #expect(model.library.forSaleCount(game: "riftbound", key: key) == 1)
    }

    /// Final fix A2: a sale refused because the game cannot change (here its file is refused now: a newer version came
    /// from another device) says why, with the card page's sentence, not "the copies for sale changed".
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleTheGameCannotTakeSaysWhy() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let folder = try #require(model.library.folder), key = PrintingKey(productID: 721334, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        model.library.setForSale(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        await model.library.flush()
        let file = folder.appending(path: "riftbound.json")
        try UserFiles.write(Data(#"{"version":2,"collection":[]}"#.utf8), to: file)
        await model.library.fileChanged(file)?.value
        #expect(!model.library.canChange(game: "riftbound"))
        #expect(!model.sell(1, game: "riftbound", key: key))
        #expect(model.statusNotice == "The counts cannot change: riftbound.json was written by a newer version of the app.")
        #expect(try Data(contentsOf: file) == Data(#"{"version":2,"collection":[]}"#.utf8))
    }

    /// Final fix A3: a sale whose write is refused at write time (a newer file came between the read and the write, and
    /// the change is dropped) is said once: "The sale was not saved: <the game's problem>".
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleDroppedAtItsWriteIsSaid() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        model.noticeDuration = .milliseconds(300)
        let folder = try #require(model.library.folder), key = PrintingKey(productID: 721334, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        model.library.setForSale(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        await model.library.flush()
        let newer = Data(#"{"version":2,"collection":[]}"#.utf8), file = folder.appending(path: "riftbound.json")
        #expect(model.sell(1, game: "riftbound", key: key))                     // its write is queued
        try newer.write(to: file)                                                // before the write runs
        await model.library.flush()
        try await until { model.statusNotice != nil }
        #expect(model.statusNotice == "The sale was not saved: riftbound.json was written by a newer version of the app.")
        #expect(try Data(contentsOf: file) == newer)
        #expect(model.library.sold(game: "riftbound").isEmpty)
        // Said once: its own time ends it, and nothing says it again.
        try await until { model.statusNotice == nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.statusNotice == nil)
    }

    /// Final fix A3: a change that is not a sale and is dropped at its write keeps today's behaviour: the problem line
    /// says why, the status line says nothing.
    @MainActor @Test(.timeLimit(.minutes(1))) func anotherChangeDroppedAtItsWriteIsNotSaidAsASale() async throws {
        // The game's file is read at launch (task 5 fix round 1: a write that would create the file is said as not saved
        // when a file appears; this test is about a write that replaces a read file).
        let root = tempRoot()
        try writeUserFile(root, "riftbound", #"{"version":1,"collection":[]}"#)
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        await model.start()
        let folder = try #require(model.library.folder), key = PrintingKey(productID: 721334, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "Dockside Lock-Up")
        try Data(#"{"version":2,"collection":[]}"#.utf8).write(to: folder.appending(path: "riftbound.json"))
        await model.library.flush()
        #expect(model.library.problem(game: "riftbound") == "riftbound.json was written by a newer version of the app.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.statusNotice == nil)
    }

    /// A for-sale count that follows an owned count down is said once in the status line, as an import's summary is;
    /// the library's notice is cleared.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleNoticeIsSaidInTheStatusLine() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let key = PrintingKey(productID: 1, finish: "Normal")
        model.library.setCount(3, game: "riftbound", key: key, name: "A")
        model.library.setForSale(3, game: "riftbound", key: key, name: "A")
        #expect(model.statusNotice == nil)
        model.library.setCount(1, game: "riftbound", key: key, name: "")
        try await until { model.statusNotice != nil }
        #expect(model.statusNotice == "2 copies are no longer for sale.")
        #expect(model.library.saleNotice == nil)
        #expect(model.status == .idle("Offline · no prices yet"))
    }

    /// An import that takes copies off sale says both in its one line once its writes ran; while its sheet is open the
    /// for-sale notice waits for it.
    @MainActor @Test(.timeLimit(.minutes(1))) func anImportThatTakesCopiesOffSaleSaysBoth() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let key = PrintingKey(productID: 1, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "A")
        model.library.setForSale(2, game: "riftbound", key: key, name: "A")
        model.importing = ImportModel(unreadable: "x", fileName: "x.csv", library: model.library, reader: model.reader)
        model.library.replace(game: "riftbound", rows: [])                     // the sheet's Import
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.statusNotice == nil); #expect(model.library.saleNotice == "2 copies are no longer for sale.")
        await model.importApplied(.init(gameID: "riftbound", games: ["riftbound"], summary: "1 not in the file (removed)"))
        #expect(model.statusNotice == "Imported: 1 not in the file (removed). 2 copies are no longer for sale.")
        #expect(model.library.saleNotice == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.statusNotice == "Imported: 1 not in the file (removed). 2 copies are no longer for sale.")
    }

    /// The problem sentence of an import whose write failed stays in the status line: the for-sale notice does not hide
    /// it, it waits behind it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleNoticeDoesNotHideAProblem() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        let folder = try #require(model.library.folder), key = PrintingKey(productID: 1, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "A")
        model.library.setForSale(2, game: "riftbound", key: key, name: "A")
        await model.library.flush()
        model.importing = ImportModel(unreadable: "x", fileName: "x.csv", library: model.library, reader: model.reader)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        model.library.replace(game: "riftbound", rows: [])
        await model.importApplied(.init(gameID: "riftbound", games: ["riftbound"], summary: "1 not in the file (removed)"))
        let problem = try #require(model.library.problem(game: "riftbound"))
        #expect(model.statusNotice == problem)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.statusNotice == problem)
        #expect(model.library.saleNotice == "2 copies are no longer for sale.")
    }

    /// Fix round 1: a for-sale notice that waited behind a problem sentence is said once that sentence is gone (here: its
    /// time is up), then the library's notice is cleared.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSaleNoticeIsSaidOnceTheProblemIsGone() async throws {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await model.start()
        model.noticeDuration = .milliseconds(300)
        let folder = try #require(model.library.folder), key = PrintingKey(productID: 1, finish: "Normal")
        model.library.setCount(2, game: "riftbound", key: key, name: "A")
        model.library.setForSale(2, game: "riftbound", key: key, name: "A")
        await model.library.flush()
        model.importing = ImportModel(unreadable: "x", fileName: "x.csv", library: model.library, reader: model.reader)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        model.library.replace(game: "riftbound", rows: [])
        await model.importApplied(.init(gameID: "riftbound", games: ["riftbound"], summary: "1 not in the file (removed)"))
        let problem = try #require(model.library.problem(game: "riftbound"))
        #expect(model.statusNotice == problem)
        try await until { model.statusNotice == "2 copies are no longer for sale." }
        #expect(model.library.saleNotice == nil)
        try await until { model.statusNotice == nil }                            // said once: its own time ends it
    }

    /// Fix round 1, item 5: while a file is still being read, and while an import is open, a second import (the panel, or
    /// a file) is ignored. The gate holds the first read, so it is in progress for sure.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSecondImportIsIgnoredWhileOneIsReadOrOpen() async throws {
        let launched = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        let gate = ReadGate()
        launched.beforeImportRead = { await gate.pass($0) }
        let first = Task { await launched.importCSV(from: fixtureURL("collection-riftbound.csv")) }
        try await gate.waitUntilHolding()
        #expect(launched.readsImport)
        await launched.importCSV(from: fixtureURL("collection-mixed.csv"))      // ignored: a read is in progress
        launched.chooseCSVFile()
        #expect(launched.importing == nil && !launched.choosesCSVFile)
        gate.open()
        await first.value
        #expect(launched.importing?.fileName == "collection-riftbound.csv" && !launched.readsImport)
        await launched.importCSV(from: fixtureURL("collection-mixed.csv"))      // ignored: an import is open
        launched.chooseCSVFile()
        #expect(launched.importing?.fileName == "collection-riftbound.csv" && !launched.choosesCSVFile)
    }

    /// Final fix B7: the Yu-Gi-Oh! index's identity is part of a deck join's key: when the index is replaced (it arrives on
    /// a first launch), the deck page's and the sidebar's kinds are read again at once. Other list joins keep their key.
    @MainActor @Test func aNewYGOIndexChangesTheDeckJoinsKey() {
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        let before = DeckJoin.deckKey(game: "yu-gi-oh", model: model)
        let list = CatalogJoin<[CollectionEntry]>.key(game: "yu-gi-oh", model: model)
        let version = model.ygoIndexVersion
        model.ygoIndex = nil
        #expect(model.ygoIndexVersion == version + 1)
        #expect(DeckJoin.deckKey(game: "yu-gi-oh", model: model) != before)
        #expect(CatalogJoin<[CollectionEntry]>.key(game: "yu-gi-oh", model: model) == list)
    }

    /// Final fix B5: Cmd+I (and a picked file) does nothing while another sheet of the window is open (New Deck, Rename,
    /// the paste sheet, the folder sheet), so an import is never left pending behind it; once the sheet closes it works.
    @MainActor @Test func anImportWaitsForNoOtherSheet() async throws {
        let launched = model(["app", "-store", tempRoot().path, "-offline", "YES"])
        await launched.start()
        let file = fixtureURL("collection-riftbound.csv")
        func tryImport() async {
            launched.chooseCSVFile()
            await launched.importCSV(from: file)
        }
        launched.showsNewDeck = true
        await tryImport()
        #expect(launched.importing == nil && !launched.choosesCSVFile)
        launched.showsNewDeck = false
        launched.renamingDeck = true
        #expect(launched.showsSheet)
        await tryImport()
        #expect(launched.importing == nil && !launched.choosesCSVFile)
        launched.renamingDeck = false
        launched.pasteDeck(into: nil)
        #expect(launched.pasting != nil)
        await tryImport()
        #expect(launched.importing == nil && !launched.choosesCSVFile)
        launched.pasting = nil
        launched.showsFolderSheet = true
        await tryImport()
        #expect(launched.importing == nil && !launched.choosesCSVFile)
        launched.showsFolderSheet = false
        launched.chooseCSVFile()
        #expect(launched.choosesCSVFile)
        launched.choosesCSVFile = false
        await launched.importCSV(from: file)
        #expect(launched.importing?.fileName == "collection-riftbound.csv")
    }

    /// `-importCSV <path>` with `-store`: the launch opens the import of that file (DEBUG; the unit tests are Debug).
    @MainActor @Test func theImportFlagOpensTheImportAtLaunch() async throws {
        let file = fixtureURL("collection-riftbound.csv")
        let launched = model(["app", "-store", tempRoot().path, "-offline", "YES", "-importCSV", file.path])
        await launched.start()
        #expect(launched.importing?.fileName == "collection-riftbound.csv")
        let missing = model(["app", "-store", tempRoot().path, "-offline", "YES", "-importCSV", "/nonexistent/c.csv"])
        await missing.start()
        await missing.importing?.prepare()
        guard case .failed(let text)? = missing.importing?.state else { Issue.record("no failed import"); return }
        #expect(text.hasPrefix("This file could not be read ("))
    }

    // MARK: Followed games (phase 4B task 2: A28, G3–G6)

    /// A game file that turns the game off (G1).
    private static let notFollowed = #"{"version":1,"collection":[],"profile":{"followed":false}}"#

    /// Writes `<root>/user/<game>.json` before the launch.
    private func writeUserFile(_ root: URL, _ game: String, _ json: String) throws {
        let user = AppPaths.userTestRoot(root)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: user.appending(path: "\(game).json"))
    }

    /// A model on the fixture network (all four games), counting its requests.
    @MainActor private func fixtureModel(_ root: URL, _ network: CountingFixtures, _ extra: [String] = []) -> AppModel {
        AppModel(options: .init(arguments: ["app", "-store", root.path] + extra), catalogClient: network,
                 archiveClient: network, fetcher: network, now: { Self.day1 })
    }

    /// G5, A28: Yu-Gi-Oh! is not followed. The launch fetches no set list or set of it, scans no filter list or set index
    /// of it, fills no price of it from the archive and asks for no Yu-Gi-Oh! picture index; the other three games are
    /// synced as before, and nothing waits for Yu-Gi-Oh!.
    @MainActor @Test(.timeLimit(.minutes(1))) func aGameThatIsNotFollowedIsNeitherFetchedNorScanned() async throws {
        let root = tempRoot()
        try writeUserFile(root, "yu-gi-oh", Self.notFollowed)
        let network = CountingFixtures()
        let model = fixtureModel(root, network, ["-game", "riftbound"])
        await model.start()
        await model.waitForSetIndexes()
        #expect(model.followedGames.map(\.id) == ["magic-the-gathering", "riftbound", "cyberpunk"])
        #expect(!model.isFollowed("yu-gi-oh")); #expect(model.isFollowed("riftbound"))
        #expect(await network.groups == [89, 1, 92])                          // the game on screen first, then the others
        #expect(await !network.products.contains(2))
        #expect(try await model.reader.sets(game: "yu-gi-oh").isEmpty)
        #expect(try await model.reader.progress(game: "yu-gi-oh").fetched == 0)
        for game in ["magic-the-gathering", "riftbound", "cyberpunk"] {
            #expect(try await model.reader.progress(game: game).fetched >= 1, "\(game)")
            #expect(FileManager.default.fileExists(atPath: model.paths.facets(game).path), "\(game)")
            #expect(FileManager.default.fileExists(atPath: model.paths.sets(game).path), "\(game)")
        }
        #expect(!FileManager.default.fileExists(atPath: model.paths.facets("yu-gi-oh").path))
        #expect(!FileManager.default.fileExists(atPath: model.paths.sets("yu-gi-oh").path))
        #expect(await network.fetches.isEmpty)                                 // no cardinfo.php
        #expect(model.ygoIndex == nil)
        #expect(await network.archives == ["2026-01-02"])                      // the day's archive, once, for the others
        #expect(model.prices.day(game: "riftbound") == "2026-01-02")
        #expect(model.prices.day(game: "yu-gi-oh") == nil)
        #expect(Games.all.allSatisfy { model.catalogSettled(game: $0.id) })
        #expect(model.status == .idle("Catalog up to date · prices of 2026-01-02"))
    }

    /// G5: a game that is not followed is not pending: during the price step (between the game on screen and the other
    /// games) Yu-Gi-Oh! is settled while Cyberpunk, still due, is not.
    @MainActor @Test(.timeLimit(.minutes(1))) func aGameThatIsNotFollowedIsNeverPending() async throws {
        let root = tempRoot()
        try writeUserFile(root, "yu-gi-oh", Self.notFollowed)
        let archive = GatedArchive()
        let model = AppModel(options: .init(arguments: ["app", "-store", root.path, "-game", "riftbound"]),
                             catalogClient: fakeCatalog, archiveClient: archive, fetcher: fakeFetcher, now: { Self.day1 })
        let run = Task { await model.start() }
        while await !archive.called { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.catalogSettled(game: "riftbound"))
        #expect(model.catalogSettled(game: "yu-gi-oh"))
        #expect(!model.catalogSettled(game: "cyberpunk"))
        await archive.release()
        await run.value
        #expect(Games.all.allSatisfy { model.catalogSettled(game: $0.id) })
        #expect(await !log.entries.contains("groups 2"))
    }

    /// G4: a launched (`-game`) or stored game that is not followed opens the first followed game.
    @MainActor @Test func aLaunchOnAGameThatIsNotFollowedShowsTheFirstFollowedGame() async throws {
        let root = tempRoot()
        let first = model(["app", "-store", root.path, "-offline", "YES"])
        await first.start()
        first.gameID = "yu-gi-oh"                                              // stored
        try writeUserFile(root, "magic-the-gathering", Self.notFollowed)
        try writeUserFile(root, "yu-gi-oh", Self.notFollowed)
        let stored = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(stored.gameID == "yu-gi-oh")                                  // before the folder is read
        await stored.start()
        #expect(stored.gameID == "riftbound")
        let launched = model(["app", "-store", root.path, "-offline", "YES", "-game", "magic-the-gathering"])
        await launched.start()
        #expect(launched.gameID == "riftbound")
        #expect(launched.followedGames.map(\.id) == ["riftbound", "cyberpunk"])
    }

    /// Before the folder is read every game counts as followed, so nothing changes at launch for a folder whose games are
    /// all followed (A30).
    @MainActor @Test func everyGameIsFollowedBeforeTheFolderIsRead() async throws {
        let root = tempRoot()
        try writeUserFile(root, "yu-gi-oh", Self.notFollowed)
        let model = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(model.followedGames.map(\.id) == Games.all.map(\.id))
        await model.start()
        #expect(model.followedGames.map(\.id) == ["magic-the-gathering", "riftbound", "cyberpunk"])
    }

    /// G5: turning a game on runs its catalog step once (also when `profilesChanged` is called more than once) and fills
    /// its prices from the archive already on disk (no download); turning it off again fetches and removes nothing.
    @MainActor @Test(.timeLimit(.minutes(1))) func turningAGameOnRunsItsCatalogStepAndOffRemovesNothing() async throws {
        let root = tempRoot()
        try writeUserFile(root, "yu-gi-oh", Self.notFollowed)
        let network = CountingFixtures()
        let model = fixtureModel(root, network, ["-game", "riftbound"])
        await model.start()
        await model.waitForSetIndexes()
        #expect(try await model.reader.progress(game: "yu-gi-oh").fetched == 0)

        model.library.setProfile(.all, game: "yu-gi-oh")
        model.profilesChanged()
        model.profilesChanged()
        await model.waitForProfileWork()
        await model.waitForSetIndexes()
        #expect(await network.groups == [89, 1, 92, 2])                       // one set list: one step
        let fetched = try await model.reader.progress(game: "yu-gi-oh").fetched
        #expect(fetched >= 1)
        #expect(model.catalogSettled(game: "yu-gi-oh"))
        #expect(model.prices.day(game: "yu-gi-oh") == "2026-01-02")           // from the archive on disk
        #expect(await network.archives == ["2026-01-02"])                      // no second download
        #expect(FileManager.default.fileExists(atPath: model.paths.facets("yu-gi-oh").path))
        #expect(FileManager.default.fileExists(atPath: model.paths.sets("yu-gi-oh").path))
        #expect(model.followedGames.map(\.id) == Games.all.map(\.id))

        let requests = (await network.groups, await network.products.count, await network.archives, await network.fetches)
        model.library.setProfile(GameProfile(followed: false), game: "yu-gi-oh")
        model.profilesChanged()
        await model.waitForProfileWork()
        await model.library.flush()
        #expect(await network.groups == requests.0); #expect(await network.products.count == requests.1)
        #expect(await network.archives == requests.2); #expect(await network.fetches == requests.3)
        #expect(try await model.reader.progress(game: "yu-gi-oh").fetched == fetched)   // its catalog stays
        #expect(FileManager.default.fileExists(atPath: model.paths.facets("yu-gi-oh").path))
        #expect(FileManager.default.fileExists(atPath: model.paths.sets("yu-gi-oh").path))
        #expect(model.prices.day(game: "yu-gi-oh") == "2026-01-02")
        #expect(!model.isFollowed("yu-gi-oh"))
    }

    /// G4: the game on screen stops being followed by a reload (another device): the first followed game is shown, on its
    /// Collection (a switch made by code). The model reacts by itself (it observes the library).
    @MainActor @Test(.timeLimit(.minutes(1))) func theGameOnScreenTurnedOffByAReloadShowsTheFirstFollowedGame() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "all-cards"])
        await model.start()
        #expect(model.gameID == "riftbound"); #expect(model.screen == .allCards)
        let file = AppPaths.userTestRoot(root).appending(path: "riftbound.json")
        try Data(Self.notFollowed.utf8).write(to: file)
        await model.library.fileChanged(file)?.value
        try await until { model.gameID == "magic-the-gathering" }
        #expect(model.screen == .collection); #expect(model.showsRoot(.collection))
        #expect(model.followedGames.map(\.id) == ["magic-the-gathering", "yu-gi-oh", "cyberpunk"])
    }

    /// G6: with no folder chosen the library has not loaded: `start()` begins no catalog step and no price step. Once a
    /// folder is used (and read) the steps run.
    @MainActor @Test(.timeLimit(.minutes(1))) func noCatalogStepBeforeTheFolderIsRead() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-askUserFolder", "YES"])
        #expect(!model.catalogMayStart)
        let run = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fakeCatalog.groupCalls == 0)
        #expect(await fakeArchive.calls.isEmpty)
        try await model.useICloudDrive()
        #expect(model.catalogMayStart)
        await run.value
        #expect(await fakeCatalog.groupCalls == 4)
        #expect(try await model.store.progress(game: "riftbound").fetched == 14)
    }

    /// G6 with `-store`: the folder is read at once, and every game file is read before the first catalog request.
    @MainActor @Test func theFirstCatalogRequestComesAfterTheFoldersFirstRead() async throws {
        let model = model(["app", "-store", tempRoot().path, "-game", "riftbound"])
        let log = log
        model.library.beforeRead = { url in await log.add("read \(url.lastPathComponent)") }
        await model.start()
        #expect(Array(await log.entries.prefix(5)) == ["read magic-the-gathering.json", "read yu-gi-oh.json",
                                                         "read riftbound.json", "read cyberpunk.json", "groups 89"])
    }

    // MARK: Onboarding (phase 4B task 5: G6, G11, A30)

    /// The files of `<root>/user` but `settings.json`, sorted.
    private func gameFiles(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != "settings.json" }.sorted()
    }

    /// A game file's `profile` object as written.
    private func storedProfile(_ folder: URL, _ game: String) throws -> [String: Bool]? {
        let data = try Data(contentsOf: folder.appending(path: "\(game).json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["profile"] as? [String: Bool]
    }

    /// G6, G11: with onboarding due (a new folder, `-onboarding YES`) no catalog, price or index request is made and no
    /// game file is written until "Continue". `finishOnboarding` with Riftbound and Cyberpunk (Player off) ticked writes the
    /// four files (two followed as chosen, two not followed with both roles), then only those two games are synced, and
    /// the game on screen is the first followed one, on its Collection.
    @MainActor @Test(.timeLimit(.minutes(1))) func onboardingHoldsTheSyncUntilContinueAndStartsTheChosenGames() async throws {
        let root = tempRoot(), user = AppPaths.userTestRoot(root)
        let network = CountingFixtures()
        let model = fixtureModel(root, network, ["-onboarding", "YES", "-game", "yu-gi-oh", "-screen", "all-cards"])
        let run = Task { await model.start() }
        try await until { model.library.isLoaded }
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.onboardingDue); #expect(model.showsOnboarding); #expect(model.showsSheet)
        #expect(!model.catalogMayStart)
        #expect(await network.groups.isEmpty); #expect(await network.archives.isEmpty); #expect(await network.fetches.isEmpty)
        #expect(gameFiles(user).isEmpty)
        model.chooseCSVFile()
        #expect(!model.choosesCSVFile)                                         // no other sheet under it

        var draft = Onboarding.draft(games: Games.all)
        await model.finishOnboarding(draft)                                    // nothing ticked: nothing happens
        #expect(model.onboardingDue); #expect(gameFiles(user).isEmpty)
        draft = ProfileRows.toggled(draft, game: "riftbound", member: .followed)
        draft = ProfileRows.toggled(draft, game: "cyberpunk", member: .followed)
        draft = ProfileRows.toggled(draft, game: "cyberpunk", member: .player)
        await model.finishOnboarding(draft)
        #expect(!model.onboardingDue); #expect(!model.showsOnboarding)
        #expect(gameFiles(user) == ["cyberpunk.json", "magic-the-gathering.json", "riftbound.json", "yu-gi-oh.json"])
        #expect(try storedProfile(user, "riftbound") == ["followed": true, "player": true, "collector": true])
        #expect(try storedProfile(user, "cyberpunk") == ["followed": true, "player": false, "collector": true])
        #expect(try storedProfile(user, "magic-the-gathering") == ["followed": false, "player": true, "collector": true])
        #expect(try storedProfile(user, "yu-gi-oh") == ["followed": false, "player": true, "collector": true])
        #expect(model.gameID == "riftbound"); #expect(model.screen == .collection); #expect(model.showsRoot(.collection))
        await run.value
        await model.waitForSetIndexes()
        #expect(await network.groups == [89, 92])                              // the game on screen first
        #expect(await !network.products.contains(1)); #expect(await !network.products.contains(2))
        #expect(await network.fetches.isEmpty)                                 // Yu-Gi-Oh! is not followed: no index
        #expect(model.followedGames.map(\.id) == ["riftbound", "cyberpunk"])

        // The next launch on that folder finds game files: no second onboarding.
        let next = fixtureModel(root, network, ["-onboarding", "YES", "-offline", "YES"])
        await next.start()
        #expect(!next.onboardingDue); #expect(!next.showsOnboarding)
    }

    /// Review Focus 5: a model torn down before "Continue" (a quit) leaves the folder with no game file; the next launch
    /// asks again. Without `-onboarding YES` a Debug build never asks (the UI tests' fresh roots).
    @MainActor @Test func aQuitBeforeContinueWritesNothingAndAsksAgain() async throws {
        let root = tempRoot(), user = AppPaths.userTestRoot(root)
        do {
            let first = model(["app", "-store", root.path, "-offline", "YES", "-onboarding", "YES"])
            await first.start()
            #expect(first.onboardingDue)
            await first.library.flush()
        }
        #expect(gameFiles(user).isEmpty)
        let again = model(["app", "-store", root.path, "-offline", "YES", "-onboarding", "YES"])
        await again.start()
        #expect(again.onboardingDue); #expect(again.showsOnboarding)
        let without = model(["app", "-store", root.path, "-offline", "YES"])
        await without.start()
        #expect(!without.onboardingDue); #expect(!without.showsOnboarding); #expect(without.catalogMayStart)
    }

    /// The ledger's ruling (A30): a folder whose only game file is an iCloud placeholder (not downloaded) has a game file,
    /// and a missing folder is not new: neither asks. Nor does a reload that leaves the folder with no game file (another
    /// device deleted it): the question belongs to a folder's first read.
    @MainActor @Test func aPlaceholderAMissingFolderAndAReloadDoNotAsk() async throws {
        let placeholder = tempRoot()
        let user = AppPaths.userTestRoot(placeholder)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data().write(to: user.appending(path: ".riftbound.json.icloud"))
        let one = model(["app", "-store", placeholder.path, "-offline", "YES", "-onboarding", "YES"])
        await one.start()
        #expect(one.library.isLoaded); #expect(!one.onboardingDue)

        let missing = tempRoot()
        let two = model(["app", "-store", missing.path, "-offline", "YES", "-onboarding", "YES"])
        try FileManager.default.removeItem(at: AppPaths.userTestRoot(missing))   // made by the model's init
        await two.start()
        #expect(two.library.folderIsMissing); #expect(!two.onboardingDue); #expect(two.catalogMayStart)

        let reloaded = tempRoot()
        try writeUserFile(reloaded, "riftbound", #"{"version":1,"collection":[]}"#)
        let three = model(["app", "-store", reloaded.path, "-offline", "YES", "-onboarding", "YES"])
        await three.start()
        #expect(!three.onboardingDue)
        let file = AppPaths.userTestRoot(reloaded).appending(path: "riftbound.json")
        try FileManager.default.removeItem(at: file)
        await three.library.fileChanged(file)?.value
        #expect(!three.library.hasGameFile)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!three.onboardingDue); #expect(!three.showsOnboarding)
    }

    /// Review Focus 5: a folder switch ("Collection Folder…") to a new folder makes onboarding due again once that folder
    /// is read; a switch to a folder with game files does not. A switch while the sheet is open: the sheet stays open
    /// during the new folder's read (a load does not dismiss it), then follows the new folder.
    @MainActor @Test func aFolderSwitchAsksOnANewFolderOnly() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES", "-askUserFolder", "YES", "-onboarding", "YES"])
        await model.start()
        #expect(model.needsUserFolder); #expect(!model.onboardingDue)       // no folder yet: the folder sheet first
        try await model.useICloudDrive()
        #expect(model.onboardingDue); #expect(model.showsOnboarding)

        let withFiles = root.appending(path: "with-files")
        try FileManager.default.createDirectory(at: withFiles, withIntermediateDirectories: true)
        try Data(#"{"version":1,"collection":[]}"#.utf8).write(to: withFiles.appending(path: "cyberpunk.json"))
        var during: [(Bool, Bool)] = []
        model.library.beforeRead = { _ in during.append((model.onboardingDue, model.showsOnboarding)) }
        try await model.useFolder(withFiles)
        model.library.beforeRead = nil
        #expect(!during.isEmpty && during.allSatisfy { $0.0 && $0.1 }, "\(during)")
        #expect(!model.onboardingDue); #expect(!model.showsOnboarding); #expect(model.catalogMayStart)

        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await model.useFolder(empty)
        #expect(model.onboardingDue); #expect(model.showsOnboarding); #expect(!model.catalogMayStart)
        #expect(gameFiles(empty).isEmpty)
    }

    /// Two sheets never change places at once: while the folder sheet is on screen (closing after a choice) the onboarding
    /// sheet waits, and opens when the folder sheet has gone. "Collection Folder…" while the onboarding sheet is open
    /// closes it first and opens the folder sheet when it has gone; Cancel there brings the question back.
    @MainActor @Test func theOnboardingSheetWaitsForTheFolderSheet() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-offline", "YES", "-askUserFolder", "YES", "-onboarding", "YES"])
        await model.start()
        model.folderSheetOnScreen = true
        try await model.useICloudDrive()
        #expect(model.onboardingDue); #expect(!model.showsOnboarding); #expect(model.showsSheet)
        model.folderSheetClosed()
        #expect(model.showsOnboarding)

        model.askForFolder()
        #expect(!model.showsOnboarding); #expect(!model.showsFolderSheet)
        model.onboardingSheetClosed()
        #expect(model.showsFolderSheet); #expect(!model.showsOnboarding)
        model.folderSheetOnScreen = true
        model.showsFolderSheet = false                                         // Cancel
        model.folderSheetClosed()
        #expect(model.showsOnboarding); #expect(model.onboardingDue)
        // With no onboarding, "Collection Folder…" opens the folder sheet at once.
        await model.finishOnboarding(ProfileRows.toggled(Onboarding.draft(games: Games.all), game: "riftbound", member: .followed))
        model.onboardingSheetClosed()
        model.askForFolder()
        #expect(model.showsFolderSheet)
    }

    // MARK: Onboarding, fix round 1 (the owner's folder arriving late)

    /// A game file with one row (2 copies), as another device writes it.
    private static let lateFile = Data(#"{"collection":[{"count":2,"finish":"Normal","productID":7,"name":"Owner"}],"version":1}"#.utf8)

    /// (a) A new folder is due; a game file arrives (another writer) and the watcher's read runs: the question closes,
    /// nothing is written, the gate opens, the game shows its rows.
    @MainActor @Test(.timeLimit(.minutes(1))) func aGameFileThatArrivesClosesTheQuestion() async throws {
        let root = tempRoot(), user = AppPaths.userTestRoot(root)
        let model = model(["app", "-store", root.path, "-offline", "YES", "-onboarding", "YES"])
        await model.start()
        #expect(model.onboardingDue); #expect(model.showsOnboarding); #expect(!model.catalogMayStart)
        let file = user.appending(path: "cyberpunk.json")
        try Self.lateFile.write(to: file)
        await model.library.fileChanged(file)?.value
        try await until { !model.onboardingDue }
        #expect(!model.showsOnboarding); #expect(model.catalogMayStart)
        await model.library.flush()
        #expect(try Data(contentsOf: file) == Self.lateFile)
        #expect(gameFiles(user) == ["cyberpunk.json"])
        #expect(model.library.rows(game: "cyberpunk").map(\.count) == [2])
    }

    /// (b) A new folder is due; a valid game file is put on disk with no read of it. "Continue" reads the folder first and
    /// stops: the file keeps its bytes, the question closes, no other game file is made (with that game ticked or not).
    @MainActor @Test(.timeLimit(.minutes(1))) func continueReadsTheFolderFirstAndWritesNothingOverIt() async throws {
        for ticked in [false, true] {
            let root = tempRoot(), user = AppPaths.userTestRoot(root)
            let model = model(["app", "-store", root.path, "-offline", "YES", "-onboarding", "YES"])
            await model.start()
            #expect(model.onboardingDue)
            let file = user.appending(path: "riftbound.json")
            try Self.lateFile.write(to: file)                                    // no reload
            var draft = ProfileRows.toggled(Onboarding.draft(games: Games.all), game: "cyberpunk", member: .followed)
            if ticked { draft = ProfileRows.toggled(draft, game: "riftbound", member: .followed) }
            await model.finishOnboarding(draft)
            await model.library.flush()
            #expect(try Data(contentsOf: file) == Self.lateFile, "ticked: \(ticked)")
            #expect(gameFiles(user) == ["riftbound.json"], "ticked: \(ticked)")
            #expect(!model.onboardingDue); #expect(!model.showsOnboarding); #expect(model.catalogMayStart)
            #expect(model.library.rows(game: "riftbound").map(\.count) == [2])
        }
    }

    /// (d) Refresh (and "Try again") while the question is due makes no catalog request.
    @MainActor @Test(.timeLimit(.minutes(1))) func refreshWaitsForContinue() async throws {
        let root = tempRoot()
        let model = model(["app", "-store", root.path, "-onboarding", "YES", "-game", "riftbound"])
        let run = Task { await model.start() }
        try await until { model.onboardingDue }
        await model.refresh(rebuild: false)
        await model.refresh(rebuild: true)
        #expect(await fakeCatalog.groupCalls == 0); #expect(await fakeArchive.calls.isEmpty)
        await model.finishOnboarding(ProfileRows.toggled(Onboarding.draft(games: Games.all), game: "riftbound",
                                                         member: .followed))
        await run.value
        #expect(await fakeCatalog.groupCalls == 1)                           // Riftbound only
    }

    /// (e) A switch from a folder with Yu-Gi-Oh! off to a new empty folder: the new folder "follows" every game, but while
    /// the question is due no catalog step, price fill, filter list or set index scan starts for any game.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSwitchToANewFolderStartsNothingBeforeContinue() async throws {
        let root = tempRoot()
        let first = root.appending(path: "icloud").appending(path: "TCG Collection")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data(Self.notFollowed.utf8).write(to: first.appending(path: "yu-gi-oh.json"))
        // Yu-Gi-Oh!'s set index is marked due (a scan waits for the game to be followed again).
        let preferences = try #require(UserDefaults(suiteName: AppPaths(root: root).support.appending(path: "preferences").path))
        AppModel.markSetIndexDue("yu-gi-oh", in: preferences)
        let network = CountingFixtures()
        let model = fixtureModel(root, network, ["-askUserFolder", "YES", "-onboarding", "YES", "-game", "riftbound"])
        var scanned: [String] = []
        model.setIndexScanHook = { scanned.append($0) }
        let run = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(100))
        try await model.useICloudDrive()
        #expect(!model.onboardingDue)
        await run.value
        await model.waitForProfileWork(); await model.waitForSetIndexes()
        #expect(await !network.groups.contains(2))
        #expect(!scanned.contains("yu-gi-oh")); #expect(model.prices.day(game: "yu-gi-oh") == nil)
        let before = (await network.groups, await network.products.count, await network.archives, await network.fetches)
        let scansBefore = scanned

        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await model.useFolder(empty)
        #expect(model.onboardingDue)
        try await Task.sleep(for: .milliseconds(500))
        await model.waitForProfileWork(); await model.waitForSetIndexes()
        #expect(await network.groups == before.0); #expect(await network.products.count == before.1)
        #expect(await network.archives == before.2); #expect(await network.fetches == before.3)
        #expect(scanned == scansBefore, "\(scanned)")
        #expect(model.prices.day(game: "yu-gi-oh") == nil)                     // no price fill either
        #expect(!FileManager.default.fileExists(atPath: model.paths.facets("yu-gi-oh").path))
        #expect(gameFiles(empty).isEmpty)
    }

    /// The review's small items: `-importCSV` with `-onboarding YES` on a new folder opens no import sheet; a newer-version
    /// file as the only game file is a game file (not asked).
    @MainActor @Test func noImportUnderTheQuestionAndANewerFileIsAGameFile() async throws {
        let root = tempRoot()
        let csv = root.appending(path: "x.csv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not an export".utf8).write(to: csv)
        let model = model(["app", "-store", root.path, "-offline", "YES", "-onboarding", "YES", "-importCSV", csv.path])
        await model.start()
        #expect(model.onboardingDue); #expect(model.importing == nil)

        let newer = tempRoot()
        try writeUserFile(newer, "cyberpunk", #"{"version": 99, "collection": []}"#)
        let other = self.model(["app", "-store", newer.path, "-offline", "YES", "-onboarding", "YES"])
        await other.start()
        #expect(!other.onboardingDue); #expect(other.library.hasGameFile)
    }

    // MARK: Roles (phase 4B task 3: G7–G9)

    /// A Riftbound file with one active deck `rb1` (2 Dockside Lock-Up) and the given profile members.
    private static func riftboundDeck(profile: String) -> String {
        #"{"version":1,"collection":[],"decks":[{"id":"rb1","name":"Wind","format":"standard","active":true,"cards":[{"cardKey":"dockside lock up","name":"Dockside Lock-Up","section":"main","count":2}]}],"profile":"# + profile + "}"
    }

    /// G7, G8: a stored or launched deck screen without the player role, and Sets without the collector role, open the
    /// Collection; `-pasteDeck` opens no paste sheet without the player role. With the role, as before.
    @MainActor @Test func aLaunchOnAScreenOfARoleThatIsOffOpensTheCollection() async throws {
        let root = tempRoot()
        try writeUserFile(root, "riftbound", Self.riftboundDeck(profile: #"{"player":false}"#))
        let text = root.appending(path: "paste.txt")
        try Data("2 Dockside Lock-Up".utf8).write(to: text)
        let deck = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "deck:rb1",
                          "-pasteDeck", text.path])
        await deck.start()
        #expect(deck.screen == .collection)
        #expect(deck.pasting == nil)
        #expect(deck.decksInPlay(game: "riftbound").isEmpty); #expect(deck.library.decks(game: "riftbound").count == 1)
        let sets = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "sets"])
        await sets.start()
        #expect(sets.screen == .sets)                                          // the collector role is on

        let other = tempRoot()
        try writeUserFile(other, "riftbound", Self.riftboundDeck(profile: #"{"collector":false}"#))
        let off = model(["app", "-store", other.path, "-offline", "YES", "-game", "riftbound", "-screen", "sets"])
        await off.start()
        #expect(off.screen == .collection)
        let on = model(["app", "-store", other.path, "-offline", "YES", "-game", "riftbound", "-screen", "deck:rb1"])
        await on.start()
        #expect(on.screen == .deck("rb1"))                                     // the player role is on
        #expect(on.decksInPlay(game: "riftbound").map(\.id) == ["rb1"])
    }

    /// Review Focus 3: the player role turned off by another device while a deck page shows, with its sheets open (the
    /// paste sheet, New Deck, the sharing sheet): the Collection shows at its root, every sheet closes, `showsSheet` is
    /// false, and nothing is written (the file is the other device's, byte for byte; the deck stays in it). The collector
    /// role turned off while Sets shows: the Collection. A role of another game changes nothing on screen.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRoleTurnedOffElsewhereLeavesItsScreenAndClosesItsSheets() async throws {
        let root = tempRoot()
        try writeUserFile(root, "riftbound", Self.riftboundDeck(profile: "{}"))
        let model = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "deck:rb1"])
        await model.start()
        #expect(model.screen == .deck("rb1"))
        model.pasteDeck(into: "rb1")
        model.showsNewDeck = true
        model.newDeckCard = DeckCardToAdd(cardKey: "dockside lock up", name: "Dockside Lock-Up", kind: nil)
        model.pendingPaste = ("Deck", "standard")
        model.showsSharing = true
        #expect(model.pasting != nil && model.showsSheet)

        // Another game's role: nothing here moves.
        let magic = AppPaths.userTestRoot(root).appending(path: "magic-the-gathering.json")
        try Data(#"{"version":1,"collection":[],"profile":{"player":false,"collector":false}}"#.utf8).write(to: magic)
        await model.library.fileChanged(magic)?.value
        await model.waitForProfileWork()
        #expect(model.screen == .deck("rb1") && model.pasting != nil && model.showsSharing)

        let file = AppPaths.userTestRoot(root).appending(path: "riftbound.json")
        let written = Data(Self.riftboundDeck(profile: #"{"player":false}"#).utf8)
        try written.write(to: file)
        await model.library.fileChanged(file)?.value
        try await until { model.screen == .collection }
        #expect(model.showsRoot(.collection))
        #expect(model.pasting == nil); #expect(!model.showsNewDeck); #expect(model.newDeckCard == nil)
        #expect(model.pendingPaste == nil); #expect(!model.showsSharing); #expect(!model.showsSheet)
        #expect(model.library.decks(game: "riftbound").map(\.id) == ["rb1"])
        await model.library.flush()
        #expect(try Data(contentsOf: file) == written)

        // The collector role, while Sets shows.
        model.screen = .sets
        let noCollector = Data(Self.riftboundDeck(profile: #"{"player":false,"collector":false}"#).utf8)
        try noCollector.write(to: file)
        await model.library.fileChanged(file)?.value
        try await until { model.screen == .collection }
        await model.library.flush()
        #expect(try Data(contentsOf: file) == noCollector)
    }

    /// G8: a game switch to a game without the collector role while Sets shows opens that game's Collection; G9: with both
    /// roles off the Collection, Wanted, For Sale and All cards stay on a switch.
    @MainActor @Test func aGameSwitchFollowsTheRolesOfTheNewGame() async throws {
        let root = tempRoot()
        try writeUserFile(root, "cyberpunk", #"{"version":1,"collection":[],"profile":{"player":false,"collector":false}}"#)
        let model = model(["app", "-store", root.path, "-offline", "YES", "-game", "riftbound", "-screen", "sets"])
        await model.start()
        model.gameID = "cyberpunk"
        #expect(model.screen == .collection)
        for screen in [Screen.collection, .wanted, .forSale, .allCards] {
            model.gameID = "riftbound"
            model.screen = screen
            model.gameID = "cyberpunk"
            #expect(model.screen == screen, "\(screen)")
        }
    }

    /// G8: without the collector role the game's set index is not scanned (its due mark stays, no file is written); the
    /// role turned on asks for the scan, and the index is made.
    @MainActor @Test(.timeLimit(.minutes(1))) func noSetIndexScanWithoutTheCollectorRole() async throws {
        let root = tempRoot()
        try writeUserFile(root, "riftbound", #"{"version":1,"collection":[],"profile":{"collector":false}}"#)
        let network = CountingFixtures()
        let model = fixtureModel(root, network, ["-game", "riftbound"])
        var scanned: [String] = []
        model.setIndexScanHook = { scanned.append($0) }
        await model.start()
        await model.waitForSetIndexes()
        #expect(try await model.reader.progress(game: "riftbound").fetched >= 1)     // its catalog is synced
        #expect(!scanned.contains("riftbound"), "\(scanned)")
        #expect(!FileManager.default.fileExists(atPath: model.paths.sets("riftbound").path))
        #expect(model.setIndexIsDue("riftbound"))
        for game in ["magic-the-gathering", "yu-gi-oh", "cyberpunk"] {
            #expect(FileManager.default.fileExists(atPath: model.paths.sets(game).path), "\(game)")
        }

        model.library.setProfile(.all, game: "riftbound")
        try await until { scanned.contains("riftbound") }
        await model.waitForSetIndexes()
        #expect(FileManager.default.fileExists(atPath: model.paths.sets("riftbound").path))
        #expect(!model.setIndexIsDue("riftbound"))
    }
}

/// The fixture network (every game) with its requests counted: set lists and sets by category, archives by day, other
/// requests by the URL's last path component.
private actor CountingFixtures {
    private let catalog = FileCatalogClient(directory: fixturesDirectory())
    private let archive = FileArchiveClient(directory: fixturesDirectory())
    private let fetcher = FileFetcher(directory: fixturesDirectory())
    private(set) var groups: [Int] = []
    private(set) var products: [Int] = []
    private(set) var archives: [String] = []
    private(set) var fetches: [String] = []

    func groups(category: Int) async throws -> Data {
        groups.append(category)
        return try await catalog.groups(category: category)
    }

    func products(category: Int, group: Int) async throws -> Data {
        products.append(category)
        return try await catalog.products(category: category, group: group)
    }

    func download(day: String, to file: URL) async throws -> Bool {
        archives.append(day)
        return try await archive.download(day: day, to: file)
    }

    func data(from url: URL) async throws -> (Data, Int) {
        fetches.append(url.lastPathComponent)
        return try await fetcher.data(from: url)
    }
}

extension CountingFixtures: TCGCSVFetching, ArchiveFetching, DataFetching {}

/// An archive client whose first download waits until `release()`: a test can look at the model during the price step.
private actor GatedArchive: ArchiveFetching {
    private(set) var called = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    func download(day: String, to file: URL) async throws -> Bool {
        if !called {
            called = true
            if !released { await withCheckedContinuation { waiting = $0 } }
        }
        return false
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}
