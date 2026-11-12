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
    /// comparison has Task 6's numbers: one line not in the catalog (999999), one ignored basic rune (900001).
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
        #expect(c.new.map { "\($0.key.productID) \($0.name) \($0.old)->\($0.new)" } == ["722282 Calm Rune (R02a) 0->4", "721337 Kai'Sa, Rebel 0->3"])
        #expect(c.changed.map { "\($0.key.productID) \($0.old)->\($0.new) \($0.condition)" } == ["721334 1->3 Near Mint, Lightly Played"])
        #expect(c.missing.map(\.key) == [onlyHere])
        #expect(c.notRecognised.map(\.line) == [6] && c.ignoredBasics.map(\.line) == [5])
        #expect(model.skipped.isEmpty && model.remove.isEmpty && model.notice == nil)
        #expect(model.summary == "2 new, 1 changed, 1 not in the file (kept)")
        #expect(model.block(game: "riftbound") == nil && model.canApply)
        // "Not imported": the parse's skips, other games, not-recognised and ignored lines, by line.
        #expect(model.notImported.map { "\($0.line) \($0.reason)" } == ["5 basic rune", "6 not in the catalog"])
        #expect(model.setName(of: PrintingKey(productID: 721337, finish: "Normal")) == "Radiance")
        #expect(model.setName(of: onlyHere) == nil)                             // not in the catalog
    }

    @Test func applyWritesTheNewAndChangedRowsAndKeepsTheMissingOne() async throws {
        let (library, folder) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        #expect(model.apply() == ImportModel.Applied(gameID: "riftbound", summary: "2 new, 1 changed, 1 not in the file (kept)"))
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "555 Normal 2", "722282 Normal 4", "721337 Normal 3"])
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
        #expect(model.summary == "2 new, 1 changed, 1 not in the file (removed)")
        model.setAllMissing(remove: false, game: "riftbound")
        #expect(model.remove.isEmpty && !model.allMissingRemoved(game: "riftbound"))
        model.setAllMissing(remove: true, game: "yu-gi-oh")                     // a game the file does not have: nothing
        #expect(model.remove.isEmpty)
        model.setAllMissing(remove: true, game: "riftbound")
        #expect(model.apply()?.summary == "2 new, 1 changed, 1 not in the file (removed)")
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "722282 Normal 4", "721337 Normal 3"])
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
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "722282 Normal 4", "721337 Normal 3"])
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
        #expect(model.block(game: "riftbound") == .catalog("The catalog is still downloading. This game can be imported when it is ready."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(model.notImported.isEmpty)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 1", "555 Normal 2"])

        catalogStep.settled = true
        #expect(model.block(game: "riftbound") == .catalog("The catalog is still downloading. This game can be imported when it is ready."))
        #expect(!model.canApply && model.apply() == nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 1", "555 Normal 2"])
        model.setAllMissing(remove: true, game: "riftbound")
        await model.prepare()                                                  // the sheet does it when the step ends
        #expect(model.block(game: "riftbound") == nil && model.canApply)
        #expect(model.remove == [onlyHere])
        #expect(model.apply()?.summary == "2 new, 1 changed, 1 not in the file (removed)")
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

    /// Fix round 1, item 3: the sheet prepares again only when one of the file's games becomes settled, not when a step
    /// starts or the catalog only grows.
    @Test func aPrepareIsDueOnlyWhenAGameBecomesSettled() {
        #expect(ImportModel.prepareIsDue(settled: ["riftbound"], before: []))
        #expect(ImportModel.prepareIsDue(settled: ["riftbound", "yu-gi-oh"], before: ["riftbound"]))
        #expect(!ImportModel.prepareIsDue(settled: [], before: ["riftbound"]))            // a Refresh started
        #expect(!ImportModel.prepareIsDue(settled: ["riftbound"], before: ["riftbound"]))
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
        #expect(model.summary == "2 new, 1 not in the file (removed)")
        #expect(model.apply()?.summary == "2 new, 1 not in the file (removed)")
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "722282 Normal 4", "721337 Normal 3"])
    }

    /// A change that leaves the comparison as it is (another game's row) does not hold the import up.
    @Test func aChangeElsewhereThatLeavesTheComparisonAloneDoesNotHoldTheImport() async throws {
        let (library, _) = try await library()
        let model = importing(try fixture("collection-riftbound.csv"), library: library, reader: try await catalog())
        await model.prepare()
        library.setCount(1, game: "yu-gi-oh", key: PrintingKey(productID: 7, finish: "Normal"), name: "Other")
        #expect(model.apply() != nil && model.notice == nil)
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 3", "555 Normal 2", "722282 Normal 4", "721337 Normal 3"])
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
        #expect(model.apply() == ImportModel.Applied(gameID: "riftbound", summary: "1 new, 1 changed, 1 not in the file (kept)"))
        #expect(shown(library.rows(game: "riftbound")) == ["721334 Foil 2", "555 Normal 2", "721337 Normal 1"])
        await library.flush()
        #expect(try Data(contentsOf: folder.appending(path: "yu-gi-oh.json")) == Data("not json".utf8))
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
