import Testing
@testable import TCGCollection2

@MainActor
struct CollectionViewTests {
    /// Final fix A6: what the Collection lists comes from its last join, and so does the catalog's settled state. The
    /// entries of a join made during a download lack the products of the step's last batch: had the screen read the live
    /// state (settled as soon as the step ended), such a row would open the "not in the catalog any more" page until the
    /// next join ended. It stays pending until a join on the settled catalog has read it.
    @Test func theListUsesTheSettledStateOfItsOwnJoin() throws {
        let rows = [CollectionRow(productID: 1, finish: "Normal", count: 1, condition: "", name: "Calm Rune"),
                    CollectionRow(productID: 2, finish: "Normal", count: 2, condition: "", name: "Last Batch")]
        let state = CollectionScreenState(gameID: "riftbound")
        #expect(state.content(rows: rows) == nil)                                    // no join has ended yet

        // A join made during the download: product 2 was not in yet.
        let entries = CollectionList.entries(rows: rows, products: [1: product(id: 1, name: "Calm Rune")], setNames: [:]) { _ in nil }
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 3, priceDay: nil, catalogSettled: false)
        state.join.catalogHasProducts = true
        state.join.entries = entries
        let during = try #require(state.content(rows: rows))
        #expect(!during.settled && during.note == CollectionList.catalogDownloading)
        #expect(during.link(for: entries[0]) == .card && during.link(for: entries[1]) == .none)

        // The join on the settled catalog found product 2 as well: nothing is pending.
        let settledEntries = CollectionList.entries(rows: rows, products: [1: product(id: 1, name: "Calm Rune"),
                                                                           2: product(id: 2, name: "Last Batch")],
                                                    setNames: [:]) { _ in nil }
        state.join.joined = CollectionJoin(game: "riftbound", libraryVersion: 1, catalogVersion: 4, priceDay: nil, catalogSettled: true)
        state.join.entries = settledEntries
        let after = try #require(state.content(rows: rows))
        #expect(after.settled && after.note == nil && settledEntries.allSatisfy { after.link(for: $0) == .card })

        // A settled join that still lacks a product: that row has left the catalog.
        state.join.entries = entries
        #expect(state.content(rows: rows)?.link(for: entries[1]) == .unknownPrinting)
    }

    /// Feedback 1: "Clear" stands in the Collection's toolbar while `filtersOn` is over 0. The search text is not a filter.
    @Test func filtersOnCountsTheFourMenusAndClearResetsThem() {
        let state = CollectionScreenState(gameID: "riftbound")
        state.text = "rune"
        #expect(state.filtersOn == 0)
        state.rarity = "Showcase"
        #expect(state.filtersOn == 1)
        state.groupID = 24344
        state.price = .from5
        state.playset = .moreThanAPlayset
        #expect(state.filtersOn == 4)
        state.clearFilters()
        #expect(state.filtersOn == 0)
        #expect(state.groupID == nil && state.rarity == nil && state.price == .any && state.playset == .any)
        #expect(state.text == "rune")
    }
}
