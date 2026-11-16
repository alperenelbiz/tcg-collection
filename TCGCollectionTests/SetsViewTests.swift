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
        #expect(SetsScreenState.note(catalogSettled: true, failed: state.failed, hasIndex: true, indexInWork: false, rows: state.rows)
                == "The catalog could not be read. Showing what was read before.")
        await state.run(key(1), loaded: true) { [row(1, owned: 2, total: 4)] }
        #expect(!state.failed && state.rows == [row(1, owned: 2, total: 4)])
    }

    // MARK: The catalog line

    /// Final fix A4 (Review Focus 5): the list always says why it shows nothing or old numbers, in this priority: not
    /// settled, failed, being read, being updated, no sets.
    @Test func theNoteSaysWhyInPriorityOrder() {
        let some = [row(1, owned: 1, total: 4)]
        func note(settled: Bool = true, failed: Bool = false, index: Bool = true, inWork: Bool = false,
                  rows: [SetRow]?) -> String? {
            SetsScreenState.note(catalogSettled: settled, failed: failed, hasIndex: index, indexInWork: inWork, rows: rows)
        }
        // 1. Not settled, whatever else holds.
        for failed in [false, true] {
            for index in [false, true] {
                for inWork in [false, true] {
                    #expect(note(settled: false, failed: failed, index: index, inWork: inWork, rows: index ? some : nil)
                            == "The catalog is still downloading. Sets come when it is ready.")
                }
            }
        }
        // 2. A failed read: alone without rows, "showing" with them; before the index's work.
        #expect(note(failed: true, inWork: true, rows: nil) == "The catalog could not be read.")
        #expect(note(failed: true, index: false, inWork: true, rows: nil) == "The catalog could not be read.")
        #expect(note(failed: true, inWork: true, rows: some) == "The catalog could not be read. Showing what was read before.")
        // 3. No index yet and its scan queued, running, or due at launch.
        #expect(note(index: false, inWork: true, rows: nil) == "The sets of this game are being read.")
        #expect(note(index: false, inWork: true, rows: []) == "The sets of this game are being read.")
        // 4. An index and a newer one in work: under the old rows.
        #expect(note(inWork: true, rows: some) == "Sets are being updated.")
        #expect(note(inWork: true, rows: []) == "Sets are being updated.")
        // 5. No sets: no index and none in work, or an index with no set row to list (a held catalog, a store in memory).
        #expect(note(index: false, rows: nil) == "The catalog has no sets of this game yet.")
        #expect(note(rows: []) == "The catalog has no sets of this game yet.")
        // Whole: no note; rows not made yet (loading): no note.
        #expect(note(rows: some) == nil)
        #expect(note(rows: nil) == nil)
    }

    /// A4: a first failed read (no rows yet) is no loading state: the list is empty and the sentence says why.
    @Test func aFirstFailedReadShowsNoLoadingBlocks() async {
        let state = SetsScreenState(gameID: "riftbound")
        #expect(state.listing == nil)                                                // loading
        await state.run(key(), loaded: true) { throw ReadFailed() }
        #expect(state.rows == nil && state.failed)
        #expect(state.listing == false)                                              // empty, not loading
        await state.run(key(), loaded: true) { [] }
        #expect(state.listing == false)
        await state.run(key(1), loaded: true) { [row(1, owned: 1, total: 4)] }
        #expect(state.listing == true)
    }

    /// B: a cancelled run stores nothing; a newer key's result wins over an older run that ends later.
    @Test func aCancelledRunStoresNothingAndTheNewerKeyWins() async {
        let state = SetsScreenState(gameID: "riftbound")
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let older = Task { @MainActor in
            await state.run(key(0), loaded: true) {
                start.yield()
                for await _ in gate {}
                return [row(1, owned: 0, total: 4)]
            }
        }
        var waiting = started.makeAsyncIterator()
        _ = await waiting.next()                                                    // the older run is in its making
        await state.run(key(1), loaded: true) { [row(2, owned: 2, total: 4)] }
        #expect(state.rows == [row(2, owned: 2, total: 4)])
        open.finish()
        await older.value
        // The older run ended later: its key is older, so its rows do not replace the newer ones.
        #expect(state.rows == [row(2, owned: 2, total: 4)])
        #expect(state.rowsKey == key(1))

        let cancelled = SetsScreenState(gameID: "riftbound")
        let (gate2, open2) = AsyncStream.makeStream(of: Void.self)
        let (started2, start2) = AsyncStream.makeStream(of: Void.self)
        let run = Task { @MainActor in
            await cancelled.run(key(), loaded: true) {
                start2.yield()
                for await _ in gate2 {}
                return [row(3, owned: 1, total: 4)]
            }
        }
        var waiting2 = started2.makeAsyncIterator()
        _ = await waiting2.next()
        run.cancel()
        open2.finish()
        await run.value
        #expect(cancelled.rows == nil && cancelled.rowsKey == nil && !cancelled.failed)
    }

    /// A10: the subtitle's count of all rows of the scope needs no sort.
    @Test func theScopeCountNeedsNoSort() {
        let rows = [row(1, owned: 1, total: 4), row(2, owned: 0, total: 4), row(3, owned: 4, total: 4)]
        #expect(SetMaths.count(rows, scope: .all) == 3)
        #expect(SetMaths.count(rows, scope: .mine) == 2)
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
