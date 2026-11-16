import Foundation
import Testing
@testable import TCGCollection2

/// The two rows of the Task 6 test (`ImportComparisonTests.current`), in the file form the app keeps.
private let twoRows = #"{"version":1,"collection":[{"productID":721334,"finish":"Foil","count":1,"condition":"","name":"Dockside Lock-Up"},{"productID":555,"finish":"Normal","count":2,"condition":"Mint","name":"Only Here"}]}"#

private let dockside = PrintingKey(productID: 721334, finish: "Foil")
private let onlyHere = PrintingKey(productID: 555, finish: "Normal")

/// Stands in for `AppModel.catalogSettled`: whether the game's catalog step of this run has ended.
@MainActor private final class CatalogStep {
    var settled = false
}

/// `"<productID> <finish> <count>"` per row, in the file's order.
private func shown(_ rows: [CollectionRow]) -> [String] { rows.map { "\($0.productID) \($0.finish) \($0.count)" } }

@MainActor
struct ImportModelTests {
    /// The fixture catalog (`filledStore`) plus the plain basic rune of the Task 6 test, in a set of its own, so the
    /// comparison has Task 6's numbers: one line not in the catalog (999999), the plain basic rune (900001), which is imported like any card (A9).
    private func catalog() async throws -> CatalogStore {
        let store = try await filledStore()
        let rune = product(id: 900001, game: "riftbound", groupID: 99, name: "Calm Rune", number: "R02", rarity: "Common", cardType: "Rune")
        try await store.replaceProducts(of: 99, with: [rune], at: Date(timeIntervalSince1970: 1_800_000_000))
        return store
    }

    /// A library on a temporary folder whose `riftbound.json` holds `json` (no file when nil), read once.
    private func library(_ json: String? = twoRows, extra: [String: String] = [:]) async throws -> (UserLibrary, URL) {
        let folder = tempDir()
        if let json { try Data(json.utf8).write(to: folder.appending(path: "riftbound.json")) }
        for (name, text) in extra { try Data(text.utf8).write(to: folder.appending(path: name)) }
        let library = UserLibrary(folder: folder, watcher: nil)
        await library.load()
        return (library, folder)
    }

    private func importing(_ data: Data, library: UserLibrary, reader: CatalogStore,
                           settled: @escaping @MainActor (String) -> Bool = { _ in true }) -> ImportModel {
        ImportModel(data: data, fileName: "collection-riftbound.csv", library: library, reader: reader, catalogSettled: settled)
    }

    // MARK: The brief's six

