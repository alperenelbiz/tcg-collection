import Foundation
import Testing
@testable import TCGCollection2

/// A set's page (phase 4A task 4, A26, F8): its targets in card-number order, a cell's label and left text, the filters
/// and their sentences, a product the read lacks (F5), the faded cell, and the products read once per key.
@MainActor
struct SetPageViewTests {
    /// The index's order (card-number order, F4): 1 (Normal, Foil), 2 (no price: Normal), 3 (Normal, Foil).
    private var read: [Int: ProductRecord] { [
        1: product(id: 1, name: "Alpha", number: "001"),
        2: product(id: 2, name: "Beta Rune", number: "002"),
        3: product(id: 3, name: "Gamma", number: "010"),
    ] }

    private var prices: GamePrices { GamePrices(day: "2026-11-16", finishes: ["Normal", "Foil"],
                                    rows: [1: [0: Price(market: 1, low: nil, mid: nil, high: nil),
                                               1: Price(market: 4, low: nil, mid: nil, high: nil)],
                                           3: [0: Price(market: 2, low: nil, mid: nil, high: nil),
                                               1: Price(market: nil, low: 0.5, mid: nil, high: nil)]]) }

    private func priced(_ id: Int) -> [String] { prices.prices(productID: id).map(\.finish) }

    private func row(_ id: Int, _ finish: String, _ count: Int) -> CollectionRow {
        CollectionRow(productID: id, finish: finish, count: count, condition: "", name: "x")
    }

    private func keys(_ cells: [SetCell]) -> [String] { cells.map { "\($0.product.productID) \($0.finish)" } }

    // MARK: The targets

    /// Card-number order is the index's; a printing's finishes side by side in the finishes' order (F1); an owned finish
    /// the price table lacks is a target too (Review Focus 1).
    @Test func theTargetsAreInCardNumberOrderWithTheFinishesSideBySide() {
        let owned = SetOwned(rows: [row(2, "Foil", 1)])
        let cells = SetPage.cells(products: [1, 2, 3], read: read, owned: owned, priced: priced)
        #expect(keys(cells) == ["1 Normal", "1 Foil", "2 Normal", "2 Foil", "3 Normal", "3 Foil"])
    }

    /// F5: a product id of the index that the read lacks is skipped, and the subtitle counts the page's targets.
    @Test func aProductTheReadLacksIsSkipped() {
        let owned = SetOwned(rows: [])
        let cells = SetPage.cells(products: [1, 99, 3], read: read, owned: owned, priced: priced)
        #expect(keys(cells) == ["1 Normal", "1 Foil", "3 Normal", "3 Foil"])
        let numbers = SetPage.numbers(products: [1, 99, 3], read: read, owned: owned, priced: priced,
                                      price: { prices.shown(key: $0) })
        #expect(numbers == SetNumbers(owned: 0, total: 4, missingSum: 7.5, missingUnpriced: 0))
    }

    /// F2: owned at a count of 1 or more, by the rule of the Sets list (`SetMaths.rows`): a row under 1 is not owned.
    @Test func theOwnedCountsFollowTheListsRule() {
        let owned = SetOwned(rows: [row(1, "Normal", 2), row(3, "Foil", 0), row(2, "Normal", 1)])
        #expect(owned.count(PrintingKey(productID: 1, finish: "Normal")) == 2)
        #expect(owned.count(PrintingKey(productID: 3, finish: "Foil")) == 0)
        #expect(owned.finishes(of: 3) == [])
        #expect(owned.finishes(of: 1) == ["Normal"])
        let numbers = SetPage.numbers(products: [1, 2, 3], read: read, owned: owned, priced: priced,
                                      price: { prices.shown(key: $0) })
        #expect(numbers == SetNumbers(owned: 2, total: 5, missingSum: 6.5, missingUnpriced: 0))
        // The list's numbers of the same set agree.
        let set = SetRecord(groupID: 7, gameID: "riftbound", name: "Seven", abbreviation: "SVN", publishedOn: nil)
        let listed = SetsScreenState.rows(sets: [set], index: SetIndex(sets: [7: [1, 2, 3]]),
                                          rows: [row(1, "Normal", 2), row(3, "Foil", 0), row(2, "Normal", 1)], prices: prices)
        #expect(listed.first?.numbers == numbers)
        #expect(SetMaths.pageSubtitle(numbers) == "2 of 5 · $6.50 to complete")
    }

    // MARK: A cell

