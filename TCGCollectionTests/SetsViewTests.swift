import Foundation
import Testing
@testable import TCGCollection2

/// The Sets list's state (phase 4A task 3): its screen value, when its rows are made again, what its catalog line says,
/// and the rows made off the main thread from a snapshot of the prices.
@MainActor
struct SetsViewTests {
    private func key(_ library: Int = 0, game: String = "riftbound", index: Int = 1) -> SetsKey {
        SetsKey(game: game, libraryVersion: library, priceDay: "2026-11-16", catalogVersion: 3, setIndexVersion: index)
    }

    private func row(_ id: Int, owned: Int, total: Int) -> SetRow {
        SetRow(set: SetRecord(groupID: id, gameID: "riftbound", name: "Set \(id)", abbreviation: "S\(id)", publishedOn: nil),
               numbers: SetNumbers(owned: owned, total: total, missingSum: nil, missingUnpriced: total - owned))
    }

    private struct ReadFailed: Error {}

    // MARK: The screen

    @Test func setsIsAStoredScreen() {
        #expect(Screen(storedValue: "sets") == .sets)
        #expect(Screen.sets.storedValue == "sets")
        #expect(Screen.sets.isList)
        #expect(LaunchOptions(arguments: ["app", "-screen", "sets"]).screen == .sets)
    }

    // MARK: When the rows are made

    @Test func rowsAreMadeOncePerKey() async {
        let state = SetsScreenState(gameID: "riftbound")
        #expect(state.needsRows(for: key()))
        await state.run(key(), loaded: true) { [row(1, owned: 1, total: 4)] }
        #expect(!state.needsRows(for: key()))
        #expect(state.needsRows(for: key(1)))                    // the collection changed
        #expect(state.needsRows(for: key(index: 2)))             // the index arrived or was made again
        #expect(state.rows == [row(1, owned: 1, total: 4)])
    }

    @Test func nothingIsMadeBeforeTheFolderIsRead() async {
        let state = SetsScreenState(gameID: "riftbound")
        var made = false
        await state.run(key(), loaded: false) { made = true; return [] }
        #expect(!made && state.rows == nil && state.needsRows(for: key()))
    }

    /// Review Focus 5: a failed read keeps the last rows, says so, and is tried again with the same key.
    @Test func aFailedReadKeepsTheLastRows() async {
        let state = SetsScreenState(gameID: "riftbound")
        await state.run(key(), loaded: true) { [row(1, owned: 1, total: 4)] }
        await state.run(key(1), loaded: true) { throw ReadFailed() }
        #expect(state.rows == [row(1, owned: 1, total: 4)])
        #expect(state.failed)
        #expect(state.needsRows(for: key(1)))
        #expect(SetsScreenState.note(catalogSettled: true, hasIndex: true, failed: state.failed, hasRows: true)
                == "The catalog could not be read. Showing what was read before.")
        await state.run(key(1), loaded: true) { [row(1, owned: 2, total: 4)] }
        #expect(!state.failed && state.rows == [row(1, owned: 2, total: 4)])
    }

    // MARK: The catalog line

    @Test func theNoteSaysWhatTheCatalogCannotGiveYet() {
        #expect(SetsScreenState.note(catalogSettled: false, hasIndex: true, failed: false, hasRows: true)
                == "The catalog is still downloading. Sets come when it is ready.")
        #expect(SetsScreenState.note(catalogSettled: false, hasIndex: false, failed: false, hasRows: false)
                == "The catalog is still downloading. Sets come when it is ready.")
        #expect(SetsScreenState.note(catalogSettled: true, hasIndex: false, failed: false, hasRows: false)
                == "The catalog has no sets of this game yet.")
        #expect(SetsScreenState.note(catalogSettled: true, hasIndex: false, failed: true, hasRows: false)
                == "The catalog could not be read.")
        #expect(SetsScreenState.note(catalogSettled: true, hasIndex: true, failed: false, hasRows: true) == nil)
    }

    // MARK: The rows

    /// F1, F6 from a snapshot of the game's prices (`GamePrices`, a value): the priced finishes are the targets, and a
    /// missing target's own price goes into the sum.
    @Test func rowsComeFromAPriceSnapshot() {
        let prices = GamePrices(day: "2026-11-16", finishes: ["Normal", "Foil"],
                                rows: [1: [0: Price(market: 2, low: nil, mid: nil, high: nil),
                                           1: Price(market: 5, low: nil, mid: nil, high: nil)],
                                       2: [1: Price(market: nil, low: 0.5, mid: nil, high: nil)]])
        #expect(prices.shown(key: PrintingKey(productID: 2, finish: "Foil")) == ShownPrice(amount: 0.5, isLow: true))
        #expect(prices.prices(productID: 1).map(\.finish) == ["Normal", "Foil"])
        let set = SetRecord(groupID: 7, gameID: "riftbound", name: "Seven", abbreviation: "SVN", publishedOn: nil)
        let rows = SetsScreenState.rows(sets: [set], index: SetIndex(sets: [7: [1, 2, 3]]),
                                        rows: [CollectionRow(productID: 1, finish: "Normal", count: 1, condition: "", name: "A")],
                                        prices: prices)
        // Targets: 1 Normal (owned), 1 Foil ($5), 2 Foil (~$0.50), 3 Normal (no price).
        #expect(rows == [SetRow(set: set, numbers: SetNumbers(owned: 1, total: 4, missingSum: 5.5, missingUnpriced: 1))])
        // No prices at all: every product is one Normal target.
        let bare = SetsScreenState.rows(sets: [set], index: SetIndex(sets: [7: [1, 2, 3]]), rows: [], prices: nil)
        #expect(bare.first?.numbers == SetNumbers(owned: 0, total: 3, missingSum: nil, missingUnpriced: 3))
    }

    /// The whole path on a real store: the folder's rows, the store's sets and the model's index; the key changes when the
    /// index arrives, so the rows are made again then.
    @Test func rowsAreMadeFromTheModel() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: [product(id: 1, number: "1"), product(id: 2, number: "2")])
        let user = root.appending(path: "user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "collection": [{"productID": 2, "finish": "Normal", "count": 3, "condition": "", "name": "B"}]}"#.utf8)
            .write(to: user.appending(path: "riftbound.json"))
        let model = AppModel(options: LaunchOptions(arguments: ["app", "-store", root.path, "-offline", "YES"]),
                             catalogClient: FakeCatalog(groups: Data(), products: Data()), archiveClient: FakeArchive(),
                             fetcher: FakeFetcher())
        let before = SetsKey.of(game: "riftbound", model: model)
        await model.start()
        await model.waitForSetIndexes()
        await model.library.flush()
        #expect(model.setIndexes["riftbound"] != nil)
        let key = SetsKey.of(game: "riftbound", model: model)
        #expect(key.setIndexVersion != before.setIndexVersion)
        let state = SetsScreenState(gameID: "riftbound")
        await state.makeRows(key, model: model)
        #expect(state.rows?.map(\.numbers) == [SetNumbers(owned: 1, total: 2, missingSum: nil, missingUnpriced: 1)])
        #expect(state.rows?.map(\.set.name) == ["Set"])
        #expect(!state.needsRows(for: key))
    }
}