    @Test func prepareComparesTheFileWithTheCollection() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        #expect(model.state == .reading)
        await model.prepare()
        #expect(model.state == .ready)
        let c = try #require(model.comparisons.first)
        #expect(model.comparisons.count == 1 && c.gameID == "riftbound")
        #expect(c.new.map { "\($0.key.productID) \($0.name) \($0.old)->\($0.new)" } == ["900001 Calm Rune 0->5", "722282 Calm Rune (R02a) 0->4", "721337 Kai'Sa, Rebel 0->3"])
        #expect(c.changed.map { "\($0.key.productID) \($0.old)->\($0.new) \($0.condition)" } == ["721334 1->3 Near Mint, Lightly Played"])
        #expect(c.missing.map(\.key) == [onlyHere])
        #expect(c.notRecognised.map(\.line) == [6])
        #expect(model.skipped.isEmpty && model.remove.isEmpty && model.notice == nil)
        #expect(model.summary == "3 new, 1 changed, 1 not in the file (kept)")
        #expect(model.block(game: "riftbound") == nil && model.canApply)
        // "Not imported": the parse's skips, other games, not-recognised lines, by line.
        #expect(model.notImported.map { "\($0.line) \($0.reason)" } == ["6 not in the catalog"])
        #expect(model.setName(of: PrintingKey(productID: 721337, finish: "Normal")) == "Radiance")
        #expect(model.setName(of: onlyHere) == nil)                             // not in the catalog
    }

    @Test func applyWritesTheNewAndChangedRowsAndKeepsTheMissingOne() async throws {
        let (library, folder) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.apply() == ImportModel.Applied(gameID: "riftbound", games: ["riftbound"], summary: "3 new, 1 changed, 1 not in the file (kept)",
                                                     counts: ["riftbound": .init(new: 3, changed: 1, missing: 1)]))
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "555 Normal 2", "900001 Normal 5", "722282 Normal 4", "721337 Normal 3"])
        // The import's own write is not "a change made while the sheet was open" (the sheet sees the version move).
        #expect(!model.refreshComparison() && model.notice == nil)
        await library.flush()
        let file = try GameUserFile(data: Data(contentsOf: folder.appending(path: "riftbound.json")))
        #expect(file.collection == library.rows(game: "riftbound"))
        #expect(file.collection[1] == CollectionRow(productID: 555, finish: "Normal", count: 2, condition: "Mint", name: "Only Here"))
    }

    @Test func removeAllThenApplyRemovesTheMissingRow() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        model.setAllMissing(remove: true, game: "riftbound")
        #expect(model.remove == [onlyHere] && model.allMissingRemoved(game: "riftbound"))
        #expect(model.summary == "3 new, 1 changed, 1 not in the file (removed)")
        model.setAllMissing(remove: false, game: "riftbound")
        #expect(model.remove.isEmpty && !model.allMissingRemoved(game: "riftbound"))
        model.setAllMissing(remove: true, game: "yu-gi-oh")                     // a game the file does not have: nothing
        #expect(model.remove.isEmpty)
        model.setAllMissing(remove: true, game: "riftbound")
        #expect(model.apply()?.summary == "3 new, 1 changed, 1 not in the file (removed)")
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "900001 Normal 5", "722282 Normal 4", "721337 Normal 3"])
    }

    /// The same file a second time: nothing would change, only Close is offered, and `apply` writes nothing. (The first
    /// import removes "Only Here": a kept row would still be offered for removal, see the next test.)
    @Test func aSecondImportOfTheSameFileChangesNothing() async throws {
        let (library, _) = try await library()
        let reader = try await catalog()
        let first = importing(try fixture("collection-riftbound.csv"), library: library, reader: reader)
        await first.prepare()
        first.setAllMissing(remove: true, game: "riftbound")
        #expect(first.apply() != nil)
        let rows = library.rows(game: "riftbound"), version = library.version

        let second = importing(try fixture("collection-riftbound.csv"), library: library, reader: reader)
        await second.prepare()
        #expect(second.state == .ready)
        #expect(second.summary == "This file matches your collection.")
        #expect(!second.canApply)
        #expect(second.apply() == nil)
        #expect(library.version == version && library.rows(game: "riftbound") == rows)
    }

    /// A row kept at the first import is still not in the file: the second import shows it, says there is nothing to
    /// import and offers no Import (fix round 1, item 2) until the row is set to Remove.
    @Test func aSecondImportAfterKeepingOffersOnlyTheMissingRow() async throws {
        let (library, _) = try await library()
        let reader = try await catalog()
        let first = importing(try fixture("collection-riftbound.csv"), library: library, reader: reader)
        await first.prepare()
        #expect(first.apply() != nil)
        let version = library.version

        let second = importing(try fixture("collection-riftbound.csv"), library: library, reader: reader)
        await second.prepare()
        let c = try #require(second.comparisons.first)
        #expect(c.new.isEmpty && c.changed.isEmpty && c.missing.map(\.key) == [onlyHere])
        #expect(second.summary == "Nothing to import: this file adds nothing to your collection.")
        #expect(!second.writes && !second.canApply)
        #expect(second.apply() == nil)
        #expect(library.version == version)                                     // nothing was written

        second.setAllMissing(remove: true, game: "riftbound")                   // Remove makes Import available again
        #expect(second.writes && second.canApply && second.summary == "1 not in the file (removed)")
        #expect(second.apply()?.summary == "1 not in the file (removed)")
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "900001 Normal 5", "722282 Normal 4", "721337 Normal 3"])
    }

    @Test func dataThatIsNotAnExportFails() async throws {
        let (library, _) = try await library()
        let model = importing(Data("not json".utf8), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.state == .failed("This is not a TCGplayer collection export."))
        #expect(model.comparisons.isEmpty && !model.canApply && model.apply() == nil)
    }

    @Test func aFileOfOnlyAnotherGameHasNoComparison() async throws {
        let (library, _) = try await library()
        let csv = "Product ID,Product Line,Product Name,Add to Quantity\n700001,Pokemon,Pikachu,2\n"
        let model = importing(Data(csv.utf8), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.state == .ready && model.comparisons.isEmpty)
        #expect(model.skipped == [SkippedLine(line: 2, name: "Pikachu", reason: "not one of the four games")])
        #expect(model.notImported == model.skipped)
        #expect(model.summary == "This file has no cards of the four games.")
        #expect(!model.canApply && model.apply() == nil)
    }

    /// Final fix A1: a new row takes the price table's spelling of its finish (`Foil`, not the file's `foil`), so the card
    /// page, the price lookup and `+` find it. The price table is the model's: the fixture prices have 721334 Normal and
    /// Foil.
    @Test func aNewRowTakesTheFinishSpellingOfThePriceTable() async throws {
        let (library, _) = try await library(nil)
        let csv = "Product ID,Product Line,Product Name,Printing,Add to Quantity\n"
            + "721334,Riftbound: League of Legends Trading Card Game,Dockside Lock-Up,foil,2\n"
        let model = ImportModel(data: Data(csv.utf8), fileName: "c.csv", library: library, reader: try await catalog(),
                                prices: try filledTable(), catalogSettled: { _ in true })
        await model.prepare()
        #expect(model.comparisons.first?.new.map { "\($0.key.finish) \($0.new)" } == ["Foil 2"])
        #expect(model.apply() != nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 2"])
    }

    /// Final fix A7: the sheet's tables have a choice column only when a shown group offers Remove ("In your collection,
    /// not in this file"); every row then keeps it, so the numbers stay in one column. Without one (a first import: all
    /// New), the name takes that width.
    @Test func theChoiceColumnIsThereOnlyWhenAGroupOffersRemove() async throws {
        let reader = try await catalog()
        let (empty, _) = try await library(nil)
        let first = importing(try fixture("collection-riftbound.csv"), library: empty, reader: reader)
        await first.prepare()
        #expect(first.comparisons.first?.missing.isEmpty == true && !first.offersRemove)
        let (owned, _) = try await library()
        let again = importing(try fixture("collection-riftbound.csv"), library: owned, reader: reader)
        await again.prepare()
        #expect(again.offersRemove)
        // A game whose groups are not shown (its catalog is not ready) offers nothing.
        let downloading = importing(try fixture("collection-riftbound.csv"), library: owned, reader: reader, settled: { _ in false })
        await downloading.prepare()
        #expect(downloading.comparisons.first?.missing.isEmpty == false && !downloading.offersRemove)
    }

    // MARK: The rulings of the dispatch

    /// `-importCSV` opens the sheet while the folder is still read: a comparison with an unread collection would call
    /// every row new and offer nothing for removal. `prepare` waits for the first read.
    @Test(.timeLimit(.minutes(1))) func prepareWaitsUntilTheCollectionIsRead() async throws {
        let folder = tempDir()
        try Data(twoRows.utf8).write(to: folder.appending(path: "riftbound.json"))
        let library = UserLibrary(folder: folder, watcher: nil)
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        let preparing = Task { await model.prepare() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.state == .reading)
        await library.load()
        await preparing.value
        let c = try #require(model.comparisons.first)
        #expect(c.changed.map(\.key) == [dockside] && c.missing.map(\.key) == [onlyHere])
    }

    /// A folder that is not there: the wait ends, the game is shown with the folder's problem, and nothing is offered.
    @Test(.timeLimit(.minutes(1))) func aMissingFolderEndsTheWaitAndBlocksTheImport() async throws {
        let folder = tempDir().appending(path: "gone", directoryHint: .isDirectory)
        let library = UserLibrary(folder: folder, watcher: nil)
        await library.load()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.state == .ready)
        #expect(model.block(game: "riftbound") == .collection("The collection folder is not at \(folder.path)."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A game whose file this app must not rewrite: its comparison is shown with the reason, and it is left out of apply.
    @Test func aRefusedFileIsShownButNotImported() async throws {
        let newer = #"{"version":2,"collection":[]}"#
        let (library, folder) = try await library(newer)
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.comparisons.map(\.gameID) == ["riftbound"])
        #expect(model.block(game: "riftbound") == .collection("riftbound.json was written by a newer version of the app."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(model.summary == "Nothing in this file can be imported now.")
        await library.flush()
        #expect(try Data(contentsOf: folder.appending(path: "riftbound.json")) == Data(newer.utf8))
    }

    /// While the game's catalog step has not ended, every line could read as "not in the catalog": no Import for that
    /// game, the sheet says the catalog is downloading, and its lines are not listed as unknown. When the step ends, the
    /// comparison made during the download is still not importable (fix round 1, item 1): only a `prepare` made after it
    /// makes the game importable, and it keeps the Remove choices that still apply.
    @Test func aCatalogThatIsStillDownloadingBlocksTheGame() async throws {
        let (library, _) = try await library()
        let catalogStep = CatalogStep()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog(),
                              settled: { _ in catalogStep.settled })
        await model.prepare()
        #expect(model.state == .ready)
        #expect(model.block(game: "riftbound") == .catalog("The catalog is being updated. This game can be imported when the update is done."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(model.notImported.isEmpty)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 1", "555 Normal 2"])

        catalogStep.settled = true
        #expect(model.block(game: "riftbound") == .catalog("The catalog is being updated. This game can be imported when the update is done."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 1", "555 Normal 2"])
        model.setAllMissing(remove: true, game: "riftbound")
        await model.prepare()                                                  // the sheet does it when the step ends
        #expect(model.block(game: "riftbound") == nil && model.canApply)
        #expect(model.remove == [onlyHere])
        #expect(model.apply()?.summary == "3 new, 1 changed, 1 not in the file (removed)")
    }

    /// Fix round 1, item 1: while a `prepare` runs again (a catalog step ended), the comparison on screen stays, and
    /// Import is off until the new one is made.
    @Test(.timeLimit(.minutes(1))) func importIsOffWhileARePrepareRuns() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.canApply)
        let gate = ReadGate()
        model.beforeLookup = { await gate.pass(URL(fileURLWithPath: "/lookup")) }
        let again = Task { await model.prepare() }
        try await gate.waitUntilHolding()
        #expect(model.state == .ready && model.isPreparing && model.comparisons.count == 1)
        #expect(!model.canApply && model.apply() == nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 1", "555 Normal 2"])
        gate.open()
        await again.value
        #expect(!model.isPreparing && model.canApply)
    }

    /// Fix round 2, item 1: a first `prepare` on a settled catalog leaves nothing due (the sheet runs no second one).
    @Test func aFirstPrepareOnASettledCatalogLeavesNoPrepareDue() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        #expect(!model.needsPrepare)
        await model.prepare()
        #expect(!model.needsPrepare && model.canApply)
    }

    /// Fix round 2, item 1: a comparison made while the game's catalog downloaded is due again once the catalog is
    /// settled, and only then; the `prepare` that follows leaves nothing due.
    @Test func aComparisonMadeDuringADownloadIsDueOnceSettled() async throws {
        let (library, _) = try await library()
        let catalogStep = CatalogStep()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog(),
                              settled: { _ in catalogStep.settled })
        await model.prepare()
        #expect(!model.needsPrepare)                                            // still downloading: nothing to gain yet
        catalogStep.settled = true
        #expect(model.needsPrepare)
        await model.prepare()
        #expect(!model.needsPrepare && model.canApply)
    }

    /// Fix round 2, item 2: a row added elsewhere whose product the last lookup did not read is not compared from the
    /// cached lookup: Import is off, a full `prepare` is due, and after it the product is known (its set's name).
    @Test func aRowOfAProductNotLookedUpAsksForAFullPrepare() async throws {
        let (library, _) = try await library()
        let reader = try await catalog()
        let elsewhere = product(id: 900002, game: "riftbound", groupID: 98, name: "Elsewhere", number: "E01", rarity: "Common", cardType: "Unit")
        try await reader.upsertSets([SetRecord(groupID: 98, gameID: "riftbound", name: "Elsewhere Set", abbreviation: "", publishedOn: nil)])
        try await reader.replaceProducts(of: 98, with: [elsewhere], at: Date(timeIntervalSince1970: 1_800_000_000))
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: reader)
        await model.prepare()
        let key = PrintingKey(productID: 900002, finish: "Normal")
        library.setCount(1, game: "riftbound", key: key, name: "Elsewhere")
        let version = library.version
        #expect(model.refreshComparison())                                      // not the comparison shown any more
        #expect(model.needsPrepare && !model.canApply && model.apply() == nil)
        #expect(library.version == version)
        #expect(model.notice == "Your collection changed while this sheet was open. Check the comparison again.")
        await model.prepare()
        #expect(!model.needsPrepare && model.canApply)
        #expect(model.comparisons.first?.missing.map(\.key) == [key, onlyHere])  // by name: Elsewhere, Only Here
        #expect(model.setName(of: key) == "Elsewhere Set")
    }

    /// Fix round 2, item 3: a first `prepare` that is cancelled (the sheet closed while it ran) never says the file or the
    /// catalog failed; the next `prepare` works.
    @Test(.timeLimit(.minutes(1))) func aCancelledPrepareDoesNotFail() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        let gate = ReadGate()
        model.beforeLookup = { await gate.pass(URL(fileURLWithPath: "/lookup")) }
        let first = Task { await model.prepare() }
        try await gate.waitUntilHolding()
        first.cancel()
        gate.open()
        await first.value
        #expect(model.state == .reading && !model.isPreparing)
        model.beforeLookup = nil
        await model.prepare()
        #expect(model.state == .ready)
    }

    /// A settled catalog with no product of the game (offline on an empty catalog, every set failed): blocked as well.
    @Test func aCatalogWithoutTheGamesCardsBlocksTheGame() async throws {
        let (library, _) = try await library()
        let empty = try CatalogStore(url: tempDir().appending(path: "catalog.store"))
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: empty)
        await model.prepare()
        #expect(model.block(game: "riftbound") == .catalog("The catalog has no cards of this game yet. Import the file again once it has downloaded."))
        #expect(!model.canApply && model.apply() == nil && model.notImported.isEmpty)
    }

    /// The collection changed after the comparison was made (a click elsewhere, a reload from disk): `apply` makes the
    /// comparison again and writes nothing, so the user confirms what is shown; the next `apply` writes the new one.
    @Test func aCollectionThatChangedSincePrepareIsComparedAgainBeforeAnythingIsWritten() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        model.setAllMissing(remove: true, game: "riftbound")
        library.setCount(3, game: "riftbound", key: dockside, name: "Dockside Lock-Up")
        let version = library.version
        #expect(model.apply() == nil)
        #expect(library.version == version)
        #expect(model.notice == "Your collection changed while this sheet was open. Check the comparison again.")
        #expect(model.comparisons.first?.changed.isEmpty == true)
        #expect(model.remove == [onlyHere])                                     // still in group 3: the choice stays
        #expect(model.summary == "3 new, 1 not in the file (removed)")
        #expect(model.apply()?.summary == "3 new, 1 not in the file (removed)")
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "900001 Normal 5", "722282 Normal 4", "721337 Normal 3"])
    }

    /// A change that leaves the comparison as it is (another game's row) does not hold the import up.
    @Test func aChangeElsewhereThatLeavesTheComparisonAloneDoesNotHoldTheImport() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        library.setCount(1, game: "yu-gi-oh", key: PrintingKey(productID: 7, finish: "Normal"), name: "Other")
        #expect(model.apply() != nil && model.notice == nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "555 Normal 2", "900001 Normal 5", "722282 Normal 4", "721337 Normal 3"])
    }

    /// A file of two games where one game's file is refused: only the other game is imported, the summary counts only it,
    /// and the first game imported is the one the Collection then shows.
    @Test func aBlockedGameIsLeftOutOfApplyAndTheSummary() async throws {
        let (library, folder) = try await library(extra: ["yu-gi-oh.json": "not json"])
        let model = importing(try fixture("collection-mixed.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.comparisons.map(\.gameID) == ["yu-gi-oh", "riftbound"])
        #expect(model.block(game: "yu-gi-oh") == .collection("yu-gi-oh.json cannot be read."))
        #expect(model.block(game: "riftbound") == nil)
        #expect(model.skipped.map(\.name) == ["Pikachu"])
        #expect(model.summary == "1 new, 1 changed, 1 not in the file (kept)")
        #expect(model.apply() == ImportModel.Applied(gameID: "riftbound", games: ["riftbound"], summary: "1 new, 1 changed, 1 not in the file (kept)",
                                                     counts: ["riftbound": .init(new: 1, changed: 1, missing: 1)]))
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 2", "555 Normal 2", "721337 Normal 1"])
        await library.flush()
        #expect(try Data(contentsOf: folder.appending(path: "yu-gi-oh.json")) == Data("not json".utf8))
    }

    /// G12: a game that is not followed is not imported: its header says it is turned off, its groups and its unknown
    /// lines are not shown, and its file is not written. The other games of the file are imported.
    @Test func aGameThatIsNotFollowedIsNotImported() async throws {
        let off = #"{"version":1,"collection":[],"profile":{"followed":false}}"#
        let (library, folder) = try await library(extra: ["yu-gi-oh.json": off])
        let model = importing(try fixture("collection-mixed.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.comparisons.map(\.gameID) == ["yu-gi-oh", "riftbound"])
        let block = try #require(model.block(game: "yu-gi-oh"))
        #expect(block == .turnedOff)
        #expect(block.text == "This game is turned off in Settings.")
        #expect(block.hidesComparison)
        #expect(model.block(game: "riftbound") == nil)
        #expect(model.notImported.map(\.name) == ["Pikachu"])
        #expect(model.summary == "1 new, 1 changed, 1 not in the file (kept)")
        #expect(model.apply() == ImportModel.Applied(gameID: "riftbound", games: ["riftbound"], summary: "1 new, 1 changed, 1 not in the file (kept)",
                                                     counts: ["riftbound": .init(new: 1, changed: 1, missing: 1)]))
        await library.flush()
        #expect(try Data(contentsOf: folder.appending(path: "yu-gi-oh.json")) == Data(off.utf8))
        #expect(library.rows(game: "yu-gi-oh").isEmpty)
    }

    /// B3 (final fix): a game turned on while the sheet is open makes a `prepare` due, so the sheet does not end on a
    /// comparison made while the game was off; after it the game is no longer blocked as turned off.
    @Test func aGameTurnedOnWhileTheSheetIsOpenIsPreparedAgain() async throws {
        let off = #"{"version":1,"collection":[],"profile":{"followed":false}}"#
        let (library, _) = try await library(extra: ["yu-gi-oh.json": off])
        let model = importing(try fixture("collection-mixed.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.block(game: "yu-gi-oh") == .turnedOff)
        #expect(!model.needsPrepare)
        library.setProfile(.all, game: "yu-gi-oh")
        #expect(model.needsPrepare)
        await model.prepare()
        #expect(!model.needsPrepare)
        #expect(model.block(game: "yu-gi-oh") != .turnedOff)
        library.setProfile(GameProfile(followed: false), game: "yu-gi-oh")
        #expect(model.needsPrepare)                                             // turned off again: prepared again too
    }

    /// A3 (final fix): `Applied` keeps each game's counts, so the summary of only the games written can be said; the
    /// summary of every game written is the summary itself.
    @Test func theSummaryOfSomeGamesOfAnImport() {
        let applied = ImportModel.Applied(gameID: "riftbound", games: ["riftbound", "yu-gi-oh"], summary: "3 new, 1 changed, 2 not in the file (1 removed, 1 kept)",
                                          counts: ["riftbound": .init(new: 2, changed: 1),
                                                   "yu-gi-oh": .init(new: 1, missing: 2, removed: 1)])
        #expect(applied.summary(of: ["riftbound", "yu-gi-oh"]) == applied.summary)
        #expect(applied.summary(of: ["yu-gi-oh", "riftbound"]) == applied.summary)
        #expect(applied.summary(of: ["riftbound"]) == "2 new, 1 changed")
        #expect(applied.summary(of: ["yu-gi-oh"]) == "1 new, 2 not in the file (1 removed, 1 kept)")
        #expect(ImportModel.summaryText(.init()) == nil)
        #expect(ImportModel.summaryText(.init(missing: 1, removed: 1)) == "1 not in the file (removed)")
    }

    /// A file that could not be read at all: one sentence, nothing else.
    @Test func anUnreadableFileFails() async throws {
        let (library, _) = try await library()
        let model = ImportModel(unreadable: "no permission", fileName: "x.csv", library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.state == .failed("This file could not be read (no permission)."))
        #expect(!model.canApply && model.apply() == nil)
    }

    /// Two rows that would read the same in a table (name and finish, any case) get their set's name.
    @Test func rowsThatReadTheSameAreToldApart() {
        func change(_ id: Int, _ finish: String, _ name: String) -> ImportComparison.Change {
            .init(key: PrintingKey(productID: id, finish: finish), name: name, old: 0, new: 1, condition: "")
        }
        let changes = [change(1, "Normal", "Lightning Bolt"), change(2, "Normal", "lightning bolt"), change(1, "Foil", "Lightning Bolt"),
                       change(3, "Normal", "Shock")]
        #expect(ImportModel.ambiguous(changes) == [PrintingKey(productID: 1, finish: "Normal"), PrintingKey(productID: 2, finish: "Normal")])
    }
}