    @Test func theLabelAndLeftTextOfAnOwnedAndAMissingTarget() {
        let shown = ShownPrice(amount: 4, isLow: false)
        #expect(SetPage.label(name: "Alpha", count: 2, finish: "Normal", price: ShownPrice(amount: 1, isLow: false))
                == "Alpha, ×2, $1.00")
        #expect(SetPage.label(name: "Alpha", count: 1, finish: "Foil", price: shown) == "Alpha, ×1, Foil, $4.00")
        #expect(SetPage.label(name: "Alpha", count: 0, finish: "Foil", price: shown) == "Alpha, missing, Foil, $4.00")
        #expect(SetPage.label(name: "Beta Rune", count: 0, finish: "Normal", price: nil) == "Beta Rune, missing, no price")
        #expect(SetMaths.leftText(count: 2, finish: "Foil") == "×2 · Foil")
        #expect(SetMaths.leftText(count: 0, finish: "Foil") == "Foil")
        #expect(SetMaths.leftText(count: 0, finish: "Normal") == "")
        #expect(SetPage.isFaded(count: 0) && !SetPage.isFaded(count: 1))
    }

    /// The faded state of `CardCell` (spec 5.7): the picture and the texts at `Theme.fadedOpacity`, 0.35; else whole.
    @Test func aFadedCellIsDrawnAtTheFadedOpacity() {
        #expect(Theme.fadedOpacity == 0.35)
        #expect(CardCell.contentOpacity(faded: true) == Theme.fadedOpacity)
        #expect(CardCell.contentOpacity(faded: false) == 1)
    }

    // MARK: Filters and the search

    @Test func theThreeFiltersAndTheSearch() {
        let owned = SetOwned(rows: [row(1, "Foil", 1)])
        let cells = SetPage.cells(products: [1, 2, 3], read: read, owned: owned, priced: priced)
        #expect(keys(SetPage.shown(cells, filter: .all, text: "", owned: owned)) == keys(cells))
        #expect(keys(SetPage.shown(cells, filter: .owned, text: "", owned: owned)) == ["1 Foil"])
        #expect(keys(SetPage.shown(cells, filter: .missing, text: "", owned: owned))
                == ["1 Normal", "2 Normal", "3 Normal", "3 Foil"])
        // The product's name, every folded word.
        #expect(keys(SetPage.shown(cells, filter: .all, text: "rune BETA", owned: owned)) == ["2 Normal"])
        #expect(keys(SetPage.shown(cells, filter: .missing, text: "alpha", owned: owned)) == ["1 Normal"])
        #expect(SetPage.shown(cells, filter: .owned, text: "gamma", owned: owned).isEmpty)
    }

    @Test func theEmptySentences() {
        #expect(SetPage.emptySentence(filter: .missing, text: "") == "This set is complete.")
        #expect(SetPage.emptySentence(filter: .owned, text: "") == "No card of this set in your collection yet.")
        #expect(SetPage.emptySentence(filter: .owned, text: "zzz") == "No card matches \"zzz\".")
        #expect(SetPage.emptySentence(filter: .all, text: "zzz") == "No card matches \"zzz\".")
        #expect(SetPage.emptySentence(filter: .missing, text: " ? ") == "This set is complete.")   // no word: no search
    }

    // MARK: The read

    private func key(catalog: Int = 3, index: Int = 1, group: Int = 7) -> SetPageKey {
        SetPageKey(game: "riftbound", groupID: group, catalogVersion: catalog, setIndexVersion: index)
    }

    private struct ReadFailed: Error {}

    @Test func theProductsAreReadOncePerKey() async {
        let state = SetPageState(gameID: "riftbound", groupID: 7)
        var reads = 0
        await state.run(key()) { reads += 1; return read }
        await state.run(key()) { reads += 1; return read }
        #expect(reads == 1 && state.products == read)
        #expect(state.needsRead(for: key(catalog: 4)))
        #expect(state.needsRead(for: key(index: 2)))
        await state.run(key(catalog: 4)) { throw ReadFailed() }
        #expect(state.failed && state.products == read)                    // the last read is kept
        #expect(state.needsRead(for: key(catalog: 4)))                     // and tried again
        #expect(SetPage.note(catalogSettled: true, failed: true, hasProducts: true)
                == "The catalog could not be read. Showing what was read before.")
        #expect(SetPage.note(catalogSettled: true, failed: true, hasProducts: false) == "The catalog could not be read.")
        #expect(SetPage.note(catalogSettled: false, failed: false, hasProducts: true)
                == "The catalog is still downloading. Cards come when it is ready.")
        #expect(SetPage.note(catalogSettled: true, failed: false, hasProducts: true) == nil)
    }

    /// The window keeps one page state per set with the list's state, so the filter and the text survive Back and a
    /// sidebar switch.
    @Test func theListKeepsOnePageStatePerSet() {
        let list = SetsScreenState(gameID: "riftbound")
        let page = list.page(7)
        page.filter = .missing
        page.text = "alpha"
        #expect(list.page(7) === page)
        #expect(list.page(8) !== page)
    }

    /// The whole read on a real store: the index's products through `reader`.
    @Test func theProductsComeFromTheReader() async throws {
        let root = tempRoot()
        let paths = AppPaths(root: root)
        try await writeClosedStore(at: paths.catalogStore, products: [product(id: 1, number: "2"), product(id: 2, number: "1")])
        let model = AppModel(options: LaunchOptions(arguments: ["app", "-store", root.path, "-offline", "YES"]),
                             catalogClient: FakeCatalog(groups: Data(), products: Data()), archiveClient: FakeArchive(),
                             fetcher: FakeFetcher())
        await model.start()
        await model.waitForSetIndexes()
        let index = try #require(model.setIndexes["riftbound"])
        let group = try #require(index.sets.keys.first)
        #expect(index.products(of: group) == [2, 1])
        let state = SetPageState(gameID: "riftbound", groupID: group)
        let key = SetPageKey.of(game: "riftbound", groupID: group, model: model)
        await state.read(key, model: model)
        #expect(state.products.map { Set($0.keys) } == [1, 2])
        #expect(!state.needsRead(for: key))
    }
}
