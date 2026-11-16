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
        #expect(first.setIndexes["riftbound"] == SetIndex(sets: [1: [1]]))
        let madeUp = SetIndex(sets: [77: [5, 6]])
        try madeUp.write(to: paths.sets("riftbound"))
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(second.setIndexes["riftbound"] == madeUp)                            // before any store read
        await second.start()
        #expect(second.setIndexes["riftbound"] == madeUp)                            // no scan replaced it
        #expect(SetIndex.read(paths.sets("riftbound")) == madeUp)
    }

    /// F3: a catalog step that changed a game writes its set index, as it writes the facets file.
    @MainActor @Test func theSetIndexIsWrittenAfterASync() async throws {
        let root = tempRoot()
        let first = model(["app", "-store", root.path])
        await first.start()
        let index = try #require(first.setIndexes["riftbound"])
        #expect(!index.sets.isEmpty)
        #expect(SetIndex.read(AppPaths(root: root).sets("riftbound")) == index)
        let second = model(["app", "-store", root.path, "-offline", "YES"])
        #expect(second.setIndexes["riftbound"] == index)
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
        let model = model(["app", "-store", tempRoot().path, "-offline", "YES"])
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
}

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
